import Foundation
import XCTest
@testable import NeuronSearchLab

final class NeuronSDKTests: XCTestCase {
  func testBatchesEventsWithinCollateWindowAndPreservesOrder() async throws {
    let http = MockHTTPDataLoader { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        #"{"success":true}"#.data(using: .utf8)!
      )
    }
    let sdk = try makeSDK(
      http: http,
      collateWindowSeconds: 0.05,
      maxBatchSize: 10
    )

    let first = Task {
      try await sdk.trackEvent(
        TrackEventPayload(type: "view", userId: "u1", itemId: "i1")
      )
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    let second = Task {
      try await sdk.trackEvent(
        TrackEventPayload(type: "click", userId: "u1", itemId: "i2")
      )
    }
    _ = try await [first.value, second.value]

    let requests = http.requests
    XCTAssertEqual(requests.count, 1)
    let body = try XCTUnwrap(requests[0].httpBody)
    let events = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [[String: Any]])

    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0]["type"] as? String, "view")
    XCTAssertEqual(events[0]["user_id"] as? String, "u1")
    XCTAssertEqual(events[0]["item_id"] as? String, "i1")
    XCTAssertEqual(events[1]["type"] as? String, "click")
    XCTAssertEqual(events[1]["item_id"] as? String, "i2")
    XCTAssertNotNil(events[0]["client_ts"])
    XCTAssertNotNil(events[1]["client_ts"])
  }

  func testFlushesImmediatelyWhenMaxBatchSizeIsReached() async throws {
    let http = MockHTTPDataLoader { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        #"{"success":true}"#.data(using: .utf8)!
      )
    }
    let sdk = try makeSDK(
      http: http,
      collateWindowSeconds: 10,
      maxBatchSize: 2
    )

    async let first = sdk.trackEvent(
      TrackEventPayload(type: "view", userId: "u1", itemId: "i3")
    )
    async let second = sdk.trackEvent(
      TrackEventPayload(type: "click", userId: "u1", itemId: "i4")
    )
    _ = try await [first, second]

    let requests = http.requests
    XCTAssertEqual(requests.count, 1)
    let body = try XCTUnwrap(requests[0].httpBody)
    let events = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [[String: Any]])
    XCTAssertEqual(events.count, 2)
  }

  func testSearchPostsPayloadAndPropagatesRequestIdToNextEvent() async throws {
    let http = MockHTTPDataLoader { request in
      if request.url?.path.hasSuffix("/search") == true {
        return (
          HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!,
          """
          {
            "object":"list",
            "url":"/v1/search",
            "request_id":"66666666-6666-4666-8666-666666666666",
            "query":"fresh tech",
            "recommendations":[],
            "data":[]
          }
          """.data(using: .utf8)!
        )
      }

      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        #"{"success":true}"#.data(using: .utf8)!
      )
    }
    let sdk = try makeSDK(http: http, collateWindowSeconds: 0, maxBatchSize: 10)

    let result = try await sdk.search(
      SearchOptions(
        query: " fresh tech ",
        userId: "u1",
        contextId: "101",
        limit: 3,
        filters: .strings(["category:tech"]),
        queryRetrievalEnabled: true,
        fusionMethod: "weighted",
        semanticWeight: 0.7,
        keywordWeight: 0.3,
        keywordFields: ["name", "description"]
      )
    )

    let requestsAfterSearch = http.requests
    XCTAssertEqual(result.url, "/v1/search")
    XCTAssertEqual(requestsAfterSearch[0].url?.absoluteString, "https://api.example.com/v1/search")
    XCTAssertEqual(requestsAfterSearch[0].httpMethod, "POST")

    let searchBody = try XCTUnwrap(requestsAfterSearch[0].httpBody)
    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: searchBody) as? [String: Any])
    XCTAssertEqual(payload["query"] as? String, "fresh tech")
    XCTAssertEqual(payload["user_id"] as? String, "u1")
    XCTAssertEqual(payload["context_id"] as? String, "101")
    XCTAssertEqual(payload["limit"] as? String, "3")
    XCTAssertEqual(payload["filter"] as? [String], ["category:tech"])
    XCTAssertEqual(payload["query_retrieval_enabled"] as? String, "true")
    XCTAssertEqual(payload["fusion_method"] as? String, "weighted")
    XCTAssertEqual(payload["semantic_weight"] as? String, "0.7")
    XCTAssertEqual(payload["keyword_weight"] as? String, "0.3")
    XCTAssertEqual(payload["keyword_fields"] as? String, "name,description")

    try await sdk.trackEvent(TrackEventPayload(type: "click", userId: "u1", itemId: "item-i30"))

    let requestsAfterEvent = http.requests
    let eventBody = try XCTUnwrap(requestsAfterEvent[1].httpBody)
    let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: eventBody) as? [String: Any])
    XCTAssertEqual(event["request_id"] as? String, "66666666-6666-4666-8666-666666666666")
    XCTAssertNotNil(event["session_id"])
  }

  func testRecommendationsNormalizeBaseURLAndCaptureRequestId() async throws {
    let http = MockHTTPDataLoader { request in
      XCTAssertEqual(request.url?.path, "/v1/recommendations")
      XCTAssertEqual(request.url?.query?.contains("user_id=42"), true)
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        #"{"request_id":"rid-1","recommendations":[]}"#.data(using: .utf8)!
      )
    }
    let sdk = try makeSDK(baseURL: "https://api.example.com", http: http)

    let result = try await sdk.getRecommendations(
      RecommendationOptions(userId: 42, contextId: "homepage", limit: 5)
    )

    XCTAssertEqual(result.requestId, "rid-1")
    XCTAssertEqual(sdk.getRequestId(), "rid-1")
  }

  private func makeSDK(
    baseURL: String = "https://api.example.com/v1",
    http: MockHTTPDataLoader,
    collateWindowSeconds: TimeInterval = 0,
    maxBatchSize: Int = 200
  ) throws -> NeuronSDK {
    try NeuronSDK(
      SDKConfig(
        baseURL: baseURL,
        accessToken: "token",
        urlSession: http,
        collateWindowSeconds: collateWindowSeconds,
        maxBatchSize: maxBatchSize
      )
    )
  }
}

final class MockHTTPDataLoader: HTTPDataLoading, @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.neuronsearchlab.sdk.tests.http")
  private var capturedRequests: [URLRequest] = []
  private let handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

  init(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
    self.handler = handler
  }

  var requests: [URLRequest] {
    queue.sync {
      capturedRequests
    }
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    queue.sync {
      capturedRequests.append(request)
    }

    let response = try handler(request)
    return (response.1, response.0)
  }
}
