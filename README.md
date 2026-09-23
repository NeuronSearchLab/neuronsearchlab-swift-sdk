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
| `getAutoRecommendations(_:)` | Gets the next auto-generated recommendation section. |
| `search(_:)` | Runs query-driven retrieval through `/v1/search` and captures returned `request_id`. Pass `resultItemIds` when your own engine ran the query. |
| `trackSearch(userId:query:resultItemIds:)` | Records a search as an event that steers the user's recommendations. |

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

## Related SDKs

- JavaScript / TypeScript: https://github.com/NeuronSearchLab/neuronsearchlab-sdk-js
