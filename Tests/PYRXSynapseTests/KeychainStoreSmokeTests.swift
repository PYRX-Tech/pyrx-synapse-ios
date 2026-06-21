//
//  KeychainStoreSmokeTests.swift
//  PYRXSynapseTests
//
//  Opt-in smoke test that exercises real Keychain APIs end-to-end. SPM unit
//  tests don't get a host app entitlement, so `SecItem*` typically returns
//  `errSecMissingEntitlement` on iOS Simulator. We skip unless the developer
//  explicitly opts in via `PYRX_RUN_KEYCHAIN_SMOKE=1`. PR 6 will add proper
//  instrumented coverage via the SwiftUI sample app's UI test target.
//

import XCTest
@testable import PYRXSynapse

final class KeychainStoreSmokeTests: XCTestCase {
    /// Scoped service so the smoke test never collides with a real install.
    static let testService = "tech.pyrx.synapse.tests"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PYRX_RUN_KEYCHAIN_SMOKE"] == "1",
            "Set PYRX_RUN_KEYCHAIN_SMOKE=1 to run real Keychain smoke tests."
        )
    }

    override func tearDownWithError() throws {
        let store = KeychainStore(service: Self.testService)
        try? store.wipe()
    }

    func test_realKeychain_roundTrip_anonymousId() throws {
        let store = KeychainStore(service: Self.testService)
        try store.wipe()

        XCTAssertNil(try store.get(.anonymousId))
        let value = UUID().uuidString
        try store.set(.anonymousId, value: value)
        XCTAssertEqual(try store.get(.anonymousId), value)

        try store.delete(.anonymousId)
        XCTAssertNil(try store.get(.anonymousId))
    }

    func test_realKeychain_wipe_clearsAll() throws {
        let store = KeychainStore(service: Self.testService)
        try store.set(.anonymousId, value: "anon")
        try store.set(.externalId, value: "ext")
        try store.set(.deviceToken, value: "tok")

        try store.wipe()

        XCTAssertNil(try store.get(.anonymousId))
        XCTAssertNil(try store.get(.externalId))
        XCTAssertNil(try store.get(.deviceToken))
    }
}
