import Foundation
import XCTest
@testable import NeuronSearchLab

final class IdentityTests: XCTestCase {
  private var suiteName = ""
  private let key = NeuronSDK.anonymousIdStorageKey

  override func setUp() {
    super.setUp()
    suiteName = "com.neuronsearchlab.tests.\(UUID().uuidString)"
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private var stored: String? {
    UserDefaults(suiteName: suiteName)?.string(forKey: key)
  }

  // MARK: Anonymous id

  func testAnonymousIdIsPersistedAndReusedWhileConsentIsGranted() throws {
    let first = try makeSDK()
    let id = first.getAnonymousId()
    XCTAssertNotNil(UUID(uuidString: id), "anonymous id should be a random UUID")
    XCTAssertEqual(stored, id)

    let second = try makeSDK()
    XCTAssertEqual(second.getAnonymousId(), id)
  }

  func testNothingIsStoredOrReadWhileConsentIsWithheld() throws {
    UserDefaults(suiteName: suiteName)?.set("left-over", forKey: key)

    let first = try makeSDK(consentGranted: false)
    XCTAssertNotEqual(first.getAnonymousId(), "left-over")
    XCTAssertNil(stored, "a stored id from an earlier grant is removed")

    let second = try makeSDK(consentGranted: false)
    XCTAssertNotEqual(second.getAnonymousId(), first.getAnonymousId())
    XCTAssertNil(stored)
  }

  func testConfiguredAnonymousIdOverridesAndIsNotStored() throws {
    UserDefaults(suiteName: suiteName)?.set("stored-id", forKey: key)
    let sdk = try makeSDK(anonymousId: " app-visitor-1 ")
    XCTAssertEqual(sdk.getAnonymousId(), "app-visitor-1")
    XCTAssertEqual(stored, "stored-id")
  }

  // MARK: Defaults on events and recommendations

  func testEventsAndRecommendationsFallBackToAnonymousIdThenIdentifiedUser() async throws {
    let http = routedLoader()
    let sdk = try makeSDK(http: http)
    let anonymousId = sdk.getAnonymousId()

    try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: 1))
    var event = try body(http.requests[0])
    XCTAssertEqual(event["user_id"] as? String, anonymousId)
    XCTAssertEqual(event["anonymous_id"] as? String, anonymousId)

    _ = try await sdk.getRecommendations(RecommendationOptions(contextId: 101))
    var query = queryItems(http.requests[1])
    XCTAssertEqual(query["user_id"], anonymousId)
    XCTAssertEqual(query["anonymous_id"], anonymousId)

    let result = try await sdk.identify("user-9")
    XCTAssertEqual(
      result,
      IdentifyResult(linked: true, eventsMoved: 3, reason: nil, embeddingRefresh: .object(["queued": .bool(true)]))
    )
    XCTAssertEqual(sdk.getUserId(), "user-9")
    let identify = http.requests[2]
    XCTAssertEqual(identify.httpMethod, "POST")
    XCTAssertEqual(identify.url?.absoluteString, "https://api.example.com/v1/identify")
    XCTAssertEqual(identify.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    let identifyBody = try body(identify)
    XCTAssertEqual(identifyBody["anonymous_id"] as? String, anonymousId)
    XCTAssertEqual(identifyBody["user_id"] as? String, "user-9")
    XCTAssertEqual(identifyBody["source"] as? String, "swift-sdk")

    try await sdk.trackSearch(query: "vans")
    event = try body(http.requests[3])
    XCTAssertEqual(event["user_id"] as? String, "user-9")
    XCTAssertEqual(event["anonymous_id"] as? String, anonymousId)
    XCTAssertEqual(event["query"] as? String, "vans")

    _ = try await sdk.getAutoRecommendations(AutoRecommendationsOptions(contextId: 101))
    query = queryItems(http.requests[4])
    XCTAssertEqual(query["user_id"], "user-9")
    XCTAssertEqual(query["anonymous_id"], anonymousId)

    _ = try await sdk.getRecommendationSets(
      RecommendationSetsOptions(sets: [RecommendationSetRequest(key: "for_you", contextId: 101)])
    )
    let sets = try body(http.requests[5])
    XCTAssertEqual(sets["user_id"] as? String, "user-9")
    XCTAssertEqual(sets["anonymous_id"] as? String, anonymousId)

    // An explicit userId still wins.
    try await sdk.trackEvent(TrackEventPayload(eventId: 42, userId: 7, itemId: 1))
    event = try body(http.requests[6])
    XCTAssertEqual(event["user_id"] as? String, "7")
    XCTAssertEqual(event["anonymous_id"] as? String, anonymousId)
  }

  func testAnEventTrackedBeforeIdentifyIsSentBeforeTheLink() async throws {
    let http = routedLoader()
    let sdk = try makeSDK(http: http, collateWindowSeconds: 60)

    let pending = Task { try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: 1)) }
    try await Task.sleep(nanoseconds: 20_000_000)
    try await sdk.identify("user-9")
    _ = try await pending.value

    XCTAssertEqual(http.requests.map { $0.url?.path }, ["/v1/events", "/v1/identify"])
  }

  func testIdentifyingTheSameUserAgainMakesNoRequest() async throws {
    let http = routedLoader()
    let sdk = try makeSDK(http: http)

    try await sdk.identify("user-9")
    let again = try await sdk.identify(" user-9 ")
    XCTAssertEqual(again, IdentifyResult(linked: false, eventsMoved: 0, reason: "already_identified"))
    XCTAssertEqual(http.requests.count, 1)

    try await sdk.identify("user-10")
    XCTAssertEqual(http.requests.count, 2)
    XCTAssertEqual(sdk.getUserId(), "user-10")
  }

  func testFailedIdentifyStaysAnonymous() async throws {
    let http = MockHTTPDataLoader { request in
      (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
    }
    let sdk = try makeSDK(http: http)

    do {
      try await sdk.identify("user-9")
      XCTFail("Expected identify to throw")
    } catch let error as SDKHTTPError {
      XCTAssertEqual(error.status, 500)
    }
    XCTAssertNil(sdk.getUserId())

    await assertThrows { try await sdk.identify("  ") }
  }

  // MARK: Reset and consent

  func testResetStartsANewAnonymousVisitor() async throws {
    let http = routedLoader()
    let sdk = try makeSDK(http: http)
    let oldAnonymousId = sdk.getAnonymousId()
    let oldSessionId = sdk.getSessionId()
    try await sdk.identify("user-9")

    sdk.reset()

    XCTAssertNil(sdk.getUserId())
    XCTAssertNotEqual(sdk.getAnonymousId(), oldAnonymousId)
    XCTAssertNotEqual(sdk.getSessionId(), oldSessionId)
    XCTAssertEqual(stored, sdk.getAnonymousId())

    try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: 1))
    let event = try body(http.requests.last!)
    XCTAssertEqual(event["user_id"] as? String, sdk.getAnonymousId())
    XCTAssertEqual(event["session_id"] as? String, sdk.getSessionId())
  }

  func testWithdrawingConsentRemovesTheStoredIdAndRotatesIds() throws {
    let sdk = try makeSDK()
    let oldAnonymousId = sdk.getAnonymousId()
    let oldSessionId = sdk.getSessionId()
    XCTAssertEqual(stored, oldAnonymousId)

    sdk.setConsent(false)
    XCTAssertNil(stored)
    XCTAssertNotEqual(sdk.getAnonymousId(), oldAnonymousId)
    XCTAssertNotEqual(sdk.getSessionId(), oldSessionId)

    sdk.reset()
    XCTAssertNil(stored, "reset while consent is withheld stays in memory")

    sdk.setConsent(true)
    XCTAssertEqual(stored, sdk.getAnonymousId())
  }

  func testGrantingConsentLaterPersistsTheInMemoryId() throws {
    let sdk = try makeSDK(consentGranted: false)
    let id = sdk.getAnonymousId()
    XCTAssertNil(stored)

    sdk.setConsent(true)
    XCTAssertEqual(stored, id)
    XCTAssertEqual(sdk.getAnonymousId(), id)
  }

  // MARK: Session timeout

  func testManagedSessionRotatesAfterThirtyMinutesOfInactivity() async throws {
    let clock = TestClock()
    let http = routedLoader()
    let sdk = try makeSDK(http: http, clock: clock)
    let first = try XCTUnwrap(sdk.getSessionId())

    clock.advance(minutes: 29)
    try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: 1))
    XCTAssertEqual(try body(http.requests[0])["session_id"] as? String, first)

    clock.advance(minutes: 29)
    XCTAssertEqual(sdk.getSessionId(), first, "activity 29 minutes ago keeps the session")

    clock.advance(minutes: 2)
    let second = try XCTUnwrap(sdk.getSessionId())
    XCTAssertNotEqual(second, first)

    try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: 1))
    XCTAssertEqual(try body(http.requests[1])["session_id"] as? String, second)
  }

  func testExplicitSessionIdsAreNeverRotated() throws {
    let clock = TestClock()
    let sdk = try makeSDK(sessionId: "app-session", clock: clock)
    clock.advance(minutes: 120)
    XCTAssertEqual(sdk.getSessionId(), "app-session")

    sdk.setSessionId("mine")
    clock.advance(minutes: 120)
    XCTAssertEqual(sdk.getSessionId(), "mine")

    sdk.setSessionId(nil)
    let managed = try XCTUnwrap(sdk.getSessionId())
    XCTAssertNotEqual(managed, "mine")
    clock.advance(minutes: 31)
    XCTAssertNotEqual(sdk.getSessionId(), managed)
  }

  // MARK: Platform and client tags

  func testEveryEventSaysWhereItCameFrom() async throws {
    let http = routedLoader()
    let sdk = try makeSDK(http: http)

    try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: 1))
    try await sdk.trackSearch(query: "vans")
    let expectedClient = "swift-sdk/" + (try versionFile())
    for request in http.requests {
      let event = try body(request)
      XCTAssertEqual(event["platform"] as? String, "ios")
      XCTAssertEqual(event["client"] as? String, expectedClient)
    }

    try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: 1, platform: .server))
    XCTAssertEqual(try body(http.requests[2])["platform"] as? String, "server")

    // Recommendation calls are not events and carry no tags.
    _ = try await sdk.getRecommendations(RecommendationOptions(contextId: 101))
    XCTAssertNil(queryItems(http.requests[3])["platform"])
  }

  func testConfiguredPlatformAppliesToEveryEvent() async throws {
    let http = routedLoader()
    let sdk = try makeSDK(http: http, platform: "web")

    try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: 1))
    try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: 1, additionalFields: ["client": "spoofed"]))
    XCTAssertEqual(try body(http.requests[0])["platform"] as? String, "web")
    XCTAssertEqual(try body(http.requests[1])["client"] as? String, NeuronSDK.client)
    XCTAssertEqual(EventPlatform.magento.rawValue, "magento")
  }

  func testVersionConstantMatchesVersionFile() throws {
    XCTAssertEqual(NeuronSDK.version, try versionFile(), "run scripts/sync-version.sh after bumping VERSION")
    XCTAssertEqual(NeuronSDK.client, "swift-sdk/\(NeuronSDK.version)")
  }

  // MARK: Helpers

  private func versionFile() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func makeSDK(
    http: MockHTTPDataLoader? = nil,
    collateWindowSeconds: TimeInterval = 0,
    anonymousId: String? = nil,
    consentGranted: Bool = true,
    sessionId: String? = nil,
    platform: EventPlatform = .ios,
    clock: TestClock = TestClock()
  ) throws -> NeuronSDK {
    try NeuronSDK(
      SDKConfig(
        baseURL: "https://api.example.com/v1",
        accessToken: "token",
        maxRetries: 0,
        urlSession: http ?? routedLoader(),
        collateWindowSeconds: collateWindowSeconds,
        sessionId: sessionId,
        anonymousId: anonymousId,
        consentGranted: consentGranted,
        userDefaultsSuiteName: suiteName,
        platform: platform
      ),
      clock: { clock.now }
    )
  }

  private func routedLoader() -> MockHTTPDataLoader {
    MockHTTPDataLoader { request in
      let path = request.url?.path ?? ""
      let json: String
      if path.hasSuffix("/identify") {
        json = #"{"object":"identify","linked":true,"events_moved":3,"reason":null,"embedding_refresh":{"queued":true}}"#
      } else if path.hasSuffix("/recommendations/batch") {
        json = #"{"results":[]}"#
      } else if path.hasSuffix("/recommendations") {
        json = #"{"request_id":"rid-1","recommendations":[]}"#
      } else {
        json = #"{"success":true}"#
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }
  }

  private func body(_ request: URLRequest) throws -> [String: Any] {
    let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
    if let list = json as? [[String: Any]] { return try XCTUnwrap(list.first) }
    return try XCTUnwrap(json as? [String: Any])
  }

  private func queryItems(_ request: URLRequest) -> [String: String] {
    let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    var result: [String: String] = [:]
    for item in items {
      result[item.name] = item.value
    }
    return result
  }

  private func assertThrows(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("Expected an error", file: file, line: line)
    } catch {}
  }
}

final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_800_000_000)

  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(minutes: Double) {
    lock.lock()
    current = current.addingTimeInterval(minutes * 60)
    lock.unlock()
  }
}
