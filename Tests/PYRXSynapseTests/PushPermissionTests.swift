//
//  PushPermissionTests.swift
//  PYRXSynapseTests
//
//  Exercises the `PushPermission` wrapper (Phase 8.4a Task 8.4a.7) end-to-end
//  through `Pyrx.shared.requestPushPermission(options:)`. All OS calls go
//  through the `MockPushPermissionRequester` + `MockPushRegistrar` seams —
//  no real UN authorization prompt, no real APNs registration.
//
//  Coverage:
//
//   1. `.authorized` outcome → `.authorized` status + registerForRemoteNotifications fires
//   2. `.denied` outcome → `.denied` status + NO registration
//   3. `.notDetermined` (system threw) → `.notDetermined` status + NO registration
//   4. `.provisional` outcome → `.provisional` status + registerForRemoteNotifications fires
//   5. `.ephemeral` outcome → `.ephemeral` status + NO registration
//   6. Pre-existing `.denied` → short-circuits without re-prompting
//

import XCTest
import UserNotifications
@testable import PYRXSynapse

final class PushPermissionTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-push-permission-tests-\(UUID().uuidString)", isDirectory: true)
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
        let requester: MockPushPermissionRequester
        let registrar: MockPushRegistrar
    }

    private func makeBench(
        beforeStatus: UNAuthorizationStatus = .notDetermined,
        afterStatus: UNAuthorizationStatus = .authorized,
        granted: Bool = true,
        requestError: Error? = nil
    ) -> Bench {
        let requester = MockPushPermissionRequester(
            beforeStatus: beforeStatus,
            afterStatus: afterStatus,
            granted: granted,
            requestError: requestError
        )
        let registrar = MockPushRegistrar()
        let permission = PushPermission(requester: requester, registrar: registrar)
        let queueStore = FileSystemQueueStore(
            fileURL: tempDir.appendingPathComponent("event_queue.jsonl")
        )
        let pyrx = Pyrx(
            storage: InMemoryStorage(),
            session: MockHTTPSession(),
            queueStore: queueStore,
            reachability: MockReachability(),
            queueClock: NoOpClock(),
            pushPermission: permission
        )
        return Bench(pyrx: pyrx, requester: requester, registrar: registrar)
    }

    private func makeConfig() -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: .production,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    // MARK: - Outcome matrix

    func test_authorized_returnsAuthorized_andRegistersForRemoteNotifications() async throws {
        let bench = makeBench(afterStatus: .authorized, granted: true)
        try await bench.pyrx.initialize(config: makeConfig())

        let status = await bench.pyrx.requestPushPermission()

        XCTAssertEqual(status, .authorized)
        XCTAssertEqual(bench.requester.requestCallCount, 1)
        XCTAssertEqual(bench.registrar.registerCallCount, 1)
    }

    func test_denied_returnsDenied_andDoesNotRegister() async throws {
        let bench = makeBench(afterStatus: .denied, granted: false)
        try await bench.pyrx.initialize(config: makeConfig())

        let status = await bench.pyrx.requestPushPermission()

        XCTAssertEqual(status, .denied)
        XCTAssertEqual(bench.requester.requestCallCount, 1)
        XCTAssertEqual(bench.registrar.registerCallCount, 0)
    }

    func test_notDetermined_whenSystemThrows_doesNotRegister() async throws {
        struct PermissionFailed: Error {}
        let bench = makeBench(
            afterStatus: .notDetermined,
            granted: false,
            requestError: PermissionFailed()
        )
        try await bench.pyrx.initialize(config: makeConfig())

        let status = await bench.pyrx.requestPushPermission()

        XCTAssertEqual(status, .notDetermined)
        XCTAssertEqual(bench.requester.requestCallCount, 1)
        XCTAssertEqual(bench.registrar.registerCallCount, 0)
    }

    func test_provisional_returnsProvisional_andRegisters() async throws {
        let bench = makeBench(afterStatus: .provisional, granted: true)
        try await bench.pyrx.initialize(config: makeConfig())

        let status = await bench.pyrx.requestPushPermission(
            options: [.provisional, .alert, .sound, .badge]
        )

        XCTAssertEqual(status, .provisional)
        XCTAssertEqual(bench.registrar.registerCallCount, 1)
        // Caller-supplied options forwarded verbatim into the OS request
        XCTAssertTrue(bench.requester.lastOptions.contains(.provisional))
    }

    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    // `UNAuthorizationStatus.ephemeral` is iOS-family only (App Clips). The
    // SPM test target on macOS — where CI runs — cannot reference it.
    func test_ephemeral_returnsEphemeral_andDoesNotRegister() async throws {
        let bench = makeBench(afterStatus: .ephemeral, granted: true)
        try await bench.pyrx.initialize(config: makeConfig())

        let status = await bench.pyrx.requestPushPermission()

        XCTAssertEqual(status, .ephemeral)
        // App Clips cannot receive remote pushes — we deliberately skip
        // registration to avoid a misleading entry in the device table.
        XCTAssertEqual(bench.registrar.registerCallCount, 0)
    }
    #endif

    func test_preExistingDenied_shortCircuits_withoutRePrompting() async throws {
        let bench = makeBench(
            beforeStatus: .denied,
            afterStatus: .denied,
            granted: false
        )
        try await bench.pyrx.initialize(config: makeConfig())

        let status = await bench.pyrx.requestPushPermission()

        XCTAssertEqual(status, .denied)
        XCTAssertEqual(bench.requester.requestCallCount, 0, "must NOT re-prompt when status is already .denied")
        XCTAssertEqual(bench.registrar.registerCallCount, 0)
    }
}

// MARK: - Mocks

/// In-process stub for `PushPermissionRequester` — never touches the real
/// `UNUserNotificationCenter`. Returns canned outcomes so the test can
/// exercise every branch of `PushPermission.request(options:)`.
final class MockPushPermissionRequester: PushPermissionRequester, @unchecked Sendable {
    private let beforeStatus: UNAuthorizationStatus
    private let afterStatus: UNAuthorizationStatus
    private let granted: Bool
    private let requestError: Error?

    private(set) var requestCallCount = 0
    private(set) var lastOptions: UNAuthorizationOptions = []

    init(
        beforeStatus: UNAuthorizationStatus,
        afterStatus: UNAuthorizationStatus,
        granted: Bool,
        requestError: Error? = nil
    ) {
        self.beforeStatus = beforeStatus
        self.afterStatus = afterStatus
        self.granted = granted
        self.requestError = requestError
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestCallCount += 1
        lastOptions = options
        if let error = requestError {
            throw error
        }
        return granted
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        // First call returns `beforeStatus` (the pre-prompt snapshot);
        // subsequent calls return `afterStatus`. Use the request-count
        // flag because the request method is the only thing between the
        // two reads.
        requestCallCount == 0 ? beforeStatus : afterStatus
    }
}

/// In-process stub for `PushRegistrar` — never touches UIApplication.
/// Uses a synchronous helper for the mutation so `async` callers don't
/// trip the "NSLock unavailable from async" Swift 6 warning.
final class MockPushRegistrar: PushRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var _registerCallCount = 0

    var registerCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _registerCallCount
    }

    func registerForRemoteNotifications() async {
        bump()
    }

    private func bump() {
        lock.lock(); defer { lock.unlock() }
        _registerCallCount += 1
    }
}
