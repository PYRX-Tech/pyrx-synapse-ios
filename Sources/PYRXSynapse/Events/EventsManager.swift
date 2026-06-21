//
//  EventsManager.swift
//  PYRXSynapse
//
//  Public events surface. Owned by the `Pyrx` actor; never instantiated by
//  callers. Two methods:
//
//    - track(eventName:properties:)
//    - screen(screenName:properties:)
//
//  Both shapes ultimately produce a `QueuedEvent` and append to the
//  on-disk `EventQueue`. The queue handles the wire-level POST + retry +
//  bounded persistence.
//
//  external_id resolution
//  ======================
//
//    1. If `identify()` has been called and externalId is in storage →
//       use it.
//    2. Otherwise → use the device's anonymousId (always present after
//       `Pyrx.initialize`).
//    3. If neither is present (a developer bug — track called before init
//       completed) → throw `.notInitialized`.
//
//  screen() encoding
//  =================
//
//    Screen views map onto the same `/v1/events` endpoint with the
//    canonical event name `"$screen"`. The screen name lands in
//    `attributes["screen_name"]`. This matches the cross-platform shape
//    the browser SDK uses for `$pageview` (`event_name="$pageview"`,
//    `attributes.url/path/title`) — we keep the `$`-prefix for analytics
//    consumers to distinguish SDK-emitted system events from user-defined
//    events.
//

import Foundation

/// Events surface owned by `Pyrx`. Forwards `track` / `screen` calls into
/// the `EventQueue`, after resolving the active external_id and stamping
/// the wall-clock timestamp.
final class EventsManager: @unchecked Sendable {

    private let queue: EventQueue
    private let storage: PyrxStorage
    private let logger: PyrxLogger

    /// Snapshot of the SDK-level anonymousId captured at SDK initialize
    /// time. We keep it in-memory so the events path does not need to
    /// hit Keychain on every `track` — only the (rarer) externalId
    /// lookup goes through `storage`.
    private let anonymousId: String

    /// ISO-8601 formatter for `occurred_at`. Reused instance — formatters
    /// are expensive to construct.
    private let isoFormatter: ISO8601DateFormatter

    init(
        queue: EventQueue,
        storage: PyrxStorage,
        anonymousId: String,
        logger: PyrxLogger = .shared
    ) {
        self.queue = queue
        self.storage = storage
        self.anonymousId = anonymousId
        self.logger = logger

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    // MARK: - track

    /// Track a custom event. Persists to the disk-backed queue and
    /// triggers a non-blocking drain. Returns once the event is durably
    /// on disk; network success/failure is handled asynchronously by the
    /// queue's drain loop.
    func track(
        eventName: String,
        properties: [String: JSONValue]?
    ) async throws {
        let trimmed = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PyrxError.invalidConfig(reason: "eventName must not be empty")
        }

        let event = try makeQueuedEvent(
            name: trimmed,
            attributes: properties ?? [:]
        )
        try await queue.enqueue(event)
        logger.debug("track enqueued — event=\(trimmed) externalId=\(event.externalId)")
    }

    // MARK: - screen

    /// Track a screen view. Wire shape: `$screen` event with
    /// `attributes.screen_name = screenName`. Additional caller
    /// `properties` are merged into the same attributes bag — caller
    /// values do NOT overwrite the SDK-stamped `screen_name`.
    func screen(
        screenName: String,
        properties: [String: JSONValue]?
    ) async throws {
        let trimmed = screenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PyrxError.invalidConfig(reason: "screenName must not be empty")
        }

        var attributes: [String: JSONValue] = properties ?? [:]
        // SDK-stamped fields are last-write-wins so a caller cannot spoof
        // the canonical screen identifier through `properties`.
        attributes["screen_name"] = .string(trimmed)

        let event = try makeQueuedEvent(
            name: "$screen",
            attributes: attributes
        )
        try await queue.enqueue(event)
        logger.debug("screen enqueued — name=\(trimmed) externalId=\(event.externalId)")
    }

    // MARK: - Internals

    /// Resolve the active external_id (identify-set externalId or anonymousId)
    /// and stamp the wall-clock timestamp.
    private func makeQueuedEvent(
        name: String,
        attributes: [String: JSONValue]
    ) throws -> QueuedEvent {
        let externalId = try resolveExternalId()
        return QueuedEvent(
            externalId: externalId,
            eventName: name,
            attributes: attributes,
            occurredAt: isoFormatter.string(from: Date())
        )
    }

    /// `externalId` from storage if set, else the cached `anonymousId`.
    /// Throws `.notInitialized` only if both are missing — which is a
    /// programmer error (SDK must have been initialised already).
    private func resolveExternalId() throws -> String {
        if let external = try storage.get(.externalId), !external.isEmpty {
            return external
        }
        guard !anonymousId.isEmpty else {
            throw PyrxError.notInitialized
        }
        return anonymousId
    }
}
