//
//  PyrxStorage.swift
//  PYRXSynapse
//
//  Abstract storage interface. Production builds use `KeychainStore`. Tests
//  use `InMemoryStorage` (defined in the test target) to avoid mutating the
//  real Keychain — Keychain access requires a host app on iOS Simulator unit
//  test runs.
//

import Foundation

/// Well-known keys persisted by the SDK. Strings are stable across versions.
public enum PyrxStorageKey: String, CaseIterable, Sendable {
    case anonymousId = "anonymous_id"
    case externalId = "external_id"
    case deviceToken = "device_token"
}

/// Synchronous key/value store. Implementations must be thread-safe.
public protocol PyrxStorage: Sendable {
    func get(_ key: PyrxStorageKey) throws -> String?
    func set(_ key: PyrxStorageKey, value: String) throws
    func delete(_ key: PyrxStorageKey) throws

    /// GDPR cascade — remove every SDK-owned value.
    func wipe() throws
}
