//
//  PyrxConfig.swift
//  PYRXSynapse
//
//  Configuration object for the PYRX Synapse SDK. Pass to `Pyrx.shared.initialize(config:)`
//  exactly once per app launch — typically from your @main entry point.
//

import Foundation

/// Runtime environment the SDK targets.
///
/// `.production` routes traffic to the live ingestion endpoint
/// (`https://synapse-events.pyrx.tech`). `.sandbox` is reserved for
/// staging/QA traffic and is wired to the same default base URL until
/// staging endpoints are provisioned in a later PR.
public enum PyrxEnvironment: String, Sendable {
    case production
    case sandbox

    /// Translate the SDK-facing environment selector into the wire-level
    /// `environment` field accepted by identify / alias / devices request
    /// bodies. ``production`` → `.live`, ``sandbox`` → `.test`.
    var wireEnvironment: WireEnvironment {
        switch self {
        case .production: return .live
        case .sandbox: return .test
        }
    }
}

/// Log verbosity for the SDK's internal `OSLog`-backed logger.
public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case none = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// SDK configuration. Immutable once `Pyrx.initialize(config:)` accepts it.
public struct PyrxConfig: Sendable, Equatable {
    /// Synapse workspace identifier (UUID v4).
    public let workspaceId: UUID

    /// Public ingestion API key. Format: `psk_{env}_{hex32}`.
    public let apiKey: String

    /// Runtime environment selector.
    public let environment: PyrxEnvironment

    /// Base URL for the ingestion API. Defaults to the production endpoint.
    public let baseUrl: URL

    /// Log verbosity. Defaults to `.info`.
    public let logLevel: LogLevel

    public static let defaultBaseUrl: URL = {
        // Force-unwrap is safe — the literal is a valid URL.
        guard let url = URL(string: "https://synapse-events.pyrx.tech") else {
            preconditionFailure("PYRXSynapse: default base URL is malformed (compile-time bug).")
        }
        return url
    }()

    public init(
        workspaceId: UUID,
        apiKey: String,
        environment: PyrxEnvironment = .production,
        baseUrl: URL = PyrxConfig.defaultBaseUrl,
        logLevel: LogLevel = .info
    ) {
        self.workspaceId = workspaceId
        self.apiKey = apiKey
        self.environment = environment
        self.baseUrl = baseUrl
        self.logLevel = logLevel
    }

    /// Throws `PyrxError.invalidConfig` if any required field fails validation.
    /// Called by `Pyrx.initialize(config:)` before persisting the config.
    public func validate() throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw PyrxError.invalidConfig(reason: "apiKey must not be empty")
        }
        guard trimmedKey.hasPrefix("psk_") else {
            throw PyrxError.invalidConfig(reason: "apiKey must start with 'psk_'")
        }
        guard baseUrl.scheme == "https" || baseUrl.scheme == "http" else {
            throw PyrxError.invalidConfig(reason: "baseUrl must use http(s) scheme")
        }
    }
}
