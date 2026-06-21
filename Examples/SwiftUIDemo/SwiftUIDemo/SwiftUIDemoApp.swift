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
                        baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
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

    // MARK: - Placeholder config (override in scheme env vars for a real run)

    /// Replace with your real workspace UUID before running against a live
    /// PYRX deployment. Reads from `PYRX_WORKSPACE_ID` env var when set.
    static var workspaceId: UUID {
        if let raw = ProcessInfo.processInfo.environment["PYRX_WORKSPACE_ID"],
           let parsed = UUID(uuidString: raw) {
            return parsed
        }
        return UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    /// Replace with your real `psk_live_…` / `psk_test_…` API key before
    /// running against a live PYRX deployment. Reads from `PYRX_API_KEY`
    /// env var when set.
    static var apiKey: String {
        if let raw = ProcessInfo.processInfo.environment["PYRX_API_KEY"],
           !raw.isEmpty {
            return raw
        }
        return "psk_live_00000000000000000000000000000000"
    }
}
