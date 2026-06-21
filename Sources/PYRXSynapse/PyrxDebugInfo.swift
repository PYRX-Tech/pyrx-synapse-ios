//
//  PyrxDebugInfo.swift
//  PYRXSynapse
//
//  Snapshot of the SDK's runtime state. Returned by `Pyrx.debugInfo()` for
//  diagnostics — wire it into a debug menu or include in bug reports.
//

import Foundation

/// Read-only snapshot of SDK state at a point in time.
public struct PyrxDebugInfo: Sendable, Equatable {
    /// SDK semantic version (matches `PYRXSynapse.podspec` and the GitHub release tag).
    public let sdkVersion: String

    /// Platform identifier sent on `X-PYRX-SDK-PLATFORM` (e.g. "ios").
    public let platform: String

    /// True if `initialize(config:)` succeeded.
    public let initialized: Bool

    /// Workspace UUID the SDK is bound to, if initialized.
    public let workspaceId: UUID?

    /// Active log level.
    public let logLevel: LogLevel

    /// Locally-persisted anonymous ID (always present once initialized).
    public let anonymousId: String?

    /// True if `identify(externalId:)` has set an external ID. Always false in PR 1.
    public let hasExternalId: Bool

    /// True if push registration has stored a device token. Always false in PR 1.
    public let hasDeviceToken: Bool

    public init(
        sdkVersion: String,
        platform: String,
        initialized: Bool,
        workspaceId: UUID?,
        logLevel: LogLevel,
        anonymousId: String?,
        hasExternalId: Bool,
        hasDeviceToken: Bool
    ) {
        self.sdkVersion = sdkVersion
        self.platform = platform
        self.initialized = initialized
        self.workspaceId = workspaceId
        self.logLevel = logLevel
        self.anonymousId = anonymousId
        self.hasExternalId = hasExternalId
        self.hasDeviceToken = hasDeviceToken
    }
}
