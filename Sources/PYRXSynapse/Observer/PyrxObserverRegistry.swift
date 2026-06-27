//
//  PyrxObserverRegistry.swift
//  PYRXSynapse
//
//  Phase 9.2.1 PR-1 — Observer API.
//
//  Multi-subscriber publish/subscribe registry for `PyrxEvent`. Owned by
//  the `Pyrx` actor (constructed during `initialize` and re-used for
//  the actor's lifetime). The registry itself is its own `actor` so
//  subscribe / unsubscribe / publish never interleave — concurrent
//  observers cannot tear each other's state.
//
//  Replay buffer
//  =============
//
//  Holds the most recent 4 events. A new subscriber receives the
//  buffered events immediately upon subscription (in original order)
//  before any subsequent live events. Why 4: enough to give an app
//  that subscribes "late" (e.g. a SwiftUI view that appears after
//  initialize but before the first push arrives) a useful initial
//  picture, small enough that the replay traffic is bounded.
//
//  Per-subscriber dispatch
//  =======================
//
//  Subscribers register with both a closure and a `DispatchQueue`.
//  The registry dispatches each event onto the registered queue via
//  `queue.async` — observers do NOT block the actor while their
//  handlers run, and the handler runs on the queue the observer asked
//  for (`.main` for SwiftUI, custom queues for background work).
//
//  This means publication is fire-and-forget — if a subscriber's
//  handler crashes, the registry is unaffected. Observers should not
//  rely on observing being synchronous with the SDK call that
//  triggered the event.
//

import Foundation

/// Multi-subscriber pub/sub registry for `PyrxEvent`. Constructed once
/// during `Pyrx.initialize`; lifetime equals the `Pyrx` actor's.
actor PyrxObserverRegistry {

    /// One registered subscription.
    private struct Subscription {
        let id: Int
        let queue: DispatchQueue
        let handler: @Sendable (PyrxEvent) -> Void
    }

    /// All active subscriptions, keyed by id (assignment order).
    private var subscriptions: [Int: Subscription] = [:]

    /// Bounded replay buffer of the most recent events.
    private var replayBuffer: [PyrxEvent] = []

    /// Monotonic id source. Wraps `Int.max` is fine for our scale —
    /// no realistic app subscribes 2^63 times.
    private var nextId: Int = 0

    /// Replay buffer capacity. Exposed via `nonisolated static` so
    /// tests can read it without hopping onto the actor.
    nonisolated static var replayBufferCapacity: Int { 4 }

    // MARK: - Public surface (actor-isolated)

    /// Register a subscription. Returns the token id so the caller can
    /// build a `PyrxObserverToken`. The handler is invoked once per
    /// already-buffered event (in original order) immediately, then
    /// once per subsequent published event.
    func subscribe(
        on queue: DispatchQueue,
        handler: @escaping @Sendable (PyrxEvent) -> Void
    ) -> Int {
        nextId += 1
        let id = nextId
        let subscription = Subscription(id: id, queue: queue, handler: handler)
        subscriptions[id] = subscription

        // Replay buffered events to the new subscriber on its own
        // queue, preserving original order.
        let buffered = replayBuffer
        for event in buffered {
            queue.async { handler(event) }
        }

        return id
    }

    /// Remove the subscription with the given id. Idempotent — calls
    /// against an already-removed id are silent no-ops.
    func unsubscribe(id: Int) {
        subscriptions.removeValue(forKey: id)
    }

    /// Publish `event` to every current subscriber. The event is also
    /// appended to the replay buffer (oldest evicted on overflow) so
    /// future subscribers see it as part of the initial replay.
    ///
    /// Subscribers are dispatched onto their registered queues — this
    /// method returns once dispatch is queued, not once handlers have
    /// run.
    func publish(_ event: PyrxEvent) {
        // Snapshot before dispatch — a handler that cancels its own
        // subscription must not affect the iteration in progress.
        let snapshot = Array(subscriptions.values)

        // Update replay buffer first so a synchronous subscriber that
        // re-subscribes from within its handler would see the event
        // in the buffer.
        replayBuffer.append(event)
        if replayBuffer.count > Self.replayBufferCapacity {
            let overflow = replayBuffer.count - Self.replayBufferCapacity
            replayBuffer.removeFirst(overflow)
        }

        for subscription in snapshot {
            let handler = subscription.handler
            subscription.queue.async { handler(event) }
        }
    }

    // MARK: - Test introspection

    /// Current subscriber count. Test-only — apps should not depend on
    /// this value.
    func debugSubscriberCount() -> Int {
        subscriptions.count
    }

    /// Snapshot of the replay buffer for assertions.
    func debugReplayBuffer() -> [PyrxEvent] {
        replayBuffer
    }
}
