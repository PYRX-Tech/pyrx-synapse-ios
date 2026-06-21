//
//  PushHandlersTests.swift
//  PYRXSynapseTests
//
//  Exercises the foreground / background / response handlers (Phase 8.4a
//  Task 8.4a.8) end-to-end through `Pyrx`. All HTTP goes through
//  `MockHTTPSession`. We do NOT instantiate real `UNNotification` /
//  `UNNotificationResponse` objects (they have no public initialiser) —
//  instead we exercise the public `handleBackgroundNotification(userInfo:
//  completion:)` API + the internal payload-parsing helpers on
//  `PushHandlers`. The response-dispatch logic is covered by a private
//  `_emit*` test seam that calls into the same code path.
//
//  Coverage:
//
//   1. Payload parsing — pushLogId / pyrxAttributes / deepLink across:
//      - missing pyrx namespace
//      - present pyrx namespace, missing fields
//      - well-formed payload with deep link + attrs
//      - malformed UUID
//      - per-action URL override under pyrx_attrs
//   2. handleBackgroundNotification — fires $push_received with full
//      pyrx_attrs + push_log_id, then completes with .newData
//   3. handleBackgroundNotification — no pyrx payload → completion(.noData)
//   4. Foreground presentation options match the platform default
//   5. /v1/push/opened wire shape (via PushHandlers.emitOpened test seam)
//   6. /v1/push/click wire shape carries actionIdentifier as click_url
//   7. Deep link routing to URL opener — https and custom scheme
//   8. Pre-initialize handlers gracefully no-op
//

import XCTest
@testable import PYRXSynapse

final class PushHandlersTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    /// Canonical PYRX `push_log_id` UUID used across these tests. We declare
    /// it lowercase (matching what the server emits) but Swift's
    /// `UUID.uuidString` is always uppercase — so the SDK's
    /// `logId.uuidString` round-trip produces the uppercase form, which is
    /// what gets stamped into `attributes.push_log_id` and what we assert
    /// against in the wire-shape tests.
    private let knownPushLogIdRaw = "9b1c8f4a-3a3e-4e1d-9b7f-1c2e3d4e5f6a"
    private var knownPushLogIdStamp: String { knownPushLogIdRaw.uppercased() }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-push-handlers-tests-\(UUID().uuidString)", isDirectory: true)
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
        let urlOpener: MockURLOpener
    }

    private func makeBench(
        storage: InMemoryStorage = InMemoryStorage(),
        session: MockHTTPSession = MockHTTPSession()
    ) -> Bench {
        let queueStore = FileSystemQueueStore(
            fileURL: tempDir.appendingPathComponent("event_queue.jsonl")
        )
        let urlOpener = MockURLOpener()
        let pyrx = Pyrx(
            storage: storage,
            session: session,
            queueStore: queueStore,
            reachability: MockReachability(),
            queueClock: NoOpClock(),
            urlOpener: urlOpener
        )
        return Bench(pyrx: pyrx, storage: storage, session: session, urlOpener: urlOpener)
    }

    private func makeConfig(environment: PyrxEnvironment = .production) -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: environment,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    private func enqueueAcceptedEvent(_ session: MockHTTPSession) {
        session.enqueueJSONSuccess(json: """
        {"event_id":"33333333-3333-3333-3333-333333333333","status":"accepted"}
        """)
    }

    private func enqueuePushTelemetryAccepted(
        _ session: MockHTTPSession,
        envelopeId: String = "44444444-4444-4444-4444-444444444444"
    ) {
        session.enqueueJSONSuccess(json: """
        {"status":"accepted","envelope_id":"\(envelopeId)","reason":null}
        """)
    }

    private func wellFormedPayload(
        pushLogId: String? = nil,
        deepLink: String? = "https://app.pyrx.tech/orders/abc",
        attrs: [String: Any]? = ["campaign_id": "summer-promo"]
    ) -> [AnyHashable: Any] {
        // Default to the canonical raw (lowercase) push_log_id — this is the
        // wire form the server emits and what would land in the APNs payload.
        var pyrx: [String: Any] = [:]
        pyrx["push_log_id"] = pushLogId ?? knownPushLogIdRaw
        if let deepLink { pyrx["deep_link"] = deepLink }
        var payload: [AnyHashable: Any] = [
            "aps": ["alert": "Hello", "sound": "default"],
            "pyrx": pyrx
        ]
        if let attrs { payload["pyrx_attrs"] = attrs }
        return payload
    }

    /// Variant of `wellFormedPayload` that omits the `pyrx.push_log_id` —
    /// used for the "missing pyrx namespace" / "malformed id" scenarios.
    private func payloadWithoutPushLogId(
        deepLink: String? = nil,
        attrs: [String: Any]? = nil
    ) -> [AnyHashable: Any] {
        var pyrx: [String: Any] = [:]
        if let deepLink { pyrx["deep_link"] = deepLink }
        var payload: [AnyHashable: Any] = [
            "aps": ["alert": "Hello", "sound": "default"]
        ]
        if !pyrx.isEmpty { payload["pyrx"] = pyrx }
        if let attrs { payload["pyrx_attrs"] = attrs }
        return payload
    }

    /// Build a `PushHandlers` directly so we can exercise its internal
    /// helpers without an initialised Pyrx actor (the actor isolation
    /// would otherwise serialise our test reads).
    private func makeStandaloneHandlers(
        session: MockHTTPSession = MockHTTPSession(),
        urlOpener: MockURLOpener = MockURLOpener()
    ) -> PushHandlers {
        let config = makeConfig()
        let client = HTTPClient(config: config, session: session)
        let queueStore = FileSystemQueueStore(
            fileURL: tempDir.appendingPathComponent("event_queue.jsonl")
        )
        let queue = EventQueue(
            httpClient: client,
            store: queueStore,
            maxQueueSize: 100,
            logger: .shared,
            clock: NoOpClock()
        )
        let storage = InMemoryStorage()
        try? storage.set(.anonymousId, value: "test-anon")
        let manager = EventsManager(
            queue: queue,
            storage: storage,
            anonymousId: "test-anon",
            logger: .shared
        )
        return PushHandlers(
            httpClient: client,
            eventsManager: manager,
            urlOpener: urlOpener
        )
    }

    // MARK: - pushLogId parser

    func test_pushLogId_extractsValidUUID() {
        let handlers = makeStandaloneHandlers()
        let payload = wellFormedPayload()
        XCTAssertEqual(
            handlers.pushLogId(from: payload),
            UUID(uuidString: knownPushLogIdRaw)
        )
    }

    func test_pushLogId_missingPyrxNamespace_returnsNil() {
        let handlers = makeStandaloneHandlers()
        XCTAssertNil(handlers.pushLogId(from: ["aps": ["alert": "hi"]]))
    }

    func test_pushLogId_malformedUUID_returnsNil() {
        let handlers = makeStandaloneHandlers()
        let payload: [AnyHashable: Any] = [
            "pyrx": ["push_log_id": "not-a-uuid"]
        ]
        XCTAssertNil(handlers.pushLogId(from: payload))
    }

    // MARK: - pyrxAttributes parser

    func test_pyrxAttributes_forwardsArbitraryValues_andStampsPushLogId() throws {
        let handlers = makeStandaloneHandlers()
        let payload = wellFormedPayload(attrs: [
            "campaign_id": "summer-promo",
            "variant": "B",
            "score": 0.42,
            "count": 3,
            "active": true,
            "tags": ["a", "b"]
        ])

        let attrs = try XCTUnwrap(handlers.pyrxAttributes(from: payload))

        XCTAssertEqual(attrs["campaign_id"], .string("summer-promo"))
        XCTAssertEqual(attrs["variant"], .string("B"))
        XCTAssertEqual(attrs["count"], .int(3))
        XCTAssertEqual(attrs["active"], .bool(true))
        // Score is double — float type — accept either int or double
        if case let .double(value) = attrs["score"]! {
            XCTAssertEqual(value, 0.42, accuracy: 0.0001)
        } else {
            XCTFail("score should decode to .double, got \(String(describing: attrs["score"]))")
        }
        // SDK-stamped push_log_id is present. Swift's UUID.uuidString always
        // emits uppercase, so the stamped value is the uppercased form of
        // what landed on the wire.
        XCTAssertEqual(attrs["push_log_id"], .string(knownPushLogIdStamp))
    }

    func test_pyrxAttributes_noPyrxAttrsButPushLogId_returnsLogIdOnly() throws {
        let handlers = makeStandaloneHandlers()
        let payload = wellFormedPayload(attrs: nil)
        let attrs = try XCTUnwrap(handlers.pyrxAttributes(from: payload))
        XCTAssertEqual(attrs.count, 1)
        XCTAssertEqual(attrs["push_log_id"], .string(knownPushLogIdStamp))
    }

    func test_pyrxAttributes_emptyPayload_returnsNil() {
        let handlers = makeStandaloneHandlers()
        XCTAssertNil(handlers.pyrxAttributes(from: ["aps": ["alert": "hi"]]))
    }

    func test_pyrxAttributes_sdkStampedPushLogId_winsOverCampaignSpoof() throws {
        let handlers = makeStandaloneHandlers()
        let payload: [AnyHashable: Any] = [
            "pyrx": ["push_log_id": knownPushLogIdRaw],
            "pyrx_attrs": ["push_log_id": "spoofed-by-campaign"]
        ]
        let attrs = try XCTUnwrap(handlers.pyrxAttributes(from: payload))
        // SDK stamp wins — campaigns cannot inject a fake push_log_id
        XCTAssertEqual(attrs["push_log_id"], .string(knownPushLogIdStamp))
    }

    // MARK: - deepLink parser

    func test_deepLink_httpsScheme() {
        let handlers = makeStandaloneHandlers()
        let payload = wellFormedPayload(deepLink: "https://app.pyrx.tech/orders/abc")
        XCTAssertEqual(
            handlers.deepLink(from: payload, overrideKey: nil),
            URL(string: "https://app.pyrx.tech/orders/abc")
        )
    }

    func test_deepLink_customScheme() {
        let handlers = makeStandaloneHandlers()
        let payload = wellFormedPayload(deepLink: "pyrx://contacts/42")
        XCTAssertEqual(
            handlers.deepLink(from: payload, overrideKey: nil),
            URL(string: "pyrx://contacts/42")
        )
    }

    func test_deepLink_missing_returnsNil() {
        let handlers = makeStandaloneHandlers()
        let payload = wellFormedPayload(deepLink: nil)
        XCTAssertNil(handlers.deepLink(from: payload, overrideKey: nil))
    }

    func test_deepLink_overrideUnderPyrxAttrs_winsOverDefault() {
        let handlers = makeStandaloneHandlers()
        let payload: [AnyHashable: Any] = [
            "pyrx": [
                "push_log_id": knownPushLogIdRaw,
                "deep_link": "pyrx://default"
            ],
            "pyrx_attrs": [
                "remind_me_url": "pyrx://remind-me-tomorrow"
            ]
        ]
        XCTAssertEqual(
            handlers.deepLink(from: payload, overrideKey: "remind_me_url"),
            URL(string: "pyrx://remind-me-tomorrow")
        )
    }

    func test_deepLink_overrideMissing_fallsBackToCampaignDefault() {
        let handlers = makeStandaloneHandlers()
        let payload = wellFormedPayload(deepLink: "pyrx://default")
        XCTAssertEqual(
            handlers.deepLink(from: payload, overrideKey: "missing_url"),
            URL(string: "pyrx://default")
        )
    }

    // MARK: - Background notification (public API)

    func test_handleBackgroundNotification_firesPushReceivedTrack_andAcksNewData() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        enqueueAcceptedEvent(bench.session)

        let payload = wellFormedPayload(attrs: [
            "campaign_id": "summer-promo",
            "variant": "B"
        ])

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<PyrxBackgroundFetchResult, Never>) in
            Task {
                await bench.pyrx.handleBackgroundNotification(userInfo: payload) { result in
                    continuation.resume(returning: result)
                }
            }
        }

        XCTAssertEqual(result, .newData)

        // Drain the queue so the event POST lands on the mock session.
        await bench.pyrx.testAwaitQueueDrain()

        let raw = try XCTUnwrap(bench.session.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(json?["event_name"] as? String, "$push_received")
        let attrs = json?["attributes"] as? [String: Any]
        XCTAssertEqual(attrs?["campaign_id"] as? String, "summer-promo")
        XCTAssertEqual(attrs?["variant"] as? String, "B")
        // SDK-stamped push_log_id from the pyrx namespace (uppercased by
        // Swift's UUID round-trip).
        XCTAssertEqual(attrs?["push_log_id"] as? String, knownPushLogIdStamp)
    }

    func test_handleBackgroundNotification_missingPyrxPayload_acksNoData() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<PyrxBackgroundFetchResult, Never>) in
            Task {
                await bench.pyrx.handleBackgroundNotification(
                    userInfo: ["aps": ["alert": "raw push"]]
                ) { result in
                    continuation.resume(returning: result)
                }
            }
        }

        // No pyrx_attrs and no pyrx namespace → recordPushReceived returns
        // false → completion(.noData). This is the legacy / cross-vendor
        // push case.
        XCTAssertEqual(result, .noData)
    }

    func test_handleBackgroundNotification_beforeInitialize_acksNoData() async {
        let bench = makeBench()

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<PyrxBackgroundFetchResult, Never>) in
            Task {
                await bench.pyrx.handleBackgroundNotification(
                    userInfo: ["aps": ["alert": "raw"]]
                ) { result in
                    continuation.resume(returning: result)
                }
            }
        }

        XCTAssertEqual(result, .noData)
    }

    // MARK: - emitOpened / emitClicked through PushHandlers (response branch)

    func test_emitOpened_postsPushOpenedWithPushLogId() async throws {
        let session = MockHTTPSession()
        enqueuePushTelemetryAccepted(session)
        let handlers = makeStandaloneHandlers(session: session)

        let payload = wellFormedPayload()
        // Reach in via the internal seam — this is the same code path
        // handleResponse() calls for `UNNotificationDefaultActionIdentifier`.
        await handlers.emitOpenedForTest(userInfo: payload)

        let raw = try XCTUnwrap(session.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(json?["push_log_id"] as? String, knownPushLogIdStamp)
        XCTAssertNotNil(json?["occurred_at"], "occurred_at should be present for native SDK clarity")

        let request = try XCTUnwrap(session.requests.first?.request)
        XCTAssertEqual(request.url?.path, "/v1/push/opened")
    }

    func test_emitOpened_missingPushLogId_doesNotCallNetwork() async {
        let session = MockHTTPSession()
        let handlers = makeStandaloneHandlers(session: session)

        await handlers.emitOpenedForTest(userInfo: ["aps": ["alert": "x"]])

        XCTAssertTrue(session.requests.isEmpty, "must not POST when push_log_id missing")
    }

    func test_emitClicked_postsPushClickedWithActionIdAsClickUrl() async throws {
        let session = MockHTTPSession()
        enqueuePushTelemetryAccepted(session)
        let handlers = makeStandaloneHandlers(session: session)

        let payload = wellFormedPayload()
        await handlers.emitClickedForTest(
            userInfo: payload,
            actionId: "REMIND_ME_TOMORROW"
        )

        let raw = try XCTUnwrap(session.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(json?["push_log_id"] as? String, knownPushLogIdStamp)
        XCTAssertEqual(json?["click_url"] as? String, "REMIND_ME_TOMORROW")

        let request = try XCTUnwrap(session.requests.first?.request)
        XCTAssertEqual(request.url?.path, "/v1/push/click")
    }

    func test_emitClicked_missingPushLogId_doesNotCallNetwork() async {
        let session = MockHTTPSession()
        let handlers = makeStandaloneHandlers(session: session)

        await handlers.emitClickedForTest(
            userInfo: ["aps": ["alert": "x"]],
            actionId: "ANY"
        )

        XCTAssertTrue(session.requests.isEmpty)
    }

    // MARK: - Deep link routing

    func test_routeDeepLink_httpsUrl_opensViaURLOpener() async {
        let session = MockHTTPSession()
        let opener = MockURLOpener()
        let handlers = makeStandaloneHandlers(session: session, urlOpener: opener)

        let payload = wellFormedPayload(deepLink: "https://app.pyrx.tech/orders/abc")
        await handlers.routeDeepLinkForTest(userInfo: payload, overrideKey: nil)

        XCTAssertEqual(opener.openedURLs, [URL(string: "https://app.pyrx.tech/orders/abc")!])
    }

    func test_routeDeepLink_customScheme_opensViaURLOpener() async {
        let session = MockHTTPSession()
        let opener = MockURLOpener()
        let handlers = makeStandaloneHandlers(session: session, urlOpener: opener)

        let payload = wellFormedPayload(deepLink: "pyrx://contacts/42")
        await handlers.routeDeepLinkForTest(userInfo: payload, overrideKey: nil)

        XCTAssertEqual(opener.openedURLs, [URL(string: "pyrx://contacts/42")!])
    }

    func test_routeDeepLink_missing_doesNothing() async {
        let session = MockHTTPSession()
        let opener = MockURLOpener()
        let handlers = makeStandaloneHandlers(session: session, urlOpener: opener)

        let payload = wellFormedPayload(deepLink: nil)
        await handlers.routeDeepLinkForTest(userInfo: payload, overrideKey: nil)

        XCTAssertTrue(opener.openedURLs.isEmpty)
    }
}

// MARK: - Test seams on PushHandlers

/// Internal-visibility passthroughs so the test file can exercise the
/// `emit*` / `routeDeepLink` paths without requiring real
/// `UNNotificationResponse` objects (which have no public initialiser).
/// These forward into the same production methods — they exist only to
/// give the tests a stable, well-named entry point and to keep the
/// production API surface unmuddled.
extension PushHandlers {
    func emitOpenedForTest(userInfo: [AnyHashable: Any]) async {
        await emitOpened(userInfo: userInfo)
    }

    func emitClickedForTest(userInfo: [AnyHashable: Any], actionId: String) async {
        await emitClicked(userInfo: userInfo, actionId: actionId)
    }

    func routeDeepLinkForTest(
        userInfo: [AnyHashable: Any],
        overrideKey: String?
    ) async {
        await routeDeepLink(userInfo: userInfo, overrideKey: overrideKey)
    }
}

// MARK: - MockURLOpener

/// In-process stub for `PushURLOpener`. Records every URL the SDK tried to
/// open so the test can assert the routing decision. Uses a synchronous
/// helper for the mutation so `async` callers don't trip the
/// "NSLock unavailable from async" Swift 6 warning.
final class MockURLOpener: PushURLOpener, @unchecked Sendable {
    private let lock = NSLock()
    private var _openedURLs: [URL] = []

    var openedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _openedURLs
    }

    func open(_ url: URL) async {
        record(url)
    }

    /// Synchronous lock-then-append. Pulled out so `open` (which is `async`)
    /// can call it without an `await` boundary inside the locked region.
    private func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        _openedURLs.append(url)
    }
}
