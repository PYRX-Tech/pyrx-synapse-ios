//
//  PushRegistrationTests.swift
//  PYRXSynapseTests
//
//  Exercises `Pyrx.handleDeviceToken(_:)` (Phase 8.4a Task 8.4a.7). All HTTP
//  goes through `MockHTTPSession` — no real network or APNs.
//
//  Coverage:
//
//   1. `Data` → hex string conversion is canonical lowercase
//   2. Token persisted to Keychain before the network call
//   3. POST /v1/devices wire body shape matches the backend schema
//      (external_id, platform="ios", push_token, bundle_id, app_version,
//       sdk_version, sdk_platform="ios", os_version, device_model,
//       locale, timezone, environment, push_enabled, metadata)
//   4. Sandbox environment sends "test" on the wire
//   5. After identify(), external_id resolves to the externalId — not anonymous
//   6. Before initialize(), throws .notInitialized
//   7. handleRegistrationError before initialize logs but does not crash
//   8. Empty deviceToken throws .invalidConfig
//

import XCTest
@testable import PYRXSynapse

final class PushRegistrationTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyrx-push-registration-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func enqueueDeviceResponse(
        _ session: MockHTTPSession,
        id: String = "9b1c8f4a-3a3e-4e1d-9b7f-1c2e3d4e5f6a",
        contactId: String = "2e1d0c9b-7a6b-4c5d-8e9f-0a1b2c3d4e5f",
        platform: String = "ios",
        pushToken: String = "deadbeefcafef00d"
    ) {
        session.enqueueJSONSuccess(json: """
        {
          "id":"\(id)","contact_id":"\(contactId)","platform":"\(platform)",
          "push_token":"\(pushToken)","bundle_id":"tech.pyrx.crm.ios",
          "app_version":"1.0","sdk_version":"0.1.0","sdk_platform":"ios",
          "os_version":"iOS 17.0","device_model":"iPhone15,3","locale":"en_US",
          "timezone":"UTC","environment":"live","push_enabled":true,
          "last_seen_at":"2026-06-21T10:00:00.000Z",
          "registered_at":"2026-06-21T10:00:00.000Z","revoked_at":null,
          "metadata":{}
        }
        """)
    }

    private func enqueueIdentifyResponse(_ session: MockHTTPSession) {
        session.enqueueJSONSuccess(json: """
        {"contact_id":"22222222-2222-2222-2222-222222222222","path":"first_sighting",
        "aliased_external_id":null,"events_reattributed":0,"devices_reattributed":0,
        "anonymous_contact_tombstoned":false}
        """)
    }

    // MARK: - Hex conversion

    func test_hexString_canonicalLowercase() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xF0, 0x0D])
        XCTAssertEqual(PushRegistration.hexString(from: data), "deadbeefcafef00d")
    }

    func test_hexString_realWorldAPNsTokenSize() {
        // APNs production tokens are 32 bytes → 64 hex chars
        let data = Data((0..<32).map { UInt8($0) })
        let hex = PushRegistration.hexString(from: data)
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex.prefix(8), "00010203")
        XCTAssertEqual(hex.suffix(8), "1c1d1e1f")
    }

    func test_hexString_emptyData() {
        XCTAssertEqual(PushRegistration.hexString(from: Data()), "")
    }

    // MARK: - handleDeviceToken — happy path

    func test_handleDeviceToken_persistsTokenToKeychain_andPOSTsToDevices() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        enqueueDeviceResponse(bench.session)

        let token = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xF0, 0x0D])
        let response = try await bench.pyrx.handleDeviceToken(token)

        // Token persisted to Keychain
        XCTAssertEqual(try bench.storage.get(.deviceToken), "deadbeefcafef00d")
        // Response surfaced to caller
        XCTAssertEqual(response.platform, "ios")
        XCTAssertEqual(response.id.uuidString.lowercased(), "9b1c8f4a-3a3e-4e1d-9b7f-1c2e3d4e5f6a")
    }

    func test_handleDeviceToken_wireBodyHasAllRequiredFields() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        enqueueDeviceResponse(bench.session)

        let token = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xF0, 0x0D])
        _ = try await bench.pyrx.handleDeviceToken(token)

        let raw = try XCTUnwrap(bench.session.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]

        // Required fields per app/schemas/device.py::DeviceRegister
        XCTAssertEqual(json?["platform"] as? String, "ios")
        XCTAssertEqual(json?["push_token"] as? String, "deadbeefcafef00d")
        XCTAssertEqual(json?["sdk_platform"] as? String, "ios")
        XCTAssertEqual(json?["sdk_version"] as? String, PyrxConstants.sdkVersion)
        XCTAssertEqual(json?["environment"] as? String, "live")
        XCTAssertEqual(json?["push_enabled"] as? Bool, true)
        // external_id falls back to anonymousId (no identify() yet)
        let anon = try XCTUnwrap(bench.storage.get(.anonymousId))
        XCTAssertEqual(json?["external_id"] as? String, anon)
        // metadata-shape fields — present even when empty/default
        XCTAssertNotNil(json?["bundle_id"])
        XCTAssertNotNil(json?["app_version"])
        XCTAssertNotNil(json?["os_version"])
        XCTAssertNotNil(json?["device_model"])
        XCTAssertNotNil(json?["locale"])
        XCTAssertNotNil(json?["timezone"])
        XCTAssertNotNil(json?["metadata"])
    }

    func test_handleDeviceToken_targetsCorrectEndpoint() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        enqueueDeviceResponse(bench.session)

        let token = Data([0x01, 0x02, 0x03, 0x04])
        _ = try await bench.pyrx.handleDeviceToken(token)

        let request = try XCTUnwrap(bench.session.requests.first)
        XCTAssertEqual(request.request.url?.path, "/v1/devices")
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "X-WORKSPACE-ID"), workspaceId.uuidString)
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "X-API-KEY"), apiKey)
    }

    func test_handleDeviceToken_sandboxEnvironment_sendsTest() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig(environment: .sandbox))
        enqueueDeviceResponse(bench.session)

        let token = Data([0xAB, 0xCD])
        _ = try await bench.pyrx.handleDeviceToken(token)

        let raw = try XCTUnwrap(bench.session.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(json?["environment"] as? String, "test")
    }

    func test_handleDeviceToken_afterIdentify_usesExternalId() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        enqueueIdentifyResponse(bench.session)
        _ = try await bench.pyrx.identify(externalId: "user_42")

        enqueueDeviceResponse(bench.session)
        let token = Data([0x99, 0x88])
        _ = try await bench.pyrx.handleDeviceToken(token)

        // 2nd request = the device POST
        let raw = try XCTUnwrap(bench.session.requests[1].body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(json?["external_id"] as? String, "user_42")
    }

    // MARK: - handleDeviceToken — error paths

    func test_handleDeviceToken_beforeInitialize_throwsNotInitialized() async throws {
        let bench = makeBench()
        let token = Data([0xAA])

        do {
            _ = try await bench.pyrx.handleDeviceToken(token)
            XCTFail("expected .notInitialized")
        } catch PyrxError.notInitialized {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_handleDeviceToken_emptyData_throwsInvalidConfig() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        do {
            _ = try await bench.pyrx.handleDeviceToken(Data())
            XCTFail("expected .invalidConfig")
        } catch PyrxError.invalidConfig {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_handleDeviceToken_serverFailure_doesNotClobberLocalToken() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // 500 response — backend transient failure
        bench.session.enqueue(.success(
            statusCode: 500,
            body: Data("{}".utf8),
            headers: ["Content-Type": "application/json"]
        ))

        let token = Data([0xDE, 0xAD])
        do {
            _ = try await bench.pyrx.handleDeviceToken(token)
            XCTFail("expected .network")
        } catch PyrxError.network {
            // ok — we persist the token BEFORE the call by design so the next
            // boot can short-circuit the OS round trip.
            XCTAssertEqual(try bench.storage.get(.deviceToken), "dead")
        }
    }

    // MARK: - handleRegistrationError

    func test_handleRegistrationError_beforeInitialize_doesNotCrash() async throws {
        let bench = makeBench()
        struct APNsFailed: Error {}
        // Just exercising — no observable state to assert here; the
        // important behaviour is "doesn't throw, doesn't crash".
        await bench.pyrx.handleRegistrationError(APNsFailed())
    }

    func test_handleRegistrationError_afterInitialize_doesNotCrash() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        struct APNsFailed: Error {}
        await bench.pyrx.handleRegistrationError(APNsFailed())
    }

    // MARK: - DeviceMetadata shape

    func test_deviceMetadata_fieldsAreWellFormed() {
        XCTAssertEqual(DeviceMetadata.sdkPlatform(), "ios")
        XCTAssertEqual(DeviceMetadata.sdkVersion(), PyrxConstants.sdkVersion)
        XCTAssertFalse(DeviceMetadata.bundleId().isEmpty)
        XCTAssertFalse(DeviceMetadata.appVersion().isEmpty)
        XCTAssertFalse(DeviceMetadata.osVersion().isEmpty)
        XCTAssertFalse(DeviceMetadata.deviceModel().isEmpty)
        XCTAssertFalse(DeviceMetadata.locale().isEmpty)
        XCTAssertFalse(DeviceMetadata.timezone().isEmpty)
    }
}
