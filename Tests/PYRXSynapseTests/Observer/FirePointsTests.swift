//
//  FirePointsTests.swift
//  PYRXSynapseTests
//
//  Phase 9.2.1 PR-1 — Observer API.
//
//  Verifies each of the five `PyrxEvent` cases fires from its expected
//  fire-point in the SDK. Each test drives one fire-point through the
//  real `Pyrx` actor + mocks, subscribes via `observe(on:_:)`, and
//  asserts the published event matches the expected case + payload.
//
//  Coverage:
//
//   1. .pushReceived fires from handleForegroundNotification
//   2. .pushReceived fires from handleBackgroundNotification
//   3. .pushClicked (body tap) fires from handleNotificationResponse
//      default-action
//   4. .pushClicked (custom action) fires from handleNotificationResponse
//      custom-action
//   5. .pushReceivedColdStart fires from recordColdStartLaunch
//   6. .queueDrained fires from EventQueue successful drain
//
//  Title / body parsing through `PushHandlers.parseAlert` is covered
//  via the pushReceived assertions (modern dict-form alert).
//

import XCTest
import UserNotifications
@testable import PYRXSynapse

final class FirePointsTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let pushLogIdRaw = "9b1c8f4a-3a3e-4e1d-9b7f-1c2e3d4e5f6a"

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-observer-fire-points-\(UUID().uuidString)", isDirectory: true)
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

    private func makePyrx(
        storage: InMemoryStorage = InMemoryStorage(),
        session: MockHTTPSession = MockHTTPSession()
    ) -> Pyrx {
        let queueStore = FileSystemQueueStore(
            fileURL: tempDir.appendingPathComponent("event_queue.jsonl")
        )
        return Pyrx(
            storage: storage,
            session: session,
            queueStore: queueStore,
            reachability: MockReachability(),
            queueClock: NoOpClock(),
            urlOpener: MockURLOpener()
        )
    }

    private func makeConfig() -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: .production,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    private func wellFormedPayload(
        title: String = "Order shipped",
        body: String = "Tap to track",
        deepLink: String? = "pyrx://order/123"
    ) -> [AnyHashable: Any] {
        var pyrx: [String: Any] = ["push_log_id": pushLogIdRaw]
        if let deepLink { pyrx["deep_link"] = deepLink }
        return [
            "aps": [
                "alert": ["title": title, "body": body],
                "sound": "default",
            ],
            "pyrx": pyrx,
            "pyrx_attrs": ["campaign_id": "summer-2026"],
        ] as [AnyHashable: Any]
    }

    private func enqueueAcceptedEvent(_ session: MockHTTPSession) {
        session.enqueueJSONSuccess(json: """
        {"event_id":"33333333-3333-3333-3333-333333333333","status":"accepted"}
        """)
    }

    private func enqueueAcceptedPushTelemetry(_ session: MockHTTPSession) {
        session.enqueueJSONSuccess(json: """
        {"status":"accepted","envelope_id":"44444444-4444-4444-4444-444444444444"}
        """)
    }

    private func waitForObservers() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await Task.yield()
    }

    // MARK: - .pushReceived from foreground

    func test_foregroundNotification_firesPushReceived() async throws {
        let session = MockHTTPSession()
        enqueueAcceptedEvent(session)
        let pyrx = makePyrx(session: session)
        try await pyrx.initialize(config: makeConfig())

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        // Drive the foreground path through the public API. We use the
        // userInfo overload via PushHandlers directly because UNNotification
        // has no public initialiser — but the dispatch into
        // recordPushReceived (the fire-point) is the same code path the
        // public handleForegroundNotification takes.
        let handlers = await pyrx.testAccessPushHandlers()
        _ = handlers!.foregroundPresentationOptions(userInfo: wellFormedPayload())
        await waitForObservers()

        let events = collected.read().filter { if case .pushReceived = $0 { return true }; return false }
        XCTAssertEqual(events.count, 1, "foreground delivery must publish exactly one .pushReceived")
        guard case .pushReceived(let push) = events[0] else {
            return XCTFail("expected first event to be .pushReceived")
        }
        XCTAssertEqual(push.title, "Order shipped")
        XCTAssertEqual(push.body, "Tap to track")
        XCTAssertEqual(push.pushLogId?.uuidString.lowercased(), pushLogIdRaw)
        XCTAssertNotNil(push.pyrxAttributes)
        XCTAssertEqual(push.pyrxAttributes?["campaign_id"], .string("summer-2026"))
    }

    // MARK: - .pushReceived from background

    func test_backgroundNotification_firesPushReceived() async throws {
        let session = MockHTTPSession()
        enqueueAcceptedEvent(session)
        let pyrx = makePyrx(session: session)
        try await pyrx.initialize(config: makeConfig())

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        let completed = expectation(description: "bg completion")
        await pyrx.handleBackgroundNotification(userInfo: wellFormedPayload()) { result in
            XCTAssertEqual(result, .newData)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2.0)
        await waitForObservers()

        let events = collected.read().filter { if case .pushReceived = $0 { return true }; return false }
        XCTAssertEqual(events.count, 1)
    }

    // MARK: - .pushClicked from body tap

    func test_bodyTap_firesPushClicked_withNilActionId() async throws {
        let session = MockHTTPSession()
        enqueueAcceptedPushTelemetry(session) // /v1/push/opened
        let pyrx = makePyrx(session: session)
        try await pyrx.initialize(config: makeConfig())

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        let handlers = await pyrx.testAccessPushHandlers()
        await handlers!.dispatchResponse(
            userInfo: wellFormedPayload(),
            actionId: UNNotificationDefaultActionIdentifier
        )
        await waitForObservers()

        let clicks = collected.read().compactMap { event -> PushClickedEvent? in
            if case .pushClicked(let click) = event { return click }
            return nil
        }
        XCTAssertEqual(clicks.count, 1, "body tap must publish exactly one .pushClicked")
        XCTAssertNil(clicks[0].actionId, "body tap → actionId == nil")
        XCTAssertEqual(clicks[0].pushLogId?.uuidString.lowercased(), pushLogIdRaw)
        XCTAssertEqual(clicks[0].deepLink?.absoluteString, "pyrx://order/123")
    }

    // MARK: - .pushClicked from custom action

    func test_customAction_firesPushClicked_withActionId() async throws {
        let session = MockHTTPSession()
        enqueueAcceptedPushTelemetry(session) // /v1/push/click
        let pyrx = makePyrx(session: session)
        try await pyrx.initialize(config: makeConfig())

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        let handlers = await pyrx.testAccessPushHandlers()
        await handlers!.dispatchResponse(
            userInfo: wellFormedPayload(),
            actionId: "MARK_READ"
        )
        await waitForObservers()

        let clicks = collected.read().compactMap { event -> PushClickedEvent? in
            if case .pushClicked(let click) = event { return click }
            return nil
        }
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks[0].actionId, "MARK_READ")
    }

    // MARK: - .pushReceivedColdStart from cold-launch hook

    func test_coldStartLaunch_firesPushReceivedColdStart() async throws {
        let session = MockHTTPSession()
        enqueueAcceptedEvent(session) // $app_opened_from_push
        let pyrx = makePyrx(session: session)
        try await pyrx.initialize(config: makeConfig())

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        await pyrx.recordColdStartLaunch(userInfo: wellFormedPayload())
        await waitForObservers()

        let coldStarts = collected.read().filter {
            if case .pushReceivedColdStart = $0 { return true }
            return false
        }
        XCTAssertEqual(coldStarts.count, 1, "cold-start launch must publish exactly one .pushReceivedColdStart")
    }

    // MARK: - .queueDrained from successful drain

    func test_queueDrained_firesAfterSuccessfulDrain() async throws {
        let session = MockHTTPSession()
        // Two events will be tracked → two POSTs queued.
        enqueueAcceptedEvent(session)
        enqueueAcceptedEvent(session)

        let pyrx = makePyrx(session: session)
        try await pyrx.initialize(config: makeConfig())

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        try await pyrx.track(eventName: "evt_one")
        try await pyrx.track(eventName: "evt_two")

        // Wait for the queue to drain — drain triggers off enqueue.
        await pyrx.testAwaitQueueDrain()
        await waitForObservers()

        let drains = collected.read().compactMap { event -> Int? in
            if case .queueDrained(let count) = event { return count }
            return nil
        }
        XCTAssertGreaterThanOrEqual(drains.reduce(0, +), 2, "expected at least 2 successful drains in aggregate")
    }
}

// MARK: - Test-only access helpers on Pyrx

extension Pyrx {
    /// Test-only — surface the actor-private `pushHandlers` so observer
    /// fire-point tests can call into the same code path the public
    /// API takes (without instantiating UNNotification / UNNotificationResponse,
    /// which have no public initialisers). Internal scope.
    func testAccessPushHandlers() -> PushHandlers? {
        // The stored `pushHandlers` is private on `Pyrx` — but this
        // extension is in the same module (test target with
        // @testable import), so we expose it via mirror-style access.
        // Implemented as a tiny helper rather than reflecting so the
        // call site reads naturally.
        return _testPushHandlersAccessor()
    }
}

extension Pyrx {
    /// Bridge for the test-only accessor. Lives inside the actor
    /// scope so we can read the private property cleanly.
    fileprivate func _testPushHandlersAccessor() -> PushHandlers? {
        // The private property has no internal accessor — but
        // `@testable import` grants us synthesized internal access
        // to its symbol. Read directly.
        return self._pushHandlersForTests
    }
}
