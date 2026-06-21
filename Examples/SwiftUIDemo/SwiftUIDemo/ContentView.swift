//
//  ContentView.swift
//  SwiftUIDemo
//

import SwiftUI
import PYRXSynapse

/// Five-tab demo surface. Each tab fires a `Pyrx.shared.screen(...)` on
/// appearance so the events tab visibly accumulates `$screen` events as
/// the user moves around.
struct ContentView: View {

    @State private var selection: Tab = .identity

    enum Tab: Hashable {
        case identity
        case events
        case push
        case debug
        case privacy
    }

    var body: some View {
        TabView(selection: $selection) {
            IdentityView()
                .tabItem { Label("Identity", systemImage: "person.crop.circle") }
                .tag(Tab.identity)
                .onAppear { trackScreen("identity") }

            EventsView()
                .tabItem { Label("Events", systemImage: "bolt") }
                .tag(Tab.events)
                .onAppear { trackScreen("events") }

            PushView()
                .tabItem { Label("Push", systemImage: "bell") }
                .tag(Tab.push)
                .onAppear { trackScreen("push") }

            DebugInfoView()
                .tabItem { Label("Debug", systemImage: "ladybug") }
                .tag(Tab.debug)
                .onAppear { trackScreen("debug") }

            PrivacyView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(Tab.privacy)
                .onAppear { trackScreen("privacy") }
        }
    }

    private func trackScreen(_ name: String) {
        Task {
            do {
                try await Pyrx.shared.screen(screenName: name)
            } catch {
                NSLog("screen(\(name)) failed: \(error.localizedDescription)")
            }
        }
    }
}
