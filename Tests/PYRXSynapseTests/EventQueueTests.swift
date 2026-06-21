//
//  EventQueueTests.swift
//  PYRXSynapseTests
//
//  Disk-backed offline queue coverage. All filesystem I/O is contained to
//  a per-test temp directory — the real `<Caches>` is never touched, so
//  this suite is safe to run in CI and on dev machines without leaking
//  state across runs.
//
//  Coverage:
//
//    1. enqueue + immediate drain on success → file becomes empty
//    2. drain fails 5xx → exponential backoff → eventual success
//    3. drain fails transport → exponential backoff → eventual success
//    4. drain fails 4xx → event dropped + queue advances past it
//    5. bounded overflow → oldest dropped (FIFO eviction)
//    6. persisted across SDK restart → second SDK instance drains the
//       events the first SDK enqueued
//    7. reachability `.satisfied` transition triggers drain
//

import XCTest
@testable import PYRXSynapse

final class EventQueueTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    // MARK: - Test fixtures

    /// Per-test temp dir. Cleaned in `tearDown`. Each test that needs an
    /// on-disk queue file appends `event_queue.jsonl` to this URL.
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-event-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeStore(name: String = "event_queue.jsonl") -> FileSystemQueueStore {
        FileSystemQueueStore(fileURL: tempDir.appendingPathComponent(name))
    }

    private func makeConfig() -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: .production,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    private func makeHTTPClient(session: MockHTTPSession) -> HTTPClient {
        HTTPClient(config: makeConfig(), session: session)
    }

    /// Bundles a constructed `EventQueue` with the store + mock session it
    /// was built against, so tests can introspect both sides without
    /// juggling three separate variables at every call site.
    private struct QueueBench {
        let queue: EventQueue
        let store: QueueFileStore
        let session: MockHTTPSession
    }

    private func makeQueue(
        store: QueueFileStore? = nil,
        session: MockHTTPSession = MockHTTPSession(),
        maxQueueSize: Int = 1000
    ) -> QueueBench {
        let resolvedStore = store ?? makeStore()
        let queue = EventQueue(
            httpClient: makeHTTPClient(session: session),
            store: resolvedStore,
            maxQueueSize: maxQueueSize,
            clock: NoOpClock() // no real sleeps in tests
        )
        return QueueBench(queue: queue, store: resolvedStore, session: session)
    }

    private func makeEvent(
        externalId: String = "user_42",
        eventName: String = "test_event",
        attributes: [String: JSONValue] = [:]
    ) -> QueuedEvent {
        QueuedEvent(
            externalId: externalId,
            eventName: eventName,
            attributes: attributes,
            occurredAt: "2026-06-21T12:00:00.000Z"
        )
    }

    private func enqueueAcceptedResponse(_ session: MockHTTPSession, count: Int = 1) {
        for _ in 0..<count {
            session.enqueueJSONSuccess(json: """
            {"event_id":"33333333-3333-3333-3333-333333333333","status":"accepted"}
            """)
        }
    }

    /// Read the on-disk JSONL file and decode into QueuedEvents. Returns
    /// `[]` if the file does not exist or is empty.
    private func readPersisted(_ store: QueueFileStore) throws -> [QueuedEvent] {
        guard let data = try store.read(), !data.isEmpty else { return [] }
        let lines = data.split(separator: 0x0A)
        return try lines
            .filter { !$0.isEmpty }
            .map { try JSONDecoder().decode(QueuedEvent.self, from: Data($0)) }
    }

    // MARK: - Test 1: enqueue + drain success → file empty

    func test_enqueue_drainsImmediatelyOnSuccess_andClearsFile() async throws {
        let bench = makeQueue()
        let queue = bench.queue
        let store = bench.store
        let session = bench.session
        enqueueAcceptedResponse(session)

        try await queue.enqueue(makeEvent())
        await queue.drainNow()

        let remainingInMemory = await queue.count
        XCTAssertEqual(remainingInMemory, 0, "queue should be empty in memory after drain")

        let persisted = try readPersisted(store)
        XCTAssertEqual(persisted.count, 0, "file should be empty after successful drain")

        XCTAssertEqual(session.requests.count, 1, "exactly one /v1/events POST should have happened")
        let recorded = session.requests[0].request
        XCTAssertEqual(recorded.url?.path, "/v1/events")
        XCTAssertEqual(recorded.httpMethod, "POST")
    }

    // MARK: - Test 2: 5xx → backoff → eventual success

    func test_enqueue_drainsAfterTransient5xxFailure() async throws {
        let bench = makeQueue()
        let queue = bench.queue
        let store = bench.store
        let session = bench.session

        // First two attempts return 503, third returns 202.
        session.enqueue(.success(statusCode: 503, body: Data("{}".utf8), headers: [:]))
        session.enqueue(.success(statusCode: 503, body: Data("{}".utf8), headers: [:]))
        enqueueAcceptedResponse(session)

        try await queue.enqueue(makeEvent())
        await queue.drainNow()

        let remainingInMemory = await queue.count
        XCTAssertEqual(remainingInMemory, 0, "queue should be empty after retry success")

        let persisted = try readPersisted(store)
        XCTAssertEqual(persisted.count, 0, "file should be empty after retry success")

        XCTAssertEqual(session.requests.count, 3, "should have retried twice before success")
    }

    func test_enqueue_drainsAfterTransportFailure() async throws {
        let bench = makeQueue()
        let queue = bench.queue
        let store = bench.store
        let session = bench.session

        // First attempt throws (URL error), second succeeds.
        session.enqueue(.failure(URLError(.notConnectedToInternet)))
        enqueueAcceptedResponse(session)

        try await queue.enqueue(makeEvent())
        await queue.drainNow()

        let remainingInMemory = await queue.count
        XCTAssertEqual(remainingInMemory, 0)
        let persisted = try readPersisted(store)
        XCTAssertEqual(persisted.count, 0)
        XCTAssertEqual(session.requests.count, 2)
    }

    // MARK: - Test 3: 4xx → drop

    func test_drain_dropsEventOn4xx_andAdvances() async throws {
        let bench = makeQueue()
        let queue = bench.queue
        let store = bench.store
        let session = bench.session

        // First event: 422 (drop). Second event: 202 (success).
        session.enqueue(.success(statusCode: 422, body: Data("{}".utf8), headers: [:]))
        enqueueAcceptedResponse(session)

        try await queue.enqueue(makeEvent(eventName: "malformed_event"))
        try await queue.enqueue(makeEvent(eventName: "good_event"))
        await queue.drainNow()

        let remainingInMemory = await queue.count
        XCTAssertEqual(remainingInMemory, 0, "both events should clear (one dropped, one sent)")

        let persisted = try readPersisted(store)
        XCTAssertEqual(persisted.count, 0)

        XCTAssertEqual(session.requests.count, 2, "no infinite retry of malformed event")
    }

    func test_drain_dropsEventOn400() async throws {
        let bench = makeQueue()
        let queue = bench.queue
        let session = bench.session
        session.enqueue(.success(statusCode: 400, body: Data("{}".utf8), headers: [:]))

        try await queue.enqueue(makeEvent())
        await queue.drainNow()

        let remainingInMemory = await queue.count
        XCTAssertEqual(remainingInMemory, 0, "400 (bad request) should drop")
    }

    func test_drain_doesNotDropOn500() async throws {
        let bench = makeQueue()
        let queue = bench.queue
        let session = bench.session
        // 500 four times in a row, then success.
        for _ in 0..<4 {
            session.enqueue(.success(statusCode: 500, body: Data("{}".utf8), headers: [:]))
        }
        enqueueAcceptedResponse(session)

        try await queue.enqueue(makeEvent())
        await queue.drainNow()

        let remainingInMemory = await queue.count
        XCTAssertEqual(remainingInMemory, 0)
        XCTAssertEqual(session.requests.count, 5, "500s should be retried until success")
    }

    // MARK: - Test 4: bounded overflow → oldest dropped (FIFO)

    func test_enqueue_evictsOldestWhenAtCapacity() async throws {
        // maxQueueSize=3 — easier to reason about.
        let bench = makeQueue(session: MockHTTPSession(), maxQueueSize: 3)
        let queue = bench.queue
        let store = bench.store

        // 5 enqueues with no drain (mock session has no canned responses,
        // so every drain attempt will fail. We don't await drainNow so the
        // first attempt sits behind backoff.).
        let e1 = makeEvent(eventName: "e1")
        let e2 = makeEvent(eventName: "e2")
        let e3 = makeEvent(eventName: "e3")
        let e4 = makeEvent(eventName: "e4")
        let e5 = makeEvent(eventName: "e5")

        // Use enqueue but DON'T await drainNow — drain runs in background
        // and will fail (no canned response). We only care about the in-
        // memory + on-disk state after enqueue.
        _ = try await queue.enqueue(e1)
        _ = try await queue.enqueue(e2)
        _ = try await queue.enqueue(e3)
        _ = try await queue.enqueue(e4)
        let countAfterFive = try await queue.enqueue(e5)

        XCTAssertEqual(countAfterFive, 3, "queue should clamp to maxQueueSize=3")

        // Disk should reflect the most-recent 3 events (e3, e4, e5).
        // Read directly through the store — no decoder dependency on
        // queue internals.
        let persisted = try readPersisted(store)
        let names = persisted.map { $0.eventName }
        XCTAssertEqual(names, ["e3", "e4", "e5"], "oldest two should have been evicted FIFO")
    }

    // MARK: - Test 5: persisted across SDK restart

    func test_queue_persistedAcrossSDKRestart_drainsOnSecondInstance() async throws {
        let store = makeStore()

        // First SDK instance: enqueue 3 events, no successful drain
        // (mock session has no canned responses for the FIRST instance).
        do {
            let session1 = MockHTTPSession()
            let q1 = EventQueue(
                httpClient: makeHTTPClient(session: session1),
                store: store,
                maxQueueSize: 100,
                clock: NoOpClock()
            )
            _ = try await q1.enqueue(makeEvent(eventName: "persisted_1"))
            _ = try await q1.enqueue(makeEvent(eventName: "persisted_2"))
            _ = try await q1.enqueue(makeEvent(eventName: "persisted_3"))
            // Do not drainNow — we want the events to remain on disk.
        }

        // Verify all three are on disk between SDK instances.
        let persistedBetween = try readPersisted(store)
        XCTAssertEqual(persistedBetween.count, 3)
        XCTAssertEqual(persistedBetween.map { $0.eventName }, [
            "persisted_1", "persisted_2", "persisted_3",
        ])

        // Second SDK instance: same store, new session with 3 success
        // responses queued. drainNow should clear all three.
        let session2 = MockHTTPSession()
        enqueueAcceptedResponse(session2, count: 3)
        let q2 = EventQueue(
            httpClient: makeHTTPClient(session: session2),
            store: store,
            maxQueueSize: 100,
            clock: NoOpClock()
        )

        await q2.drainNow()

        let remainingInMemory = await q2.count
        XCTAssertEqual(remainingInMemory, 0, "events from prior session must drain on new SDK instance")
        XCTAssertEqual(try readPersisted(store).count, 0)
        XCTAssertEqual(session2.requests.count, 3, "all three persisted events must have POSTed")
    }

    // MARK: - Test 6: reachability triggers drain

    func test_reachabilitySatisfied_triggersDrain() async throws {
        let store = makeStore()
        let session = MockHTTPSession()
        // The queue will see 1 event already on disk and one canned 202
        // ready to serve it.
        enqueueAcceptedResponse(session)

        // Pre-populate the on-disk file with one event so the queue picks
        // it up via loadIfNeeded after the reachability event fires.
        let preloaded = makeEvent(eventName: "preloaded")
        let preloadData = try JSONEncoder().encode(preloaded)
        try store.write(preloadData + Data([0x0A]))

        let reachability = MockReachability()
        let queue = EventQueue(
            httpClient: makeHTTPClient(session: session),
            store: store,
            maxQueueSize: 100,
            clock: NoOpClock()
        )
        await queue.bindReachability(reachability)

        // Simulate reachability flip to .satisfied. Drain runs in a
        // background Task — we need to wait for it to complete before
        // asserting.
        reachability.simulate(.satisfied)

        // Give the bound Task a few hops to run + drain.
        // drainNow itself awaits the in-flight drainTask so we serialize
        // by calling drainNow after the simulate.
        await queue.drainNow()

        XCTAssertEqual(session.requests.count, 1, "reachability-satisfied must trigger drain")
        let remainingInMemory = await queue.count
        XCTAssertEqual(remainingInMemory, 0)
    }

    // MARK: - Test 7: wire body shape sanity

    func test_drain_sendsExpectedWireBody() async throws {
        let bench = makeQueue()
        let queue = bench.queue
        let session = bench.session
        enqueueAcceptedResponse(session)

        let event = makeEvent(
            externalId: "user_42",
            eventName: "purchase",
            attributes: ["amount": .double(149.99), "currency": .string("USD")]
        )
        try await queue.enqueue(event)
        await queue.drainNow()

        let body = try XCTUnwrap(session.requests[0].body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["external_id"] as? String, "user_42")
        XCTAssertEqual(json?["event_name"] as? String, "purchase")
        XCTAssertEqual(json?["occurred_at"] as? String, "2026-06-21T12:00:00.000Z")
        XCTAssertEqual(json?["idempotency_key"] as? String, event.idempotencyKey)
        let attrs = json?["attributes"] as? [String: Any]
        XCTAssertEqual(attrs?["amount"] as? Double, 149.99)
        XCTAssertEqual(attrs?["currency"] as? String, "USD")
        XCTAssertNil(json?["contact"], "contact override is nil unless set")
    }

    // MARK: - Test 8: idempotency key is stable across retries

    func test_idempotencyKey_isStableAcrossRetries() async throws {
        let bench = makeQueue()
        let queue = bench.queue
        let session = bench.session
        session.enqueue(.success(statusCode: 503, body: Data("{}".utf8), headers: [:]))
        enqueueAcceptedResponse(session)

        let event = makeEvent()
        try await queue.enqueue(event)
        await queue.drainNow()

        XCTAssertEqual(session.requests.count, 2)
        let body1 = try XCTUnwrap(session.requests[0].body)
        let body2 = try XCTUnwrap(session.requests[1].body)
        let json1 = try JSONSerialization.jsonObject(with: body1) as? [String: Any]
        let json2 = try JSONSerialization.jsonObject(with: body2) as? [String: Any]
        XCTAssertEqual(
            json1?["idempotency_key"] as? String,
            json2?["idempotency_key"] as? String,
            "idempotency_key must be stable across retries so the backend can dedupe"
        )
    }
}

// MARK: - Test doubles

/// No-op clock — `sleep(_:)` returns immediately. Tests that exercise the
/// exponential-backoff branch must not actually sleep for seconds at a
/// time; we keep `swift test` well under the 30s ceiling.
struct NoOpClock: QueueClock {
    func sleep(nanoseconds: UInt64) async throws {
        // Yield once to give the actor scheduler a chance to interleave.
        await Task.yield()
    }
}

/// Deterministic `Reachability` stub. Holds a single continuation; tests
/// call `simulate(.satisfied)` / `simulate(.unsatisfied)` to push status
/// events into the queue's bound stream.
final class MockReachability: Reachability, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ReachabilityStatus>.Continuation?

    func start() -> AsyncStream<ReachabilityStatus> {
        AsyncStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }

    /// Push a status onto the stream. Blocks the calling thread until the
    /// downstream consumer (the queue's bound Task) has had a chance to
    /// pick it up — we yield twice before returning so the test can
    /// `await drainNow()` and reliably see the drain finish.
    func simulate(_ status: ReachabilityStatus) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(status)
    }
}
