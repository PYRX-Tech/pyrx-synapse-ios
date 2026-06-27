//
//  IdentitySnapshot.swift
//  PYRXSynapse
//
//  Phase 9.2.1 PR-1 — Observer API.
//
//  Point-in-time snapshot of the SDK's identity state. Published in pairs
//  (before / after) as part of `PyrxEvent.identityChanged` whenever the
//  caller invokes `identify`, `alias`, or `logout`.
//
//  Distinct from `IdentityResult` — `IdentityResult` is the server's RPC
//  receipt for a single `/v1/identify` or `/v1/alias` call (with merge
//  path, re-attribution counts, etc.). `IdentitySnapshot` is the
//  observer-side mirror of what the SDK believes is true locally at a
//  given moment.
//
//  Anonymous-user is a STATE, not an absence-of-identity. Every snapshot
//  has an `anonymousId` (generated during `initialize` and persisted
//  forever). `externalId` is the discriminator: nil before any
//  `identify` / `alias` ever ran, populated after the call succeeds,
//  back to nil after `logout`.
//

import Foundation

/// Point-in-time view of the SDK's identity state.
///
/// Published in pairs by `PyrxEvent.identityChanged(before:after:)` —
/// observers receive a complete before/after view of every identity
/// mutation (identify / alias / logout).
///
/// `anonymousId` is non-nil after `Pyrx.initialize(config:)` completes.
/// `externalId` is nil for anonymous-only sessions and non-nil after the
/// first successful `identify` or `alias` until the next `logout`.
public struct IdentitySnapshot: Sendable, Equatable {
    /// The SDK-generated anonymous identifier. Minted on first launch and
    /// persisted forever (Keychain). Always present once `initialize` has
    /// completed — observers will not see a snapshot with `nil` here.
    public let anonymousId: String?

    /// The canonical contact identity set by the most recent successful
    /// `identify(externalId:)` or `alias(newExternalId:)`. Nil before the
    /// first such call and after `logout`.
    public let externalId: String?

    /// Wall-clock instant at which this snapshot was captured. Useful for
    /// rendering timelines in debug UIs and for correlating observer
    /// events with other timestamps.
    public let snapshotAt: Date

    public init(
        anonymousId: String?,
        externalId: String?,
        snapshotAt: Date
    ) {
        self.anonymousId = anonymousId
        self.externalId = externalId
        self.snapshotAt = snapshotAt
    }
}
