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

/// Where events come from, sent as `platform` on every event and shown in
/// the console. The API drops values outside the ones listed here.
public struct EventPlatform: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public static let web: EventPlatform = "web"
  public static let ios: EventPlatform = "ios"
  public static let android: EventPlatform = "android"
  public static let server: EventPlatform = "server"
  public static let magento: EventPlatform = "magento"
  public static let shopify: EventPlatform = "shopify"
  public static let woocommerce: EventPlatform = "woocommerce"
  public static let bigcommerce: EventPlatform = "bigcommerce"
  public static let prestashop: EventPlatform = "prestashop"
  public static let shopware: EventPlatform = "shopware"
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
  /// Inactivity after which an SDK-managed session id is replaced. Default
  /// 30 minutes. A `sessionId` you set yourself is never rotated.
  public var sessionTimeoutSeconds: TimeInterval
  /// The visitor's anonymous id. When nil, the SDK generates a random one
  /// and keeps it in `UserDefaults` while consent is granted.
  public var anonymousId: String?
  /// Whether the user has agreed to identifiers being stored on the device.
  /// While false nothing is read from or written to `UserDefaults`; ids live
  /// in memory only. Change it later with `NeuronSDK.setConsent(_:)`.
  public var consentGranted: Bool
  /// The `UserDefaults` suite the anonymous id is kept in, e.g. an App Group.
  /// Nil uses `UserDefaults.standard`.
  public var userDefaultsSuiteName: String?
  /// Sent as `platform` on every event. Default `.ios`; a macOS, visionOS
  /// or server host can say otherwise.
  public var platform: EventPlatform

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
    autoSessionId: Bool = true,
    sessionTimeoutSeconds: TimeInterval = 30 * 60,
    anonymousId: String? = nil,
    consentGranted: Bool = true,
    userDefaultsSuiteName: String? = nil,
    platform: EventPlatform = .ios
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
    self.sessionTimeoutSeconds = sessionTimeoutSeconds
    self.anonymousId = anonymousId
    self.consentGranted = consentGranted
    self.userDefaultsSuiteName = userDefaultsSuiteName
    self.platform = platform
  }
}

public struct TrackEventPayload: Sendable {
  public var eventId: Int?
  /// Defaults to the user set by `identify(_:)`, else the anonymous id.
  public var userId: NeuronID?
  /// Defaults to the SDK's anonymous id.
  public var anonymousId: String?
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
  /// Defaults to `SDKConfig.platform`.
  public var platform: EventPlatform?
  public var additionalFields: JSONObject

  public init(
    eventId: Int? = nil,
    userId: NeuronID? = nil,
    anonymousId: String? = nil,
    itemId: Int? = nil,
    contextId: Int? = nil,
    occurredAt: Int? = nil,
    requestId: String? = nil,
    sessionId: String? = nil,
    metadata: JSONObject? = nil,
    query: String? = nil,
    resultItemIds: [Int]? = nil,
    platform: EventPlatform? = nil,
    additionalFields: JSONObject = [:]
  ) {
    self.platform = platform
    self.eventId = eventId
    self.userId = userId
    self.anonymousId = anonymousId
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

  /// `userId` and `anonymousId` are the resolved identity the SDK sends
  /// (see `NeuronSDK.resolveIdentity`).
  func normalized(userId userIdValue: String, anonymousId anonymousIdValue: String, now: Date = Date()) throws -> JSONObject {
    let queryValue = normalizeOptionalString(query)
    let isSearch = itemId == nil && queryValue != nil

    if isSearch {
      if let eventId, eventId == 0 {
        throw SDKClientError.validation("eventId must be a non-zero integer when provided")
      }
    } else {
      guard let itemId, itemId > 0, let eventId, eventId != 0 else {
        throw SDKClientError.validation("eventId must be a non-zero integer and itemId must be a positive integer (or send query without itemId for a search event)")
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
    if normalizeOptionalString(anonymousId) != nil || payload["anonymous_id"] == nil {
      payload["anonymous_id"] = .string(anonymousIdValue)
    }
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
  /// Defaults to the user set by `identify(_:)`, else the anonymous id.
  public var userId: NeuronID?
  public var contextId: Int?
  public var scope: JSONObject?
  public var limit: Int?
  public var startingAfter: String?

  public init(
    userId: NeuronID? = nil,
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
  /// Defaults to the user set by `identify(_:)`, else the anonymous id.
  public var userId: NeuronID?
  public var contextId: Int?
  public var scope: JSONObject?
  public var limit: Int?
  public var cursor: String?
  public var windowDays: Int?
  public var candidateLimit: Int?
  public var servedCap: Int?

  public init(
    userId: NeuronID? = nil,
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

/// One rail of a page, for `NeuronSDK.getRecommendationSets(_:)`.
public struct RecommendationSetRequest: Sendable {
  /// Your name for the set, unique within the call; results come back under it.
  public var key: String
  public var contextId: Int
  public var limit: Int?
  /// Seed item for a "more like this" rail.
  public var itemId: Int?
  public var cartItemIds: [Int]
  public var pageType: String?
  /// Filter shorthand, e.g. `category:shoes`.
  public var filters: [String]
  public var scope: JSONObject?
  /// Turns this set into a search.
  public var query: String?

  public init(
    key: String,
    contextId: Int,
    limit: Int? = nil,
    itemId: Int? = nil,
    cartItemIds: [Int] = [],
    pageType: String? = nil,
    filters: [String] = [],
    scope: JSONObject? = nil,
    query: String? = nil
  ) {
    self.key = key
    self.contextId = contextId
    self.limit = limit
    self.itemId = itemId
    self.cartItemIds = cartItemIds
    self.pageType = pageType
    self.filters = filters
    self.scope = scope
    self.query = query
  }

  func normalized() -> JSONValue {
    var object: JSONObject = ["key": .string(key), "context_id": .int(contextId)]
    if let limit = limit { object["limit"] = .int(limit) }
    if let itemId = itemId { object["item_id"] = .int(itemId) }
    if !cartItemIds.isEmpty { object["cart_item_ids"] = .array(cartItemIds.map(JSONValue.int)) }
    if let pageType = normalizeOptionalString(pageType) { object["page_type"] = .string(pageType) }
    if !filters.isEmpty { object["filters"] = .array(filters.map(JSONValue.string)) }
    if let scope = scope { object["scope"] = .object(scope) }
    if let query = normalizeOptionalString(query) { object["query"] = .string(query) }
    return .object(object)
  }
}

public struct RecommendationSetsOptions: Sendable {
  /// Defaults to the user set by `identify(_:)`, else the anonymous id.
  public var userId: NeuronID?
  /// Defaults to the SDK's anonymous id.
  public var anonymousId: String?
  public var sessionId: String?
  /// Makes a retry idempotent: the same requestId bills each set once.
  /// One is generated per call when nil.
  public var requestId: String?
  public var sets: [RecommendationSetRequest]

  public init(
    userId: NeuronID? = nil,
    anonymousId: String? = nil,
    sessionId: String? = nil,
    requestId: String? = nil,
    sets: [RecommendationSetRequest]
  ) {
    self.userId = userId
    self.anonymousId = anonymousId
    self.sessionId = sessionId
    self.requestId = requestId
    self.sets = sets
  }
}

/// One set's result: a full recommendations response, or that set's own error.
public struct RecommendationSetResult: Codable, Equatable, Sendable {
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

  public var key: String { raw["key"]?.stringValue ?? "" }
  public var status: Int? { raw["status"]?.intValue }
  /// Attach this to events from this rail, not another set's.
  public var requestId: String? { raw["request_id"]?.stringValue }
  public var contextId: Int? { raw["context_id"]?.intValue }
  /// Present only when this set failed.
  public var error: JSONObject? { raw["error"]?.objectValue }
  public var isSuccess: Bool { error == nil && (status ?? 200) < 400 }
  /// The set read as an ordinary recommendations response.
  public var response: RecommendationsResponse { RecommendationsResponse(raw: raw) }
  public var data: [RecommendationResource] { response.data ?? [] }
}

public struct RecommendationSetsResponse: Equatable, Sendable {
  public var requestId: String
  /// In the order requested.
  public var results: [RecommendationSetResult]
  public var usage: JSONObject

  public init(requestId: String, results: [RecommendationSetResult], usage: JSONObject) {
    self.requestId = requestId
    self.results = results
    self.usage = usage
  }

  /// The same results keyed by `key`.
  public var sets: [String: RecommendationSetResult] {
    Dictionary(results.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
  }
}

/// The result of `NeuronSDK.identify(_:)` (`POST /v1/identify`).
public struct IdentifyResult: Codable, Equatable, Sendable {
  /// Whether the anonymous id is now linked to the user.
  public var linked: Bool
  /// How many of the anonymous id's past events moved onto the user.
  public var eventsMoved: Int
  /// Why nothing was linked, e.g. `already_identified`.
  public var reason: String?
  /// How the API is refreshing the user's recommendations after the link.
  public var embeddingRefresh: JSONValue?

  public init(linked: Bool, eventsMoved: Int, reason: String? = nil, embeddingRefresh: JSONValue? = nil) {
    self.linked = linked
    self.eventsMoved = eventsMoved
    self.reason = reason
    self.embeddingRefresh = embeddingRefresh
  }

  private enum CodingKeys: String, CodingKey {
    case linked
    case eventsMoved = "events_moved"
    case reason
    case embeddingRefresh = "embedding_refresh"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    linked = (try? container.decodeIfPresent(Bool.self, forKey: .linked)) ?? false
    eventsMoved = (try? container.decodeIfPresent(Int.self, forKey: .eventsMoved)) ?? 0
    reason = try? container.decodeIfPresent(String.self, forKey: .reason)
    embeddingRefresh = try? container.decodeIfPresent(JSONValue.self, forKey: .embeddingRefresh)
  }
}

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
