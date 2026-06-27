//
//  PyrxObserverToken.swift
//  PYRXSynapse
//
//  Phase 9.2.1 PR-1 — Observer API.
//
//  Opaque handle returned by `Pyrx.shared.observe(on:_:)`. Holding the
//  token keeps the subscription alive; calling `cancel()` (or letting
//  the token deinit) removes the subscription from the registry.
//
//  Implementation detail: the token holds a weak back-reference to the
//  `PyrxObserverRegistry` and the integer id the registry assigned at
//  subscription time. `cancel()` is idempotent — second and subsequent
//  calls are no-ops.
//
//  Why a class, not a struct: tokens must have reference semantics so
//  apps can pass them around (store in a property, hand to a
//  view-model) and have a single shared cancel-effect. They also need
//  deinit so dropping the only reference automatically cleans up the
//  subscription — matches the contract of Combine's
//  `AnyCancellable`.
//

import Foundation

/// Opaque subscription handle returned by
/// `Pyrx.shared.observe(on:_:)`. Hold this token to keep the
/// subscription alive; call `cancel()` or release the last reference
/// to remove it.
///
/// Token equality is intentionally identity-based (`AnyObject ===`),
/// not value-based, because two subscriptions to the same handler are
/// distinct subscriptions.
public final class PyrxObserverToken: @unchecked Sendable {
    /// Weak back-reference to the registry so the token can call
    /// `unsubscribe` on cancel without keeping the registry alive
    /// beyond its natural lifetime (the `Pyrx` actor owns the registry).
    private weak var registry: PyrxObserverRegistry?

    /// Assigned by the registry at subscription time; stable for the
    /// life of the subscription.
    let subscriptionId: Int

    /// Idempotency guard — `cancel()` may be called explicitly, by
    /// AsyncStream `onTermination`, and again by deinit; we only want
    /// the registry hit once.
    private let lock = NSLock()
    private var cancelled = false

    init(registry: PyrxObserverRegistry, subscriptionId: Int) {
        self.registry = registry
        self.subscriptionId = subscriptionId
    }

    /// Cancel the subscription. Idempotent — second and subsequent
    /// calls are no-ops. Thread-safe; safe to call from any queue or
    /// task.
    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        // Hop onto the registry actor to remove ourselves; we do not
        // await because the caller (often `deinit`) is not in an async
        // context.
        let id = subscriptionId
        let registry = self.registry
        Task { await registry?.unsubscribe(id: id) }
    }

    deinit {
        // Auto-cancel on last-reference-drop so apps don't have to
        // manually retain tokens when the natural lifetime of an
        // owner (view-model, coordinator) is the desired subscription
        // lifetime.
        cancel()
    }
}
