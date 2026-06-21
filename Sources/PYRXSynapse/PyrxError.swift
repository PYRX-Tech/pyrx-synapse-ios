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

    /// A network call failed. See `PyrxNetworkError` for the discriminated
    /// failure mode (transport failure, non-2xx status, decode failure).
    case network(PyrxNetworkError)

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
        case let .network(inner):
            return "PYRXSynapse: network call failed — \(inner.localizedDescription)"
        }
    }
}

/// Discriminated network failure mode. Wrapped in `PyrxError.network(_)`.
///
/// Three branches mirror the three distinct failure points in `HTTPClient`:
///
/// 1. ``transport`` — `URLSession.data(for:)` threw (DNS, connection refused,
///    TLS, timeout). The `underlying` `Error` is preserved for diagnostics.
/// 2. ``invalidResponse`` — the response was not an `HTTPURLResponse` (rare
///    on real iOS — surfaces if a custom session returns an unexpected type).
/// 3. ``httpStatus`` — the server returned a non-2xx status. `body` carries
///    the raw response bytes for the SDK's offline-queue / diagnostic logs
///    (PR 3 wires retry off the `statusCode`).
/// 4. ``decode`` — the response body was not parseable as the expected
///    `Decodable` type. The underlying `DecodingError` is preserved.
public enum PyrxNetworkError: Error, Sendable, LocalizedError {
    case transport(underlying: Error)
    case invalidResponse
    case httpStatus(statusCode: Int, body: Data)
    case decode(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case let .transport(underlying):
            return "transport: \(underlying.localizedDescription)"
        case .invalidResponse:
            return "invalid response (not HTTPURLResponse)"
        case let .httpStatus(statusCode, _):
            return "HTTP \(statusCode)"
        case let .decode(underlying):
            return "decode failed: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Equatable conformance for PyrxError

// `PyrxNetworkError` wraps an arbitrary `Error` (DecodingError, URLError) so
// it cannot synthesise Equatable. We hand-roll a structural comparison that
// treats two `.transport` / `.decode` cases as equal when their localised
// descriptions match — good enough for unit-test assertions, never used to
// gate production logic.
extension PyrxNetworkError: Equatable {
    public static func == (lhs: PyrxNetworkError, rhs: PyrxNetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidResponse, .invalidResponse):
            return true
        case let (.httpStatus(lc, lb), .httpStatus(rc, rb)):
            return lc == rc && lb == rb
        case let (.transport(le), .transport(re)):
            return le.localizedDescription == re.localizedDescription
        case let (.decode(le), .decode(re)):
            return le.localizedDescription == re.localizedDescription
        default:
            return false
        }
    }
}
