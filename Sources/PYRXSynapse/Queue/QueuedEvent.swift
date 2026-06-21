//
//  QueuedEvent.swift
//  PYRXSynapse
//
//  On-disk representation of a single event waiting to flush to
//  `POST /v1/events`. Persisted line-by-line in a JSONL file under
//  `<Caches>/com.pyrx.synapse/event_queue.jsonl` (path owned by `EventQueue`).
//
//  Why a dedicated struct instead of persisting `EventIngestRequest` directly:
//
//    - We need to capture state captured AT ENQUEUE TIME (the external_id the
//      user had when they called `track`, the wall-clock timestamp from the
//      device, the SDK-generated idempotency key). If we re-derived these at
//      drain time we'd corrupt history when the user identifies between the
//      `track` call and the eventual successful drain.
//
//    - Browser SDK uses the same pattern (`SynapseEvent`) — see
//      `pyrx-synapse-browser/src/index.ts:36-44`. Keeping the iOS shape
//      analogous helps cross-platform reasoning.
//
//  Persistence shape (one JSON object per line):
//
//    {"id":"...uuid...","externalId":"user_42","eventName":"page_viewed",
//     "attributes":{"path":"/"},"occurredAt":"2026-06-21T12:00:00Z",
//     "idempotencyKey":"...uuid...","attemptCount":2}
//
//  `attemptCount` is bumped each time the drain loop pops the event and the
//  POST fails with a retryable error (5xx / transport). It is used only for
//  diagnostic logging today; PR 7 may wire it into a max-attempt eviction.
//

import Foundation

/// A single event waiting to be POSTed to `/v1/events`. JSON-Codable for
/// on-disk persistence in the JSONL queue file.
///
/// `id` is a SDK-side UUID we use to dedupe inside the queue (same event
/// enqueued twice keeps a single row). `idempotencyKey` is what we send on
/// the wire so the backend can dedupe across SDK reinstalls / queue replays.
struct QueuedEvent: Codable, Equatable, Sendable {
    /// Stable per-event UUID. Generated on enqueue; never mutates. Used by
    /// the queue itself for in-process dedupe and for log correlation.
    let id: UUID

    /// The `external_id` resolved at enqueue time — the user's `externalId`
    /// if `identify()` had been called, otherwise the device's `anonymousId`.
    /// We capture it at enqueue (not drain) so events that were tracked
    /// before identify still bear their original attribution.
    let externalId: String

    /// Event name as supplied by the caller of `track` / `screen`.
    let eventName: String

    /// Caller-supplied properties. Mapped onto `attributes` in the wire body
    /// (see `EventIngestRequest.attributes` in Codables.swift). Stored as
    /// `[String: JSONValue]` because `Any` is not `Codable` / `Sendable`.
    let attributes: [String: JSONValue]

    /// ISO-8601 wall-clock timestamp captured at enqueue. Sent as the
    /// `occurred_at` field — the server may rewrite it based on `received_at`
    /// if it arrives more than `MAX_FUTURE_SKEW` ahead, but the SDK always
    /// supplies the original.
    let occurredAt: String

    /// SDK-side idempotency key. Sent as `idempotency_key` so the backend
    /// can dedupe across drain attempts (network failure → device retries
    /// from disk after backoff → server sees the same key and 200s without
    /// double-recording).
    let idempotencyKey: String

    /// Per-event attempt counter. Starts at 0; incremented each time a drain
    /// attempt fails with a retryable error. Diagnostic only today.
    var attemptCount: Int

    init(
        id: UUID = UUID(),
        externalId: String,
        eventName: String,
        attributes: [String: JSONValue] = [:],
        occurredAt: String,
        idempotencyKey: String = UUID().uuidString,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.externalId = externalId
        self.eventName = eventName
        self.attributes = attributes
        self.occurredAt = occurredAt
        self.idempotencyKey = idempotencyKey
        self.attemptCount = attemptCount
    }

    /// Project this queued event onto the wire request body. Pure projection
    /// — no validation, no mutation. The queue calls this immediately before
    /// `httpClient.post(.events, body:)`.
    func toWireRequest() -> EventIngestRequest {
        EventIngestRequest(
            externalId: externalId,
            eventName: eventName,
            attributes: attributes,
            idempotencyKey: idempotencyKey,
            contact: nil,
            occurredAt: occurredAt
        )
    }
}
