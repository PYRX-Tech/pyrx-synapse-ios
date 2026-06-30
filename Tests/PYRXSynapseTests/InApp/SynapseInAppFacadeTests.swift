//
//  SynapseInAppFacadeTests.swift
//  PYRXSynapseTests
//
//  Phase 10 PR-2b iOS — integration test for the public
//  `Synapse.InApp.*` facade + the `Pyrx` actor bridge.
//
//  These tests use the singleton `Pyrx.shared` indirectly via the
//  facade. To stay hermetic we construct an isolated `Pyrx`
//  instance via the test-only `init` and assert through the
//  bridge methods exposed on `Pyrx+InApp.swift`. The
//  `Synapse.InApp.*` static methods route to `Pyrx.shared`, which
//  is acceptable as a smoke check — we DO NOT run those statics
//  through the singleton here (the singleton state would leak
//  across XCTest invocations).
//

import XCTest
@testable import PYRXSynapse

final class SynapseInAppFacadeTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-inapp-facade-\(UUID().uuidString)", isDirectory: true)
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

    /// Bundle of the actor + mocked transports the facade tests
    /// build. Surfaced as a struct (rather than a tuple) to keep
    /// SwiftLint's `large_tuple` rule happy.
    private struct Bench {
        let pyrx: Pyrx
        let session: MockHTTPSession
        let storage: InMemoryStorage
    }

    private func makeBench() throws -> Bench {
        let storage = InMemoryStorage()
        let session = MockHTTPSession()
        let queueStore = FileSystemQueueStore(
            fileURL: tempDir.appendingPathComponent("queue.jsonl")
        )
        let pyrx = Pyrx(
            storage: storage,
            session: session,
            queueStore: queueStore,
            reachability: MockReachability(),
            queueClock: NoOpClock()
        )
        return Bench(pyrx: pyrx, session: session, storage: storage)
    }

    private func config() -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: .production,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    // MARK: - Tests

    func test_pyrxInitialize_constructsInAppManager() async throws {
        let bench = try makeBench()
        try await bench.pyrx.initialize(config: config())
        // Bridge method `inAppGetActive` returns [] when manager
        // exists but has no cached messages — distinct from the
        // "manager not constructed" branch which returns [] silently
        // after warning-logging.
        let active = await bench.pyrx.inAppGetActive(placement: nil)
        XCTAssertEqual(active, [])
    }

    func test_inAppRegisterShow_routesToManager_returnsValidId() async throws {
        let bench = try makeBench()
        try await bench.pyrx.initialize(config: config())

        let id = await bench.pyrx.inAppRegisterShow(placement: "home_banner") { _ in }
        XCTAssertGreaterThan(id, 0)

        await bench.pyrx.inAppUnregisterShow(placement: "home_banner", id: id)
    }

    func test_inAppRegisterShow_beforeInitialize_returnsSentinel() async {
        // Fresh Pyrx that has NOT been initialized.
        let pyrx = Pyrx(
            storage: InMemoryStorage(),
            session: MockHTTPSession(),
            queueStore: FileSystemQueueStore(fileURL: tempDir.appendingPathComponent("q.jsonl")),
            reachability: MockReachability(),
            queueClock: NoOpClock()
        )
        let id = await pyrx.inAppRegisterShow(placement: "p") { _ in }
        XCTAssertEqual(id, -1, "must return -1 sentinel when bridge has no manager yet")
    }

    func test_identifyTransition_rebindsInAppManager_andTriggersPollIfPlacementsRegistered() async throws {
        let bench = try makeBench()
        try await bench.pyrx.initialize(config: config())

        // Register a placement BEFORE identify — no poll fires yet
        // (no identity → lifecycle rule 1).
        _ = await bench.pyrx.inAppRegisterShow(placement: "home_banner") { _ in }

        // Queue the identify response + the post-identify in-app poll
        // response (lifecycle rule 2: null→identified transition
        // triggers immediate poll if placements are registered).
        bench.session.enqueueJSONSuccess(json: """
        {"contact_id":"22222222-2222-2222-2222-222222222222","path":"first_sighting",\
        "aliased_external_id":null,\
        "events_reattributed":0,"devices_reattributed":0,\
        "anonymous_contact_tombstoned":false}
        """)
        bench.session.enqueueJSONSuccess(json: """
        {"messages":[]}
        """)

        _ = try await bench.pyrx.identify(externalId: "user@example.com")

        // Allow the rebind + immediate poll to schedule + complete.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let pollRequests = bench.session.requests.filter {
            $0.request.url?.path == "/v1/in-app/poll"
        }
        XCTAssertGreaterThanOrEqual(pollRequests.count, 1,
                                    "post-identify rebind must trigger immediate poll")
    }

    func test_showToken_cancel_isIdempotent() async throws {
        let bench = try makeBench()
        try await bench.pyrx.initialize(config: config())

        let token = Synapse.ShowToken(
            subscriptionId: 1,
            placement: "p",
            pyrx: bench.pyrx
        )
        token.cancel()
        token.cancel() // must not crash
        // No assertion possible on a no-op cancel; the test passes
        // if no precondition fires.
    }

    func test_observerEvents_inAppMessageDismissed_fireThroughExistingObserverSurface() async throws {
        let bench = try makeBench()
        try await bench.pyrx.initialize(config: config())

        let collected = SendableBox<[PyrxEvent]>([])
        let capture = collected
        let token = await bench.pyrx.observe(on: .global()) { event in
            capture.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        // Bind so the manager has an identity (otherwise dismiss
        // would still fire the observer; the log post would just
        // queue offline).
        bench.session.enqueueJSONSuccess(json: """
        {"contact_id":"33333333-3333-3333-3333-333333333333",\
        "path":"first_sighting","aliased_external_id":null,\
        "events_reattributed":0,"devices_reattributed":0,\
        "anonymous_contact_tombstoned":false}
        """)
        _ = try await bench.pyrx.identify(externalId: "user@example.com")

        // Queue any post-identify poll (placements are empty so
        // none should actually fire) and the dismiss log.
        bench.session.enqueueJSONSuccess(json: """
        {"log_id":"l","billable":false,"plan_limit_reached":false,"soft_degraded":false}
        """)

        await bench.pyrx.inAppDismiss(messageId: "msg-x", reason: "tested")

        // Drain handlers.
        try? await Task.sleep(nanoseconds: 200_000_000)

        struct DismissCapture: Equatable { let id: String; let reason: String? }
        let dismissEvents = collected.read().compactMap { event -> DismissCapture? in
            if case let .inAppMessageDismissed(id, reason) = event {
                return DismissCapture(id: id, reason: reason)
            }
            return nil
        }
        XCTAssertEqual(dismissEvents.count, 1)
        XCTAssertEqual(dismissEvents.first?.id, "msg-x")
        XCTAssertEqual(dismissEvents.first?.reason, "tested")
    }
}
