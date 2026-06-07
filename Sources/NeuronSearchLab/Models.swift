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
  public var type: String?
  public var eventType: String?
  public var eventId: NeuronID?
  public var userId: NeuronID?
  public var itemId: NeuronID?
  public var occurredAt: Int?
  public var requestId: String?
  public var sessionId: String?
  public var metadata: JSONObject?
  public var additionalFields: JSONObject

  public init(
    type: String? = nil,
    eventType: String? = nil,
    eventId: NeuronID? = nil,
    userId: NeuronID? = nil,
    itemId: NeuronID? = nil,
    occurredAt: Int? = nil,
    requestId: String? = nil,
    sessionId: String? = nil,
    metadata: JSONObject? = nil,
    additionalFields: JSONObject = [:]
  ) {
    self.type = type
    self.eventType = eventType
    self.eventId = eventId
    self.userId = userId
    self.itemId = itemId
    self.occurredAt = occurredAt
    self.requestId = requestId
    self.sessionId = sessionId
    self.metadata = metadata
    self.additionalFields = additionalFields
  }

  func normalized(now: Date = Date()) throws -> JSONObject {
    let userIdValue = userId?.normalized
    let itemIdValue = itemId?.normalized
    let typeValue = normalizeOptionalString(type) ??
      normalizeOptionalString(eventType) ??
      eventId?.normalized

    guard let userIdValue, let itemIdValue, let typeValue else {
      throw SDKClientError.validation("type, userId, and itemId are required")
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
    payload["item_id"] = .string(itemIdValue)
    payload["type"] = .string(typeValue)
    payload["occurred_at"] = .int(occurredAt ?? Int(floor(now.timeIntervalSince1970)))
    return payload
  }
}

public struct ItemUpsertPayload: Sendable {
  public var id: NeuronID?
  public var name: String?
  public var description: String?
  public var metadata: JSONObject?
  public var additionalFields: JSONObject

  public init(
    id: NeuronID? = nil,
    name: String? = nil,
    description: String? = nil,
    metadata: JSONObject? = nil,
    additionalFields: JSONObject = [:]
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.metadata = metadata
    self.additionalFields = additionalFields
  }

  func normalized() throws -> JSONObject {
    var payload = additionalFields
    if let id {
      guard let normalizedId = id.normalized else {
        throw SDKClientError.validation("item id must be a non-empty string or number")
      }
      payload["id"] = .string(normalizedId)
    }
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
  public var itemId: NeuronID
  public var active: Bool?
  public var additionalFields: JSONObject

  public init(
    itemId: NeuronID,
    active: Bool? = nil,
    additionalFields: JSONObject = [:]
  ) {
    self.itemId = itemId
    self.active = active
    self.additionalFields = additionalFields
  }

  func patchPayload() throws -> JSONObject {
    guard itemId.normalized != nil else {
      throw SDKClientError.validation("itemId is required and must be a non-empty string or number")
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
  public var itemId: NeuronID

  public init(itemId: NeuronID) {
    self.itemId = itemId
  }
}

public struct RecommendationOptions: Sendable {
  public var userId: NeuronID
  public var contextId: String?
  public var contextKey: String?
  public var scope: JSONObject?
  public var limit: Int?
  public var startingAfter: String?

  public init(
    userId: NeuronID,
    contextId: String? = nil,
    contextKey: String? = nil,
    scope: JSONObject? = nil,
    limit: Int? = nil,
    startingAfter: String? = nil
  ) {
    self.userId = userId
    self.contextId = contextId
    self.contextKey = contextKey
    self.scope = scope
    self.limit = limit
    self.startingAfter = startingAfter
  }
}

public struct AutoRecommendationsOptions: Sendable {
  public var userId: NeuronID
  public var contextId: String?
  public var contextKey: String?
  public var scope: JSONObject?
  public var limit: Int?
  public var cursor: String?
  public var windowDays: Int?
  public var candidateLimit: Int?
  public var servedCap: Int?

  public init(
    userId: NeuronID,
    contextId: String? = nil,
    contextKey: String? = nil,
    scope: JSONObject? = nil,
    limit: Int? = nil,
    cursor: String? = nil,
    windowDays: Int? = nil,
    candidateLimit: Int? = nil,
    servedCap: Int? = nil
  ) {
    self.userId = userId
    self.contextId = contextId
    self.contextKey = contextKey
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
  public var contextId: String?
  public var contextKey: String?
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

  public init(
    query: String,
    userId: NeuronID? = nil,
    contextId: String? = nil,
    contextKey: String? = nil,
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
    includeSuppressed: Bool? = nil
  ) {
    self.query = query
    self.userId = userId
    self.contextId = contextId
    self.contextKey = contextKey
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
    if let contextId = normalizeOptionalString(contextId) {
      payload["context_id"] = .string(contextId)
    }
    if let contextKey = normalizeOptionalString(contextKey) {
      payload["context_key"] = .string(contextKey)
    }
    if let limit {
      payload["limit"] = .string(String(limit))
    }
    if let requestId = normalizeOptionalString(requestId) {
      payload["request_id"] = .string(requestId)
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

  public var id: String? { raw["id"]?.stringValue }
  public var object: String? { raw["object"]?.stringValue }
  public var itemId: String? { raw["item_id"]?.stringValue }
  public var entityId: String? { raw["entity_id"]?.stringValue }
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

  public var id: String? { raw["id"]?.stringValue }
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
    itemIds: [String],
    deletedCount: Int,
    data: [JSONValue]
  ) {
    raw = [
      "message": .string(message),
      "object": .string(object),
      "itemIds": .array(itemIds.map { .string($0) }),
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
  public var id: String? { raw["id"]?.stringValue }
  public var itemId: String? { raw["itemId"]?.stringValue ?? raw["item_id"]?.stringValue }
  public var itemIds: [String] {
    raw["itemIds"]?.arrayValue?.compactMap(\.stringValue) ??
      raw["item_ids"]?.arrayValue?.compactMap(\.stringValue) ??
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
