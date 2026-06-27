//
//  PyrxEvent.swift
//  PYRXSynapse
//
//  Phase 9.2.1 PR-1 — Observer API.
//
//  The closed taxonomy of events the SDK publishes to observers. Five
//  cases — every SDK lifecycle moment an app might want to react to:
//
//    * `.pushReceived`           — foreground or background delivery
//    * `.pushClicked`            — body tap or custom action tap
//    * `.pushReceivedColdStart`  — push that launched the app from
//                                  terminated state
//    * `.queueDrained`           — the event queue successfully drained
//                                  N events to the wire (N > 0 only)
//    * `.identityChanged`        — identify / alias / logout completed
//
//  Forward-compatibility
//  =====================
//
//  This enum is NOT marked `@frozen`. For source consumers (SPM,
//  CocoaPods — both source-distribution surfaces) adding cases in
//  future minor versions is source-compatible: callers' existing
//  `switch` statements continue to compile, with a warning that they
//  should handle the new case.
//
//  For binary consumers (xcframework distribution — not currently
//  shipped, may land at 1.0) the enum is treated as `@frozen` and new
//  cases WILL break exhaustive switches. App code that needs to be
//  forward-compatible against a future binary-distributed SDK should
//  include `@unknown default: break` in every `switch` over `PyrxEvent`.
//
//  See `docs/observers.md` for the full forward-compatibility note.
//

import Foundation

/// Closed taxonomy of events the PYRX Synapse SDK publishes to observers.
///
/// Subscribe via `Pyrx.shared.observe(on:_:)` (closure-based) or
/// `Pyrx.shared.events()` (AsyncStream-based).
public enum PyrxEvent: Sendable {
    /// A push notification was delivered while the app was in the
    /// foreground or background. Emitted from `recordPushReceived` —
    /// the same fire-point that emits the `$push_received` analytics
    /// event. Always fires for foreground deliveries; for background
    /// deliveries fires once per `didReceiveRemoteNotification`.
    case pushReceived(PushReceivedEvent)

    /// The user tapped the notification body (`actionId == nil`) or a
    /// custom action button (`actionId == <identifier>`). Emitted from
    /// `emitOpened` / `emitClicked` — the same fire-points that POST
    /// `/v1/push/opened` and `/v1/push/click`.
    ///
    /// NOT emitted for the cold-start branch — that fires
    /// `.pushReceivedColdStart` instead, deduped against the
    /// `didReceive` path to prevent double-publication of the same
    /// payload.
    case pushClicked(PushClickedEvent)

    /// A push tap launched the app from terminated state. Emitted from
    /// `recordColdStartOpen` — the same fire-point that emits the
    /// `$app_opened_from_push` analytics event.
    ///
    /// Cold-start delivery + the subsequent `didReceive` of the same
    /// payload are deduped by `push_log_id` within a 5s window so
    /// observers see exactly one `pushReceivedColdStart` per launch
    /// AND zero `pushClicked` events for the cold-start payload.
    case pushReceivedColdStart(PushReceivedEvent)

    /// The event queue successfully sent `count` events to the wire on
    /// a single drain pass. Fired only when `count > 0` — zero-drain
    /// passes (no events to send, or all sends failed) are not
    /// surfaced (would spam observers and burn battery on no-op
    /// notifications).
    case queueDrained(count: Int)

    /// Identity state changed via `identify`, `alias`, or `logout`.
    /// Both `before` and `after` are non-Optional: anonymous-user is a
    /// state (the SDK always has at least an `anonymousId` after
    /// `initialize`), not absence-of-identity. Observers can rely on
    /// `before.anonymousId == after.anonymousId` (identity changes
    /// never re-mint the anonymous id) and on
    /// `before.externalId != after.externalId` (the publisher only
    /// fires when something actually changed).
    case identityChanged(before: IdentitySnapshot, after: IdentitySnapshot)
}
