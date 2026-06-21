//
//  PyrxActorTests.swift
//  PYRXSynapseTests
//
//  Exercises the public `Pyrx` actor surface using injected `InMemoryStorage`
//  to avoid Keychain entitlement issues in SPM unit tests.
//

import XCTest
@testable import PYRXSynapse

final class PyrxActorTests: XCTestCase {
    let validWorkspace = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let validKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private func makeActor(storage: PyrxStorage = InMemoryStorage()) -> Pyrx {
        Pyrx(storage: storage)
    }

    private func makeConfig(logLevel: LogLevel = .info) -> PyrxConfig {
        PyrxConfig(
            workspaceId: validWorkspace,
            apiKey: validKey,
            environment: .production,
            logLevel: logLevel
        )
    }

    // MARK: - initialize

    func test_initialize_succeeds_andPersistsAnonymousId() async throws {
        let storage = InMemoryStorage()
        let pyrx = makeActor(storage: storage)

        try await pyrx.initialize(config: makeConfig())

        let info = await pyrx.debugInfo()
        XCTAssertTrue(info.initialized)
        XCTAssertEqual(info.workspaceId, validWorkspace)
        XCTAssertNotNil(info.anonymousId)
        XCTAssertEqual(info.anonymousId, storage.snapshot[.anonymousId])
    }

    func test_initialize_isNoOp_whenCalledTwiceWithIdenticalConfig() async throws {
        let storage = InMemoryStorage()
        let pyrx = makeActor(storage: storage)

        try await pyrx.initialize(config: makeConfig())
        let firstAnon = await pyrx.debugInfo().anonymousId

        try await pyrx.initialize(config: makeConfig())
        let secondAnon = await pyrx.debugInfo().anonymousId

        XCTAssertEqual(firstAnon, secondAnon, "anonymousId must be stable across re-init")
    }

    func test_initialize_throws_whenCalledTwiceWithDifferentConfig() async throws {
        let pyrx = makeActor()
        try await pyrx.initialize(config: makeConfig(logLevel: .info))

        do {
            try await pyrx.initialize(config: makeConfig(logLevel: .debug))
            XCTFail("expected .alreadyInitialized")
        } catch PyrxError.alreadyInitialized {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_initialize_throws_onInvalidApiKey() async {
        let pyrx = makeActor()
        let badConfig = PyrxConfig(workspaceId: validWorkspace, apiKey: "")

        do {
            try await pyrx.initialize(config: badConfig)
            XCTFail("expected validation failure")
        } catch PyrxError.invalidConfig {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_initialize_reusesPersistedAnonymousId() async throws {
        let storage = InMemoryStorage()
        try storage.set(.anonymousId, value: "preexisting-anon-id")

        let pyrx = makeActor(storage: storage)
        try await pyrx.initialize(config: makeConfig())

        let info = await pyrx.debugInfo()
        XCTAssertEqual(info.anonymousId, "preexisting-anon-id")
    }

    // MARK: - setLogLevel

    func test_setLogLevel_appliesBeforeInitialize() async {
        let pyrx = makeActor()
        await pyrx.setLogLevel(.debug)
        let info = await pyrx.debugInfo()
        XCTAssertEqual(info.logLevel, .debug)
        XCTAssertFalse(info.initialized)
    }

    func test_setLogLevel_appliesAfterInitialize() async throws {
        let pyrx = makeActor()
        try await pyrx.initialize(config: makeConfig(logLevel: .info))
        await pyrx.setLogLevel(.error)
        let info = await pyrx.debugInfo()
        XCTAssertEqual(info.logLevel, .error)
    }

    // MARK: - debugInfo

    func test_debugInfo_priorToInitialize() async {
        let pyrx = makeActor()
        let info = await pyrx.debugInfo()
        XCTAssertFalse(info.initialized)
        XCTAssertNil(info.workspaceId)
        XCTAssertNil(info.anonymousId)
        XCTAssertFalse(info.hasExternalId)
        XCTAssertFalse(info.hasDeviceToken)
        XCTAssertEqual(info.sdkVersion, PyrxConstants.sdkVersion)
        XCTAssertEqual(info.platform, "ios")
    }

    func test_debugInfo_reflectsPersistedExternalIdAndDeviceToken() async throws {
        let storage = InMemoryStorage()
        try storage.set(.externalId, value: "user-42")
        try storage.set(.deviceToken, value: "device-token-hex")

        let pyrx = makeActor(storage: storage)
        try await pyrx.initialize(config: makeConfig())

        let info = await pyrx.debugInfo()
        XCTAssertTrue(info.hasExternalId)
        XCTAssertTrue(info.hasDeviceToken)
    }

    // MARK: - Constants

    func test_constants_haveStableValues() {
        // PR 7's release script will bump sdkVersion in concert with the
        // podspec — guard the values here so a one-sided change fails CI.
        XCTAssertEqual(PyrxConstants.platform, "ios")
        XCTAssertFalse(PyrxConstants.sdkVersion.isEmpty)
        XCTAssertTrue(PyrxConstants.sdkVersion.split(separator: ".").count >= 2,
                      "sdkVersion must be semver-like")
    }
}
