//
//  IdentityView.swift
//  SwiftUIDemo
//
//  Calls `Pyrx.shared.identify(externalId:traits:)` with the form
//  inputs and surfaces the SDK's response (or error) inline.
//

import SwiftUI
import PYRXSynapse

struct IdentityView: View {

    @State private var externalId: String = "test-user-123"
    @State private var email: String = "test@pyrx.tech"
    @State private var firstName: String = "Demo"
    @State private var statusMessage: String = "Tap Identify to send."
    @State private var inFlight: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("External ID") {
                    TextField("external_id", text: $externalId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Traits") {
                    TextField("email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("first_name", text: $firstName)
                }

                Section {
                    Button(action: identify) {
                        if inFlight {
                            ProgressView()
                        } else {
                            Text("Identify")
                        }
                    }
                    .disabled(inFlight || externalId.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button(role: .destructive, action: logout) {
                        Text("Log out (clear externalId)")
                    }
                    .disabled(inFlight)
                }

                Section("Status") {
                    Text(statusMessage)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Identity")
        }
    }

    private func identify() {
        inFlight = true
        statusMessage = "Identifying…"
        Task {
            do {
                let traits: [String: JSONValue] = [
                    "email": .string(email),
                    "first_name": .string(firstName),
                    "demo_source": .string("SwiftUIDemo")
                ]
                let result = try await Pyrx.shared.identify(
                    externalId: externalId,
                    traits: traits
                )
                await MainActor.run {
                    statusMessage = "OK — path=\(result.path.rawValue), contact=\(result.contactId.uuidString.prefix(8))…"
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

    private func logout() {
        inFlight = true
        statusMessage = "Logging out…"
        Task {
            do {
                try await Pyrx.shared.logout()
                await MainActor.run {
                    statusMessage = "Logged out — externalId cleared."
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
}
