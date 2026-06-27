//
//  Pyrx+Observer.swift
//  PYRXSynapse
//
//  Phase 9.2.1 PR-1 — Observer API public surface.
//
//  Two subscription styles, both backed by the same `PyrxObserverRegistry`:
//
//    * `observe(on:_:)` — closure-based. Returns a `PyrxObserverToken`;
//      hold the token to keep the subscription alive, cancel it to
//      unsubscribe. Handlers run on the caller-supplied
//      `DispatchQueue` (`.main` for SwiftUI / UIKit, custom for
//      background work).
//
//    * `events()` — AsyncStream-based. Returns an `AsyncStream<PyrxEvent>`
//      that yields every published event until the consuming task is
//      cancelled. Sugar on top of `observe(on:_:)` — `onTermination`
//      hooks the underlying token's `cancel()`.
//
//  Replay
//  ======
//
//  Both styles receive the most recent N events buffered by the registry
//  (`PyrxObserverRegistry.replayBufferCapacity`) on subscribe, before
//  any subsequent live events. The buffer is for catch-up — an app
//  that subscribes after the SDK has already started receiving pushes
//  still sees the recent history.
//

import Foundation

extension Pyrx {

    /// Subscribe to SDK events with a closure-based handler.
    ///
    /// - Parameters:
    ///   - queue: the `DispatchQueue` on which `handler` will be invoked.
    ///            Defaults to `.main` for SwiftUI / UIKit ergonomics —
    ///            pass `.global(qos: .utility)` or a custom serial
    ///            queue for background work.
    ///   - handler: invoked once per published `PyrxEvent`. Also invoked
    ///              once per replay-buffered event (in original order)
    ///              immediately upon subscription.
    /// - Returns: an opaque `PyrxObserverToken`. Hold the token to keep
    ///            the subscription alive; release it (or call `cancel()`)
    ///            to unsubscribe.
    ///
    /// Example:
    /// ```swift
    /// let token = await Pyrx.shared.observe { event in
    ///     switch event {
    ///     case .pushReceived(let push):
    ///         print("Received: \(push.title)")
    ///     case .pushClicked(let click):
    ///         print("Clicked: \(click.actionId ?? "body")")
    ///     case .pushReceivedColdStart(let push):
    ///         print("Cold-start: \(push.title)")
    ///     case .queueDrained(let count):
    ///         print("Drained \(count) events")
    ///     case .identityChanged(let before, let after):
    ///         print("Identity: \(before.externalId ?? "—") → \(after.externalId ?? "—")")
    ///     }
    /// }
    /// // Keep `token` alive for the duration you want to observe.
    /// ```
    public func observe(
        on queue: DispatchQueue = .main,
        _ handler: @escaping @Sendable (PyrxEvent) -> Void
    ) async -> PyrxObserverToken {
        let id = await observerRegistry.subscribe(on: queue, handler: handler)
        return PyrxObserverToken(registry: observerRegistry, subscriptionId: id)
    }

    /// Subscribe to SDK events as an `AsyncStream`.
    ///
    /// The returned stream yields every published `PyrxEvent` (plus
    /// any replay-buffered events on the initial subscription) until
    /// the consuming task is cancelled — at which point the underlying
    /// subscription is auto-cancelled via `onTermination`.
    ///
    /// Example:
    /// ```swift
    /// Task {
    ///     for await event in await Pyrx.shared.events() {
    ///         // handle event
    ///     }
    ///     // stream completes when the Task is cancelled
    /// }
    /// ```
    public func events() async -> AsyncStream<PyrxEvent> {
        // Build a holder for the token so `onTermination` can reach it.
        // We capture `self` because the registry needs to be reachable
        // from the (sync) closure passed to `AsyncStream.makeStream`.
        let registry = self.observerRegistry

        // `AsyncStream.makeStream` gives us a stream + continuation pair
        // up-front so we can register `onTermination` before subscribing.
        // This closes the race where a fast-cancel happens before the
        // subscription is wired.
        let (stream, continuation) = AsyncStream.makeStream(of: PyrxEvent.self)

        // Subscribe; the handler simply yields each event into the
        // continuation. The registry dispatches on the queue we hand it
        // — for AsyncStream consumers we don't care about a specific
        // queue (the consumer's `for await` picks up on its own task),
        // so we use a single utility queue dedicated to bridge work.
        let bridgeQueue = DispatchQueue(label: "tech.pyrx.synapse.observer-bridge", qos: .utility)
        let subscriptionId = await registry.subscribe(on: bridgeQueue) { event in
            continuation.yield(event)
        }
        let token = PyrxObserverToken(registry: registry, subscriptionId: subscriptionId)

        // When the consumer cancels the iterating task (or simply
        // drops the stream), `onTermination` fires and we cancel the
        // underlying subscription so the registry no longer dispatches
        // to a now-dropped continuation. Capturing `token` keeps it
        // alive until termination — without that capture, the token
        // would deinit (which also cancels) as soon as this method
        // returns, prematurely tearing the subscription.
        continuation.onTermination = { _ in
            token.cancel()
        }

        return stream
    }
}
