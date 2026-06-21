//
//  EventsManagerTests.swift
//  PYRXSynapseTests
//
//  Public events surface (`Pyrx.track` + `Pyrx.screen`) coverage. All
//  filesystem state is contained to a per-test temp dir and all HTTP
//  goes through `MockHTTPSession` — no real network or Caches I/O.
//
//  Coverage:
//
//    1. track() rejects empty event name (.invalidConfig)
//    2. track() throws .notInitialized before initialize()
//    3. track() before identify() uses anonymousId as external_id
//    4. track() after identify() uses externalId as external_id
//    5. screen() emits $screen with screen_name attribute
//    6. screen() preserves caller properties but SDK-stamped fields win
//    7. POST /v1/events wire shape matches backend schema
//

import XCTest
@testable import PYRXSynapse

final class EventsManagerTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-events-tests-\(UUID().uuidString)", isDirectory: true)
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

    private struct Bench {
        let pyrx: Pyrx
        let storage: InMemoryStorage
        let session: MockHTTPSession
        let store: FileSystemQueueStore
        let reachability: MockReachability
    }

    private func makeBench(
        storage: InMemoryStorage = InMemoryStorage(),
        session: MockHTTPSession = MockHTTPSession()
    ) -> Bench {
        let queueStore = FileSystemQueueStore(
            fileURL: tempDir.appendingPathComponent("event_queue.jsonl")
        )
        let reachability = MockReachability()
        let pyrx = Pyrx(
            storage: storage,
            session: session,
            queueStore: queueStore,
            reachability: reachability,
            queueClock: NoOpClock()
        )
        return Bench(
            pyrx: pyrx,
            storage: storage,
            session: session,
            store: queueStore,
            reachability: reachability
        )
    }

    private func makeConfig(environment: PyrxEnvironment = .production) -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: environment,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    private func enqueueAcceptedResponse(_ session: MockHTTPSession, count: Int = 1) {
        for _ in 0..<count {
            session.enqueueJSONSuccess(json: """
            {"event_id":"33333333-3333-3333-3333-333333333333","status":"accepted"}
            """)
        }
    }

    private func enqueueIdentifyResponse(
        _ session: MockHTTPSession,
        contactId: String = "22222222-2222-2222-2222-222222222222",
        path: String = "first_sighting"
    ) {
        session.enqueueJSONSuccess(json: """
        {"contact_id":"\(contactId)","path":"\(path)",\
        "aliased_external_id":null,\
        "events_reattributed":0,"devices_reattributed":0,\
        "anonymous_contact_tombstoned":false}
        """)
    }

    /// Find a /v1/events request among the recorded requests (skipping
    /// any /v1/identify call that happened first).
    private func eventsRequest(in session: MockHTTPSession) -> RecordedRequest? {
        session.requests.first(where: { $0.request.url?.path == "/v1/events" })
    }

    // MARK: - Test 1: empty event name

    func test_track_rejectsEmptyEventName() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        do {
            try await bench.pyrx.track(eventName: "   ")
            XCTFail("expected .invalidConfig")
        } catch PyrxError.invalidConfig {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_screen_rejectsEmptyScreenName() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        do {
            try await bench.pyrx.screen(screenName: "")
            XCTFail("expected .invalidConfig")
        } catch PyrxError.invalidConfig {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Test 2: notInitialized

    func test_track_throwsNotInitialized_beforeInit() async throws {
        let bench = makeBench()

        do {
            try await bench.pyrx.track(eventName: "foo")
            XCTFail("expected .notInitialized")
        } catch PyrxError.notInitialized {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_screen_throwsNotInitialized_beforeInit() async throws {
        let bench = makeBench()

        do {
            try await bench.pyrx.screen(screenName: "home")
            XCTFail("expected .notInitialized")
        } catch PyrxError.notInitialized {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Test 3: external_id = anonymousId before identify

    func test_track_beforeIdentify_usesAnonymousIdAsExternalId() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        let anon = try XCTUnwrap(bench.storage.get(.anonymousId))

        enqueueAcceptedResponse(bench.session)
        try await bench.pyrx.track(eventName: "app_opened")

        // Allow the queue's drain Task to complete.
        await bench.pyrx.testAwaitQueueDrain()

        let request = try XCTUnwrap(eventsRequest(in: bench.session))
        let body = try XCTUnwrap(request.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["external_id"] as? String, anon)
        XCTAssertEqual(json?["event_name"] as? String, "app_opened")
    }

    // MARK: - Test 4: external_id = externalId after identify

    func test_track_afterIdentify_usesExternalIdAsExternalId() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // identify first
        enqueueIdentifyResponse(bench.session)
        _ = try await bench.pyrx.identify(externalId: "user_42")

        // then track
        enqueueAcceptedResponse(bench.session)
        try await bench.pyrx.track(eventName: "purchase_completed")
        await bench.pyrx.testAwaitQueueDrain()

        let request = try XCTUnwrap(eventsRequest(in: bench.session))
        let body = try XCTUnwrap(request.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["external_id"] as? String, "user_42")
    }

    // MARK: - Test 5: $screen wire shape

    func test_screen_emitsDollarScreenWithScreenNameAttribute() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        enqueueAcceptedResponse(bench.session)
        try await bench.pyrx.screen(screenName: "home")
        await bench.pyrx.testAwaitQueueDrain()

        let request = try XCTUnwrap(eventsRequest(in: bench.session))
        let body = try XCTUnwrap(request.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["event_name"] as? String, "$screen")
        let attrs = json?["attributes"] as? [String: Any]
        XCTAssertEqual(attrs?["screen_name"] as? String, "home")
    }

    // MARK: - Test 6: caller cannot spoof screen_name

    func test_screen_callerPropertiesCannotOverwriteScreenName() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        enqueueAcceptedResponse(bench.session)
        try await bench.pyrx.screen(
            screenName: "cart",
            properties: [
                "screen_name": .string("spoofed_value"),
                "item_count": .int(3),
            ]
        )
        await bench.pyrx.testAwaitQueueDrain()

        let request = try XCTUnwrap(eventsRequest(in: bench.session))
        let body = try XCTUnwrap(request.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let attrs = json?["attributes"] as? [String: Any]
        XCTAssertEqual(attrs?["screen_name"] as? String, "cart", "SDK-stamped screen_name must win")
        XCTAssertEqual(attrs?["item_count"] as? Int, 3, "non-conflicting properties must be preserved")
    }

    // MARK: - Test 7: full wire shape

    func test_track_fullWireShape_matchesBackendSchema() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        enqueueAcceptedResponse(bench.session)
        try await bench.pyrx.track(
            eventName: "checkout_started",
            properties: [
                "cart_total": .double(149.99),
                "items": .int(3),
                "discount_code": .string("SUMMER25"),
                "first_purchase": .bool(true),
            ]
        )
        await bench.pyrx.testAwaitQueueDrain()

        let request = try XCTUnwrap(eventsRequest(in: bench.session))
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // Required wire fields per app/schemas/event.py EventIngest
        XCTAssertNotNil(json["external_id"] as? String)
        XCTAssertEqual(json["event_name"] as? String, "checkout_started")
        XCTAssertNotNil(json["attributes"] as? [String: Any])
        XCTAssertNotNil(json["idempotency_key"] as? String)
        XCTAssertNotNil(json["occurred_at"] as? String)

        // occurred_at parseable as ISO-8601
        let occurred = try XCTUnwrap(json["occurred_at"] as? String)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: occurred), "occurred_at must parse as ISO-8601 with fractional seconds")

        // attributes round-trip
        let attrs = try XCTUnwrap(json["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["cart_total"] as? Double, 149.99)
        XCTAssertEqual(attrs["items"] as? Int, 3)
        XCTAssertEqual(attrs["discount_code"] as? String, "SUMMER25")
        XCTAssertEqual(attrs["first_purchase"] as? Bool, true)

        // Deprecated fields must NOT be emitted by the iOS SDK
        XCTAssertNil(json["user_id"], "SDK must emit external_id, not deprecated user_id")
        XCTAssertNil(json["contact_overrides"], "SDK must emit contact, not deprecated contact_overrides")
    }

    // MARK: - Test 8: queue file persisted

    func test_track_persistsEventToDisk() async throws {
        // Use a separate temp dir with no canned responses so we can
        // inspect the on-disk state before drain success.
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        try await bench.pyrx.track(eventName: "no_network_event")

        // The drain attempt has no canned response and will fail
        // (URLError / mock 'no canned response queued'). Event must
        // remain on disk.
        await bench.pyrx.testAwaitQueueDrain()

        let data = try bench.store.read()
        XCTAssertNotNil(data)
        let lines = data!.split(separator: 0x0A).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "event must be on disk pending retry")

        let decoded = try JSONDecoder().decode(QueuedEvent.self, from: Data(lines[0]))
        XCTAssertEqual(decoded.eventName, "no_network_event")
    }
}
