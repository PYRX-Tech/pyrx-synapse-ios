//
//  Pyrx+InApp.swift
//  PYRXSynapse
//
//  Phase 10 PR-2b iOS — bridge from the `Pyrx` actor into the
//  `InAppManager`. Public-but-undocumented accessor methods used by
//  the `Synapse.InApp.*` facade in `Synapse+InApp.swift`; host apps
//  should call `Synapse.InApp.*` instead.
//
//  The manager is constructed during `Pyrx.initialize(config:)` and
//  lives for the lifetime of the actor. Each accessor here hops onto
//  the actor and then awaits the manager (which is itself an actor).
//
//  Tracker binding
//  ===============
//
//  The manager needs to know the current external_id (the
//  "contactId" per ADR-0008 D1 — `/v1/in-app/poll` requires it as a
//  query param). We re-bind on every identity transition — see
//  `Pyrx.identify` / `Pyrx.alias` / `Pyrx.logout` in
//  `Pyrx.swift`. This file exposes the `rebindInAppTracker()` helper
//  those methods call.
//

import Foundation

extension Pyrx {

    // MARK: - Bridge methods (called by `Synapse.InApp.*`)

    /// Register a placement render callback. Returns the
    /// subscription id (wrapped in a `ShowToken` by the caller).
    func inAppRegisterShow(
        placement: String,
        callback: @escaping @Sendable (InAppMessage) -> Void
    ) async -> Int {
        guard let manager = inAppManagerForBridge() else {
            logger.warning("Synapse.InApp.show called before Pyrx.initialize — ignored.")
            return -1
        }
        return await manager.registerShow(placement: placement, callback: callback)
    }

    /// Unregister a placement render callback. Called from
    /// `ShowToken.cancel()` / `ShowToken.deinit`.
    func inAppUnregisterShow(placement: String, id: Int) async {
        guard let manager = inAppManagerForBridge() else { return }
        await manager.unregisterShow(placement: placement, id: id)
    }

    /// Sync read of currently-active messages.
    func inAppGetActive(placement: String?) async -> [InAppMessage] {
        guard let manager = inAppManagerForBridge() else { return [] }
        return await manager.getActive(placement: placement)
    }

    /// Mark a message dismissed.
    func inAppDismiss(messageId: String, reason: String?) async {
        guard let manager = inAppManagerForBridge() else {
            logger.warning("Synapse.InApp.dismiss called before Pyrx.initialize — ignored.")
            return
        }
        await manager.dismiss(messageId: messageId, reason: reason)
    }

    /// Mark a message interacted.
    func inAppMarkInteracted(messageId: String, ctaId: String) async {
        guard let manager = inAppManagerForBridge() else {
            logger.warning("Synapse.InApp.markInteracted called before Pyrx.initialize — ignored.")
            return
        }
        await manager.markInteracted(messageId: messageId, ctaId: ctaId)
    }

    /// Explicit poll trigger.
    func inAppRefresh() async {
        guard let manager = inAppManagerForBridge() else { return }
        await manager.refresh()
    }

    // MARK: - Internal bridge helpers

    /// Read the actor-private `inAppManager` for the public
    /// facade methods. Returns `nil` when `initialize` has not yet
    /// completed.
    private func inAppManagerForBridge() -> InAppManager? {
        inAppManager
    }

    /// Re-bind the in-app manager's tracker snapshot from the
    /// current identity state. Called from `identify` / `alias` /
    /// `logout` so the manager's `/v1/in-app/poll` contactId stays
    /// in sync.
    func rebindInAppTracker() async {
        guard let manager = inAppManager else { return }
        // `try?` over a throwing call that returns `String?` yields
        // `String??` — flatten with `.flatMap { $0 }` so we end up
        // with a single-level Optional.
        let externalId = (try? storage.get(.externalId)).flatMap { $0 }
        let contactId = (externalId?.isEmpty == false) ? externalId : nil
        await manager.bindTracker(BoundInAppTracker(contactId: contactId))
    }

    /// Hook called from `EventsManager.track` after each track event
    /// (lifecycle rule 3 — track-call refresh hint). Fire-and-forget.
    func notifyInAppTracked() async {
        await inAppManager?.notifyTracked()
    }
}
