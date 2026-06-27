//
//  ObserverDemoView.swift
//  SwiftUIDemo
//
//  Demonstrates the Phase 9.2.1 observer API:
//   - `Pyrx.shared.events()` returns an `AsyncStream<PyrxEvent>`
//   - subscribe via SwiftUI's `.task { for await event in stream }`
//     pattern; lifecycle is tied to view membership, no manual cleanup
//   - shows received events as a scrollable list with the event-kind
//     label + a one-line summary of the payload
//

import SwiftUI
import PYRXSynapse

struct ObserverDemoView: View {

    @State private var received: [DisplayedEvent] = []

    var body: some View {
        NavigationStack {
            Group {
                if received.isEmpty {
                    ContentUnavailableView {
                        Label("No events yet", systemImage: "eye")
                    } description: {
                        Text("Trigger a push from the Push tab or run `identify` from the Identity tab — events will stream here in real time.")
                            .font(.callout)
                    }
                } else {
                    List(received) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.kind)
                                    .font(.headline)
                                Spacer()
                                Text(event.timestamp, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Observer")
            .toolbar {
                if !received.isEmpty {
                    Button("Clear") { received.removeAll() }
                }
            }
            .task {
                // `task` modifier cancels the Task when the view leaves
                // the hierarchy — which in turn cancels the AsyncStream,
                // which deinit's the observer token, which removes the
                // subscription from the registry. No manual cleanup.
                let stream = await Pyrx.shared.events()
                for await event in stream {
                    received.insert(DisplayedEvent(event: event), at: 0)
                    // Cap at 50 to keep the demo tidy.
                    if received.count > 50 { received.removeLast() }
                }
            }
        }
    }
}

private struct DisplayedEvent: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let kind: String
    let summary: String

    init(event: PyrxEvent) {
        switch event {
        case .pushReceived(let push):
            self.kind = "pushReceived"
            self.summary = push.title.isEmpty ? push.body : "\(push.title) — \(push.body)"
        case .pushClicked(let click):
            self.kind = "pushClicked"
            self.summary = click.deepLink?.absoluteString
                ?? click.actionId.map { "action=\($0)" }
                ?? "(body tap)"
        case .pushReceivedColdStart(let push):
            self.kind = "pushReceivedColdStart"
            self.summary = "cold-start: \(push.title.isEmpty ? push.body : push.title)"
        case .queueDrained(let count):
            self.kind = "queueDrained"
            self.summary = "flushed \(count) events"
        case .identityChanged(let before, let after):
            self.kind = "identityChanged"
            self.summary = "\(before.externalId ?? "anon") → \(after.externalId ?? "anon")"
        }
    }
}
