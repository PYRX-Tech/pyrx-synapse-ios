//
//  KeychainStore.swift
//  PYRXSynapse
//
//  Keychain-backed implementation of `PyrxStorage`. Uses the iOS Security
//  framework directly — no third-party dependencies.
//
//  Design choices:
//    - Service identifier scoped to `tech.pyrx.synapse.keychain` so we don't
//      collide with host-app keys.
//    - Access policy `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` —
//      readable in background after first user unlock; never synced via
//      iCloud Keychain (sensitive to device).
//    - Items survive app reinstall on iOS (Keychain is preserved). Use
//      `wipe()` from a logout flow if that surprises you.
//

import Foundation
import Security

/// Production storage. Backed by the iOS Keychain.
public final class KeychainStore: PyrxStorage, @unchecked Sendable {
    /// Default service identifier — namespaces all SDK-owned keys.
    public static let defaultService = "tech.pyrx.synapse.keychain"

    private let service: String
    private let accessGroup: String?

    public init(service: String = KeychainStore.defaultService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - PyrxStorage

    public func get(_ key: PyrxStorageKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = withUnsafeMutablePointer(to: &result) {
            SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
        }

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw PyrxError.keychainFailure(status: status, operation: "get(\(key.rawValue))")
        }
    }

    public func set(_ key: PyrxStorageKey, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw PyrxError.keychainFailure(status: errSecParam, operation: "encode(\(key.rawValue))")
        }

        // Try update first — if no existing item, fall through to add.
        let query = baseQuery(for: key)
        let updateAttrs: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery(for: key)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PyrxError.keychainFailure(status: addStatus, operation: "add(\(key.rawValue))")
            }
        default:
            throw PyrxError.keychainFailure(status: updateStatus, operation: "update(\(key.rawValue))")
        }
    }

    public func delete(_ key: PyrxStorageKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw PyrxError.keychainFailure(status: status, operation: "delete(\(key.rawValue))")
        }
    }

    public func wipe() throws {
        // Iterate every well-known key. Cheaper and more deterministic than a
        // generic SecItemDelete with no kSecAttrAccount filter (which would
        // remove every item under our service, including future ones we may
        // not own yet — explicit is safer).
        for key in PyrxStorageKey.allCases {
            try delete(key)
        }
    }

    // MARK: - Private

    private func baseQuery(for key: PyrxStorageKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
