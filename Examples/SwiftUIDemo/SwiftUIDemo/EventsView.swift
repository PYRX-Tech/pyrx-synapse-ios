//
//  EventsView.swift
//  SwiftUIDemo
//
//  Fires custom `track(...)` events. Each tap surfaces the SDK's response
//  inline so the manual tester knows the event was queued.
//

import SwiftUI
import PYRXSynapse

struct EventsView: View {

    @State private var customEventName: String = "button_tapped"
    @State private var eventLog: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick events") {
                    Button("track('button_tapped')") {
                        fire("button_tapped", properties: ["source": .string("quick-button")])
                    }
                    Button("track('cart_viewed')") {
                        fire("cart_viewed", properties: [
                            "items": .int(3),
                            "total_cents": .int(2599)
                        ])
                    }
                    Button("track('purchase_completed')") {
                        fire("purchase_completed", properties: [
                            "order_id": .string("ord_\(Int(Date().timeIntervalSince1970))"),
                            "currency": .string("USD"),
                            "amount": .double(25.99)
                        ])
                    }
                }

                Section("Custom event") {
                    TextField("event_name", text: $customEventName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Send") {
                        let trimmed = customEventName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        fire(trimmed, properties: nil)
                    }
                }

                Section("Log") {
                    if eventLog.isEmpty {
                        Text("No events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(eventLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("Events")
        }
    }

    private func fire(_ name: String, properties: [String: JSONValue]?) {
        Task {
            do {
                try await Pyrx.shared.track(eventName: name, properties: properties)
                await MainActor.run {
                    eventLog.insert("OK  \(timestamp()) \(name)", at: 0)
                }
            } catch {
                await MainActor.run {
                    eventLog.insert("ERR \(timestamp()) \(name) — \(error.localizedDescription)", at: 0)
                }
            }
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
