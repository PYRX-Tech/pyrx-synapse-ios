//
//  ContentView.swift
//  SwiftUIDemo
//

import SwiftUI
import PYRXSynapse

/// Six-tab demo surface. Each tab fires a `Pyrx.shared.screen(...)` on
/// appearance so the events tab visibly accumulates `$screen` events as
/// the user moves around. The Observer tab demonstrates the new
/// `Pyrx.shared.events()` AsyncStream introduced in 0.1.2.
///
/// On iPhone SE-class devices (compact width), iOS collapses the 6th
/// tab into a "More" menu — acceptable for a demo.
struct ContentView: View {

    @State private var selection: Tab = .identity

    enum Tab: Hashable {
        case identity
        case events
        case push
        case observer
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

            ObserverDemoView()
                .tabItem { Label("Observer", systemImage: "eye") }
                .tag(Tab.observer)
                .onAppear { trackScreen("observer") }

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
