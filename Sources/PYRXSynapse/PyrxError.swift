//
//  PyrxError.swift
//  PYRXSynapse
//
//  Typed error hierarchy surfaced from the SDK's public API. All `async throws`
//  methods in subsequent PRs (network, storage, push) will surface variants of
//  this enum so callers can pattern-match against well-known failure modes.
//

import Foundation

/// All errors thrown by the public PYRXSynapse API.
public enum PyrxError: Error, Sendable, Equatable, LocalizedError {
    /// `initialize(config:)` was called more than once with conflicting values.
    case alreadyInitialized

    /// A method that requires `initialize(config:)` was called before init.
    case notInitialized

    /// Configuration validation failed. See `reason` for details.
    case invalidConfig(reason: String)

    /// Keychain storage operation failed. Wraps the underlying OSStatus.
    case keychainFailure(status: Int32, operation: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInitialized:
            return "PYRXSynapse: SDK is already initialized."
        case .notInitialized:
            return "PYRXSynapse: SDK has not been initialized — call Pyrx.shared.initialize(config:) first."
        case let .invalidConfig(reason):
            return "PYRXSynapse: invalid configuration — \(reason)."
        case let .keychainFailure(status, operation):
            return "PYRXSynapse: Keychain \(operation) failed (OSStatus \(status))."
        }
    }
}
