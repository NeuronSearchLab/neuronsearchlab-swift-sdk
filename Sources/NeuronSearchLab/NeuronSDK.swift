import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SDKClientError: Error, Equatable, LocalizedError, Sendable {
  case validation(String)
  case invalidBaseURL(String)
  case invalidURL(String)

  public var errorDescription: String? {
    switch self {
    case .validation(let message), .invalidBaseURL(let message), .invalidURL(let message):
      return message
    }
  }
}

public struct SDKHTTPError: Error, LocalizedError, Sendable {
  public let status: Int
  public let statusText: String
  public let body: JSONValue?
  public let method: String
  public let url: URL

  public var errorDescription: String? {
    "HTTP \(status) \(statusText) for \(method) \(url.absoluteString)"
  }
}

public struct SDKTimeoutError: Error, LocalizedError, Sendable {
  public let timeoutSeconds: TimeInterval

  public var errorDescription: String? {
    "Request timed out after \(timeoutSeconds) seconds"
  }
}

public final class NeuronSDK: @unchecked Sendable {
  private struct BufferedEvent {
    let payload: JSONObject
    let continuation: CheckedContinuation<JSONValue, Error>
    let enqueueTime: Date
  }

  private let stateQueue = DispatchQueue(label: "com.neuronsearchlab.sdk.state")
  private var baseURL: URL
  private var accessToken: String
  private var timeoutSeconds: TimeInterval
  private var maxRetries: Int
  private let urlSession: any HTTPDataLoading
  private var collateWindowSeconds: TimeInterval
  private var maxBatchSize: Int
  private var maxBufferedEvents: Int
  private var maxEventRetries: Int
  private var disableArrayBatching: Bool
  private var eventBuffer: [BufferedEvent] = []
  private var flushTask: Task<Void, Never>?
  private var isFlushing = false
  private var flushRetryCount = 0
  private var arrayBatchingRejected = false
  private var propagateRecommendationRequestId: Bool
  private var lastRecommendationRequestId: String?
  private var autoSessionId: Bool
  private var currentSessionId: String?

  public init(_ config: SDKConfig) throws {
    guard !config.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SDKClientError.validation("baseURL and accessToken are required")
    }

    baseURL = try Self.normalizeAPIBaseURL(config.baseURL)
    accessToken = config.accessToken
    timeoutSeconds = config.timeoutSeconds
    maxRetries = max(0, config.maxRetries)
    urlSession = config.urlSession
    collateWindowSeconds = max(0, config.collateWindowSeconds)
    maxBatchSize = max(1, config.maxBatchSize)
    maxBufferedEvents = max(1, config.maxBufferedEvents)
    maxEventRetries = max(0, config.maxEventRetries)
    disableArrayBatching = config.disableArrayBatching
    propagateRecommendationRequestId = config.propagateRecommendationRequestId
    autoSessionId = config.autoSessionId
    currentSessionId = normalizeOptionalString(config.sessionId)

    if autoSessionId && currentSessionId == nil {
      currentSessionId = UUID().uuidString
    }
  }

  deinit {
    flushTask?.cancel()
  }

  public func setAccessToken(_ token: String) {
    stateQueue.sync {
      accessToken = token
    }
  }

  public func setBaseURL(_ url: String) throws {
    let normalized = try Self.normalizeAPIBaseURL(url)
    stateQueue.sync {
      baseURL = normalized
    }
  }

  public func setTimeout(seconds: TimeInterval) {
    stateQueue.sync {
      timeoutSeconds = seconds
    }
  }

  public func setRequestId(_ requestId: String?) {
    stateQueue.sync {
      lastRecommendationRequestId = normalizeOptionalString(requestId)
    }
  }

  public func getRequestId() -> String? {
    stateQueue.sync {
      lastRecommendationRequestId
    }
  }

  public func setSessionId(_ sessionId: String?) {
    stateQueue.sync {
      currentSessionId = normalizeOptionalString(sessionId)
      if autoSessionId && currentSessionId == nil {
        currentSessionId = UUID().uuidString
      }
    }
  }

  public func getSessionId() -> String? {
    stateQueue.sync {
      currentSessionId
    }
  }

  @discardableResult
  public func trackEvent(_ data: TrackEventPayload) async throws -> JSONValue {
    var payload = try data.normalized()
    payload["client_ts"] = .string(iso8601String())

    stateQueue.sync {
      if payload["request_id"] == nil,
         propagateRecommendationRequestId,
         let lastRecommendationRequestId {
        payload["request_id"] = .string(lastRecommendationRequestId)
      }

      if payload["session_id"] == nil {
        if autoSessionId && currentSessionId == nil {
          currentSessionId = UUID().uuidString
        }
        if let currentSessionId {
          payload["session_id"] = .string(currentSessionId)
        }
      }
    }

    return try await enqueueEvent(payload)
  }

  @discardableResult
  public func createEvent(_ data: TrackEventPayload) async throws -> JSONValue {
    try await trackEvent(data)
  }

  @discardableResult
  public func upsertItem(_ data: ItemUpsertPayload) async throws -> JSONValue {
    try await upsertItems([data], sendArray: false)
  }

  @discardableResult
  public func upsertItems(_ data: [ItemUpsertPayload]) async throws -> JSONValue {
    try await upsertItems(data, sendArray: true)
  }

  @discardableResult
  public func createItem(_ data: ItemUpsertPayload) async throws -> JSONValue {
    try await upsertItem(data)
  }

  public func patchItem(_ input: PatchItemInput) async throws -> PatchItemResponse {
    let patch = try input.patchPayload()
    let itemId = input.itemId

    return try await request(
      "/items/\(Self.urlPathEncode(String(itemId)))",
      method: "POST",
      body: .object(patch)
    )
  }

  public func setItemActive(itemId: Int, active: Bool) async throws -> PatchItemResponse {
    try await patchItem(PatchItemInput(itemId: itemId, active: active))
  }

  public func deleteItems(_ items: [DeleteItemInput]) async throws -> DeleteItemsResponse {
    guard !items.isEmpty else {
      throw SDKClientError.validation("itemId is required and must be a positive integer returned by NSL")
    }

    let itemIds = try items.map { item -> Int in
      guard item.itemId > 0 else {
        throw SDKClientError.validation("itemId is required and must be a positive integer returned by NSL")
      }
      return item.itemId
    }

    var responses: [JSONValue] = []
    for itemId in itemIds {
      let response: JSONValue = try await request(
        "/items/\(Self.urlPathEncode(String(itemId)))",
        method: "DELETE"
      )
      responses.append(response)
    }

    if responses.count == 1, case .object(let object) = responses[0] {
      return DeleteItemsResponse(raw: object)
    }

    return DeleteItemsResponse(
      message: "Items deleted successfully",
      itemIds: itemIds,
      deletedCount: responses.count,
      data: responses
    )
  }

  public func deleteItems(_ item: DeleteItemInput) async throws -> DeleteItemsResponse {
    try await deleteItems([item])
  }

  public func getRecommendations(_ options: RecommendationOptions) async throws -> RecommendationsResponse {
    guard let userId = options.userId.normalized else {
      throw SDKClientError.validation("userId must be a string or number")
    }
    if let contextId = options.contextId, contextId <= 0 {
      throw SDKClientError.validation("contextId must be a positive integer")
    }

    let scope = try options.scope.map { try jsonString(from: .object($0)) }
    let response: RecommendationsResponse = try await request(
      "/recommendations",
      method: "GET",
      queryItems: [
        URLQueryItem(name: "user_id", value: userId),
        URLQueryItem(name: "context_id", value: options.contextId.map(String.init)),
        URLQueryItem(name: "scope", value: scope),
        URLQueryItem(name: "limit", value: options.limit.map(String.init)),
        URLQueryItem(name: "starting_after", value: normalizeOptionalString(options.startingAfter)),
      ]
    )
    captureRequestId(from: response)
    return response
  }

  public func getAutoRecommendations(
    _ options: AutoRecommendationsOptions
  ) async throws -> RecommendationsResponse {
    guard let userId = options.userId.normalized else {
      throw SDKClientError.validation("userId must be a string or number")
    }
    if let contextId = options.contextId, contextId <= 0 {
      throw SDKClientError.validation("contextId must be a positive integer")
    }

    let scope = try options.scope.map { try jsonString(from: .object($0)) }
    let response: RecommendationsResponse = try await request(
      "/recommendations",
      method: "GET",
      queryItems: [
        URLQueryItem(name: "mode", value: "auto"),
        URLQueryItem(name: "user_id", value: userId),
        URLQueryItem(name: "context_id", value: options.contextId.map(String.init)),
        URLQueryItem(name: "scope", value: scope),
        URLQueryItem(name: "limit", value: options.limit.map(String.init)),
        URLQueryItem(name: "cursor", value: normalizeOptionalString(options.cursor)),
        URLQueryItem(name: "window_days", value: options.windowDays.map(String.init)),
        URLQueryItem(name: "candidate_limit", value: options.candidateLimit.map(String.init)),
        URLQueryItem(name: "served_cap", value: options.servedCap.map(String.init)),
      ]
    )
    captureRequestId(from: response)
    return response
  }

  public func search(_ options: SearchOptions) async throws -> SearchResponse {
    let response: SearchResponse = try await request(
      "/search",
      method: "POST",
      body: .object(try options.normalized())
    )
    captureRequestId(from: response)
    return response
  }

  public func flushEvents() async {
    await flushEvents(cancelScheduledTask: true)
  }

  private func flushEvents(cancelScheduledTask: Bool) async {
    let shouldStart = stateQueue.sync { () -> Bool in
      if cancelScheduledTask {
        flushTask?.cancel()
      }
      flushTask = nil
      guard !isFlushing, !eventBuffer.isEmpty else {
        return false
      }
      isFlushing = true
      return true
    }

    guard shouldStart else {
      return
    }

    defer {
      stateQueue.sync {
        isFlushing = false
      }
    }

    while true {
      let batch = stateQueue.sync { () -> [BufferedEvent] in
        guard !eventBuffer.isEmpty else {
          return []
        }
        let count = min(maxBatchSize, eventBuffer.count)
        let batch = Array(eventBuffer.prefix(count))
        eventBuffer.removeFirst(count)
        return batch
      }

      if batch.isEmpty {
        break
      }

      do {
        let response = try await sendBatch(batch)
        batch.forEach { $0.continuation.resume(returning: response) }
        stateQueue.sync {
          flushRetryCount = 0
        }
      } catch {
        let retryState = stateQueue.sync { () -> (willRetry: Bool, attempt: Int, maxRetries: Int, bufferedCount: Int) in
          flushRetryCount += 1
          let attempt = flushRetryCount
          let willRetry = attempt <= maxEventRetries
          if willRetry {
            eventBuffer = batch + eventBuffer
          } else {
            flushRetryCount = 0
          }
          return (willRetry, attempt, maxEventRetries, eventBuffer.count)
        }

        let logContext: JSONObject = [
          "attempt": .int(retryState.attempt),
          "maxEventRetries": .int(retryState.maxRetries),
          "error": .string(error.localizedDescription),
          "bufferedCount": .int(retryState.bufferedCount),
        ]

        if retryState.willRetry {
          logger.warn("Failed to send events, scheduling retry", context: logContext)
          scheduleFlush(delay: backoffSeconds(retryState.attempt))
        } else {
          logger.error("Dropping events after max retries", context: logContext)
          let dropError = SDKClientError.validation("Max retries reached while sending buffered events")
          batch.forEach { $0.continuation.resume(throwing: dropError) }
        }
        break
      }
    }
  }

  private func upsertItems(_ data: [ItemUpsertPayload], sendArray: Bool) async throws -> JSONValue {
    let normalized = try data.map { try $0.normalized() }
    let payload: JSONValue
    if sendArray {
      payload = .array(normalized.map { .object($0) })
    } else {
      payload = .object(normalized[0])
    }

    return try await request("/items", method: "POST", body: payload)
  }

  private func enqueueEvent(_ payload: JSONObject) async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      var dropped: [BufferedEvent] = []
      var shouldFlush = false

      stateQueue.sync {
        dropped = trimBufferLocked(incomingCount: 1)
        eventBuffer.append(
          BufferedEvent(
            payload: payload,
            continuation: continuation,
            enqueueTime: Date()
          )
        )

        if eventBuffer.count >= maxBatchSize {
          shouldFlush = true
        }
      }

      dropped.forEach {
        $0.continuation.resume(
          throwing: SDKClientError.validation("Event dropped because the buffer exceeded maxBufferedEvents")
        )
      }

      if shouldFlush {
        Task {
          await self.flushEvents()
        }
      } else {
        scheduleFlush()
      }
    }
  }

  private func trimBufferLocked(incomingCount: Int = 0) -> [BufferedEvent] {
    let overflow = eventBuffer.count + incomingCount - maxBufferedEvents
    guard overflow > 0 else {
      return []
    }

    let dropped = Array(eventBuffer.prefix(overflow))
    eventBuffer.removeFirst(overflow)
    logger.warn(
      "Dropping buffered events due to maxBufferedEvents limit",
      context: ["maxBufferedEvents": .int(maxBufferedEvents), "dropped": .int(overflow)]
    )
    return dropped
  }

  private func scheduleFlush(delay: TimeInterval? = nil) {
    stateQueue.sync {
      if flushTask != nil, delay == nil {
        return
      }

      flushTask?.cancel()
      let waitSeconds = max(0, delay ?? collateWindowSeconds)
      flushTask = Task { [weak self] in
        let nanoseconds = UInt64(waitSeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        guard !Task.isCancelled else {
          return
        }
        await self?.flushEvents(cancelScheduledTask: false)
      }
    }
  }

  private func sendBatch(_ batch: [BufferedEvent]) async throws -> JSONValue {
    let shouldSendArray = stateQueue.sync {
      batch.count > 1 && !disableArrayBatching && !arrayBatchingRejected
    }

    if shouldSendArray {
      do {
        return try await postEvents(.array(batch.map { .object($0.payload) }))
      } catch let error as SDKHTTPError {
        stateQueue.sync {
          arrayBatchingRejected = true
        }
        logger.warn(
          "Array payload rejected, falling back to single-event sends",
          context: ["status": .int(error.status), "statusText": .string(error.statusText)]
        )
        return try await sendIndividually(batch)
      }
    }

    return try await sendIndividually(batch)
  }

  private func sendIndividually(_ batch: [BufferedEvent]) async throws -> JSONValue {
    var lastResponse = JSONValue.null
    for entry in batch {
      lastResponse = try await postEvents(.object(entry.payload))
    }
    return lastResponse
  }

  private func postEvents(_ payload: JSONValue) async throws -> JSONValue {
    try await request("/events", method: "POST", body: payload)
  }

  private func request<T: Decodable>(
    _ pathOrURL: String,
    method: String,
    queryItems: [URLQueryItem] = [],
    body: JSONValue? = nil,
    retryOn: Set<Int> = [429, 500, 502, 503, 504]
  ) async throws -> T {
    let state = stateQueue.sync {
      (
        baseURL: baseURL,
        accessToken: accessToken,
        timeoutSeconds: timeoutSeconds,
        maxRetries: maxRetries
      )
    }
    let url = try makeURL(pathOrURL, baseURL: state.baseURL, queryItems: queryItems)
    let requestId = logger.shouldLog(.debug) || logger.isPerformanceLoggingEnabled()
      ? "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
      : nil
    var attempt = 0
    let encodedBody = try body.map(jsonData(from:))
    let requestBodyForLog = encodedBody.flatMap { String(data: $0, encoding: .utf8) }

    while true {
      let mutableRequest = NSMutableURLRequest(url: url)
      mutableRequest.httpMethod = method
      mutableRequest.timeoutInterval = state.timeoutSeconds
      mutableRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      mutableRequest.setValue("Bearer \(state.accessToken)", forHTTPHeaderField: "Authorization")
      mutableRequest.httpBody = encodedBody
      let request = mutableRequest as URLRequest

      if logger.shouldLog(.debug) {
        var context: JSONObject = [
          "method": .string(method),
          "url": .string(url.absoluteString),
          "attempt": .int(attempt),
          "maxRetries": .int(state.maxRetries),
        ]
        if let requestId {
          context["requestId"] = .string(requestId)
        }
        if let requestBodyForLog {
          context["requestBody"] = .string(requestBodyForLog)
        }
        logger.debug("HTTP request attempt", context: context)
      }

      let startedAt = Date()
      do {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
          throw SDKClientError.invalidURL("Expected HTTP response from \(url.absoluteString)")
        }

        let durationMilliseconds = Date().timeIntervalSince(startedAt) * 1000
        if (200..<300).contains(httpResponse.statusCode) {
          if logger.shouldLog(.debug) {
            var context: JSONObject = [
              "method": .string(method),
              "url": .string(url.absoluteString),
              "attempt": .int(attempt),
              "status": .int(httpResponse.statusCode),
              "durationMs": .double(durationMilliseconds),
            ]
            if let requestId {
              context["requestId"] = .string(requestId)
            }
            logger.debug("HTTP response received", context: context)
          }

          let responseData = data.isEmpty ? Data("null".utf8) : data

          if logger.shouldLog(.trace),
             let responseBody = String(data: data, encoding: .utf8) {
            var context: JSONObject = [
              "method": .string(method),
              "url": .string(url.absoluteString),
              "responseBody": .string(responseBody),
            ]
            if let requestId {
              context["requestId"] = .string(requestId)
            }
            logger.trace("HTTP response payload", context: context)
          }

          return try JSONDecoder().decode(T.self, from: responseData)
        }

        let statusText = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
        let responseBody = data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)

        if logger.shouldLog(.warn) {
          var context: JSONObject = [
            "method": .string(method),
            "url": .string(url.absoluteString),
            "attempt": .int(attempt),
            "status": .int(httpResponse.statusCode),
            "statusText": .string(statusText),
            "durationMs": .double(durationMilliseconds),
          ]
          if let requestId {
            context["requestId"] = .string(requestId)
          }
          if let raw = String(data: data, encoding: .utf8) {
            context["responseBody"] = .string(raw)
          }
          logger.warn("HTTP response not OK", context: context)
        }

        if retryOn.contains(httpResponse.statusCode), attempt < state.maxRetries {
          attempt += 1
          let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
          let delaySeconds = retryAfter.flatMap(TimeInterval.init) ?? backoffSeconds(attempt)
          logger.info(
            "Retrying request after HTTP status",
            context: [
              "method": .string(method),
              "url": .string(url.absoluteString),
              "attempt": .int(attempt),
              "status": .int(httpResponse.statusCode),
              "delayMs": .double(delaySeconds * 1000),
            ]
          )
          try await sleep(seconds: delaySeconds)
          continue
        }

        throw SDKHTTPError(
          status: httpResponse.statusCode,
          statusText: statusText,
          body: responseBody,
          method: method,
          url: url
        )
      } catch let error as SDKHTTPError {
        throw error
      } catch is CancellationError {
        if attempt < state.maxRetries {
          attempt += 1
          logger.warn(
            "Retrying request after timeout",
            context: [
              "method": .string(method),
              "url": .string(url.absoluteString),
              "attempt": .int(attempt),
              "timeoutSeconds": .double(state.timeoutSeconds),
            ]
          )
          try await sleep(seconds: backoffSeconds(attempt))
          continue
        }
        throw SDKTimeoutError(timeoutSeconds: state.timeoutSeconds)
      } catch {
        if attempt < state.maxRetries {
          attempt += 1
          logger.warn(
            "Retrying request after network error",
            context: [
              "method": .string(method),
              "url": .string(url.absoluteString),
              "attempt": .int(attempt),
              "error": .string(error.localizedDescription),
            ]
          )
          try await sleep(seconds: backoffSeconds(attempt))
          continue
        }
        logger.error(
          "Request failed",
          context: [
            "method": .string(method),
            "url": .string(url.absoluteString),
            "attempts": .int(attempt),
            "error": .string(error.localizedDescription),
          ]
        )
        throw error
      }
    }
  }

  private func captureRequestId(from response: RecommendationsResponse) {
    guard let requestId = response.requestId else {
      return
    }

    stateQueue.sync {
      if propagateRecommendationRequestId {
        lastRecommendationRequestId = requestId
      }
    }
  }

  private func makeURL(
    _ pathOrURL: String,
    baseURL: URL,
    queryItems: [URLQueryItem]
  ) throws -> URL {
    let url: URL
    if let absoluteURL = URL(string: pathOrURL),
       absoluteURL.scheme?.hasPrefix("http") == true {
      url = absoluteURL
    } else {
      let path = pathOrURL.hasPrefix("/") ? String(pathOrURL.dropFirst()) : pathOrURL
      url = baseURL.appendingPathComponent(path)
    }

    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw SDKClientError.invalidURL("Invalid URL: \(url.absoluteString)")
    }
    let nonNilItems = queryItems.filter { $0.value != nil }
    if !nonNilItems.isEmpty {
      components.queryItems = (components.queryItems ?? []) + nonNilItems
    }
    guard let builtURL = components.url else {
      throw SDKClientError.invalidURL("Invalid URL: \(url.absoluteString)")
    }
    return builtURL
  }

  private static func normalizeAPIBaseURL(_ rawURL: String) throws -> URL {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
      throw SDKClientError.invalidBaseURL("baseURL and accessToken are required")
    }

    let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path.range(of: #"v\d+$"#, options: .regularExpression) == nil {
      components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1"
      if !components.path.hasPrefix("/") {
        components.path = "/" + components.path
      }
    }

    guard let url = components.url else {
      throw SDKClientError.invalidBaseURL("Invalid baseURL: \(rawURL)")
    }
    return url
  }

  private static func urlPathEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private func backoffSeconds(_ attempt: Int) -> TimeInterval {
    let base = 0.3 * pow(2.0, Double(attempt - 1))
    let jitter = Double.random(in: 0...0.2)
    return base + jitter
  }

  private func sleep(seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
  }
}
