# Observers

> **New in 0.1.2** — Subscribe to SDK events as they happen: foreground pushes, taps, cold-start launches, identity changes, queue drains.

The PYRX Synapse SDK publishes a **closed taxonomy of events** (`PyrxEvent`) to any caller that subscribes. Use this to drive in-app UI (toast on push receipt, refetch on identity change, badge update on queue drain) without re-implementing `UNUserNotificationCenter` delegation or polling SDK state.

## Subscribing

### Closure-based (primary)

```swift
import PYRXSynapse

let token = await Pyrx.shared.observe(on: .main) { event in
    switch event {
    case .pushReceived(let push):
        showToast(title: push.title, body: push.body)
    case .pushClicked(let click):
        if let url = click.deepLink { Router.navigate(to: url) }
    case .pushReceivedColdStart(let push):
        Router.navigateFromColdStart(payload: push)
    case .queueDrained(let count):
        log("flushed \(count) events")
    case .identityChanged(let before, let after):
        AnalyticsClient.updateUser(externalId: after.externalId)
    @unknown default:
        break  // forward-compatibility — see below
    }
}

// Later, to stop receiving events:
token.cancel()
// Or drop the only reference to `token` — the deinit calls cancel().
```

`observe(on:_:)` is **multi-subscriber by design** — every registered closure receives every event. Tokens are independent: cancelling one doesn't affect others.

The `on:` parameter defaults to `.main`; pass any `DispatchQueue` if your handler should run elsewhere.

### AsyncStream-based (sugar)

```swift
let stream = await Pyrx.shared.events()
Task {
    for await event in stream {
        // ... same switch as above ...
    }
}
```

The stream is a thin wrapper over the closure registry. Cancelling the consuming `Task` cancels the underlying observer token automatically. Each call to `events()` returns a fresh stream — multiple consumers can each call it independently.

## Events

| Event | When it fires | Payload |
|---|---|---|
| `.pushReceived(PushReceivedEvent)` | Foreground or background push delivery | `pushLogId: UUID?`, `title: String`, `body: String`, `pyrxAttributes: [String: PyrxAttributeValue]`, `userInfo: [String: PyrxAttributeValue]`, `receivedAt: Date` |
| `.pushClicked(PushClickedEvent)` | Body tap or custom action button tap (foreground or background — NOT cold-start) | `pushLogId: UUID?`, `deepLink: URL?`, `actionId: String?`, `pyrxAttributes`, `clickedAt: Date` |
| `.pushReceivedColdStart(PushReceivedEvent)` | App launched from terminated state via a notification tap | Same shape as `.pushReceived`. Fires AFTER `Pyrx.initialize` completes. |
| `.queueDrained(count: Int)` | The event queue successfully flushed N events to the wire (`count > 0` only) | `count`: number of events drained |
| `.identityChanged(before:after:)` | `identify` / `alias` / `logout` completed successfully | `before: IdentitySnapshot`, `after: IdentitySnapshot` (both non-optional — anonymous-user is a snapshot, not absence-of-identity) |

### Cold-start dedup

When the user taps a notification that launches the app from terminated state, iOS may deliver the payload via BOTH `launchOptions[.remoteNotification]` AND a subsequent `userNotificationCenter(_:didReceive:)` call. The SDK **dedups by `push_log_id` within a 5-second window** so:

- `.pushReceivedColdStart` fires **exactly once** for the launching payload
- `.pushClicked` does **NOT** fire for the cold-start payload

If you want to handle both cold-start and warm taps with the same routing logic, listen for both `.pushClicked` and `.pushReceivedColdStart` and dispatch identically.

### Replay buffer

Late subscribers receive the **most-recent 4 events** the SDK has published. This covers the cold-start race window (the React Native bridge subscribes ~1-2s after launch — late enough to miss a cold-start event without the replay buffer). Events older than the 4 most-recent are lost on subscribe.

If your consumer must see every event, subscribe at the earliest possible point — typically `application(_:didFinishLaunchingWithOptions:)` for native iOS apps, or in your root SwiftUI `@main` `App` struct's `init()`.

## Lifecycle

Observer tokens are kept alive by the caller. **Hold the token in a property** (typically on a view-model, app-delegate, or singleton) for the duration you want the subscription to live. Letting the token's last strong reference go calls `deinit`, which cancels the subscription.

For SwiftUI:

```swift
struct MyView: View {
    var body: some View {
        Text("…")
            .task {
                let stream = await Pyrx.shared.events()
                for await event in stream { /* … */ }
                // SwiftUI's `.task` modifier cancels the Task (and
                // therefore the stream) when the view leaves the
                // hierarchy. No manual cleanup.
            }
    }
}
```

## `PyrxAttributeValue`

`PyrxAttributeValue` is a `typealias` for the SDK's `JSONValue` type — a sum that can hold any JSON-shape value (`.string`, `.int`, `.double`, `.bool`, `.null`, `.array`, `.object`). The alias gives observer-API consumers a PYRX-prefixed name without disturbing the existing `Pyrx.shared.identify(traits: [String: JSONValue])` call sites.

Pattern-match to read:

```swift
if case .string(let campaignId) = event.pyrxAttributes["campaign_id"] {
    // campaignId is a String
}
```

## Forward-compatibility

`PyrxEvent` is **not marked `@frozen`**. For source consumers (Swift Package Manager, CocoaPods — both source-distribution surfaces), adding new event cases in future minor versions is **source-compatible**: your existing `switch` statements continue to compile, with a Swift warning that you should handle the new case.

For binary consumers (xcframework distribution — not currently shipped, may land at 1.0), the enum is treated as `@frozen` and new cases WILL break exhaustive switches. If your app code needs to be forward-compatible against a future binary-distributed SDK, **include `@unknown default: break` in every `switch` over `PyrxEvent`**:

```swift
switch event {
case .pushReceived(let push): /* ... */
case .pushClicked(let click): /* ... */
case .pushReceivedColdStart(let push): /* ... */
case .queueDrained(let count): /* ... */
case .identityChanged(let before, let after): /* ... */
@unknown default:
    break  // tolerate event cases added in future minor versions
}
```

The same convention applies to `PushReceivedEvent`, `PushClickedEvent`, and `IdentitySnapshot` if we add fields to them in the future (Swift treats public structs as resilient when library evolution is enabled — see SDK release notes for the posture when that change lands).

## Error semantics

Observer handlers that throw or crash are **caught by the SDK and logged via `PyrxLogger`** at `.error` level — the SDK never propagates handler errors back to its own callers. A buggy observer must not break the SDK's queue drain, push handling, or identity mutations. Keep observer handlers tolerant: validate any payload assumptions, no force-unwraps, no fatalError.

If you're routing observer events through Sentry/Crashlytics/etc., wrap the handler body in your own do-catch and forward the error to your tracker. The SDK's swallow-and-log is the safety net, not the primary error channel.

## See also

- React Native equivalent: `usePushReceived` / `usePushClicked` / `useDeepLink` / `useIdentityChanged` in [@pyrx/synapse-react-native](https://github.com/PYRX-Tech/pyrx-synapse-react-native) v0.2.0+.
- Android equivalent: `Pyrx.events: SharedFlow<PyrxEvent>` in [tech.pyrx.synapse:synapse-core](https://github.com/PYRX-Tech/pyrx-synapse-android) v0.1.4+.
- Phase 9.2.1 design plan with full rationale: [pyrx.synapse: docs/plans/phase-9.2.1-native-callback-observers-plan-2026-06-27.md](https://github.com/PYRX-Tech/pyrx.synapse/blob/master/docs/plans/phase-9.2.1-native-callback-observers-plan-2026-06-27.md).
