//
//  InMemoryStorage.swift
//  PYRXSynapseTests
//
//  Thread-safe in-memory `PyrxStorage` for unit tests. SPM unit tests run
//  without a host app, which means `SecItem*` Keychain APIs fail with
//  `errSecMissingEntitlement` on iOS Simulator — we exercise the storage
//  contract through this stub instead. Real Keychain coverage lives in the
//  sample-app instrumented tests landing in PR 6.
//

import Foundation
@testable import PYRXSynapse

final class InMemoryStorage: PyrxStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PyrxStorageKey: String] = [:]

    /// Test hook — count calls per operation so tests can assert call patterns.
    private(set) var getCount = 0
    private(set) var setCount = 0
    private(set) var deleteCount = 0
    private(set) var wipeCount = 0

    func get(_ key: PyrxStorageKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        getCount += 1
        return values[key]
    }

    func set(_ key: PyrxStorageKey, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        setCount += 1
        values[key] = value
    }

    func delete(_ key: PyrxStorageKey) throws {
        lock.lock(); defer { lock.unlock() }
        deleteCount += 1
        values.removeValue(forKey: key)
    }

    func wipe() throws {
        lock.lock(); defer { lock.unlock() }
        wipeCount += 1
        values.removeAll()
    }

    var snapshot: [PyrxStorageKey: String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
