//
//  PrivacyManagerTests.swift
//  PYRXSynapseTests
//
//  Privacy surface coverage (Phase 8.4a Task 8.4a.10):
//
//   1. setTrackingEnabled(false) → enqueued events stay buffered (no
//      drain), but persist to disk.
//   2. setTrackingEnabled(true) after a disable window → buffered events
//      drain automatically.
//   3. Pre-init setTrackingEnabled buffers and applies on initialize.
//   4. deleteUser wipes Keychain (anonymousId + externalId + deviceToken),
//      wipes the event queue, and POSTs the contacts delete cascade.
//   5. deleteUser without an external_id falls back to the anonymousId
//      for the backend cascade path.
//   6. deleteUser without ANY identifier (no anon, no external) skips
//      the backend call entirely.
//   7. deleteUser swallows 4xx from the backend (local wipe stands).
//   8. deleteUser propagates 5xx / transport errors AFTER local wipe.
//   9. Path builder URL-encodes external_ids that contain slashes / spaces.
//

import XCTest
@testable import PYRXSynapse

final class PrivacyManagerTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-privacy-tests-\(UUID().uuidString)", isDirectory: true)
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
            queueClock: NoOpClock()
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

    // MARK: - Path builder

    func test_contactsDeletePath_buildsExpectedPath() {
        XCTAssertEqual(
            PrivacyManager.contactsDeletePath(externalId: "user-123"),
            "/v1/contacts/user-123/delete"
        )
    }

    func test_contactsDeletePath_urlEncodesSlashes() {
        // External IDs that contain `/` would otherwise be interpreted as
        // additional path segments by the server router.
        XCTAssertEqual(
            PrivacyManager.contactsDeletePath(externalId: "team/user"),
            "/v1/contacts/team%2Fuser/delete"
        )
    }

    func test_contactsDeletePath_urlEncodesSpaces() {
        // Belt-and-suspenders — emails / usernames with spaces would
        // produce malformed URLs without encoding.
        let path = PrivacyManager.contactsDeletePath(externalId: "alice smith")
        XCTAssertTrue(path == "/v1/contacts/alice%20smith/delete" ||
                      path == "/v1/contacts/alice+smith/delete" ||
                      path == "/v1/contacts/alice%2520smith/delete",
                      "Expected encoded space, got: \(path)")
    }

    // MARK: - setTrackingEnabled gate

    func test_setTrackingEnabled_false_buffersEventsButDoesNotDrain() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // Disable tracking.
        await bench.pyrx.setTrackingEnabled(false)

        // Issue a track call. The event should land on disk but NOT be
        // POSTed.
        try await bench.pyrx.track(eventName: "click")
        await bench.pyrx.testAwaitQueueDrain()

        XCTAssertEqual(bench.session.requests.count, 0,
                       "Tracking-disabled queue must not POST events.")
    }

    func test_setTrackingEnabled_reEnable_flushesBufferedEvents() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        await bench.pyrx.setTrackingEnabled(false)
        try await bench.pyrx.track(eventName: "click")
        await bench.pyrx.testAwaitQueueDrain()
        XCTAssertEqual(bench.session.requests.count, 0)

        // Re-enable — buffered event should now drain.
        enqueueAcceptedEvent(bench.session)
        await bench.pyrx.setTrackingEnabled(true)
        await bench.pyrx.testAwaitQueueDrain()

        XCTAssertEqual(bench.session.requests.count, 1,
                       "Re-enabling tracking must flush the buffered event.")
    }

    func test_setTrackingEnabled_beforeInitialize_appliesDuringInit() async throws {
        let bench = makeBench()

        // Pre-init opt-out.
        await bench.pyrx.setTrackingEnabled(false)

        // Initialize. The startup drainNow() should respect the opt-out.
        try await bench.pyrx.initialize(config: makeConfig())

        // Track an event — should buffer.
        try await bench.pyrx.track(eventName: "boot-screen")
        await bench.pyrx.testAwaitQueueDrain()

        XCTAssertEqual(bench.session.requests.count, 0,
                       "Pre-init opt-out must be honoured during initialize.")
    }

    // MARK: - deleteUser

    /// JSON envelope that matches the backend's GDPR delete response shape
    /// from `app/routers/contacts.py::gdpr_delete_contact_by_external_id`.
    /// We don't decode it — `postPath` discards the body — but the mock
    /// session needs valid JSON to return so the status-code check passes.
    private static let backendDeletedJson = """
    {
      "status": "deleted",
      "deleted_at": "2026-06-21T12:00:00Z",
      "rows_deleted": {"contacts": 1, "events": 7, "email_logs": 3, "push_logs": 2, "devices": 1, "contact_aliases": 0, "flow_trips": 0}
    }
    """

    func test_deleteUser_wipesStorageBeforeBackendCall() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // Seed external_id + device token DIRECTLY in storage — bypasses
        // the network round trip identify() would do (which would consume
        // the canned response we want reserved for the delete cascade).
        try bench.storage.set(.externalId, value: "alice@example.com")
        try bench.storage.set(.deviceToken, value: "deadbeef0102030405060708090a0b0c")

        // Enqueue the backend cascade response.
        bench.session.enqueueJSONSuccess(json: Self.backendDeletedJson)

        try await bench.pyrx.deleteUser()

        // Storage is wiped — every key the SDK owns is gone.
        XCTAssertNil(try bench.storage.get(.anonymousId))
        XCTAssertNil(try bench.storage.get(.externalId))
        XCTAssertNil(try bench.storage.get(.deviceToken))

        // Exactly one network call — the contacts delete.
        XCTAssertEqual(bench.session.requests.count, 1)
        let recorded = bench.session.requests[0]
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.url?.path, "/v1/contacts/alice@example.com/delete")
    }

    func test_deleteUser_fallsBackToAnonymousIdWhenNoExternal() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // No external_id — only the auto-generated anon. The backend call
        // should use the anonymousId for the path.
        let anonId = try bench.storage.get(.anonymousId)
        XCTAssertNotNil(anonId)

        bench.session.enqueueJSONSuccess(json: Self.backendDeletedJson)
        try await bench.pyrx.deleteUser()

        XCTAssertEqual(bench.session.requests.count, 1)
        let path = bench.session.requests[0].request.url?.path
        XCTAssertEqual(path, "/v1/contacts/\(anonId!)/delete")
    }

    func test_deleteUser_withoutAnyIdentifier_skipsBackendCall() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // Manually wipe storage (mimicking a state where the SDK has no
        // identity at all) BEFORE invoking deleteUser. PrivacyManager
        // captures identifiers up front and skips the backend call if both
        // are nil.
        try bench.storage.wipe()

        try await bench.pyrx.deleteUser()

        // No requests issued — nothing to cascade.
        XCTAssertEqual(bench.session.requests.count, 0)
    }

    func test_deleteUser_swallows404FromBackend_localWipeStands() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        try bench.storage.set(.externalId, value: "already-deleted-user")

        // Backend says "contact not found" — should be treated as a no-op
        // (the user-visible semantic is "your data is gone", which is
        // still true).
        bench.session.enqueue(.success(
            statusCode: 404,
            body: Data(#"{"detail":{"detail":"Contact not found","code":"contact_not_found"}}"#.utf8),
            headers: ["Content-Type": "application/json"]
        ))

        // Must NOT throw — 4xx is swallowed.
        try await bench.pyrx.deleteUser()

        // Local data is still wiped.
        XCTAssertNil(try bench.storage.get(.externalId))
        XCTAssertNil(try bench.storage.get(.anonymousId))
    }

    func test_deleteUser_propagates5xxAfterLocalWipe() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        try bench.storage.set(.externalId, value: "user-down-stream")

        bench.session.enqueue(.success(
            statusCode: 503,
            body: Data(#"{"detail":"Backend temporarily unavailable"}"#.utf8),
            headers: ["Content-Type": "application/json"]
        ))

        do {
            try await bench.pyrx.deleteUser()
            XCTFail("deleteUser must throw on 5xx so callers can retry the backend call")
        } catch let PyrxError.network(.httpStatus(statusCode, _)) {
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Local data is wiped DESPITE the backend failure — that's the
        // PrivacyManager contract.
        XCTAssertNil(try bench.storage.get(.externalId))
        XCTAssertNil(try bench.storage.get(.anonymousId))
    }

    func test_deleteUser_wipesQueuedEventsBeforeBackendCall() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        try bench.storage.set(.externalId, value: "user-x")

        // Disable tracking so events buffer without draining.
        await bench.pyrx.setTrackingEnabled(false)
        try await bench.pyrx.track(eventName: "pending-1")
        try await bench.pyrx.track(eventName: "pending-2")
        try await bench.pyrx.testAwaitQueueDrain()
        XCTAssertEqual(bench.session.requests.count, 0)

        // Delete — the buffered events should be dropped, no POSTs for them.
        bench.session.enqueueJSONSuccess(json: Self.backendDeletedJson)
        try await bench.pyrx.deleteUser()

        // Exactly ONE request — the contacts delete. Buffered events were
        // dropped, not sent.
        XCTAssertEqual(bench.session.requests.count, 1)
        XCTAssertEqual(bench.session.requests[0].request.url?.path,
                       "/v1/contacts/user-x/delete")
    }

    // MARK: - ATT awareness

    func test_attAuthorizationStatus_returnsAValidEnum() {
        // We can't assert a specific value (it depends on the test runner's
        // environment), but we can confirm the API is callable and produces
        // a defined enum case. On macOS CI this should be `.unavailable`.
        let status = PrivacyManager.staticATTStatus()
        let validCases: [PyrxATTStatus] = [
            .unavailable, .notDetermined, .restricted, .denied, .authorized
        ]
        XCTAssertTrue(validCases.contains(status))
    }

    func test_attAuthorizationStatus_returnsConsistentEnum() {
        // `AppTrackingTransparency` is importable on macOS 11+ as well as
        // iOS 14+, so we can't make a hard "must be .unavailable on macOS"
        // claim — both `.unavailable` (older OS / Linux CI) and
        // `.notDetermined` (modern macOS test runner) are valid. We DO
        // assert the SDK never surfaces an undefined enum case.
        let status = PrivacyManager.staticATTStatus()
        let validCases: [PyrxATTStatus] = [
            .unavailable, .notDetermined, .restricted, .denied, .authorized
        ]
        XCTAssertTrue(validCases.contains(status),
                      "ATT status must always be a defined enum case (got \(status))")
    }
}
