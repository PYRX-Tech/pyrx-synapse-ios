# PYRXSynapse

[![SPM compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![CocoaPods](https://img.shields.io/badge/pod-PYRXSynapse-blue.svg)](https://cocoapods.org)
[![iOS](https://img.shields.io/badge/iOS-14.0%2B-blue.svg)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

Native iOS SDK for the [PYRX Synapse](https://synapse.pyrx.tech) customer engagement platform.

> **Status**: Phase 8.4a foundation (PR 1 of 7). This release ships the
> project scaffold, the core `Pyrx` actor, and the Keychain storage layer.
> Event tracking, identity, push, and in-app messaging land in subsequent
> PRs. See [DEVELOPMENT_PLAN.md](https://github.com/PYRX-Tech/pyrx.synapse/blob/master/DEVELOPMENT_PLAN.md)
> §8.4a.

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…**, then enter:

```
https://github.com/PYRX-Tech/pyrx-synapse-ios.git
```

Or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/PYRX-Tech/pyrx-synapse-ios.git", from: "0.1.0"),
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

```ruby
pod 'PYRXSynapse', '~> 0.1'
```

## Quick Start

```swift
import PYRXSynapse

// In your AppDelegate / @main entry point:
@main
struct MyApp: App {
    init() {
        Task {
            try await Pyrx.shared.initialize(
                config: PyrxConfig(
                    workspaceId: UUID(uuidString: "...")!,
                    apiKey: "psk_live_YOUR_API_KEY",
                    environment: .production,
                    logLevel: .info
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

## Features

- **Foundation** (this release):
  - `Pyrx` actor: thread-safe singleton with `initialize(config:)`
  - `PyrxConfig`: workspaceId, apiKey, environment, baseUrl, logLevel
  - `KeychainStore`: identity persistence (anonymousId / externalId / deviceToken)
- **Coming in subsequent PRs**:
  - HTTP client + identity API (`identify`, `alias`, `reset`)
  - Event tracking + offline queue (`track`, `flush`)
  - Push notifications (`registerForPush`, `handleRemoteNotification`)
  - Attribution + privacy (`setIDFA`, `optOut`)
  - Diagnostics + debug tooling
  - SwiftUI sample app

## Requirements

| Tool   | Minimum |
|--------|---------|
| iOS    | 14.0    |
| Swift  | 5.9     |
| Xcode  | 15.0    |

## Documentation

Full API reference and integration guides: [synapse.pyrx.tech/developers/sdks/ios](https://synapse.pyrx.tech/developers/sdks/ios) (published with PR 7).

## License

[MIT](./LICENSE)
