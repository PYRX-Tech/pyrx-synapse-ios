//
//  PushView.swift
//  SwiftUIDemo
//
//  Calls `requestPushPermission` and surfaces the OS's verdict. The
//  device-token bridge lives in `AppDelegate.application(_:didRegister…)`
//  — once the OS hands us a token, the SDK persists it and POSTs to
//  `/v1/devices`. This screen reads the stored token from `debugInfo()`
//  so the user can copy/paste the fingerprint into a server-side test
//  push.
//

import SwiftUI
import PYRXSynapse

struct PushView: View {

    @State private var statusMessage: String = "Tap Request to ask the user."
    @State private var inFlight: Bool = false
    @State private var tokenFingerprint: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Permission") {
                    Button(action: requestPermission) {
                        if inFlight {
                            ProgressView()
                        } else {
                            Text("Request push permission")
                        }
                    }
                    .disabled(inFlight)
                    Text(statusMessage)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section("APNs device token") {
                    Button("Refresh from SDK") {
                        refreshToken()
                    }
                    if let fingerprint = tokenFingerprint {
                        Text(fingerprint)
                            .font(.system(.footnote, design: .monospaced))
                    } else {
                        Text("No token yet. Grant permission, wait for AppDelegate callback, then refresh.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Manual test") {
                    Text("""
                    1. Grant permission and wait for the AppDelegate to fire \
                    `didRegisterForRemoteNotificationsWithDeviceToken`.
                    2. Refresh above and copy the token fingerprint.
                    3. From the PYRX dashboard, send a test push to this device.
                    4. Foreground/background/tap behaviour all flow through \
                    AppDelegate → Pyrx SDK.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Push")
            .task { refreshToken() }
        }
    }

    private func requestPermission() {
        inFlight = true
        statusMessage = "Asking the user…"
        Task {
            let status = await Pyrx.shared.requestPushPermission(
                options: [.alert, .sound, .badge]
            )
            await MainActor.run {
                statusMessage = "Status: \(status.rawValue)"
                inFlight = false
            }
            // Token may now be incoming via the AppDelegate seam. Refresh
            // shortly so the UI reflects it without a manual tap.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            refreshToken()
        }
    }

    private func refreshToken() {
        Task {
            let info = await Pyrx.shared.debugInfo()
            await MainActor.run {
                self.tokenFingerprint = info.deviceTokenFingerprint
            }
        }
    }
}
