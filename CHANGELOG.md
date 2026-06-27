# Changelog

All notable changes to the PYRX Synapse iOS SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Full developer documentation set: README, Quickstart, API Reference, Push Setup, Migration, Releasing.
- `docs/RELEASING.md` walkthrough for maintainers cutting future releases.

---

## [0.1.2] - 2026-06-27

### Added

- **`feat(observer): public observer API for SDK events`** — first PUBLIC streaming surface on `Pyrx`. Native iOS apps can now subscribe to a closed taxonomy of SDK events (`PyrxEvent`) without re-implementing `UNUserNotificationCenter` delegation or polling SDK state. Five event cases:
  - `.pushReceived(PushReceivedEvent)` — foreground or background delivery
  - `.pushClicked(PushClickedEvent)` — body tap or custom action button tap (NOT cold-start)
  - `.pushReceivedColdStart(PushReceivedEvent)` — app launched from terminated state via notification tap
  - `.queueDrained(count: Int)` — event queue successfully flushed N events (`count > 0` only)
  - `.identityChanged(before: IdentitySnapshot, after: IdentitySnapshot)` — `identify` / `alias` / `logout` completed
- **`Pyrx.shared.observe(on:_:) -> PyrxObserverToken`** — closure-based observer registration. Multi-subscriber by design; tokens are independent. The closure runs on the queue passed as `on:` (defaults to `.main`).
- **`Pyrx.shared.events() -> AsyncStream<PyrxEvent>`** — AsyncStream sugar for Swift Concurrency-first callers. Each call returns a fresh stream; cancelling the consuming `Task` cancels the underlying token.
- **`PyrxObserverToken`** — opaque reference-type handle. Holding the token keeps the subscription alive; `cancel()` (or letting the token deinit) removes it. Matches `AnyCancellable`'s contract.
- **`PyrxAttributeValue`** — typealias for the existing public `JSONValue`. Gives observer-API consumers a PYRX-prefixed name in event payloads without breaking existing `Pyrx.shared.identify(traits: [String: JSONValue])` callers.
- **`IdentitySnapshot`** — `(anonymousId: String?, externalId: String?, snapshotAt: Date)`. Built from `PyrxStorage` reads immediately before and after each identity mutation. Both `before` and `after` are non-optional on `.identityChanged` because anonymous-user IS a state.
- **Replay buffer of 4** — late subscribers receive the most-recent 4 events published before they subscribed (covers the cold-start race window when consumers subscribe ~1-2s after launch).
- **Cold-start dedup** — when iOS delivers a notification tap via BOTH `launchOptions[.remoteNotification]` AND `userNotificationCenter(_:didReceive:)`, the publisher dedups by `push_log_id` within a 5-second window so `.pushReceivedColdStart` fires exactly once AND `.pushClicked` does NOT fire for the cold-start payload.
- `Examples/SwiftUIDemo/SwiftUIDemo/ObserverDemoView.swift` — sample-app screen demonstrating the observer API via SwiftUI's `.task` modifier. Added as the 6th tab in the demo's `TabView`.
- `docs/observers.md` — API reference covering subscription, lifecycle, the `PyrxEvent` taxonomy, cold-start dedup, replay buffer, `PyrxAttributeValue` pattern-matching, forward-compatibility, and error semantics.

### Internal

- New observer fire-points in `PushHandlers.swift` (`recordPushReceived`, `emitOpened`, `emitClicked`, `recordColdStartOpen`), `IdentityManager.swift` (`identify`, `alias`, `logout`), and `EventQueue.swift::drainLoop` (queue-drain success path).
- New `parseAlert` helper in `PushHandlers.swift` extracts `(title, body)` from `userInfo["aps"]["alert"]`, supporting both string and dict alert shapes per APNs.
- `EventQueue.init` accepts an optional `onDrainComplete: @Sendable (Int) async -> Void` callback for cross-actor publish (default is no-op so existing tests don't break).
- 30+ new XCTest cases in `Tests/PYRXSynapseTests/Observer/` covering observer registry semantics, AsyncStream cancellation cascade, all 5 fire-points, identity-event before/after invariants, and the cold-start dedup contract.

### Forward-compatibility

`PyrxEvent` is non-`@frozen` for source consumers (SPM, CocoaPods). Adding cases in future minor versions is source-compatible — your `switch` statements continue to compile, with a warning that you should handle the new case.

For binary consumers (xcframework distribution — not currently shipped, may land at 1.0), the enum is treated as `@frozen`. To stay forward-compatible in that distribution mode, include `@unknown default: break` in every `switch` over `PyrxEvent`. See `docs/observers.md` for the full note.

---

## [0.1.1] - 2026-06-26

### Added
- **`PyrxConfig.sdkVariant`** — new optional initializer parameter for cross-platform wrapper SDKs (React Native, Flutter, Unity, etc.) to mark their origin in telemetry. When set, the wire-level `sdk_platform` field on `/v1/devices` becomes `"ios+<variant>"` (e.g. `"ios+rn"`); when omitted (the default), the field remains `"ios"`. The `Device.platform` field stays `"ios"` regardless — push dispatch routing (APNs vs FCM) is unaffected. Telemetry-only.
- **`DeviceMetadata.sdkPlatform(variant:)`** — internal helper used by `PushRegistration` to compose the suffixed value. The bare-arg `DeviceMetadata.sdkPlatform()` is preserved for backward compatibility.

### Changed
- `PushRegistration` initializer accepts an optional `sdkVariant: String?` parameter so the variant can flow from `PyrxConfig` to the wire payload without re-resolving on every call.

### Internal
- New test coverage in `PyrxConfigTests` (default-nil, pass-through, whitespace trimming, empty-collapses-to-nil) and `PushRegistrationTests` (wire payload assertions for both variant-set and bare cases, `DeviceMetadata.sdkPlatform(variant:)` behavior).

---

## [0.1.0] - 2026-06-21

Initial public release. Ships the complete Phase 8.4a iOS SDK surface:

### Added
- **Foundation** (PR #1)
  - `Pyrx` actor — thread-safe shared singleton.
  - `Pyrx.shared.initialize(config:)` with idempotent semantics.
  - `PyrxConfig` with `workspaceId`, `apiKey`, `environment`, `baseUrl`, `logLevel`, `maxQueueSize`.
  - `PyrxEnvironment` (`.production`, `.sandbox`) and `LogLevel` (`.debug`/`.info`/`.warning`/`.error`/`.none`).
  - `PyrxError` typed error hierarchy with `LocalizedError` conformance.
  - `KeychainStore` — anonymous ID / external ID / device token persistence.
  - `PyrxLogger` — `os.log`-backed runtime logger.
  - `PyrxDebugInfo` snapshot for diagnostics.
  - SPM + CocoaPods packaging. iOS 14+, macOS 11+, tvOS 14+, watchOS 7+.
  - SwiftLint config (strict) + GitHub Actions CI (`swift build`, `swift test`, `swiftlint --strict`, `pod lib lint`, `xcodebuild` for iOS Simulator).

- **Network + Identity** (PR #2)
  - `HTTPClient` — async/await `URLSession` wrapper with PYRX headers (`X-WORKSPACE-ID`, `X-API-KEY`, `X-PYRX-SDK-PLATFORM`, `X-PYRX-SDK-VERSION`).
  - `HTTPSession` protocol — injectable for tests.
  - `IdentityManager` actor — `identify`, `alias`, `logout`.
  - `IdentityResult` — server merge-path readout.
  - All wire models (`IdentifyRequest`, `IdentifyResponse`, `AliasRequest`, `WireEnvironment`, `IdentifyPath`, etc.) shared with the future Android SDK.

- **Events + Offline Queue** (PR #3)
  - `Pyrx.track(eventName:properties:)` and `Pyrx.screen(screenName:properties:)`.
  - `EventQueue` — JSONL on-disk persistence under `<Caches>/com.pyrx.synapse/event_queue.jsonl`.
  - Disk-backed bounded retry with exponential backoff, FIFO eviction at `maxQueueSize` (default 1000), drop-on-4xx.
  - `NWPathReachability` — reactive drain on connectivity restore.
  - `JSONValue` — strongly-typed payload shape for traits + properties.
  - `EventIngestRequest` + `EventAcceptedResponse` wire models.

- **Push Registration + Delivery Handlers** (PR #4)
  - `Pyrx.requestPushPermission(options:)` — `UNUserNotificationCenter` authorization + APNs registration.
  - `Pyrx.handleDeviceToken(_:)` — bridges `application(_:didRegisterForRemoteNotifications…)` into `POST /v1/devices`.
  - `Pyrx.handleRegistrationError(_:)` — diagnostic-only failure log.
  - `Pyrx.handleForegroundNotification(_:)` — `willPresent` presentation options + `$push_received` telemetry.
  - `Pyrx.handleBackgroundNotification(userInfo:completion:)` — silent push handling + APNs ack.
  - `Pyrx.handleNotificationResponse(_:completion:)` — tap → `/v1/push/opened`, custom action → `/v1/push/click`, deep-link routing via `UIApplication.open`.
  - `PushPermissionStatus` — cross-platform mirror of `UNAuthorizationStatus`.
  - `PyrxBackgroundFetchResult` — cross-platform shim for `UIBackgroundFetchResult`.
  - `DeviceRegisterRequest` / `DeviceResponse` / `PushOpenedRequest` / `PushClickedRequest` / `PushTelemetryResponse` wire models.

- **Attribution + Privacy + Diagnostics** (PR #5)
  - `Pyrx.recordColdStartLaunch(userInfo:)` — `$app_opened_from_push` cold-start attribution, safe to call before `initialize`.
  - `Pyrx.setTrackingEnabled(_:)` — privacy kill switch with pre-init buffering.
  - `Pyrx.deleteUser()` — GDPR right-to-erasure cascade (local wipe + backend `POST /v1/contacts/{id}/delete`).
  - `PyrxATTStatus` — cross-platform App Tracking Transparency status readout.
  - `PyrxDebugInfo` extended with `environment`, `baseUrl`, `deviceTokenFingerprint` (last-8 only), `trackingEnabled`, `attStatus`, `eventQueueDepth`, `lastDrainAt`.

- **Tests + Sample App** (PR #6)
  - 177 passing tests across `Tests/PYRXSynapseTests/` covering identity, events, push, queue, storage, network, privacy, diagnostics, and cross-cutting coverage gaps.
  - `Examples/SwiftUIDemo/` — SwiftUI sample app demonstrating every public SDK surface (identity, events, push, privacy, debug). XcodeGen project + standalone xcodeproj. Reads `PYRX_WORKSPACE_ID` / `PYRX_API_KEY` from scheme env vars for live testing.

### Internal
- `nonisolated` storage protocol seams for testability without forcing actor isolation on every consumer.
- `QueueFileStore` + `QueueClock` + `Reachability` + `PushPermission` + `PushURLOpener` test seams — production paths use the real implementations, tests inject mocks.
- Cross-platform `#if canImport(UIKit)` / `#if canImport(AppTrackingTransparency)` guards so the SDK builds on macOS, tvOS, watchOS, and Linux CI lanes despite not shipping there.

### Known limitations
- Physical-device push delivery verification is deferred to maintainer manual test using the SwiftUIDemo sample app + a real Apple Developer account.
- `PyrxConstants.sdkVersion` and `PYRXSynapse.podspec` `s.version` must be hand-synced on release; automation lands in a future release.

---

[Unreleased]: https://github.com/PYRX-Tech/pyrx-synapse-ios/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/PYRX-Tech/pyrx-synapse-ios/releases/tag/v0.1.0
