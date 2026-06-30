# PYRXSynapse

[![SPM compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![CocoaPods](https://img.shields.io/badge/pod-PYRXSynapse-blue.svg)](https://cocoapods.org)
[![iOS](https://img.shields.io/badge/iOS-14.0%2B-blue.svg)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![CI](https://github.com/PYRX-Tech/pyrx-synapse-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/PYRX-Tech/pyrx-synapse-ios/actions/workflows/ci.yml)

Native iOS SDK for the [PYRX Synapse](https://synapse.pyrx.tech) customer engagement platform.

Track events, identify users, register for push notifications, and respect user privacy — all from a single thread-safe `actor` API designed for SwiftUI and UIKit apps on iOS 14+.

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…**, then enter:

```
https://github.com/PYRX-Tech/pyrx-synapse-ios.git
```

Or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/PYRX-Tech/pyrx-synapse-ios.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "PYRXSynapse", package: "pyrx-synapse-ios"),
        ]
    ),
]
```

### CocoaPods

Add to your `Podfile`:

```ruby
pod 'PYRXSynapse', '~> 1.0'
```

Then run:

```bash
pod install
```

## Quick Start

```swift
import PYRXSynapse

@main
struct MyApp: App {
    init() {
        Task {
            try await Pyrx.shared.initialize(
                config: PyrxConfig(
                    workspaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                    apiKey: "psk_live_YOUR_API_KEY"
                )
            )
            try await Pyrx.shared.identify(externalId: "user_123")
            try await Pyrx.shared.track(eventName: "app_opened")
            _ = await Pyrx.shared.requestPushPermission()
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

The APNs device token is delivered through `UIApplicationDelegate`. See [docs/QUICKSTART.md](docs/QUICKSTART.md) for the full AppDelegate adapter pattern and [docs/PUSH_SETUP.md](docs/PUSH_SETUP.md) for end-to-end push provisioning.

## What's new in 0.1.2

🆕 **Observer API** — subscribe to a closed taxonomy of SDK events (`PyrxEvent`) without re-implementing `UNUserNotificationCenter` delegation:

```swift
let stream = await Pyrx.shared.events()
for await event in stream {
    switch event {
    case .pushReceived(let push): showToast(push.title, push.body)
    case .pushClicked(let click): Router.navigate(click.deepLink)
    case .identityChanged(let before, let after): /* ... */
    /* ... + .pushReceivedColdStart, .queueDrained */
    }
}
```

Closure-based `Pyrx.shared.observe(on:_:) -> PyrxObserverToken` is also available. Multi-subscriber; cold-start dedup; 4-event replay buffer for late subscribers. Full guide: [docs/observers.md](docs/observers.md).

## Features

- **Identity** — `identify`, `alias`, `logout` with anonymous-to-known merge, server-side event/device re-attribution, and Keychain-backed identifier persistence.
- **Events** — `track` and `screen` with a durable on-disk JSONL offline queue, exponential-backoff retry on 5xx/transport failures, FIFO eviction at the configured cap (1000 default), drop-on-4xx semantics.
- **Push notifications** — permission request, APNs token registration to `/v1/devices`, foreground presentation, background silent delivery, tap/action/dismiss telemetry, cold-start attribution, deep-link routing.
- **In-app messaging** (0.2.0+) — `Synapse.InApp.show(placement:callback:)` registers a render callback; the SDK polls `/v1/in-app/poll`, dispatches fresh messages, auto-fires impressions, and surfaces dismiss / interaction telemetry. SDK ships data only — your app draws the UI. Observe `PyrxEvent.inAppMessageReceived` / `.inAppMessageDismissed` via the existing observer surface.
- **Observers** (0.1.2+) — `Pyrx.shared.observe { event in ... }` or `for await event in Pyrx.shared.events()` to react to SDK events as they happen. See [docs/observers.md](docs/observers.md).
- **Privacy controls** — tracking kill switch (`setTrackingEnabled`), GDPR cascade delete (`deleteUser`), App Tracking Transparency status readout.
- **Diagnostics** — `debugInfo()` snapshot with SDK version, queue depth, last drain timestamp, device-token fingerprint (never the full token), and configuration echo for support cases.
- **Thread safety** — public surface is a Swift `actor`. Call from any task on any thread.

## Documentation

| Guide | Purpose |
|-------|---------|
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | Five-minute setup walkthrough — Xcode → SDK → identify → track → push |
| [docs/API_REFERENCE.md](docs/API_REFERENCE.md) | Every public type and method, with usage examples |
| [docs/PUSH_SETUP.md](docs/PUSH_SETUP.md) | Apple Developer Program → APNs Auth Key → PYRX dashboard → app capability |
| [docs/observers.md](docs/observers.md) | (0.1.2+) Subscribe to SDK events via closure or AsyncStream — push, taps, cold-start, identity, queue drains |
| [docs/MIGRATION.md](docs/MIGRATION.md) | Migration notes between SDK versions |
| [docs/RELEASING.md](docs/RELEASING.md) | Release process for SDK maintainers |
| [CHANGELOG.md](CHANGELOG.md) | Per-version release notes |

Full developer portal: [synapse.pyrx.tech/developers/sdks/ios](https://synapse.pyrx.tech/developers/sdks/ios).

## Requirements

| Tool   | Minimum |
|--------|---------|
| iOS    | 14.0    |
| Swift  | 5.9     |
| Xcode  | 15.0    |

## Sample app

A complete SwiftUI sample app lives at [`Examples/SwiftUIDemo`](Examples/SwiftUIDemo) — every public SDK surface (identify, events, push, privacy, debug) is wired into a tab UI you can run on a Simulator or real device.

```bash
cd Examples/SwiftUIDemo
open SwiftUIDemo.xcodeproj
```

Set `PYRX_WORKSPACE_ID` and `PYRX_API_KEY` in the Xcode scheme's environment variables to point at your own workspace.

## Contributing

Bug reports, feature requests, and pull requests are welcome on [GitHub](https://github.com/PYRX-Tech/pyrx-synapse-ios).

For substantial changes, open an issue first so we can align on direction. Every PR is gated on `swift test`, `swiftlint --strict`, and `pod lib lint`.

## License

[MIT](./LICENSE)
