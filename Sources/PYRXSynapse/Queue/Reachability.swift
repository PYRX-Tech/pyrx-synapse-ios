//
//  Reachability.swift
//  PYRXSynapse
//
//  Thin wrapper around `NWPathMonitor` that publishes "we just became
//  reachable" notifications to the `EventQueue` drain loop. iOS 12+ /
//  macOS 10.14+ APIs only — no SystemConfiguration legacy code.
//
//  Why a protocol seam:
//
//    - Unit tests need a deterministic way to simulate reachability
//      transitions without going through `NWPathMonitor` (which depends on
//      the host network state and cannot be mocked from outside its module).
//
//    - The queue listens for "satisfied" transitions (offline → online).
//      Tests inject `MockReachability` and call `simulate(.satisfied)` to
//      drive the drain loop.
//
//  Production conformance: `NWPathReachability` starts an `NWPathMonitor`
//  on its own background queue and forwards every transition to the
//  registered callback.
//

import Foundation
import Network

/// Reachability transition the queue cares about. We do NOT distinguish
/// `wifi` / `cellular` / `wired` — the queue treats any "satisfied" path
/// as "try to drain". The server's environment header derivation does not
/// depend on the transport.
enum ReachabilityStatus: Sendable, Equatable {
    case satisfied
    case unsatisfied
}

/// Async stream of reachability transitions. Implementations must be
/// thread-safe; the queue subscribes once and consumes the stream until
/// the queue itself is deallocated.
protocol Reachability: Sendable {
    /// Start emitting status events. Implementations should immediately
    /// emit the current path status so the queue knows whether to attempt
    /// an initial drain.
    func start() -> AsyncStream<ReachabilityStatus>

    /// Stop emitting. Idempotent.
    func stop()
}

/// Production conformance — wraps `NWPathMonitor`.
///
/// `NWPathMonitor` itself is `@unchecked Sendable` in modern SDKs; we mark
/// this wrapper the same and gate all mutable state behind an `NSLock`.
final class NWPathReachability: Reachability, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let monitorQueue: DispatchQueue
    private let lock = NSLock()
    private var continuation: AsyncStream<ReachabilityStatus>.Continuation?
    private var started = false

    init() {
        self.monitor = NWPathMonitor()
        self.monitorQueue = DispatchQueue(label: "tech.pyrx.synapse.reachability", qos: .utility)
    }

    func start() -> AsyncStream<ReachabilityStatus> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            let alreadyStarted = self.started
            self.started = true
            lock.unlock()

            // Wire the path-update handler exactly once. Subsequent
            // `start()` calls reuse the existing monitor.
            if !alreadyStarted {
                monitor.pathUpdateHandler = { [weak self] path in
                    guard let self else { return }
                    let status: ReachabilityStatus = path.status == .satisfied
                        ? .satisfied
                        : .unsatisfied
                    self.lock.lock()
                    let continuation = self.continuation
                    self.lock.unlock()
                    continuation?.yield(status)
                }
                monitor.start(queue: monitorQueue)
            }

            // When the consumer cancels the AsyncStream (queue deallocated),
            // tear down the monitor.
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        monitor.cancel()
        continuation?.finish()
        continuation = nil
        started = false
    }
}
