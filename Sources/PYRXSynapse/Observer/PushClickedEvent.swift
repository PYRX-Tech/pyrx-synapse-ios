//
//  PushClickedEvent.swift
//  PYRXSynapse
//
//  Phase 9.2.1 PR-1 — Observer API.
//
//  Observer-side projection of a notification interaction (body tap or
//  custom action tap). Mirrors the dispatch in
//  `PushHandlers.dispatchResponse`:
//
//    * Body tap   → `actionId == nil`, deep link from `pyrx.deep_link`.
//    * Custom act → `actionId == <action identifier>`, deep link from
//                   `pyrx_attrs.<actionId>_url` if present, else falling
//                   back to `pyrx.deep_link`.
//    * Dismiss    → NOT emitted as a click; observers see no event for
//                   dismiss (matches existing telemetry — no
//                   `/v1/push/dismissed` endpoint).
//
//  Click context — not delivery context — so we omit `title` / `body`
//  (the system has dismissed the banner by now; those values are stale).
//  Apps that want to remember the original alert text should pair this
//  with the most recent `pushReceived` carrying the same `pushLogId`.
//

import Foundation

/// Observer-side projection of a user interaction with a delivered push.
///
/// Emitted for body taps (`actionId == nil`) and custom action taps
/// (`actionId == <identifier>`). NOT emitted for dismiss interactions —
/// those carry no telemetry today.
///
/// `deepLink` is the URL the SDK would (or did) hand to its `PushURLOpener`
/// — observers can use it to short-circuit their own routing, or to log
/// the click target without re-parsing the payload.
public struct PushClickedEvent: Sendable {
    /// Custom action identifier for action-button taps. `nil` for the
    /// default body-tap interaction.
    public let actionId: String?

    /// Resolved deep link URL — `pyrx_attrs.<actionId>_url` for custom
    /// actions when present, else `pyrx.deep_link`. `nil` for pushes
    /// without a deep link.
    public let deepLink: URL?

    /// Parsed `pyrx.push_log_id`. `nil` for non-PYRX pushes (legacy
    /// passthroughs surface here too so the observer API stays
    /// symmetric with `pushReceived`).
    public let pushLogId: UUID?

    /// `pyrx_attrs` block parsed into the SDK's strongly-typed payload
    /// shape, plus a `push_log_id` stamp. `nil` when no useful
    /// attribution context is present.
    public let pyrxAttributes: [String: PyrxAttributeValue]?

    /// Wall-clock instant at which the SDK observed the click.
    public let clickedAt: Date

    public init(
        actionId: String?,
        deepLink: URL?,
        pushLogId: UUID?,
        pyrxAttributes: [String: PyrxAttributeValue]?,
        clickedAt: Date
    ) {
        self.actionId = actionId
        self.deepLink = deepLink
        self.pushLogId = pushLogId
        self.pyrxAttributes = pyrxAttributes
        self.clickedAt = clickedAt
    }
}
