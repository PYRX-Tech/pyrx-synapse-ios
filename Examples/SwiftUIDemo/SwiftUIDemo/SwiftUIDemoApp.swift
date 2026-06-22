//
//  SwiftUIDemoApp.swift
//  SwiftUIDemo
//
//  Sample SwiftUI host app for the PYRX Synapse iOS SDK. Demonstrates
//  every public surface the SDK exposes:
//
//    • initialize(config:)              — SwiftUIDemoApp.init
//    • identify / track / screen        — IdentityView, EventsView
//    • requestPushPermission            — PushView
//    • handleDeviceToken                — AppDelegate adapter (below)
//    • debugInfo()                      — DebugInfoView
//    • setTrackingEnabled / deleteUser  — PrivacyView
//
//  This app is intentionally minimal — it is NOT a product reference. It
//  is the manual-test surface for the SDK: open it on a Simulator (or a
//  real device, for the push-delivery half) and tap through the tabs.
//
//  Configuration
//  -------------
//
//  The bundled workspaceId / apiKey below are placeholders. To exercise
//  this against a real PYRX deployment, set `PYRX_WORKSPACE_ID` and
//  `PYRX_API_KEY` in the scheme's environment variables (or hard-code them
//  here for local dev). The README in this directory documents the
//  end-to-end push-test workflow.
//

import SwiftUI
import PYRXSynapse

@main
struct SwiftUIDemoApp: App {

    /// Bridge UIKit AppDelegate callbacks (push token, registration error,
    /// cold-start launch options) into SwiftUI lifecycle. SwiftUI's own
    /// `App` lifecycle does not expose `application(_:didRegisterForRemote…)`
    /// — we need the legacy delegate seam for that.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Initialise the SDK as early as possible. Subsequent calls to
        // `Pyrx.shared.identify`, `track`, etc. queue durably even if
        // `initialize` is still in flight when the first call lands.
        Task {
            do {
                try await Pyrx.shared.initialize(
                    config: PyrxConfig(
                        workspaceId: SwiftUIDemoApp.workspaceId,
                        apiKey: SwiftUIDemoApp.apiKey,
                        environment: .production,
                        baseUrl: SwiftUIDemoApp.baseUrl
                    )
                )
            } catch {
                // In the sample app a failed initialize is informational —
                // we surface it in the Debug tab via `debugInfo()` rather
                // than blocking the UI.
                NSLog("PYRX initialize failed: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    // MARK: - Config resolution chain
    //
    // Each value is resolved in priority order:
    //   1. ProcessInfo env var — set in the scheme's "Run → Arguments →
    //      Environment Variables" for laptop dev. Highest priority. Does
    //      NOT propagate to TestFlight / sideloaded builds (Xcode-only).
    //   2. Info.plist key — baked at build time from Config.xcconfig
    //      (production defaults) + Config.local.xcconfig (gitignored
    //      dev overrides). Survives TestFlight / sideloaded builds.
    //   3. Hardcoded fallback — never useful in practice; here so the
    //      app boots even with a broken xcconfig.
    //
    // See Examples/SwiftUIDemo/Config.xcconfig + Config.local.xcconfig.template
    // for the override pattern.

    static var workspaceId: UUID {
        if let raw = ProcessInfo.processInfo.environment["PYRX_WORKSPACE_ID"],
           let parsed = UUID(uuidString: raw) {
            return parsed
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "PyrxWorkspaceId") as? String,
           let parsed = UUID(uuidString: raw) {
            return parsed
        }
        return UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    static var apiKey: String {
        if let raw = ProcessInfo.processInfo.environment["PYRX_API_KEY"],
           !raw.isEmpty {
            return raw
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "PyrxApiKey") as? String,
           !raw.isEmpty {
            return raw
        }
        return "psk_live_00000000000000000000000000000000"
    }

    static var baseUrl: URL {
        if let raw = ProcessInfo.processInfo.environment["PYRX_BASE_URL"],
           let parsed = URL(string: raw) {
            return parsed
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "PyrxBaseUrl") as? String,
           let parsed = URL(string: raw) {
            return parsed
        }
        return URL(string: "https://synapse-events.pyrx.tech")!
    }
}
