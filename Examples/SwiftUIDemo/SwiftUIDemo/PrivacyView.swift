//
//  PrivacyView.swift
//  SwiftUIDemo
//
//  Demonstrates:
//    • setTrackingEnabled — the kill switch. Events still enqueue while
//      disabled, but the drain loop refuses to send them. Re-enable to
//      flush.
//    • deleteUser — GDPR right-to-erasure cascade. Wipes Keychain +
//      event queue locally, then asks the backend to cascade.
//

import SwiftUI
import PYRXSynapse

struct PrivacyView: View {

    @State private var trackingEnabled: Bool = true
    @State private var statusMessage: String = "All good."
    @State private var inFlight: Bool = false
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Tracking") {
                    Toggle("Tracking enabled", isOn: $trackingEnabled)
                        .onChange(of: trackingEnabled) { _, newValue in
                            Task {
                                await Pyrx.shared.setTrackingEnabled(newValue)
                                await MainActor.run {
                                    statusMessage = "setTrackingEnabled(\(newValue)) applied."
                                }
                            }
                        }
                    Text("""
                    When disabled, events still enqueue but the drain loop \
                    refuses to send them. Re-enabling flushes the buffer.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("Right to erasure") {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        if inFlight {
                            ProgressView()
                        } else {
                            Text("Delete user (GDPR cascade)")
                        }
                    }
                    .disabled(inFlight)
                    Text("""
                    Wipes Keychain (anonymousId, externalId, deviceToken) + \
                    the on-disk event queue, then POSTs \
                    `/v1/contacts/{external_id}/delete` so the backend can \
                    cascade. Local wipe runs BEFORE the network call — if \
                    the server is unreachable, on-device data is still gone.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("Status") {
                    Text(statusMessage)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Privacy")
            .confirmationDialog(
                "Delete user data?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: deleteUser)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently wipes local SDK state and asks the backend to cascade. There is no undo.")
            }
            .task { syncFromSDK() }
        }
    }

    private func deleteUser() {
        inFlight = true
        statusMessage = "Deleting…"
        Task {
            do {
                try await Pyrx.shared.deleteUser()
                await MainActor.run {
                    statusMessage = "Deleted. Local state wiped + backend asked to cascade."
                    inFlight = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "ERROR — \(error.localizedDescription)"
                    inFlight = false
                }
            }
        }
    }

    private func syncFromSDK() {
        Task {
            let info = await Pyrx.shared.debugInfo()
            await MainActor.run {
                self.trackingEnabled = info.trackingEnabled
            }
        }
    }
}
