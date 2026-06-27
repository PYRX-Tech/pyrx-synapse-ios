//
//  PushReceivedEvent.swift
//  PYRXSynapse
//
//  Phase 9.2.1 PR-1 — Observer API.
//
//  Observer-side projection of a push delivery (foreground, background, or
//  cold-start). Carries the parsed APNs alert text plus the raw payload
//  so app-level code (custom in-app banners, debug UIs, integration
//  bridges) can react to a push without re-parsing the AnyHashable
//  userInfo bag.
//
//  Title / body parsing follows the APNs `aps.alert` contract:
//
//    * String form (legacy):   aps.alert = "You have a message"
//                              → title="", body="You have a message"
//
//    * Dict form (modern):     aps.alert = { "title": "Order shipped",
//                                            "body":  "Tap to track" }
//                              → title="Order shipped", body="Tap to track"
//
//    * Silent push:            no aps.alert
//                              → title="", body=""
//
//  Used by 3 of the 5 `PyrxEvent` cases:
//
//    * `.pushReceived(PushReceivedEvent)`            — foreground + background
//    * `.pushReceivedColdStart(PushReceivedEvent)`   — cold start tap
//
//  (`.pushClicked` uses `PushClickedEvent` because click context — action
//  id, deep link — is different from delivery context.)
//

import Foundation

/// Observer-side projection of a single push delivery.
///
/// `title` / `body` are extracted from the APNs `aps.alert` block. Both
/// are empty strings (never nil) for silent / data-only pushes —
/// observers can render them unconditionally without an Optional dance.
///
/// `pyrxAttributes` reflects the parsed `pyrx_attrs` namespace plus
/// the `push_log_id` stamp (the SDK's canonical "this push is from
/// Synapse" marker). `userInfo` is the verbatim APNs payload so
/// consumers that need a raw key (custom vendor extensions, debug logs)
/// can reach for it without re-decoding.
///
/// `pushLogId` is the parsed `pyrx.push_log_id` UUID — `nil` for
/// pushes that did not carry the `pyrx` namespace (legacy / cross-vendor
/// pushes pass through silently on the telemetry side, but the observer
/// API still surfaces them so apps can react to ALL deliveries).
/// `@unchecked Sendable` because `userInfo` is `[AnyHashable: Any]` —
/// the APNs payload shape. The contents are immutable after parsing
/// (the struct is a value type with `let` properties; the dict itself
/// is not mutated by observers, and the SDK never hands out a
/// reference that could be mutated). Observers that store the userInfo
/// across actors must treat it as read-only, which matches the system
/// `UNNotification` contract anyway.
public struct PushReceivedEvent: @unchecked Sendable {
    /// Parsed APNs alert title (`aps.alert.title`). Empty string for
    /// silent pushes and for legacy string-form alerts.
    public let title: String

    /// Parsed APNs alert body. For dict-form alerts this is
    /// `aps.alert.body`; for legacy string-form alerts the whole string
    /// is reported here. Empty for silent pushes.
    public let body: String

    /// `pyrx_attrs` block parsed into the SDK's strongly-typed payload
    /// shape, plus a `push_log_id` stamp the SDK writes itself (so a
    /// campaign cannot spoof the id). `nil` if no `pyrx_attrs` AND no
    /// `pyrx.push_log_id` were present.
    public let pyrxAttributes: [String: PyrxAttributeValue]?

    /// Raw APNs `userInfo` dictionary as the OS handed it to us. Kept
    /// `[AnyHashable: Any]` to match the system signature — observers
    /// that need typed access should prefer `pyrxAttributes`.
    public let userInfo: [AnyHashable: Any]

    /// Parsed `pyrx.push_log_id`. `nil` for non-PYRX pushes.
    public let pushLogId: UUID?

    /// Wall-clock instant at which the SDK observed the delivery.
    public let receivedAt: Date

    public init(
        title: String,
        body: String,
        pyrxAttributes: [String: PyrxAttributeValue]?,
        userInfo: [AnyHashable: Any],
        pushLogId: UUID?,
        receivedAt: Date
    ) {
        self.title = title
        self.body = body
        self.pyrxAttributes = pyrxAttributes
        self.userInfo = userInfo
        self.pushLogId = pushLogId
        self.receivedAt = receivedAt
    }
}
