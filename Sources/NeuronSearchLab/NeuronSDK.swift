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
  /// The most recommendation sets the API serves in one batch; larger calls are split.
  public static let maxRecommendationSetsPerBatch = 8
  /// The `UserDefaults` key the anonymous id is kept under while consent is granted.
  public static let anonymousIdStorageKey = "com.neuronsearchlab.anonymous_id"
  /// Sent as `source` on `POST /v1/identify`.
  static let identifySource = "swift-sdk"
  static let defaultSessionTimeoutSeconds: TimeInterval = 30 * 60
  /// Sent as `client` on every event, so the console can show the source.
  public static let client = "swift-sdk/\(version)"

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
  /// True while the session id is the SDK's own, which rotates after inactivity.
  private var sessionManaged = false
  private var lastActivityAt: Date
  private let sessionTimeoutSeconds: TimeInterval
  private let clock: @Sendable () -> Date
  private let defaults: UserDefaults?
  private var consentGranted: Bool
  private var anonymousId: String
  /// True when the SDK generated the anonymous id (so it may persist it);
  /// false for one passed in `SDKConfig.anonymousId`.
  private var anonymousIdManaged: Bool
  private var currentUserId: String?
  private let platform: EventPlatform

  public convenience init(_ config: SDKConfig) throws {
    try self.init(config, clock: { Date() })
  }

  init(_ config: SDKConfig, clock: @escaping @Sendable () -> Date) throws {
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
    self.clock = clock
    platform = normalizeOptionalString(config.platform.rawValue).map(EventPlatform.init(rawValue:)) ?? .ios
    lastActivityAt = clock()
    sessionTimeoutSeconds = config.sessionTimeoutSeconds > 0
      ? config.sessionTimeoutSeconds
      : Self.defaultSessionTimeoutSeconds

    let store: UserDefaults?
    if let suiteName = normalizeOptionalString(config.userDefaultsSuiteName) {
      store = UserDefaults(suiteName: suiteName)
      if store == nil {
        logger.warn(
          "UserDefaults suite unavailable; keeping the anonymous id in memory",
          context: ["suiteName": .string(suiteName)]
        )
      }
    } else {
      store = UserDefaults.standard
    }
    defaults = store

    consentGranted = config.consentGranted
    let key = Self.anonymousIdStorageKey
    if let configured = normalizeOptionalString(config.anonymousId) {
      anonymousId = configured
      anonymousIdManaged = false
    } else if config.consentGranted,
              let stored = normalizeOptionalString(store?.string(forKey: key)) {
      anonymousId = stored
      anonymousIdManaged = true
    } else {
      anonymousId = Self.newIdentifier()
      anonymousIdManaged = true
    }

    if config.consentGranted {
      persistAnonymousIdLocked()
    } else {
      // Consent withheld: nothing from an earlier grant stays on the device.
      store?.removeObject(forKey: key)
    }

    if autoSessionId && currentSessionId == nil {
      startManagedSessionLocked()
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

  /// Set your own session id, which the SDK then never rotates. Pass nil to
  /// hand sessions back to the SDK (a fresh one when `autoSessionId` is on).
  public func setSessionId(_ sessionId: String?) {
    stateQueue.sync {
      if let sessionId = normalizeOptionalString(sessionId) {
        currentSessionId = sessionId
        sessionManaged = false
      } else if autoSessionId {
        startManagedSessionLocked()
      } else {
        currentSessionId = nil
        sessionManaged = false
      }
    }
  }

  /// The session id the next event will carry. An SDK-managed session idle
  /// for `sessionTimeoutSeconds` is replaced first.
  public func getSessionId() -> String? {
    stateQueue.sync {
      sessionIdLocked(recordActivity: false)
    }
  }

  /// The random install id events and recommendations fall back to as
  /// `user_id` until `identify(_:)` is called. Not an advertising id.
  public func getAnonymousId() -> String {
    stateQueue.sync {
      anonymousId
    }
  }

  /// The user set by `identify(_:)`, or nil while the visitor is anonymous.
  public func getUserId() -> String? {
    stateQueue.sync {
      currentUserId
    }
  }

  /// Tie this device's anonymous visitor to a known user, e.g. after login.
  /// `POST /v1/identify`
  ///
  /// The API moves the anonymous id's past events onto the user, so their
  /// profile follows them across web and app; sessions stay per device.
  /// Later events and recommendations default to this user. Identifying the
  /// current user again makes no request. If the request fails the SDK stays
  /// anonymous, so calling it again still links.
  @discardableResult
  public func identify(_ userId: NeuronID) async throws -> IdentifyResult {
    guard let user = userId.normalized else {
      throw SDKClientError.validation("userId must be a non-empty string or number")
    }
    let anonymous = stateQueue.sync { () -> String? in
      currentUserId == user ? nil : anonymousId
    }
    guard let anonymous else {
      return IdentifyResult(linked: false, eventsMoved: 0, reason: "already_identified")
    }

    // Send what was tracked anonymously first, so the move covers it.
    await flushEvents()

    let result: IdentifyResult = try await request(
      "/identify",
      method: "POST",
      body: .object([
        "anonymous_id": .string(anonymous),
        "user_id": .string(user),
        "source": .string(Self.identifySource),
      ])
    )
    stateQueue.sync {
      // A reset() while the request was in flight wins.
      if anonymousId == anonymous {
        currentUserId = user
      }
    }
    return result
  }

  /// Forget the current visitor, e.g. on logout: a new anonymous id
  /// (persisted while consent is granted), a new session id, no identified
  /// user and no remembered recommendation request id. Events already
  /// buffered keep the ids they were tracked with.
  public func reset() {
    stateQueue.sync {
      currentUserId = nil
      lastRecommendationRequestId = nil
      anonymousId = Self.newIdentifier()
      anonymousIdManaged = true
      persistAnonymousIdLocked()
      if autoSessionId {
        startManagedSessionLocked()
      } else {
        currentSessionId = nil
        sessionManaged = false
      }
    }
  }

  /// Grant or withdraw consent to store identifiers on the device.
  ///
  /// Granting stores the current anonymous id in `UserDefaults`. Withdrawing
  /// removes it and replaces the anonymous id and SDK-managed session id with
  /// fresh in-memory ones, so nothing from before links to what comes after.
  public func setConsent(_ granted: Bool) {
    stateQueue.sync {
      let wasGranted = consentGranted
      consentGranted = granted
      if granted {
        persistAnonymousIdLocked()
        return
      }

      defaults?.removeObject(forKey: Self.anonymousIdStorageKey)
      if wasGranted {
        anonymousId = Self.newIdentifier()
        anonymousIdManaged = true
        if sessionManaged {
          startManagedSessionLocked()
        }
      }
    }
  }

  /// Record a search your own engine ran, as an event. It weighs into the
  /// user's recommendations by the weight of your Search event, like any tap
  /// or purchase. Use `search(_:)` with `resultItemIds` when you also want
  /// NSL's recommendations back in the same call.
  @discardableResult
  public func trackSearch(
    userId: NeuronID,
    query: String,
    resultItemIds: [Int]? = nil,
    eventId: Int? = nil,
    contextId: Int? = nil,
    sessionId: String? = nil
  ) async throws -> JSONValue {
    try await recordSearch(
      userId: userId,
      query: query,
      resultItemIds: resultItemIds,
      eventId: eventId,
      contextId: contextId,
      sessionId: sessionId
    )
  }

  /// `trackSearch(userId:query:...)` for the current visitor: the user set by
  /// `identify(_:)`, else the anonymous id.
  @discardableResult
  public func trackSearch(
    query: String,
    resultItemIds: [Int]? = nil,
    eventId: Int? = nil,
    contextId: Int? = nil,
    sessionId: String? = nil
  ) async throws -> JSONValue {
    try await recordSearch(
      userId: nil,
      query: query,
      resultItemIds: resultItemIds,
      eventId: eventId,
      contextId: contextId,
      sessionId: sessionId
    )
  }

  private func recordSearch(
    userId: NeuronID?,
    query: String,
    resultItemIds: [Int]?,
    eventId: Int?,
    contextId: Int?,
    sessionId: String?
  ) async throws -> JSONValue {
    guard normalizeOptionalString(query) != nil else {
      throw SDKClientError.validation("query is required")
    }
    return try await trackEvent(TrackEventPayload(
      eventId: eventId,
      userId: userId,
      contextId: contextId,
      sessionId: sessionId,
      query: query,
      resultItemIds: resultItemIds
    ))
  }

  /// Buffer an event for `/v1/events`. `userId` defaults to the user set by
  /// `identify(_:)`, else the anonymous id; `anonymous_id` is always sent.
  @discardableResult
  public func trackEvent(_ data: TrackEventPayload) async throws -> JSONValue {
    let identity = try resolveIdentity(userId: data.userId, anonymousId: data.anonymousId)
    var payload = try data.normalized(userId: identity.userId, anonymousId: identity.anonymousId)
    payload["client_ts"] = .string(iso8601String())
    // In the body, not headers, like the JS SDK.
    payload["platform"] = .string(
      normalizeOptionalString(data.platform?.rawValue)
        ?? normalizeOptionalString(payload["platform"]?.stringValue)
        ?? platform.rawValue
    )
    payload["client"] = .string(Self.client)

    stateQueue.sync {
      if payload["request_id"] == nil,
         propagateRecommendationRequestId,
         let lastRecommendationRequestId {
        payload["request_id"] = .string(lastRecommendationRequestId)
      }

      if payload["session_id"] == nil,
         let sessionId = sessionIdLocked(recordActivity: true) {
        payload["session_id"] = .string(sessionId)
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
    let identity = try resolveIdentity(userId: options.userId)
    if let contextId = options.contextId, contextId <= 0 {
      throw SDKClientError.validation("contextId must be a positive integer")
    }

    let scope = try options.scope.map { try jsonString(from: .object($0)) }
    let response: RecommendationsResponse = try await request(
      "/recommendations",
      method: "GET",
      queryItems: [
        URLQueryItem(name: "user_id", value: identity.userId),
        URLQueryItem(name: "anonymous_id", value: identity.anonymousId),
        URLQueryItem(name: "context_id", value: options.contextId.map(String.init)),
        URLQueryItem(name: "scope", value: scope),
        URLQueryItem(name: "limit", value: options.limit.map(String.init)),
        URLQueryItem(name: "starting_after", value: normalizeOptionalString(options.startingAfter)),
      ]
    )
    captureRequestId(from: response)
    return response
  }

  /// Every recommendation rail a page needs, in one request
  /// (`POST /v1/recommendations/batch`).
  ///
  /// Each set is served and billed on its own, with its own request id for
  /// event attribution, but the visitor's state is read once for the page. A
  /// set that fails carries its own `error` without failing the others. More
  /// than `maxRecommendationSetsPerBatch` sets are sent as several batches.
  public func getRecommendationSets(
    _ options: RecommendationSetsOptions
  ) async throws -> RecommendationSetsResponse {
    if let groupId = options.groupId, groupId <= 0 {
      throw SDKClientError.validation("groupId must be a positive integer")
    }
    if options.limit != nil && options.groupId == nil {
      throw SDKClientError.validation("limit applies to a group request; give each set its own limit")
    }
    guard !options.sets.isEmpty || options.groupId != nil else {
      throw SDKClientError.validation("sets must be a non-empty array, or pass a groupId")
    }
    var keys = Set<String>()
    for set in options.sets {
      guard let key = set.key else {
        // A group request may adjust one of the group's rails without naming it.
        guard options.groupId != nil else {
          throw SDKClientError.validation("Each set needs a key outside a group request")
        }
        guard set.contextId > 0 else {
          throw SDKClientError.validation("A group rail adjustment needs a positive integer contextId")
        }
        continue
      }
      guard key.range(of: #"^[A-Za-z0-9_.:-]{1,64}$"#, options: .regularExpression) != nil else {
        throw SDKClientError.validation("Set key \"\(key)\" must match [A-Za-z0-9_.:-]{1,64}")
      }
      guard keys.insert(key).inserted else {
        throw SDKClientError.validation("Duplicate set key \"\(key)\"")
      }
      guard set.contextId > 0 else {
        throw SDKClientError.validation("Set \"\(key)\": contextId must be a positive integer")
      }
    }

    let identity = try resolveIdentity(userId: options.userId, anonymousId: options.anonymousId)
    let requestId = normalizeOptionalString(options.requestId) ?? UUID().uuidString.lowercased()
    let perBatch = NeuronSDK.maxRecommendationSetsPerBatch
    var results: [RecommendationSetResult] = []
    var usage: [String: Int] = ["sets": 0, "computed": 0, "reused": 0, "coalesced": 0]

    // The server expands a group, so a group request cannot be split here.
    let chunks: [ArraySlice<RecommendationSetRequest>] = options.groupId != nil
      ? [options.sets[...]]
      : stride(from: 0, to: options.sets.count, by: perBatch).map {
          options.sets[$0..<min($0 + perBatch, options.sets.count)]
        }

    for (index, chunk) in chunks.enumerated() {
      // Each chunk is its own batch, so each needs its own idempotency key.
      let chunkRequestId = index == 0 ? requestId : UUID().uuidString.lowercased()
      var body: JSONObject = [
        "request_id": .string(chunkRequestId),
        "user_id": .string(identity.userId),
        "anonymous_id": .string(identity.anonymousId),
        "requests": .array(chunk.map { $0.normalized() }),
      ]
      if let sessionId = normalizeOptionalString(options.sessionId) { body["session_id"] = .string(sessionId) }
      if let groupId = options.groupId { body["group_id"] = .int(groupId) }
      if let limit = options.limit { body["limit"] = .int(limit) }

      let response: JSONValue = try await request(
        "/recommendations/batch",
        method: "POST",
        body: .object(body),
        headers: ["X-Request-Id": chunkRequestId]
      )
      let object = response.objectValue ?? [:]
      results += (object["results"]?.arrayValue ?? []).compactMap { value in
        value.objectValue.map(RecommendationSetResult.init(raw:))
      }
      for (field, value) in object["usage"]?.objectValue ?? [:] {
        usage[field, default: 0] += value.intValue ?? 0
      }
    }

    return RecommendationSetsResponse(
      requestId: requestId,
      groupId: options.groupId,
      results: results,
      usage: usage.mapValues { JSONValue.int($0) }
    )
  }

  public func getAutoRecommendations(
    _ options: AutoRecommendationsOptions
  ) async throws -> RecommendationsResponse {
    let identity = try resolveIdentity(userId: options.userId)
    if let contextId = options.contextId, contextId <= 0 {
      throw SDKClientError.validation("contextId must be a positive integer")
    }

    let scope = try options.scope.map { try jsonString(from: .object($0)) }
    let response: RecommendationsResponse = try await request(
      "/recommendations",
      method: "GET",
      queryItems: [
        URLQueryItem(name: "mode", value: "auto"),
        URLQueryItem(name: "user_id", value: identity.userId),
        URLQueryItem(name: "anonymous_id", value: identity.anonymousId),
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

  /// The ids a call sends. `user_id` is the caller's, else (when the caller
  /// names another visitor's anonymous id) that id, else the identified user,
  /// else this device's anonymous id.
  private func resolveIdentity(
    userId: NeuronID?,
    anonymousId explicitAnonymousId: String? = nil
  ) throws -> (userId: String, anonymousId: String) {
    if let userId, userId.normalized == nil {
      throw SDKClientError.validation("userId must be a non-empty string or number when provided")
    }
    let explicitAnonymousId = normalizeOptionalString(explicitAnonymousId)
    return stateQueue.sync { () -> (userId: String, anonymousId: String) in
      let anonymous = explicitAnonymousId ?? anonymousId
      let user = userId?.normalized ?? explicitAnonymousId ?? currentUserId ?? anonymousId
      return (user, anonymous)
    }
  }

  /// Call on `stateQueue`. Replaces an SDK-managed session idle past the
  /// timeout; `recordActivity` marks the session as used now.
  private func sessionIdLocked(recordActivity: Bool) -> String? {
    guard sessionManaged else {
      return currentSessionId
    }
    let now = clock()
    if currentSessionId == nil || now.timeIntervalSince(lastActivityAt) >= sessionTimeoutSeconds {
      startManagedSessionLocked(now: now)
    }
    if recordActivity {
      lastActivityAt = now
    }
    return currentSessionId
  }

  /// Call on `stateQueue` (or from init).
  private func startManagedSessionLocked(now: Date? = nil) {
    sessionManaged = true
    currentSessionId = Self.newIdentifier()
    lastActivityAt = now ?? clock()
  }

  /// Call on `stateQueue` (or from init). Writes only an SDK-generated id,
  /// and only while consent is granted.
  private func persistAnonymousIdLocked() {
    guard consentGranted, anonymousIdManaged else {
      return
    }
    defaults?.set(anonymousId, forKey: Self.anonymousIdStorageKey)
  }

  private static func newIdentifier() -> String {
    UUID().uuidString.lowercased()
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
    headers: [String: String] = [:],
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
      for (name, value) in headers {
        mutableRequest.setValue(value, forHTTPHeaderField: name)
      }
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
