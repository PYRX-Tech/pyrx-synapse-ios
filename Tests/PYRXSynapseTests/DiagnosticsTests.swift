//
//  DiagnosticsTests.swift
//  PYRXSynapseTests
//
//  Coverage for the enriched `Pyrx.debugInfo()` snapshot (Phase 8.4a
//  Task 8.4a.11):
//
//   1. fingerprint(forDeviceToken:) — nil/empty input → nil output.
//   2. fingerprint(forDeviceToken:) — long token → ellipsis-prefixed last 8.
//   3. fingerprint(forDeviceToken:) — short token (<= 8 chars) →
//      ellipsis-prefixed full string.
//   4. debugInfo() pre-init → safe defaults (not initialized, tracking on,
//      empty queue, no identifiers).
//   5. debugInfo() post-init → reflects env, baseUrl, anonymousId, log level.
//   6. debugInfo() reflects device-token fingerprint AFTER push registration.
//   7. debugInfo() reflects tracking gate after setTrackingEnabled(false).
//   8. debugInfo() reflects event queue depth after a buffered enqueue.
//   9. debugInfo() lastDrainAt is nil before any drain, populated after.
//

import XCTest
@testable import PYRXSynapse

final class DiagnosticsTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeConfig(environment: PyrxEnvironment = .production) -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: environment,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    // MARK: - fingerprint helper

    func test_fingerprint_nilToken_returnsNil() {
        XCTAssertNil(PyrxDebugInfo.fingerprint(forDeviceToken: nil))
    }

    func test_fingerprint_emptyToken_returnsNil() {
        XCTAssertNil(PyrxDebugInfo.fingerprint(forDeviceToken: ""))
    }

    func test_fingerprint_longToken_returnsLastEightWithEllipsisPrefix() {
        // A canonical 64-hex-char APNs token.
        let token = "0102030405060708090a0b0c0d0e0f1011121314151617181920212223242526"
        let fp = PyrxDebugInfo.fingerprint(forDeviceToken: token)
        XCTAssertEqual(fp, "…23242526")
    }

    func test_fingerprint_shortToken_returnsFullStringWithEllipsisPrefix() {
        // Defensive — production tokens are never short, but a malformed
        // token must not crash the diagnostic snapshot.
        XCTAssertEqual(PyrxDebugInfo.fingerprint(forDeviceToken: "abcd"), "…abcd")
        // Boundary at exactly 8 — also handled by the "short" branch.
        XCTAssertEqual(PyrxDebugInfo.fingerprint(forDeviceToken: "12345678"), "…12345678")
    }

    // MARK: - debugInfo pre-init

    func test_debugInfo_preInitialize_safeDefaults() async {
        let bench = makeBench()
        let info = await bench.pyrx.debugInfo()

        XCTAssertFalse(info.initialized)
        XCTAssertNil(info.workspaceId)
        XCTAssertNil(info.environment)
        XCTAssertNil(info.baseUrl)
        XCTAssertNil(info.anonymousId)
        XCTAssertFalse(info.hasExternalId)
        XCTAssertFalse(info.hasDeviceToken)
        XCTAssertNil(info.deviceTokenFingerprint)
        XCTAssertTrue(info.trackingEnabled, "Default tracking state must be true (opt-out, not opt-in)")
        XCTAssertEqual(info.eventQueueDepth, 0)
        XCTAssertNil(info.lastDrainAt)

        // Constants always carry — not gated on initialise.
        XCTAssertEqual(info.sdkVersion, PyrxConstants.sdkVersion)
        XCTAssertEqual(info.platform, PyrxConstants.platform)
    }

    // MARK: - debugInfo post-init

    func test_debugInfo_postInitialize_carriesConfigFields() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig(environment: .sandbox))
        let info = await bench.pyrx.debugInfo()

        XCTAssertTrue(info.initialized)
        XCTAssertEqual(info.workspaceId, workspaceId)
        XCTAssertEqual(info.environment, "sandbox")
        XCTAssertEqual(info.baseUrl, "https://synapse-events.pyrx.tech")
        XCTAssertNotNil(info.anonymousId, "Anonymous id should be generated during initialize")
        XCTAssertFalse(info.hasExternalId)
        XCTAssertFalse(info.hasDeviceToken)
        XCTAssertNil(info.deviceTokenFingerprint)
        XCTAssertTrue(info.trackingEnabled)
    }

    // MARK: - device token fingerprint

    func test_debugInfo_reflectsDeviceTokenFingerprint_afterPersist() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // Seed a token directly via storage — bypasses the network round
        // trip that handleDeviceToken would do.
        let token = "feeddeadbeef0102030405060708090a0b0c0d0e0f1011121314151617181900"
        try bench.storage.set(.deviceToken, value: token)

        let info = await bench.pyrx.debugInfo()
        XCTAssertTrue(info.hasDeviceToken)
        XCTAssertEqual(info.deviceTokenFingerprint, "…17181900")

        // Belt-and-suspenders: NEVER the full token.
        XCTAssertNotEqual(info.deviceTokenFingerprint, token)
        XCTAssertFalse(info.deviceTokenFingerprint?.contains("feed") ?? true,
                       "Fingerprint must not leak the token prefix")
    }

    // MARK: - tracking gate reflection

    func test_debugInfo_reflectsTrackingGate_afterDisable() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        await bench.pyrx.setTrackingEnabled(false)
        let info = await bench.pyrx.debugInfo()
        XCTAssertFalse(info.trackingEnabled)

        // Re-enable — should flip back.
        await bench.pyrx.setTrackingEnabled(true)
        let info2 = await bench.pyrx.debugInfo()
        XCTAssertTrue(info2.trackingEnabled)
    }

    // MARK: - queue depth

    func test_debugInfo_eventQueueDepth_reflectsBufferedEvents() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // Disable tracking so events stay buffered.
        await bench.pyrx.setTrackingEnabled(false)
        try await bench.pyrx.track(eventName: "e1")
        try await bench.pyrx.track(eventName: "e2")
        try await bench.pyrx.track(eventName: "e3")
        await bench.pyrx.testAwaitQueueDrain()

        let info = await bench.pyrx.debugInfo()
        XCTAssertEqual(info.eventQueueDepth, 3,
                       "Buffered events should reflect in debugInfo queue depth")
    }

    func test_debugInfo_eventQueueDepth_zeroAfterSuccessfulDrain() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // Enqueue ack response then issue track — should drain immediately.
        bench.session.enqueueJSONSuccess(json: """
        {"event_id":"33333333-3333-3333-3333-333333333333","status":"accepted"}
        """)
        try await bench.pyrx.track(eventName: "drained")
        await bench.pyrx.testAwaitQueueDrain()

        let info = await bench.pyrx.debugInfo()
        XCTAssertEqual(info.eventQueueDepth, 0)
    }

    // MARK: - lastDrainAt

    func test_debugInfo_lastDrainAt_populatedAfterDrain() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        // Initialize calls drainNow() so the stamp should already be set.

        let info = await bench.pyrx.debugInfo()
        XCTAssertNotNil(info.lastDrainAt,
                        "initialize() calls drainNow() — lastDrainAt should be stamped")
    }

    // MARK: - ATT status surface

    func test_debugInfo_carriesATTStatus() async {
        let bench = makeBench()
        let info = await bench.pyrx.debugInfo()
        // Don't assert a specific value (environment-dependent) — just
        // confirm the field exists and is a defined enum case.
        let valid: [PyrxATTStatus] = [
            .unavailable, .notDetermined, .restricted, .denied, .authorized
        ]
        XCTAssertTrue(valid.contains(info.attStatus))
    }
}
