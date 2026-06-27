//
//  ObserverRegistryTests.swift
//  PYRXSynapseTests
//
//  Phase 9.2.1 PR-1 — Observer API.
//
//  Exercises the multi-subscriber pub/sub registry directly (not through
//  the `Pyrx` actor). The registry is an actor itself, so we hop onto
//  it with `await` and assert against its internal state via the
//  `debugSubscriberCount` / `debugReplayBuffer` test seams.
//
//  Coverage:
//
//   1. Single subscriber receives a published event
//   2. Multiple subscribers all receive the same event
//   3. Replay buffer caps at the documented capacity and evicts oldest
//   4. New subscriber receives buffered events on subscribe
//   5. Token cancel() removes the subscription from the registry
//   6. Token cancel() is idempotent (safe to call twice)
//   7. Token deinit (last reference drop) auto-cancels
//   8. Concurrent subscribe + publish doesn't crash and preserves count
//   9. Handler dispatch happens on the queue the subscriber registered with
//

import XCTest
@testable import PYRXSynapse

final class ObserverRegistryTests: XCTestCase {

    // MARK: - Helpers

    /// A simple `PushReceivedEvent` for stuffing into events. Empty
    /// payload — the registry doesn't care about the contents.
    private func makePushReceived(title: String = "t") -> PushReceivedEvent {
        PushReceivedEvent(
            title: title,
            body: "b",
            pyrxAttributes: nil,
            userInfo: [:],
            pushLogId: nil,
            receivedAt: Date()
        )
    }

    /// Wait a short async tick so DispatchQueue-dispatched handlers
    /// have a chance to run before the assertion.
    private func waitForHandlers() async {
        // Two yields + a small sleep covers the registry's
        // `queue.async` hop on .main and the test's own task hop.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await Task.yield()
    }

    // MARK: - Tests

    func test_singleSubscriber_receivesPublishedEvent() async {
        let registry = PyrxObserverRegistry()
        let received = SendableBox<[PyrxEvent]>([])
        _ = await registry.subscribe(on: .main) { event in
            received.mutate { $0.append(event) }
        }
        await registry.publish(.queueDrained(count: 3))
        await waitForHandlers()

        let snapshot = received.read()
        XCTAssertEqual(snapshot.count, 1)
        guard case .queueDrained(let count) = snapshot[0] else {
            return XCTFail("expected queueDrained")
        }
        XCTAssertEqual(count, 3)
    }

    func test_multipleSubscribers_allReceiveSameEvent() async {
        let registry = PyrxObserverRegistry()
        let subA = SendableBox<Int>(0)
        let subB = SendableBox<Int>(0)
        let subC = SendableBox<Int>(0)

        _ = await registry.subscribe(on: .main) { _ in subA.mutate { $0 += 1 } }
        _ = await registry.subscribe(on: .main) { _ in subB.mutate { $0 += 1 } }
        _ = await registry.subscribe(on: .main) { _ in subC.mutate { $0 += 1 } }

        await registry.publish(.queueDrained(count: 1))
        await registry.publish(.queueDrained(count: 2))
        await waitForHandlers()

        XCTAssertEqual(subA.read(), 2)
        XCTAssertEqual(subB.read(), 2)
        XCTAssertEqual(subC.read(), 2)
    }

    func test_replayBuffer_capsAtCapacity_andEvictsOldest() async {
        let registry = PyrxObserverRegistry()
        let cap = PyrxObserverRegistry.replayBufferCapacity

        // Push cap+2 events — first 2 should be evicted, last `cap` retained.
        for i in 1...(cap + 2) {
            await registry.publish(.queueDrained(count: i))
        }

        let buffer = await registry.debugReplayBuffer()
        XCTAssertEqual(buffer.count, cap)

        // Expected last `cap` counts == 3...cap+2 (oldest two evicted).
        let expectedCounts = Array(3...(cap + 2))
        let actualCounts = buffer.compactMap { event -> Int? in
            if case .queueDrained(let count) = event { return count }
            return nil
        }
        XCTAssertEqual(actualCounts, expectedCounts)
    }

    func test_lateSubscriber_receivesBufferedEvents() async {
        let registry = PyrxObserverRegistry()
        await registry.publish(.queueDrained(count: 1))
        await registry.publish(.queueDrained(count: 2))
        await registry.publish(.queueDrained(count: 3))

        let received = SendableBox<[Int]>([])
        _ = await registry.subscribe(on: .main) { event in
            if case .queueDrained(let count) = event {
                received.mutate { $0.append(count) }
            }
        }
        await waitForHandlers()

        XCTAssertEqual(received.read(), [1, 2, 3], "late subscriber must see buffered events in original order")

        // A subsequent publish lands AFTER the replay.
        await registry.publish(.queueDrained(count: 4))
        await waitForHandlers()
        XCTAssertEqual(received.read(), [1, 2, 3, 4])
    }

    func test_tokenCancel_removesSubscription() async {
        let registry = PyrxObserverRegistry()
        let received = SendableBox<Int>(0)
        let id = await registry.subscribe(on: .main) { _ in received.mutate { $0 += 1 } }
        let token = PyrxObserverToken(registry: registry, subscriptionId: id)

        await registry.publish(.queueDrained(count: 1))
        await waitForHandlers()
        XCTAssertEqual(received.read(), 1)

        token.cancel()
        // Token cancel hops onto the actor via a Task — give it time.
        await waitForHandlers()

        let count = await registry.debugSubscriberCount()
        XCTAssertEqual(count, 0, "token cancel must remove the subscription")

        await registry.publish(.queueDrained(count: 2))
        await waitForHandlers()
        XCTAssertEqual(received.read(), 1, "cancelled subscriber must not receive subsequent events")
    }

    func test_tokenCancel_isIdempotent() async {
        let registry = PyrxObserverRegistry()
        let id = await registry.subscribe(on: .main) { _ in }
        let token = PyrxObserverToken(registry: registry, subscriptionId: id)

        token.cancel()
        token.cancel()
        token.cancel()
        await waitForHandlers()

        let count = await registry.debugSubscriberCount()
        XCTAssertEqual(count, 0)
    }

    func test_tokenDeinit_autoCancelsSubscription() async {
        let registry = PyrxObserverRegistry()
        let id = await registry.subscribe(on: .main) { _ in }
        let preDropCount = await registry.debugSubscriberCount()
        XCTAssertEqual(preDropCount, 1)

        // Drop the only reference — the deinit fires, which cancels the
        // subscription on the registry actor.
        autoreleasepool {
            _ = PyrxObserverToken(registry: registry, subscriptionId: id)
        }
        await waitForHandlers()

        let count = await registry.debugSubscriberCount()
        XCTAssertEqual(count, 0, "token deinit must auto-cancel the subscription")
    }

    func test_concurrentSubscribeAndPublish_doesNotCrash() async {
        let registry = PyrxObserverRegistry()
        let received = SendableBox<Int>(0)

        // Concurrent subscribers + publishers — the actor must serialise
        // both without crashing or losing events.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = await registry.subscribe(on: .main) { _ in
                        received.mutate { $0 += 1 }
                    }
                }
            }
            for i in 0..<20 {
                group.addTask {
                    await registry.publish(.queueDrained(count: i))
                }
            }
        }
        await waitForHandlers()

        // We don't assert an exact count because subscribe vs publish
        // ordering is racy by design; we DO assert the actor finished
        // without crashing and at least some events were delivered.
        XCTAssertGreaterThan(received.read(), 0)
        let subs = await registry.debugSubscriberCount()
        XCTAssertEqual(subs, 20)
    }

    func test_handlerRunsOnRegisteredQueue() async {
        let registry = PyrxObserverRegistry()
        let queueLabel = "tech.pyrx.synapse.observer-tests.dedicated"
        let queue = DispatchQueue(label: queueLabel)
        queue.setSpecific(key: Self.specificKey, value: queueLabel)

        let observed = SendableBox<String?>(nil)
        _ = await registry.subscribe(on: queue) { _ in
            observed.mutate {
                $0 = DispatchQueue.getSpecific(key: Self.specificKey)
            }
        }
        await registry.publish(.queueDrained(count: 1))
        await waitForHandlers()

        XCTAssertEqual(observed.read(), queueLabel, "handler must run on the registered queue")
    }

    private static let specificKey = DispatchSpecificKey<String>()
}

// MARK: - Tiny thread-safe box for collecting observed state in tests.

/// Minimal `@unchecked Sendable` box — XCTest closures capture across
/// concurrency domains and we need a single source of truth that's
/// safe to mutate from any queue without compiler complaints.
final class SendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) {
        self.value = initial
    }

    func read() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }
}
