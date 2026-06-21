//
//  PyrxDebugInfo.swift
//  PYRXSynapse
//
//  Snapshot of the SDK's runtime state. Returned by `Pyrx.debugInfo()` for
//  diagnostics — wire it into a debug menu or include in bug reports.
//
//  PR 1 fields: sdkVersion, platform, initialized, workspaceId, logLevel,
//               anonymousId, hasExternalId, hasDeviceToken.
//
//  PR 5 extension (Phase 8.4a Task 8.4a.11) adds:
//    - environment           — the SDK's wire environment ("live" / "test").
//    - baseUrl               — the base URL the SDK is POSTing to.
//    - deviceTokenFingerprint — last-8-char ellipsis-prefixed view of the
//                               APNs token (never the full token).
//    - trackingEnabled       — current value of the privacy kill switch.
//    - attStatus             — `AppTrackingTransparency` authorisation
//                              status (or `.unavailable` on non-iOS).
//    - eventQueueDepth       — pending count in the offline queue.
//    - lastDrainAt           — wall-clock timestamp of the last drain pass
//                              (any outcome — success or transient failure
//                              counts). Nil if no drain has run yet.
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

    /// SDK environment selector ("production" or "sandbox") — string form of
    /// `PyrxEnvironment` so the debug payload stays JSON-friendly.
    public let environment: String?

    /// Base URL the SDK is POSTing to (full URL string). Useful for
    /// diagnosing "wrong cluster" misconfigurations.
    public let baseUrl: String?

    /// Active log level.
    public let logLevel: LogLevel

    /// Locally-persisted anonymous ID (always present once initialized).
    public let anonymousId: String?

    /// True if `identify(externalId:)` has set an external ID.
    public let hasExternalId: Bool

    /// True if push registration has stored a device token.
    public let hasDeviceToken: Bool

    /// Last-8-char view of the APNs device token, prefixed with `…` (a
    /// horizontal ellipsis). Mirrors the dashboard `…<8 chars>` pattern
    /// (dashboard PR #134) so support diffs reconcile cleanly across
    /// frontend + backend + SDK. `nil` when no token has been stored.
    ///
    /// **NEVER** the full token — full tokens are PII-adjacent and are
    /// only ever sent to APNs by the OS / to the SDK's own
    /// `/v1/devices` registration endpoint.
    public let deviceTokenFingerprint: String?

    /// Current value of the privacy kill switch. `true` by default;
    /// flipped by `setTrackingEnabled(_:)`.
    public let trackingEnabled: Bool

    /// Current ATT authorisation status. Always `.unavailable` on
    /// non-iOS / pre-iOS-14 builds.
    public let attStatus: PyrxATTStatus

    /// Pending event count on the offline queue at the moment of the
    /// snapshot. Always 0 before `initialize(config:)` completes.
    public let eventQueueDepth: Int

    /// Wall-clock timestamp of the last drain attempt (any outcome).
    /// `nil` until the queue has at least attempted to flush once.
    public let lastDrainAt: Date?

    public init(
        sdkVersion: String,
        platform: String,
        initialized: Bool,
        workspaceId: UUID?,
        environment: String?,
        baseUrl: String?,
        logLevel: LogLevel,
        anonymousId: String?,
        hasExternalId: Bool,
        hasDeviceToken: Bool,
        deviceTokenFingerprint: String?,
        trackingEnabled: Bool,
        attStatus: PyrxATTStatus,
        eventQueueDepth: Int,
        lastDrainAt: Date?
    ) {
        self.sdkVersion = sdkVersion
        self.platform = platform
        self.initialized = initialized
        self.workspaceId = workspaceId
        self.environment = environment
        self.baseUrl = baseUrl
        self.logLevel = logLevel
        self.anonymousId = anonymousId
        self.hasExternalId = hasExternalId
        self.hasDeviceToken = hasDeviceToken
        self.deviceTokenFingerprint = deviceTokenFingerprint
        self.trackingEnabled = trackingEnabled
        self.attStatus = attStatus
        self.eventQueueDepth = eventQueueDepth
        self.lastDrainAt = lastDrainAt
    }

    // MARK: - Helpers

    /// Build the `…<last-8>` fingerprint view of a stored hex device-token
    /// string. Returns `nil` for an empty/missing token; returns the full
    /// string prefixed by `…` if the token is somehow shorter than 8
    /// characters (defensive — production tokens are always 64 hex chars).
    ///
    /// Surfaced as a static so `Pyrx.debugInfo()` can build the view at
    /// snapshot time without round-tripping through `PrivacyManager`.
    public static func fingerprint(forDeviceToken token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        if token.count <= 8 { return "…\(token)" }
        let suffix = token.suffix(8)
        return "…\(suffix)"
    }
}
