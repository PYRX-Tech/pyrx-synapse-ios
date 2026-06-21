//
//  StorageContractTests.swift
//  PYRXSynapseTests
//
//  Validates the `PyrxStorage` contract. Exercised against `InMemoryStorage`
//  because the SPM test target has no host app entitlement for Keychain
//  (real Keychain coverage lands in PR 6 instrumented tests). The same
//  assertions hold for `KeychainStore` — both implementations must agree on
//  round-trip, idempotent delete, and full wipe.
//

import XCTest
@testable import PYRXSynapse

final class StorageContractTests: XCTestCase {
    var storage: InMemoryStorage!

    override func setUp() {
        super.setUp()
        storage = InMemoryStorage()
    }

    override func tearDown() {
        storage = nil
        super.tearDown()
    }

    // MARK: - get / set / delete round-trip

    func test_get_returnsNil_whenKeyMissing() throws {
        for key in PyrxStorageKey.allCases {
            XCTAssertNil(try storage.get(key), "expected nil for unset key \(key)")
        }
    }

    func test_set_thenGet_roundTrips_anonymousId() throws {
        let value = UUID().uuidString
        try storage.set(.anonymousId, value: value)
        XCTAssertEqual(try storage.get(.anonymousId), value)
    }

    func test_set_thenGet_roundTrips_externalId() throws {
        try storage.set(.externalId, value: "user-42")
        XCTAssertEqual(try storage.get(.externalId), "user-42")
    }

    func test_set_thenGet_roundTrips_deviceToken() throws {
        let hex = "abcd1234efef5678abcd1234efef5678abcd1234efef5678abcd1234efef5678"
        try storage.set(.deviceToken, value: hex)
        XCTAssertEqual(try storage.get(.deviceToken), hex)
    }

    func test_set_overwritesExistingValue() throws {
        try storage.set(.externalId, value: "user-1")
        try storage.set(.externalId, value: "user-2")
        XCTAssertEqual(try storage.get(.externalId), "user-2")
    }

    func test_delete_removesKey() throws {
        try storage.set(.externalId, value: "user-42")
        try storage.delete(.externalId)
        XCTAssertNil(try storage.get(.externalId))
    }

    func test_delete_isIdempotent_whenKeyMissing() throws {
        // Must not throw even though nothing exists at this key.
        XCTAssertNoThrow(try storage.delete(.deviceToken))
        XCTAssertNoThrow(try storage.delete(.deviceToken))
    }

    // MARK: - wipe (GDPR cascade)

    func test_wipe_removesAllKeys() throws {
        try storage.set(.anonymousId, value: "anon-1")
        try storage.set(.externalId, value: "user-1")
        try storage.set(.deviceToken, value: "token-1")

        try storage.wipe()

        for key in PyrxStorageKey.allCases {
            XCTAssertNil(try storage.get(key), "expected wipe to clear \(key)")
        }
    }

    func test_wipe_isIdempotent_whenEmpty() throws {
        XCTAssertNoThrow(try storage.wipe())
        XCTAssertNoThrow(try storage.wipe())
    }

    func test_storageKeys_areStable() {
        // Stability guard — these raw values are persisted on user devices.
        // Changing them silently would orphan installed users' identities.
        XCTAssertEqual(PyrxStorageKey.anonymousId.rawValue, "anonymous_id")
        XCTAssertEqual(PyrxStorageKey.externalId.rawValue, "external_id")
        XCTAssertEqual(PyrxStorageKey.deviceToken.rawValue, "device_token")
        XCTAssertEqual(PyrxStorageKey.allCases.count, 3)
    }
}
