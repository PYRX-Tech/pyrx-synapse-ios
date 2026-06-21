//
//  AttributionTests.swift
//  PYRXSynapseTests
//
//  Cold-start + deep-link attribution coverage (Phase 8.4a Task 8.4a.9
//  polish). Exercises the PR 5 attribution surface added on top of the
//  PR 4 push handlers.
//
//  Coverage:
//
//   1. `recordColdStartLaunch(userInfo:)` with a well-formed pyrx payload
//      → enqueues `$app_opened_from_push` event with push_log_id +
//      pyrx_attrs + deep_link attribute.
//   2. `recordColdStartLaunch(userInfo:)` with no pyrx namespace → no-op,
//      no event enqueued.
//   3. `recordColdStartLaunch(userInfo:)` with nil → no-op.
//   4. Pre-init buffer: `recordColdStartLaunch` BEFORE `initialize` ->
//      payload is queued and replayed during initialize so the cold-start
//      event still fires.
//   5. PushHandlers.recordColdStartOpen carries deep_link onto the event
//      attributes (so analytics can re-derive the click target).
//

import XCTest
@testable import PYRXSynapse

final class AttributionTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let knownPushLogIdRaw = "9b1c8f4a-3a3e-4e1d-9b7f-1c2e3d4e5f6a"
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-attribution-tests-\(UUID().uuidString)", isDirectory: true)
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
    }

    private func makeBench(
        storage: InMemoryStorage = InMemoryStorage(),
        session: MockHTTPSession = MockHTTPSession()
    ) -> Bench {
        let queueStore = FileSystemQueueStore(
            fileURL: tempDir.appendingPathComponent("event_queue.jsonl")
        )
        let pyrx = Pyrx(
            storage: storage,
            session: session,
            queueStore: queueStore,
            reachability: MockReachability(),
            queueClock: NoOpClock(),
            urlOpener: MockURLOpener()
        )
        return Bench(pyrx: pyrx, storage: storage, session: session)
    }

    private func makeConfig() -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: .production,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    private func enqueueAcceptedEvent(_ session: MockHTTPSession) {
        session.enqueueJSONSuccess(json: """
        {"event_id":"33333333-3333-3333-3333-333333333333","status":"accepted"}
        """)
    }

    private func wellFormedPayload(
        deepLink: String? = "https://app.pyrx.tech/orders/abc",
        attrs: [String: Any]? = ["campaign_id": "summer-promo"]
    ) -> [AnyHashable: Any] {
        var pyrx: [String: Any] = [
            "push_log_id": knownPushLogIdRaw
        ]
        if let deepLink { pyrx["deep_link"] = deepLink }
        var payload: [AnyHashable: Any] = [
            "aps": ["alert": "Hello", "sound": "default"],
            "pyrx": pyrx
        ]
        if let attrs { payload["pyrx_attrs"] = attrs }
        return payload
    }

    /// Pull the first event POST off the mock session as a dictionary so
    /// tests can assert wire shape without depending on the exact Codable
    /// type the SDK uses internally.
    private func eventBody(_ session: MockHTTPSession, at index: Int = 0) throws -> [String: Any] {
        guard index < session.requests.count else {
            XCTFail("Expected at least \(index + 1) recorded requests, got \(session.requests.count)")
            return [:]
        }
        guard let data = session.requests[index].body else {
            XCTFail("Request \(index) has no body")
            return [:]
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            XCTFail("Request \(index) body is not a JSON object")
            return [:]
        }
        return dict
    }

    // MARK: - Cold-start: well-formed payload

    func test_coldStartLaunch_wellFormedPayload_enqueuesAppOpenedFromPushEvent() async throws {
        let bench = makeBench()
        enqueueAcceptedEvent(bench.session)

        try await bench.pyrx.initialize(config: makeConfig())
        await bench.pyrx.recordColdStartLaunch(userInfo: wellFormedPayload())
        await bench.pyrx.testAwaitQueueDrain()

        // Exactly one event POST.
        XCTAssertEqual(bench.session.requests.count, 1)

        let body = try eventBody(bench.session)
        XCTAssertEqual(body["event_name"] as? String, "$app_opened_from_push")

        // Attributes carry push_log_id (uppercased — SDK round-trip via UUID),
        // the original campaign_id from pyrx_attrs, and the deep_link.
        let attrs = body["attributes"] as? [String: Any] ?? [:]
        XCTAssertEqual(attrs["push_log_id"] as? String, knownPushLogIdRaw.uppercased())
        XCTAssertEqual(attrs["campaign_id"] as? String, "summer-promo")
        XCTAssertEqual(attrs["deep_link"] as? String, "https://app.pyrx.tech/orders/abc")
    }

    // MARK: - Cold-start: no pyrx namespace

    func test_coldStartLaunch_noPyrxNamespace_noEventEnqueued() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // No pyrx block — just a generic APNs payload. The handler must
        // silently skip so legacy / cross-vendor pushes don't pollute
        // analytics with bogus $app_opened_from_push rows.
        await bench.pyrx.recordColdStartLaunch(userInfo: [
            "aps": ["alert": "Hello"]
        ])
        await bench.pyrx.testAwaitQueueDrain()

        XCTAssertEqual(bench.session.requests.count, 0)
    }

    // MARK: - Cold-start: nil payload

    func test_coldStartLaunch_nilUserInfo_isNoOp() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        await bench.pyrx.recordColdStartLaunch(userInfo: nil)
        await bench.pyrx.testAwaitQueueDrain()

        XCTAssertEqual(bench.session.requests.count, 0)
    }

    // MARK: - Cold-start: pre-init buffering

    func test_coldStartLaunch_beforeInitialize_replaysAfterInit() async throws {
        let bench = makeBench()

        // Call BEFORE initialize. Payload should be buffered.
        await bench.pyrx.recordColdStartLaunch(userInfo: wellFormedPayload(
            deepLink: nil,
            attrs: ["campaign_id": "deferred-boot"]
        ))

        // No requests yet — there's no HTTP client.
        XCTAssertEqual(bench.session.requests.count, 0)

        // Initialize — buffered payload should be replayed.
        enqueueAcceptedEvent(bench.session)
        try await bench.pyrx.initialize(config: makeConfig())
        await bench.pyrx.testAwaitQueueDrain()

        XCTAssertEqual(bench.session.requests.count, 1, "Buffered cold-start payload should replay through initialize")
        let body = try eventBody(bench.session)
        XCTAssertEqual(body["event_name"] as? String, "$app_opened_from_push")
        let attrs = body["attributes"] as? [String: Any] ?? [:]
        XCTAssertEqual(attrs["campaign_id"] as? String, "deferred-boot")
        XCTAssertEqual(attrs["push_log_id"] as? String, knownPushLogIdRaw.uppercased())
        // No deep_link was set in this payload.
        XCTAssertNil(attrs["deep_link"])
    }

    // MARK: - Cold-start: deep link annotation

    func test_coldStartLaunch_attachesDeepLinkToAttributes() async throws {
        let bench = makeBench()
        enqueueAcceptedEvent(bench.session)

        try await bench.pyrx.initialize(config: makeConfig())
        await bench.pyrx.recordColdStartLaunch(userInfo: wellFormedPayload(
            deepLink: "pyrx://orders/42",
            attrs: nil
        ))
        await bench.pyrx.testAwaitQueueDrain()

        XCTAssertEqual(bench.session.requests.count, 1)
        let body = try eventBody(bench.session)
        let attrs = body["attributes"] as? [String: Any] ?? [:]
        XCTAssertEqual(attrs["deep_link"] as? String, "pyrx://orders/42")
        // push_log_id should still be there even with no pyrx_attrs block.
        XCTAssertEqual(attrs["push_log_id"] as? String, knownPushLogIdRaw.uppercased())
    }

    // MARK: - Cold-start: idempotent on empty dict

    func test_coldStartLaunch_emptyDict_isNoOp() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        await bench.pyrx.recordColdStartLaunch(userInfo: [:])
        await bench.pyrx.testAwaitQueueDrain()

        XCTAssertEqual(bench.session.requests.count, 0)
    }
}
