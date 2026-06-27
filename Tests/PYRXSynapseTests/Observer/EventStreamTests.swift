//
//  EventStreamTests.swift
//  PYRXSynapseTests
//
//  Phase 9.2.1 PR-1 — Observer API AsyncStream sugar.
//
//  Exercises `Pyrx.shared.events()` and the underlying lifecycle
//  guarantees:
//
//   1. Stream yields events as the registry publishes them
//   2. Cancelling the consuming Task auto-cancels the underlying token
//   3. The bridge subscription is auto-removed from the registry on
//      stream termination
//   4. Multiple concurrent stream consumers each get every event
//   5. Replay-buffered events appear at the start of the stream
//

import XCTest
@testable import PYRXSynapse

final class EventStreamTests: XCTestCase {

    func test_stream_yieldsPublishedEvents() async throws {
        let pyrx = Pyrx(storage: InMemoryStorage(), session: MockHTTPSession())
        let stream = await pyrx.events()

        let collector = Task<[PyrxEvent], Never> {
            var events: [PyrxEvent] = []
            for await event in stream {
                events.append(event)
                if events.count >= 2 { break }
            }
            return events
        }

        // Give the consumer a moment to attach.
        try await Task.sleep(nanoseconds: 50_000_000)

        await pyrx.observerRegistry.publish(.queueDrained(count: 7))
        await pyrx.observerRegistry.publish(.queueDrained(count: 9))

        let events = await collector.value
        XCTAssertEqual(events.count, 2)
        guard case .queueDrained(let a) = events[0],
              case .queueDrained(let b) = events[1]
        else { return XCTFail("expected two queueDrained events") }
        XCTAssertEqual([a, b], [7, 9])
    }

    func test_streamCancellation_removesUnderlyingSubscription() async throws {
        let pyrx = Pyrx(storage: InMemoryStorage(), session: MockHTTPSession())

        // Initial subscriber count is zero.
        let initialCount = await pyrx.observerRegistry.debugSubscriberCount()
        XCTAssertEqual(initialCount, 0)

        // Move the stream entirely into a Task — once the Task body
        // finishes, both the stream and its iterator are dropped,
        // which fires AsyncStream's onTermination → token.cancel().
        // If `stream` lived in the test method scope, the test
        // method's stack frame would keep the stream alive past the
        // consumer's break and the subscription would (correctly)
        // still be registered.
        let task = Task { @Sendable in
            let stream = await pyrx.events()
            for await _ in stream { break }
        }
        await pyrx.observerRegistry.publish(.queueDrained(count: 1))
        await task.value

        // Allow the onTermination callback to hop the registry actor.
        try await Task.sleep(nanoseconds: 200_000_000)

        let count = await pyrx.observerRegistry.debugSubscriberCount()
        XCTAssertEqual(count, 0, "stream termination must remove the bridge subscription")
    }

    func test_consumerTaskCancellation_terminatesStream() async throws {
        let pyrx = Pyrx(storage: InMemoryStorage(), session: MockHTTPSession())

        // Move the stream entirely into the Task body so cancellation
        // truly releases both the stream and the iterator (which then
        // triggers onTermination → token.cancel()).
        let task = Task<Int, Never> { @Sendable in
            let stream = await pyrx.events()
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        await pyrx.observerRegistry.publish(.queueDrained(count: 1))
        try await Task.sleep(nanoseconds: 100_000_000)

        // Cancel the consuming task — this causes the AsyncStream
        // for-await to exit normally (yield no more), and our
        // onTermination hook fires.
        task.cancel()
        _ = await task.value

        // Give onTermination its async window.
        try await Task.sleep(nanoseconds: 200_000_000)
        let subs = await pyrx.observerRegistry.debugSubscriberCount()
        XCTAssertEqual(subs, 0)
    }

    func test_concurrentStreams_eachReceiveAllEvents() async throws {
        let pyrx = Pyrx(storage: InMemoryStorage(), session: MockHTTPSession())
        let s1 = await pyrx.events()
        let s2 = await pyrx.events()

        async let consume1: [Int] = {
            var counts: [Int] = []
            for await event in s1 {
                if case .queueDrained(let count) = event { counts.append(count) }
                if counts.count >= 3 { break }
            }
            return counts
        }()
        async let consume2: [Int] = {
            var counts: [Int] = []
            for await event in s2 {
                if case .queueDrained(let count) = event { counts.append(count) }
                if counts.count >= 3 { break }
            }
            return counts
        }()

        try await Task.sleep(nanoseconds: 50_000_000)
        for value in 1...3 {
            await pyrx.observerRegistry.publish(.queueDrained(count: value))
        }

        let (got1, got2) = await (consume1, consume2)
        XCTAssertEqual(got1, [1, 2, 3])
        XCTAssertEqual(got2, [1, 2, 3])
    }

    func test_streamReceivesReplayBufferedEventsOnSubscribe() async throws {
        let pyrx = Pyrx(storage: InMemoryStorage(), session: MockHTTPSession())

        // Publish first, subscribe after — replay buffer should yield
        // them at the start of the stream.
        await pyrx.observerRegistry.publish(.queueDrained(count: 1))
        await pyrx.observerRegistry.publish(.queueDrained(count: 2))

        let stream = await pyrx.events()
        let collector = Task<[Int], Never> {
            var counts: [Int] = []
            for await event in stream {
                if case .queueDrained(let count) = event { counts.append(count) }
                if counts.count >= 2 { break }
            }
            return counts
        }

        let counts = await collector.value
        XCTAssertEqual(counts, [1, 2], "replay buffer must arrive at the head of the stream")
    }
}
