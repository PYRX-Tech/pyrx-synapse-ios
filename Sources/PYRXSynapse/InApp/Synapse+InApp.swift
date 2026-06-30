//
//  Synapse+InApp.swift
//  PYRXSynapse
//
//  Phase 10 PR-2b iOS — public in-app messaging surface.
//
//  This file introduces the `Synapse` namespace (a public empty enum
//  used purely as a static namespace) and the nested `Synapse.InApp`
//  namespace that hosts the five in-app messaging methods. The
//  cross-SDK symmetric contract per ADR-0009 D5 names the surface
//  `Synapse.InApp.*` (matching the browser SDK's
//  `synapse('inApp.show', …)` call shape); iOS callers reach it as
//  `Synapse.InApp.show(placement:callback:)`.
//
//  All five methods delegate to the singleton `Pyrx.shared`'s
//  internal `InAppManager`. The manager is constructed during
//  `Pyrx.shared.initialize(config:)` and held for the lifetime of
//  the actor.
//
//  Identity gating
//  ===============
//
//  Per ADR-0008 D1 (and lifecycle rule 1 in PR #218): the SDK does
//  NOT poll `/v1/in-app/poll` until `Pyrx.shared.identify(…)` has
//  been called. The manager is identity-aware via the tracker
//  binding that flows through on every identify / alias / logout.
//
//  Observer events
//  ===============
//
//  `.inAppMessageReceived` and `.inAppMessageDismissed` flow through
//  the existing `Pyrx.shared.observe(on:_:)` /
//  `Pyrx.shared.events()` surface — there is NO separate observer
//  registration for in-app. This is the same pattern as push
//  events (per ADR-0005 D9) and is the cross-SDK symmetric contract
//  per ADR-0009 D6.
//

import Foundation

/// Public top-level namespace shared across the cross-SDK symmetric
/// contract. The iOS SDK keeps `Pyrx` as the actor / singleton entry
/// point; `Synapse` exists as a thin facade for the few surfaces
/// that ADR-0009 names without the `Pyrx` prefix (currently:
/// `Synapse.InApp.*`).
public enum Synapse {

    /// Opaque handle returned by `Synapse.InApp.show(placement:callback:)`.
    /// Hold the token to keep the registration alive; drop it (or
    /// call `cancel()`) to unregister the callback.
    ///
    /// Mirrors the browser SDK's unregister closure
    /// (`packages/sdk/src/in-app.ts:262`) — Swift consumers prefer a
    /// named type over a closure, especially for SwiftUI views that
    /// store the token in `@State`.
    public final class ShowToken: @unchecked Sendable {
        private let subscriptionId: Int
        private let placement: String
        private weak var pyrx: Pyrx?
        private var cancelled: Bool = false
        private let lock = NSLock()

        init(subscriptionId: Int, placement: String, pyrx: Pyrx) {
            self.subscriptionId = subscriptionId
            self.placement = placement
            self.pyrx = pyrx
        }

        /// Unregister the callback. Idempotent — calling twice (or
        /// after `deinit`) is a silent no-op.
        public func cancel() {
            lock.lock()
            if cancelled {
                lock.unlock()
                return
            }
            cancelled = true
            lock.unlock()

            let placement = self.placement
            let id = self.subscriptionId
            let pyrx = self.pyrx
            // Hop onto the Pyrx actor to reach the manager; the
            // manager's `unregisterShow` is itself actor-isolated.
            Task { [pyrx] in
                await pyrx?.inAppUnregisterShow(placement: placement, id: id)
            }
        }

        deinit {
            cancel()
        }
    }

    /// In-app messaging surface. Five methods — `show` / `getActive` /
    /// `dismiss` / `markInteracted` / `refresh`. Cross-SDK symmetric
    /// per ADR-0009 D5.
    ///
    /// The SDK delivers `InAppMessage` data to the host app's render
    /// callback. The SDK does NOT render — the host draws the UI in
    /// whatever style fits its design system.
    public enum InApp {

        /// Register a render callback for a placement.
        ///
        /// The SDK invokes `callback` once per fresh `InAppMessage`
        /// whose `placement` matches `placement`. The callback runs
        /// on a Task that hops onto the manager's actor — host apps
        /// that need to touch UIKit / SwiftUI inside the callback
        /// should marshal onto `MainActor` themselves (`Task { @MainActor in … }`).
        ///
        /// Triggers an immediate poll if the SDK has been identified.
        /// If the SDK has not yet been identified (no
        /// `Pyrx.shared.identify(…)` call has succeeded yet), the
        /// registration is buffered and a poll will fire as soon as
        /// identity lands (lifecycle rule 2 of PR #218).
        ///
        /// - Parameters:
        ///   - placement: non-empty placement key the host app maps
        ///                to a UI surface (e.g. `"home_banner"`).
        ///   - callback:  invoked once per fresh message. The SDK
        ///                does not render — `callback` is where the
        ///                host app draws the UI.
        /// - Returns: a `ShowToken`. Hold it to keep the
        ///            registration alive; release it (or call
        ///            `cancel()`) to unregister.
        @discardableResult
        public static func show(
            placement: String,
            callback: @escaping @Sendable (InAppMessage) -> Void
        ) async -> ShowToken {
            let id = await Pyrx.shared.inAppRegisterShow(placement: placement, callback: callback)
            return ShowToken(subscriptionId: id, placement: placement, pyrx: Pyrx.shared)
        }

        /// Sync-style read of currently-active messages from the
        /// in-memory cache. Does NOT trigger a poll.
        ///
        /// Returns a sorted copy (priority desc, then expiry asc) so
        /// the host app sees the same "most important first"
        /// ordering across SDKs.
        ///
        /// - Parameter placement: optional placement filter. `nil`
        ///                        returns every cached message.
        public static func getActive(placement: String? = nil) async -> [InAppMessage] {
            await Pyrx.shared.inAppGetActive(placement: placement)
        }

        /// Mark a message dismissed.
        ///
        /// Evicts the message from the in-memory cache, fires
        /// `PyrxEvent.inAppMessageDismissed(messageId:reason:)`, and
        /// POSTs `/v1/in-app/log` with `event="dismissed"`. The
        /// `reason` is host-side observer-only — it does NOT cross
        /// the wire (PR-1 backend schema does not carry it).
        ///
        /// Safe to call with an unknown id.
        public static func dismiss(messageId: String, reason: String? = nil) async {
            await Pyrx.shared.inAppDismiss(messageId: messageId, reason: reason)
        }

        /// Mark a message interacted (a CTA was tapped).
        ///
        /// POSTs `/v1/in-app/log` with `event="interacted"` and
        /// `cta_id=ctaId`. Does NOT evict from cache — the host
        /// decides whether interaction implies dismissal.
        ///
        /// `ctaId` must be non-empty (the backend's
        /// `model_validator` enforces this); the SDK validates
        /// client-side to skip the round-trip on misuse.
        public static func markInteracted(messageId: String, ctaId: String) async {
            await Pyrx.shared.inAppMarkInteracted(messageId: messageId, ctaId: ctaId)
        }

        /// Explicit poll trigger. Coalesces with any in-flight poll.
        ///
        /// Use cases: pull-to-refresh on a screen that hosts an
        /// in-app banner, foreground-resume hook in a SceneDelegate.
        /// The background poll timer (60s default, doubled on
        /// `soft_degraded`) covers most cases without needing
        /// explicit refresh.
        public static func refresh() async {
            await Pyrx.shared.inAppRefresh()
        }
    }
}
