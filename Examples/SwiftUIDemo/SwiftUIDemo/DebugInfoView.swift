//
//  DebugInfoView.swift
//  SwiftUIDemo
//
//  Renders `Pyrx.shared.debugInfo()` as a JSON-ish key/value table.
//  Useful for support: a screenshot of this tab tells us everything
//  about the SDK's runtime state without leaking PII.
//

import SwiftUI
import PYRXSynapse

struct DebugInfoView: View {

    @State private var info: PyrxDebugInfo?

    var body: some View {
        NavigationStack {
            List {
                if let info {
                    Section("SDK") {
                        kv("sdkVersion", info.sdkVersion)
                        kv("platform", info.platform)
                        kv("initialized", String(info.initialized))
                        kv("environment", info.environment ?? "—")
                        kv("baseUrl", info.baseUrl ?? "—")
                        kv("logLevel", String(describing: info.logLevel))
                    }
                    Section("Identity") {
                        kv("workspaceId", info.workspaceId?.uuidString ?? "—")
                        kv("anonymousId", info.anonymousId ?? "—")
                        kv("hasExternalId", String(info.hasExternalId))
                    }
                    Section("Push") {
                        kv("hasDeviceToken", String(info.hasDeviceToken))
                        kv("deviceTokenFingerprint", info.deviceTokenFingerprint ?? "—")
                    }
                    Section("Privacy") {
                        kv("trackingEnabled", String(info.trackingEnabled))
                        kv("attStatus", String(describing: info.attStatus))
                    }
                    Section("Queue") {
                        kv("eventQueueDepth", String(info.eventQueueDepth))
                        kv("lastDrainAt", info.lastDrainAt.map { String(describing: $0) } ?? "—")
                    }
                } else {
                    Text("Loading…")
                }
            }
            .navigationTitle("Debug")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", action: refresh)
                }
            }
            .task { refresh() }
        }
    }

    private func refresh() {
        Task {
            let snapshot = await Pyrx.shared.debugInfo()
            await MainActor.run { self.info = snapshot }
        }
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}
