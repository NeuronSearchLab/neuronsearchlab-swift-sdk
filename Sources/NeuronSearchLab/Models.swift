import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct NeuronID: Codable, Hashable, Sendable, CustomStringConvertible,
  ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
  public let value: String

  public init(_ value: String) {
    self.value = value
  }

  public init(_ value: Int) {
    self.value = String(value)
  }

  public init(stringLiteral value: String) {
    self.value = value
  }

  public init(integerLiteral value: Int) {
    self.value = String(value)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let string = try? container.decode(String.self) {
      value = string
    } else if let int = try? container.decode(Int.self) {
      value = String(int)
    } else if let double = try? container.decode(Double.self) {
      value = String(double)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "NeuronID must be a string or number"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }

  public var description: String {
    value
  }

  var normalized: String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public protocol HTTPDataLoading: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataLoading {}

public struct SDKConfig: Sendable {
  public var baseURL: String
  public var accessToken: String
  public var timeoutSeconds: TimeInterval
  public var maxRetries: Int
  public var urlSession: any HTTPDataLoading
  public var collateWindowSeconds: TimeInterval
  public var maxBatchSize: Int
  public var maxBufferedEvents: Int
  public var maxEventRetries: Int
  public var disableArrayBatching: Bool
  public var propagateRecommendationRequestId: Bool
  public var sessionId: String?
  public var autoSessionId: Bool

  public init(
    baseURL: String,
    accessToken: String,
    timeoutSeconds: TimeInterval = 10,
    maxRetries: Int = 2,
    urlSession: any HTTPDataLoading = URLSession.shared,
    collateWindowSeconds: TimeInterval = 3,
    maxBatchSize: Int = 200,
    maxBufferedEvents: Int = 5_000,
    maxEventRetries: Int = 5,
    disableArrayBatching: Bool = false,
    propagateRecommendationRequestId: Bool = true,
    sessionId: String? = nil,
    autoSessionId: Bool = true
  ) {
    self.baseURL = baseURL
    self.accessToken = accessToken
    self.timeoutSeconds = timeoutSeconds
    self.maxRetries = maxRetries
    self.urlSession = urlSession
    self.collateWindowSeconds = collateWindowSeconds
    self.maxBatchSize = maxBatchSize
    self.maxBufferedEvents = maxBufferedEvents
    self.maxEventRetries = maxEventRetries
    self.disableArrayBatching = disableArrayBatching
    self.propagateRecommendationRequestId = propagateRecommendationRequestId
    self.sessionId = sessionId
    self.autoSessionId = autoSessionId
  }
}

public struct TrackEventPayload: Sendable {
  public var eventId: Int?
  public var userId: NeuronID?
  public var itemId: Int?
  public var contextId: Int?
  public var occurredAt: Int?
  public var requestId: String?
  public var sessionId: String?
  public var metadata: JSONObject?
  /// What the user searched for. With no `itemId` this is a search event:
  /// `eventId` becomes optional and defaults to the event your `search`
  /// signal is bound to. With an `itemId`, the query is kept on the item
  /// event as the search the user reached it from.
  public var query: String?
  /// Item ids your own search engine showed for `query`, in rank order.
  public var resultItemIds: [Int]?
  public var additionalFields: JSONObject

  public init(
    eventId: Int? = nil,
    userId: NeuronID? = nil,
    itemId: Int? = nil,
    contextId: Int? = nil,
    occurredAt: Int? = nil,
    requestId: String? = nil,
    sessionId: String? = nil,
    metadata: JSONObject? = nil,
    query: String? = nil,
    resultItemIds: [Int]? = nil,
    additionalFields: JSONObject = [:]
  ) {
    self.eventId = eventId
    self.userId = userId
    self.itemId = itemId
    self.contextId = contextId
    self.occurredAt = occurredAt
    self.requestId = requestId
    self.sessionId = sessionId
    self.metadata = metadata
    self.query = query
    self.resultItemIds = resultItemIds
    self.additionalFields = additionalFields
  }

  func normalized(now: Date = Date()) throws -> JSONObject {
    let userIdValue = userId?.normalized
    let queryValue = normalizeOptionalString(query)
    let isSearch = itemId == nil && queryValue != nil

    guard let userIdValue else {
      throw SDKClientError.validation(
        isSearch
          ? "userId is required"
          : "eventId must be a non-zero integer, itemId must be a positive integer, and userId is required (or send query without itemId for a search event)"
      )
    }
    if isSearch {
      if let eventId, eventId == 0 {
        throw SDKClientError.validation("eventId must be a non-zero integer when provided")
      }
    } else {
      guard let itemId, itemId > 0, let eventId, eventId != 0 else {
        throw SDKClientError.validation("eventId must be a non-zero integer, itemId must be a positive integer, and userId is required (or send query without itemId for a search event)")
      }
    }
    if let resultItemIds {
      guard isSearch else {
        throw SDKClientError.validation("resultItemIds is only accepted on a search event: a query without itemId")
      }
      try validateResultItemIds(resultItemIds)
    }
    if let contextId, contextId <= 0 {
      throw SDKClientError.validation("contextId must be a positive integer when provided")
    }

    var payload = additionalFields
    if let metadata {
      payload["metadata"] = .object(metadata)
    }
    if let requestId = normalizeOptionalString(requestId) {
      payload["request_id"] = .string(requestId)
    }
    if let sessionId = normalizeOptionalString(sessionId) {
      payload["session_id"] = .string(sessionId)
    }

    payload["user_id"] = .string(userIdValue)
    if let itemId { payload["item_id"] = .int(itemId) }
    if let eventId { payload["event_id"] = .int(eventId) }
    if let queryValue { payload["query"] = .string(queryValue) }
    if let resultItemIds { payload["result_item_ids"] = .array(resultItemIds.map { .int($0) }) }
    if let contextId { payload["context_id"] = .int(contextId) }
    payload["occurred_at"] = .int(occurredAt ?? Int(floor(now.timeIntervalSince1970)))
    return payload
  }
}

func validateResultItemIds(_ ids: [Int]) throws {
  guard ids.allSatisfy({ $0 > 0 }) else {
    throw SDKClientError.validation("resultItemIds must contain positive integer item ids returned by NSL")
  }
}

public struct ItemUpsertPayload: Sendable {
  public var name: String?
  public var description: String?
  public var metadata: JSONObject?
  public var additionalFields: JSONObject

  public init(
    name: String? = nil,
    description: String? = nil,
    metadata: JSONObject? = nil,
    additionalFields: JSONObject = [:]
  ) {
    self.name = name
    self.description = description
    self.metadata = metadata
    self.additionalFields = additionalFields
  }

  func normalized() throws -> JSONObject {
    var payload = additionalFields
    if let name {
      payload["name"] = .string(name)
    }
    if let description {
      payload["description"] = .string(description)
    }
    if let metadata {
      payload["metadata"] = .object(metadata)
    }
    return payload
  }
}

public struct PatchItemInput: Sendable {
  public var itemId: Int
  public var active: Bool?
  public var additionalFields: JSONObject

  public init(
    itemId: Int,
    active: Bool? = nil,
    additionalFields: JSONObject = [:]
  ) {
    self.itemId = itemId
    self.active = active
    self.additionalFields = additionalFields
  }

  func patchPayload() throws -> JSONObject {
    guard itemId > 0 else {
      throw SDKClientError.validation("itemId is required and must be a positive integer returned by NSL")
    }

    var payload = additionalFields
    if let active {
      payload["active"] = .bool(active)
    }
    if payload.isEmpty {
      throw SDKClientError.validation("patchItem requires at least one field to update")
    }
    return payload
  }
}

public struct DeleteItemInput: Sendable {
  public var itemId: Int

  public init(itemId: Int) {
    self.itemId = itemId
  }
}

public struct RecommendationOptions: Sendable {
  public var userId: NeuronID
  public var contextId: Int?
  public var scope: JSONObject?
  public var limit: Int?
  public var startingAfter: String?

  public init(
    userId: NeuronID,
    contextId: Int? = nil,
    scope: JSONObject? = nil,
    limit: Int? = nil,
    startingAfter: String? = nil
  ) {
    self.userId = userId
    self.contextId = contextId
    self.scope = scope
    self.limit = limit
    self.startingAfter = startingAfter
  }
}

public struct AutoRecommendationsOptions: Sendable {
  public var userId: NeuronID
  public var contextId: Int?
  public var scope: JSONObject?
  public var limit: Int?
  public var cursor: String?
  public var windowDays: Int?
  public var candidateLimit: Int?
  public var servedCap: Int?

  public init(
    userId: NeuronID,
    contextId: Int? = nil,
    scope: JSONObject? = nil,
    limit: Int? = nil,
    cursor: String? = nil,
    windowDays: Int? = nil,
    candidateLimit: Int? = nil,
    servedCap: Int? = nil
  ) {
    self.userId = userId
    self.contextId = contextId
    self.scope = scope
    self.limit = limit
    self.cursor = cursor
    self.windowDays = windowDays
    self.candidateLimit = candidateLimit
    self.servedCap = servedCap
  }
}

public struct SearchStructuredFilter: Codable, Equatable, Sendable {
  public var column: String
  public var `operator`: String
  public var value: JSONValue
  public var logic: String?

  public init(
    column: String,
    operator: String,
    value: JSONValue,
    logic: String? = nil
  ) {
    self.column = column
    self.operator = `operator`
    self.value = value
    self.logic = logic
  }
}

public enum SearchFilters: Sendable {
  case string(String)
  case strings([String])
  case structured([SearchStructuredFilter])
}

public struct SearchOptions: Sendable {
  public var query: String
  public var userId: NeuronID?
  public var contextId: Int?
  public var limit: Int?
  public var filters: SearchFilters?
  public var scope: JSONValue?
  public var queryRetrievalEnabled: Bool?
  public var fusionMethod: String?
  public var semanticWeight: Double?
  public var keywordWeight: Double?
  public var keywordFields: [String]?
  public var requestId: String?
  public var debug: Bool?
  public var explain: String?
  public var includeSuppressed: Bool?
  /// Your own engine ran `query` and showed these item ids, in rank order.
  /// NSL records the search with them and returns recommendations that
  /// complement them; these ids are left out of the response.
  public var resultItemIds: [Int]?

  public init(
    query: String,
    userId: NeuronID? = nil,
    contextId: Int? = nil,
    limit: Int? = nil,
    filters: SearchFilters? = nil,
    scope: JSONValue? = nil,
    queryRetrievalEnabled: Bool? = nil,
    fusionMethod: String? = nil,
    semanticWeight: Double? = nil,
    keywordWeight: Double? = nil,
    keywordFields: [String]? = nil,
    requestId: String? = nil,
    debug: Bool? = nil,
    explain: String? = nil,
    includeSuppressed: Bool? = nil,
    resultItemIds: [Int]? = nil
  ) {
    self.query = query
    self.resultItemIds = resultItemIds
    self.userId = userId
    self.contextId = contextId
    self.limit = limit
    self.filters = filters
    self.scope = scope
    self.queryRetrievalEnabled = queryRetrievalEnabled
    self.fusionMethod = fusionMethod
    self.semanticWeight = semanticWeight
    self.keywordWeight = keywordWeight
    self.keywordFields = keywordFields
    self.requestId = requestId
    self.debug = debug
    self.explain = explain
    self.includeSuppressed = includeSuppressed
  }

  func normalized() throws -> JSONObject {
    guard let query = normalizeOptionalString(query) else {
      throw SDKClientError.validation("query is required")
    }

    var payload: JSONObject = ["query": .string(query)]
    if let userId = userId?.normalized {
      payload["user_id"] = .string(userId)
    }
    if let contextId {
      guard contextId > 0 else {
        throw SDKClientError.validation("contextId must be a positive integer")
      }
      payload["context_id"] = .int(contextId)
    }
    if let limit {
      payload["limit"] = .string(String(limit))
    }
    if let requestId = normalizeOptionalString(requestId) {
      payload["request_id"] = .string(requestId)
    }
    if let resultItemIds {
      try validateResultItemIds(resultItemIds)
      payload["result_item_ids"] = .array(resultItemIds.map { .int($0) })
    }

    if let filters {
      switch filters {
      case .string(let filter):
        payload["filter"] = .string(filter)
      case .strings(let filters):
        payload["filter"] = .array(filters.map { .string($0) })
      case .structured(let filters):
        let encodedFilters = filters.map { filter in
          var object: JSONObject = [
            "column": .string(filter.column),
            "operator": .string(filter.operator),
            "value": filter.value,
          ]
          if let logic = filter.logic {
            object["logic"] = .string(logic)
          }
          return JSONValue.object(object)
        }
        payload["scope"] = .string(try jsonString(from: .object(["filters": .array(encodedFilters)])))
      }
    }

    if let scope {
      switch scope {
      case .string(let string):
        if let normalized = normalizeOptionalString(string) {
          payload["scope"] = .string(normalized)
        }
      case .object:
        payload["scope"] = .string(try jsonString(from: scope))
      case .array, .int, .double, .bool, .null:
        break
      }
    }

    if let queryRetrievalEnabled {
      payload["query_retrieval_enabled"] = .string(queryRetrievalEnabled ? "true" : "false")
    }
    if let fusionMethod {
      payload["fusion_method"] = .string(fusionMethod)
    }
    if let semanticWeight {
      payload["semantic_weight"] = .string(String(semanticWeight))
    }
    if let keywordWeight {
      payload["keyword_weight"] = .string(String(keywordWeight))
    }
    if let keywordFields {
      payload["keyword_fields"] = .string(
        keywordFields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .joined(separator: ",")
      )
    }
    if let debug {
      payload["debug"] = .bool(debug)
    }
    if let explain {
      payload["explain"] = .string(explain)
    }
    if let includeSuppressed {
      payload["include_suppressed"] = .bool(includeSuppressed)
    }

    return payload
  }
}

public struct RecommendationResource: Codable, Equatable, Sendable {
  public var raw: JSONObject

  public init(raw: JSONObject) {
    self.raw = raw
  }

  public init(from decoder: Decoder) throws {
    raw = try JSONObject(from: decoder)
  }

  public func encode(to encoder: Encoder) throws {
    try raw.encode(to: encoder)
  }

  public var id: Int? { raw["id"]?.intValue }
  public var object: String? { raw["object"]?.stringValue }
  public var itemId: Int? { raw["item_id"]?.intValue }
  public var entityId: Int? { raw["entity_id"]?.intValue }
  public var name: String? { raw["name"]?.stringValue }
  public var description: String? { raw["description"]?.stringValue }
  public var score: Double? { raw["score"]?.doubleValue }
  public var rank: Int? { raw["rank"]?.intValue }
  public var metadata: JSONObject? { raw["metadata"]?.objectValue }
  public var embedding: [Double]? { raw["embedding"]?.arrayValue?.compactMap(\.doubleValue) }

  public var item: RecommendationResource? {
    raw["item"]?.objectValue.map(RecommendationResource.init(raw:))
  }

  public var items: [RecommendationResource]? {
    raw["items"]?.arrayValue?.compactMap { value in
      value.objectValue.map(RecommendationResource.init(raw:))
    }
  }
}

public struct RecommendationsResponse: Codable, Equatable, Sendable {
  public var raw: JSONObject

  public init(raw: JSONObject) {
    self.raw = raw
  }

  public init(from decoder: Decoder) throws {
    raw = try JSONObject(from: decoder)
  }

  public func encode(to encoder: Encoder) throws {
    try raw.encode(to: encoder)
  }

  public var message: String? { raw["message"]?.stringValue }
  public var requestId: String? { raw["request_id"]?.stringValue }
  public var object: String? { raw["object"]?.stringValue }
  public var recommendations: [RecommendationResource] {
    raw["recommendations"]?.arrayValue?.compactMap { value in
      value.objectValue.map(RecommendationResource.init(raw:))
    } ?? []
  }
  public var data: [RecommendationResource]? {
    raw["data"]?.arrayValue?.compactMap { value in
      value.objectValue.map(RecommendationResource.init(raw:))
    }
  }
  public var quantity: Int? { raw["quantity"]?.intValue }
  public var limit: Int? { raw["limit"]?.intValue }
  public var hasMore: Bool? { raw["has_more"]?.boolValue }
  public var processingTimeMilliseconds: Double? { raw["processing_time_ms"]?.doubleValue }
  public var mode: String? { raw["mode"]?.stringValue }
  public var section: JSONObject? { raw["section"]?.objectValue }
  public var nextCursor: String? { raw["next_cursor"]?.stringValue }
  public var done: Bool? { raw["done"]?.boolValue }
  public var query: String? { raw["query"]?.stringValue }
  public var url: String? { raw["url"]?.stringValue }
  /// On a search: who ran it ("nsl" or "client") and whether it was recorded.
  public var search: JSONObject? { raw["search"]?.objectValue }
  /// On recommendations: how much the user's recent searches steered them.
  public var searchIntent: JSONObject? { raw["search_intent"]?.objectValue }
}

public typealias SearchResponse = RecommendationsResponse

public struct PatchItemResponse: Codable, Equatable, Sendable {
  public var raw: JSONObject

  public init(raw: JSONObject) {
    self.raw = raw
  }

  public init(from decoder: Decoder) throws {
    raw = try JSONObject(from: decoder)
  }

  public func encode(to encoder: Encoder) throws {
    try raw.encode(to: encoder)
  }

  public var id: Int? { raw["id"]?.intValue }
  public var object: String? { raw["object"]?.stringValue }
  public var message: String? { raw["message"]?.stringValue }
  public var active: Bool? { raw["active"]?.boolValue }
  public var updatedAt: Int? { raw["updated_at"]?.intValue }
  public var processingTimeMilliseconds: Double? { raw["processing_time_ms"]?.doubleValue }
}

public struct DeleteItemsResponse: Codable, Equatable, Sendable {
  public var raw: JSONObject

  public init(raw: JSONObject) {
    self.raw = raw
  }

  public init(
    message: String,
    object: String = "list",
    itemIds: [Int],
    deletedCount: Int,
    data: [JSONValue]
  ) {
    raw = [
      "message": .string(message),
      "object": .string(object),
      "itemIds": .array(itemIds.map { .int($0) }),
      "deletedCount": .int(deletedCount),
      "data": .array(data),
    ]
  }

  public init(from decoder: Decoder) throws {
    raw = try JSONObject(from: decoder)
  }

  public func encode(to encoder: Encoder) throws {
    try raw.encode(to: encoder)
  }

  public var message: String? { raw["message"]?.stringValue }
  public var object: String? { raw["object"]?.stringValue }
  public var id: Int? { raw["id"]?.intValue }
  public var itemId: Int? { raw["itemId"]?.intValue ?? raw["item_id"]?.intValue }
  public var itemIds: [Int] {
    raw["itemIds"]?.arrayValue?.compactMap(\.intValue) ??
      raw["item_ids"]?.arrayValue?.compactMap(\.intValue) ??
      []
  }
  public var deletedCount: Int? { raw["deletedCount"]?.intValue ?? raw["deleted_count"]?.intValue }
  public var data: [JSONValue]? { raw["data"]?.arrayValue }
  public var processingTimeMilliseconds: Double? { raw["processing_time_ms"]?.doubleValue }
}

func normalizeOptionalString(_ value: String?) -> String? {
  guard let value else {
    return nil
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}
