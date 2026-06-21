# API Reference

Complete public surface of the PYRX Synapse iOS SDK as of v1.0.0.

The SDK exposes a single entry point — `Pyrx.shared` — implemented as a Swift `actor`, so every call is automatically serialised. Call from any thread or task.

---

## Table of Contents

- [`Pyrx` (actor)](#pyrx-actor)
  - [`initialize(config:)`](#initializeconfig)
  - [`identify(externalId:traits:)`](#identifyexternalidtraits)
  - [`alias(newExternalId:)`](#aliasnewexternalid)
  - [`logout()`](#logout)
  - [`track(eventName:properties:)`](#trackeventnameproperties)
  - [`screen(screenName:properties:)`](#screenscreennameproperties)
  - [`requestPushPermission(options:)`](#requestpushpermissionoptions)
  - [`handleDeviceToken(_:)`](#handledevicetoken)
  - [`handleRegistrationError(_:)`](#handleregistrationerror)
  - [`handleForegroundNotification(_:)`](#handleforegroundnotification)
  - [`handleBackgroundNotification(userInfo:completion:)`](#handlebackgroundnotificationuserinfocompletion)
  - [`handleNotificationResponse(_:completion:)`](#handlenotificationresponsecompletion)
  - [`recordColdStartLaunch(userInfo:)`](#recordcoldstartlaunchuserinfo)
  - [`setTrackingEnabled(_:)`](#settrackingenabled)
  - [`deleteUser()`](#deleteuser)
  - [`setLogLevel(_:)`](#setloglevel)
  - [`debugInfo()`](#debuginfo)
- [`PyrxConfig`](#pyrxconfig)
- [`PyrxEnvironment`](#pyrxenvironment)
- [`LogLevel`](#loglevel)
- [`PyrxDebugInfo`](#pyrxdebuginfo)
- [`PushPermissionStatus`](#pushpermissionstatus)
- [`PyrxBackgroundFetchResult`](#pyrxbackgroundfetchresult)
- [`PyrxATTStatus`](#pyrxattstatus)
- [`IdentityResult`](#identityresult)
- [`JSONValue`](#jsonvalue)
- [`PyrxError`](#pyrxerror)
- [`PyrxNetworkError`](#pyrxnetworkerror)

---

## `Pyrx` (actor)

```swift
public actor Pyrx {
    public static let shared: Pyrx
}
```

The shared SDK singleton. Apps always use `Pyrx.shared`.

### `initialize(config:)`

```swift
public func initialize(config: PyrxConfig) async throws
```

Initialise the SDK. Must be called exactly once per app launch before any other API.

**Parameters**
- `config` — validated `PyrxConfig` (see below).

**Throws**
- `PyrxError.alreadyInitialized` if called twice with different values.
- `PyrxError.invalidConfig(reason:)` if validation fails.
- `PyrxError.keychainFailure(...)` if anonymous-ID persistence fails.

**Example**

```swift
try await Pyrx.shared.initialize(
    config: PyrxConfig(
        workspaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        apiKey: "psk_live_..."
    )
)
```

---

### `identify(externalId:traits:)`

```swift
@discardableResult
public func identify(
    externalId: String,
    traits: [String: JSONValue]? = nil
) async throws -> IdentityResult
```

Identify an anonymous session as a known user. Triggers server-side merge of the anonymous contact's events and devices into the known contact.

**Parameters**
- `externalId` — your canonical user identifier (e.g. your DB user ID).
- `traits` — optional contact attributes, shallow-merged into the contact's properties server-side.

**Returns** — `IdentityResult` with the merge path the server took.

**Throws** — `PyrxError.notInitialized`, `PyrxError.invalidConfig` (empty externalId), `PyrxError.network(...)`.

**Example**

```swift
let result = try await Pyrx.shared.identify(
    externalId: "user_123",
    traits: ["email": .string("jane@example.com")]
)
print("Re-attributed \(result.eventsReattributed) events.")
```

---

### `alias(newExternalId:)`

```swift
@discardableResult
public func alias(newExternalId: String) async throws -> IdentityResult
```

Explicitly merge an anonymous session into a known contact under a different identifier.

Use when your backend mints a permanent user ID distinct from the device-local identifier you used for the anonymous session.

**Throws** — `PyrxError.notInitialized`, `PyrxError.invalidConfig`, `PyrxError.network(...)`.

---

### `logout()`

```swift
public func logout() async throws
```

Client-side identity clear. Does NOT call the server.

- Removes `externalId` from the Keychain.
- Preserves `anonymousId` so subsequent events flow as anonymous activity.
- Preserves `deviceToken` so the device row remains valid for re-attribution at the next `identify`.

---

### `track(eventName:properties:)`

```swift
public func track(
    eventName: String,
    properties: [String: JSONValue]? = nil
) async throws
```

Track a custom event. The event is persisted to a disk-backed offline queue and drained asynchronously with exponential-backoff retry. 5xx and transport errors trigger retry; 4xx responses cause the event to be dropped with a warning log.

Returns once the event is durably on disk — actual network delivery happens in the background.

**Throws** — `PyrxError.notInitialized`, `PyrxError.invalidConfig` (empty event name).

**Example**

```swift
try await Pyrx.shared.track(
    eventName: "order_placed",
    properties: [
        "order_id": .string("ord_abc123"),
        "total": .number(49.99),
        "currency": .string("USD")
    ]
)
```

---

### `screen(screenName:properties:)`

```swift
public func screen(
    screenName: String,
    properties: [String: JSONValue]? = nil
) async throws
```

Track a screen view. Wire shape: `event_name = "$screen"`, `attributes.screen_name = screenName`. Caller `properties` are merged into the attributes bag (caller values cannot overwrite the SDK-stamped `screen_name`).

Same queue + retry semantics as `track`.

---

### `requestPushPermission(options:)`

```swift
public func requestPushPermission(
    options: UNAuthorizationOptions = [.alert, .sound, .badge]
) async -> PushPermissionStatus
```

Ask the user for push notification permission and, on success, trigger APNs registration so the OS hands a device token to `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.

Idempotent — invoking after the user already authorized does NOT re-prompt but DOES re-trigger APNs registration (the correct behaviour after a backgrounded fetch or token refresh).

**Returns** — `PushPermissionStatus`. See enum below.

---

### `handleDeviceToken(_:)`

```swift
@discardableResult
public func handleDeviceToken(_ deviceToken: Data) async throws -> DeviceResponse
```

Bridge `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` into a `POST /v1/devices` call.

Converts the raw token to lowercase-hex, persists to Keychain, and POSTs a full identifying metadata snapshot (bundle ID, app version, OS version, device model, locale, timezone, SDK fields). The server upserts by `(tenant_id, environment, platform, push_token)` so duplicate calls are idempotent.

**Throws** — `PyrxError.notInitialized`, `PyrxError.network(...)`, `PyrxError.keychainFailure(...)`.

---

### `handleRegistrationError(_:)`

```swift
public func handleRegistrationError(_ error: Error)
```

Bridge `application(_:didFailToRegisterForRemoteNotificationsWithError:)` into the SDK's logger. Fire-and-forget — no retry, no network call. To retry, fix the underlying issue (missing entitlement, APNs throttling) and call `requestPushPermission` again.

---

### `handleForegroundNotification(_:)`

```swift
public func handleForegroundNotification(
    _ notification: UNNotification
) -> UNNotificationPresentationOptions
```

Return the presentation options the OS should apply while the app is in the foreground (defaults to `[.banner, .sound, .badge]` on iOS 14+, `[.alert, .sound, .badge]` on older). Also fires `$push_received` telemetry so foreground deliveries are counted.

Returns `[]` (suppress) if `initialize(config:)` hasn't run.

---

### `handleBackgroundNotification(userInfo:completion:)`

```swift
public func handleBackgroundNotification(
    userInfo: [AnyHashable: Any],
    completion: @Sendable @escaping (PyrxBackgroundFetchResult) -> Void
)
```

Bridge `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` into a `$push_received` event + the OS-level background-fetch ack.

The completion is invoked exactly once with:
- `.newData` — the SDK enqueued a `$push_received` event.
- `.noData` — the SDK couldn't resolve a pyrx payload, or `initialize` hadn't run.

The SDK never calls `.failed` at this layer — the event-queue retry loop handles network blips.

---

### `handleNotificationResponse(_:completion:)`

```swift
public func handleNotificationResponse(
    _ response: UNNotificationResponse,
    completion: @Sendable @escaping () -> Void
) async
```

Bridge `UNUserNotificationCenter.userNotificationCenter(_:didReceive:withCompletionHandler:)` into push telemetry + deep-link routing.

Dispatch:
- Tap on notification body → `POST /v1/push/opened` + deep link.
- Tap on a custom action button → `POST /v1/push/click` (action identifier as `click_url`) + per-action deep-link override if present.
- Swipe to dismiss → no telemetry (no `/v1/push/dismissed` endpoint exists today).

The completion is invoked exactly once. Do not call `completion` yourself in addition — the SDK owns the lifecycle.

---

### `recordColdStartLaunch(userInfo:)`

```swift
public func recordColdStartLaunch(userInfo: [AnyHashable: Any]?) async
```

Capture the launch-options payload from `application(_:didFinishLaunchingWithOptions:)`. If the app was cold-launched via a push tap, the OS hands the original payload here. The SDK uses it to emit `$app_opened_from_push` for downstream analytics joins against the campaign that fired the push.

Safe to call BEFORE `initialize(config:)` — the payload is buffered and replayed once initialise lands. Pass `nil` (or omit the launch-options key) for non-push cold starts.

**Example**

```swift
func application(
    _ app: UIApplication,
    didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    let push = opts?[.remoteNotification] as? [AnyHashable: Any]
    Task { await Pyrx.shared.recordColdStartLaunch(userInfo: push) }
    return true
}
```

---

### `setTrackingEnabled(_:)`

```swift
public func setTrackingEnabled(_ enabled: Bool) async
```

Toggle the SDK's tracking kill switch.

When `enabled == false`:
- `track`, `screen`, and push handlers still ENQUEUE to the on-disk queue (so flipping back doesn't lose intent captured during opt-out).
- The drain loop refuses to send anything until tracking is re-enabled. The next `setTrackingEnabled(true)` auto-drains.

The flag is NOT persisted across launches. Apps that want a sticky opt-out should restore the value from their own preferences store on launch.

Safe to call before `initialize(config:)` — the value is buffered and applied when the privacy manager comes online.

---

### `deleteUser()`

```swift
public func deleteUser() async throws
```

GDPR right-to-erasure cascade. Order:

1. Resolve the active external ID (or anonymous fallback).
2. Wipe the Keychain (anonymousId + externalId + deviceToken).
3. Wipe the on-disk event queue.
4. POST `/v1/contacts/{external_id}/delete` to ask the backend to cascade — IF an identifier was present. Anonymous-only sessions skip step 4.

**Local wipe happens BEFORE the backend call** — if the backend fails, on-device data is still gone. A thrown error means "couldn't reach the server, please retry that part", not "the wipe didn't happen". 4xx responses are swallowed (treated as "already deleted").

**Throws** — `PyrxError.notInitialized`, `PyrxError.network(...)` for 5xx / transport failure on the backend cascade.

---

### `setLogLevel(_:)`

```swift
public func setLogLevel(_ level: LogLevel)
```

Adjust the runtime log level. Safe before or after `initialize`. Logs route through `os.log` under subsystem `tech.pyrx.synapse`, category `Synapse`.

---

### `debugInfo()`

```swift
public func debugInfo() async -> PyrxDebugInfo
```

Snapshot of SDK state. Useful for debug menus and support bundles.

The device token fingerprint is `…<last 8 chars>` — never the full token.

---

## `PyrxConfig`

```swift
public struct PyrxConfig: Sendable, Equatable {
    public let workspaceId: UUID
    public let apiKey: String
    public let environment: PyrxEnvironment
    public let baseUrl: URL
    public let logLevel: LogLevel
    public let maxQueueSize: Int

    public init(
        workspaceId: UUID,
        apiKey: String,
        environment: PyrxEnvironment = .production,
        baseUrl: URL = PyrxConfig.defaultBaseUrl,
        logLevel: LogLevel = .info,
        maxQueueSize: Int = 1000
    )

    public func validate() throws
}
```

| Field | Notes |
|-------|-------|
| `workspaceId` | UUID v4 from `synapse-app.pyrx.tech/settings/workspace`. |
| `apiKey` | `psk_live_…` / `psk_test_…`. Must start with `psk_`. Use the `data` scope. |
| `environment` | `.production` (live traffic) or `.sandbox` (staging/QA). Defaults to `.production`. |
| `baseUrl` | Ingestion API root. Defaults to `https://synapse-events.pyrx.tech`. Override only for self-hosted deployments. |
| `logLevel` | `.debug` / `.info` / `.warning` / `.error` / `.none`. Defaults to `.info`. |
| `maxQueueSize` | Offline queue cap. FIFO eviction once exceeded. Defaults to 1000. Values < 1 are clamped silently. |

`validate()` throws `PyrxError.invalidConfig` for empty `apiKey`, missing `psk_` prefix, or non-http(s) `baseUrl` scheme.

---

## `PyrxEnvironment`

```swift
public enum PyrxEnvironment: String, Sendable {
    case production   // → wire environment "live"
    case sandbox      // → wire environment "test"
}
```

---

## `LogLevel`

```swift
public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case none = 4
}
```

---

## `PyrxDebugInfo`

```swift
public struct PyrxDebugInfo: Sendable, Equatable {
    public let sdkVersion: String
    public let platform: String
    public let initialized: Bool
    public let workspaceId: UUID?
    public let environment: String?
    public let baseUrl: String?
    public let logLevel: LogLevel
    public let anonymousId: String?
    public let hasExternalId: Bool
    public let hasDeviceToken: Bool
    public let deviceTokenFingerprint: String?
    public let trackingEnabled: Bool
    public let attStatus: PyrxATTStatus
    public let eventQueueDepth: Int
    public let lastDrainAt: Date?

    public static func fingerprint(forDeviceToken token: String?) -> String?
}
```

`fingerprint(forDeviceToken:)` returns `nil` for an empty/missing token, otherwise `…<last 8 chars>`.

---

## `PushPermissionStatus`

```swift
public enum PushPermissionStatus: String, Sendable, Equatable {
    case authorized      // Full authorization. Token incoming.
    case provisional     // Quiet authorization. Token incoming.
    case denied          // User declined. No token will arrive.
    case notDetermined   // System didn't present the prompt. Retry later (rare).
    case ephemeral       // App Clip context. Token NOT requested.
}
```

---

## `PyrxBackgroundFetchResult`

```swift
public enum PyrxBackgroundFetchResult: Int, Sendable {
    case newData = 0
    case noData = 1
    case failed = 2
}
```

Cross-platform shim for `UIBackgroundFetchResult`. Map back to UIKit in your AppDelegate:

```swift
switch result {
case .newData: completionHandler(.newData)
case .noData:  completionHandler(.noData)
case .failed:  completionHandler(.failed)
}
```

---

## `PyrxATTStatus`

```swift
public enum PyrxATTStatus: Int, Sendable, Equatable, Codable {
    case unavailable = -1   // Framework not present (macOS, tvOS, Linux, iOS < 14).
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    case authorized = 3
}
```

Cross-platform mirror of `ATTrackingManager.AuthorizationStatus`. Read-only — call the real `AppTrackingTransparency` API to request authorization.

---

## `IdentityResult`

```swift
public struct IdentityResult: Sendable, Equatable {
    public let contactId: UUID
    public let path: IdentifyPath               // .merged, .createdAnonymous, .createdKnown, .noChange
    public let aliasedExternalId: String?
    public let eventsReattributed: Int
    public let devicesReattributed: Int
    public let anonymousContactTombstoned: Bool
}
```

Returned by `identify` and `alias`. Useful for support investigations — log `path` to see which merge branch the server ran.

---

## `JSONValue`

```swift
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}
```

Strongly-typed value used for `traits` and event `properties` payloads. Use literals:

```swift
let props: [String: JSONValue] = [
    "email": .string("jane@example.com"),
    "age": .number(34),
    "premium": .bool(true),
    "tags": .array([.string("vip"), .string("beta")]),
    "address": .object(["city": .string("HCMC")]),
    "deleted_at": .null
]
```

---

## `PyrxError`

```swift
public enum PyrxError: Error, Sendable, Equatable, LocalizedError {
    case alreadyInitialized
    case notInitialized
    case invalidConfig(reason: String)
    case keychainFailure(status: Int32, operation: String)
    case network(PyrxNetworkError)
}
```

All errors thrown by the public SDK API. `errorDescription` returns a user-readable string for each variant.

---

## `PyrxNetworkError`

```swift
public enum PyrxNetworkError: Error, Sendable, Equatable, LocalizedError {
    case transport(underlying: Error)              // DNS, TLS, connection refused, timeout
    case invalidResponse                            // Not an HTTPURLResponse (rare)
    case httpStatus(statusCode: Int, body: Data)   // Non-2xx
    case decode(underlying: Error)                  // Response body wasn't parseable
}
```

Wrapped by `PyrxError.network(_)`. Pattern-match for retry decisions:

```swift
do {
    try await Pyrx.shared.identify(externalId: "user_123")
} catch PyrxError.network(.httpStatus(let code, _)) where (500...599).contains(code) {
    // Backend failure — caller may retry
} catch PyrxError.network(.transport) {
    // Connectivity failure — caller may retry
} catch {
    // Unrecoverable — surface to user
}
```
