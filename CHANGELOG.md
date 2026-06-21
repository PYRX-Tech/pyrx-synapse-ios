# Changelog

All notable changes to the PYRX Synapse iOS SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Full developer documentation set: README, Quickstart, API Reference, Push Setup, Migration, Releasing.
- `docs/RELEASING.md` walkthrough for maintainers cutting future releases.

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
