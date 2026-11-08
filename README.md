# NeuronSearchLab Swift SDK

Native Swift client and structured logger for the NeuronSearchLab Core API on iOS, macOS, tvOS, and watchOS.

This SDK is implemented in Swift using `URLSession` and Swift concurrency. It does not bridge to JavaScript or require a WebView.

## Requirements

- iOS 15+
- macOS 12+
- tvOS 15+
- watchOS 8+
- Swift 5.9+

## Installation

In Xcode, choose **File > Add Package Dependencies...**, then add:

```text
https://github.com/NeuronSearchLab/neuronsearchlab-swift-sdk.git
```

Select the `NeuronSearchLabSDK` product and import the module:

```swift
import NeuronSearchLab
```

For Swift Package Manager:

```swift
dependencies: [
  .package(url: "https://github.com/NeuronSearchLab/neuronsearchlab-swift-sdk.git", from: "1.0.0")
],
targets: [
  .target(
    name: "YourApp",
    dependencies: [
      .product(name: "NeuronSearchLabSDK", package: "neuronsearchlab-swift-sdk")
    ]
  )
]
```

Swift Package Manager resolves versions from git tags. Until a release tag exists, use a branch dependency:

```swift
.package(url: "https://github.com/NeuronSearchLab/neuronsearchlab-swift-sdk.git", branch: "main")
```

## Quick Start

```swift
import NeuronSearchLab

let sdk = try NeuronSDK(
  SDKConfig(
    baseURL: "https://api.neuronsearchlab.com/v1",
    accessToken: token,
    collateWindowSeconds: 3,
    maxBatchSize: 200,
    maxBufferedEvents: 5_000
  )
)

let created = try await sdk.upsertItem(
  ItemUpsertPayload(
    name: "Premier League Highlights",
    description: "Matchday recap",
    metadata: ["league": "EPL"]
  )
)
guard case .object(let item) = created, let itemId = item["id"]?.intValue else {
  fatalError("NSL did not return an integer item ID")
}

try await sdk.trackEvent(
  TrackEventPayload(
    eventId: 42,
    userId: "42",
    itemId: itemId,
    contextId: 101,
    metadata: ["action": "view"]
  )
)

try await sdk.patchItem(
  PatchItemInput(
    itemId: itemId,
    additionalFields: ["name": "Premier League Highlights v2"]
  )
)

try await sdk.deleteItems(DeleteItemInput(itemId: itemId))

let recs = try await sdk.getRecommendations(
  RecommendationOptions(
    userId: "42",
    contextId: 101,
    limit: 5
  )
)

let results = try await sdk.search(
  SearchOptions(
    query: "latest football highlights",
    userId: "42",
    contextId: 101,
    limit: 5,
    filters: .strings(["category:sports"])
  )
)
```

## Visitor identity

The SDK identifies a visitor the same way on web, iOS and your backend: an
anonymous id for the install, a session id, and your user id once they log in.

```swift
// Before login: events and recommendations use the anonymous id as user_id.
try await sdk.trackEvent(TrackEventPayload(eventId: 42, itemId: itemId))
let recs = try await sdk.getRecommendations(RecommendationOptions(contextId: 101))

// After login (and on launch when a user is already signed in):
try await sdk.identify(user.id)

// On logout:
sdk.reset()
```

Lifecycle:

- **Anonymous id.** A random UUID generated on first use and kept in
  `UserDefaults` under `com.neuronsearchlab.anonymous_id` (or the
  `userDefaultsSuiteName` you pass, e.g. an App Group), so it survives
  relaunches. Pass `SDKConfig(anonymousId:)` to use your own instead.
  `getAnonymousId()` returns it. Every event and recommendation request sends
  it as `anonymous_id`.
- **User id.** `userId` is optional everywhere. When you leave it out it
  defaults to the user set by `identify(_:)`, else the anonymous id. A
  `userId` you pass always wins.
- **`identify(_:)`** sends `POST /v1/identify` with the anonymous id and your
  user id, after flushing buffered events. The API moves the anonymous id's
  past events onto the user, so their profile follows them across web and
  app. It returns `IdentifyResult` (`linked`, `eventsMoved`, `reason`).
  Identifying the same user again makes no request; if the request fails the
  SDK stays anonymous, so calling it again still links.
- **`reset()`** is for logout: a new anonymous id, a new session id, and no
  identified user.
- **Sessions** stay per device. The SDK-managed session id is replaced after
  30 minutes without an event (`sessionTimeoutSeconds`). A session id you set
  yourself (`SDKConfig(sessionId:)` or `setSessionId(_:)`) is never rotated.

### Where events come from

Every event carries `platform` (default `"ios"`; set `SDKConfig(platform:)`
on a macOS, visionOS or server host, or per event with
`TrackEventPayload(platform:)`) and `client` (`"swift-sdk/<version>"`). The
console shows both.

### Consent

Under UK and EU device-storage rules you may need consent before storing an
identifier on the device. Pass `consentGranted: false` until you have it:
nothing is then read from or written to `UserDefaults`, and the ids live in
memory for that launch only.

```swift
let sdk = try NeuronSDK(SDKConfig(baseURL: url, accessToken: token, consentGranted: false))

sdk.setConsent(true)   // stores the current anonymous id
sdk.setConsent(false)  // removes it and starts fresh ids, unlinked from before
```

### Not an advertising identifier

The anonymous id is a random install id that the SDK creates itself. It is not
the IDFA or any other advertising identifier, it is not shared with other apps
or companies, and it resets when the app is deleted or `reset()` is called.
When you use it only for your own app's recommendations, it is not tracking
in Apple's sense, so App Tracking Transparency does not apply and no ATT
prompt is needed. Declare it in your App Store privacy details as an
identifier used for app functionality or product personalisation, not
tracking.

### Several rails on one screen

A screen with several recommendation rails should fetch them together. One
request reads the visitor's state once; each set is still served, attributed
and billed on its own.

```swift
let page = try await sdk.getRecommendationSets(
  RecommendationSetsOptions(
    userId: "42",
    sets: [
      RecommendationSetRequest(key: "for_you", contextId: 101, limit: 12),
      RecommendationSetRequest(key: "trending", contextId: 102, limit: 8),
      RecommendationSetRequest(key: "similar", contextId: 103, limit: 4, itemId: 5501),
    ]
  )
)

page.sets["for_you"]?.data          // the items for that rail
page.sets["similar"]?.requestId     // pass this with events from that rail
page.sets["trending"]?.error        // set only if that one rail failed
```

Up to 8 sets go in one request; larger calls are split. Pass `requestId` to
make a retry idempotent: the same id never bills a set twice.

#### Load a context group

Group the rails on the Contexts page, then load them by the group's ID (shown
next to the group's name). Each rail comes back under its context key, in the
group's order, and the group's rules apply:

```swift
let page = try await sdk.getRecommendationSets(
  RecommendationSetsOptions(
    userId: "42",
    groupId: 12,
    limit: 12,
    // Optional: adjust one rail, e.g. seed "similar items" with this product.
    sets: [RecommendationSetRequest(contextId: 103, itemId: 5501)]
  )
)
```

## API

The Swift SDK exposes the native equivalents of the JavaScript SDK methods:

| Method | Notes |
| --- | --- |
| `trackEvent(_:)` / `createEvent(_:)` | Buffers events, batches to `/v1/events`, retries transient failures, and attaches `client_ts`, `request_id`, and `session_id` when available. |
| `flushEvents()` | Immediately flushes buffered events. |
| `upsertItem(_:)` / `upsertItems(_:)` / `createItem(_:)` | Creates or updates catalogue items via `/v1/items`. |
| `patchItem(_:)` / `setItemActive(itemId:active:)` | Updates a single item via `/v1/items/{item_id}`. |
| `deleteItems(_:)` | Deletes one or more items via `/v1/items/{item_id}`. |
| `getRecommendations(_:)` | Gets personalized recommendations and captures returned `request_id`. |
| `getRecommendationSets(_:)` | Gets every rail of a screen in one request (`/v1/recommendations/batch`); results keyed by set, each with its own `request_id`. |
| `getAutoRecommendations(_:)` | Gets the next auto-generated recommendation section. |
| `search(_:)` | Runs query-driven retrieval through `/v1/search` and captures returned `request_id`. Pass `resultItemIds` when your own engine ran the query. |
| `trackSearch(userId:query:resultItemIds:)` / `trackSearch(query:resultItemIds:)` | Records a search as an event that steers the user's recommendations. |
| `identify(_:)` | Links the anonymous id to a user via `/v1/identify`; later calls default to that user. |
| `reset()` | Starts a new anonymous visitor and session, e.g. on logout. |
| `setConsent(_:)` | Grants or withdraws consent to store the anonymous id on the device. |
| `getAnonymousId()` / `getUserId()` / `getSessionId()` | The ids the next call will send. |

### Searches steer recommendations

Every search is recorded as an event on your Search event type and weighs into that user's later recommendations by its weight, exactly as a tap or a purchase does. The results you send are kept as impressions, not as items the user chose.

```swift
// NSL runs the search.
_ = try await sdk.search(SearchOptions(query: "waterproof trail shoes", userId: "user-123"))

// Your engine ran it: record it with the ids it showed, and get
// recommendations that complement them (those ids are left out).
let extras = try await sdk.search(SearchOptions(
  query: "waterproof trail shoes",
  userId: "user-123",
  resultItemIds: [1042, 1077, 1013]
))

// Record only. eventId is optional and defaults to your Search event.
try await sdk.trackSearch(userId: "user-123", query: "waterproof trail shoes", resultItemIds: [1042, 1077])
```

When searches steered a recommendation response, `response.searchIntent` holds their share of the user's recent event weight and the queries involved.

## Logging

```swift
configureLogger(
  LoggerConfiguration(
    level: .debug,
    enablePerformanceLogging: true
  )
)
```

Network payload logging is disabled by default to avoid leaking sensitive data.

## Development

```bash
swift test
```

## Releasing

Bump `VERSION` and run `scripts/sync-version.sh` (it regenerates
`Sources/NeuronSearchLab/SDKVersion.swift`, which the `client` tag reads; a
test fails while the two disagree) in a pull request. When it merges to `main`,
`.github/workflows/tag-release.yml` runs the tests, tags `v<VERSION>` and
publishes a GitHub release; Swift Package Manager resolves the new version
from the tag.

## Related SDKs

- JavaScript / TypeScript: https://github.com/NeuronSearchLab/neuronsearchlab-sdk-js
