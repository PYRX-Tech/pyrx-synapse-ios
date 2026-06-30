//
//  InAppManager.swift
//  PYRXSynapse
//
//  Phase 10 PR-2b iOS — In-App Messaging manager.
//
//  Swift port of `packages/sdk/src/in-app.ts` (browser SDK PR #218).
//  Same 10 lifecycle rules, same wire contract, same observer-event
//  semantics — only the idioms differ (Swift actor + closures vs.
//  JS class + promises).
//
//  Authority chain:
//    * ADR-0008 — pull delivery (D1), rendering-callback contract
//      (D2), impression-as-billable (D4)
//    * ADR-0009 — 7-event observer taxonomy extension (D5),
//      cross-SDK symmetric shape (D5)
//    * Phase 10 plan §2.3 + §5 — SDK wire shape, iOS rendering
//      implications
//    * `packages/sdk/src/in-app.ts` — pinned reference surface
//    * Browser SDK PR #218 final comment — the 10 binding
//      lifecycle rules (this file's spec)
//
//  Boundary (per ADR-0008 D2):
//
//    * SDK owns:  fetch lifecycle, in-memory cache, dismiss /
//                 impression / interaction telemetry, soft-degrade
//                 backoff, identity-gated polling.
//    * SDK does NOT own: pixels, animation, layout, accessibility.
//                 The host app's render callback draws the UI.
//
//  No SwiftUI / UIKit imports here BY DESIGN. PYRX UI Kit is
//  deferred to Phase 10.x; this module ships data-only.
//
//  Thread safety
//  =============
//
//  Implemented as a Swift `actor` so concurrent calls from any
//  thread (host app code, the background poll timer Task, the
//  observer registry's publish hop) cannot tear state. The poll
//  timer is itself an async Task that hops onto the actor on
//  each tick.
//

import Foundation

/// Polling-interval constants. Exposed as `internal` so tests can
/// assert against them — not part of the public SDK surface.
enum InAppPollIntervals {
    /// Default polling cadence (60s). Matches the browser SDK's
    /// `IN_APP_DEFAULT_POLL_INTERVAL_MS`.
    static let defaultMs: Int = 60_000
    /// Backoff multiplier on `soft_degraded` (60s → 120s).
    static let degradedMultiplier: Int = 2
    /// Offline log-queue cap. Bounded so a permanently-offline app
    /// doesn't grow memory unbounded.
    static let logQueueCap: Int = 200
}

/// Bound tracker snapshot. Re-set on every identity transition.
/// Mirror of `BoundInAppTracker` in `packages/sdk/src/in-app.ts:48`.
///
/// `contactId` is the currently-identified user id — sourced from
/// `Pyrx.shared`'s `externalId` (the SDK's identified principal
/// becomes the in-app contact target per ADR-0008 D1). `nil` when
/// the SDK has not been identified yet — in which case polling is
/// blocked (lifecycle rule 1).
struct BoundInAppTracker: Sendable {
    let contactId: String?
}

/// In-App Messaging manager. Internal — the public surface is the
/// `Synapse.InApp.*` namespace in `Synapse+InApp.swift`.
///
/// Lifecycle:
///   1. Constructed during `Pyrx.initialize`.
///   2. `bindTracker(_:)` called once per identity transition.
///   3. `show(placement:callback:)` registers per-placement render
///      callbacks and starts the background poll timer.
///   4. The background timer wakes every `currentPollIntervalMs`
///      and triggers a `poll()`.
///   5. Each poll updates the cache (server-authoritative) and
///      dispatches fresh messages to registered callbacks.
///   6. `dismiss` / `markInteracted` POST telemetry to
///      `/v1/in-app/log`.
///   7. `refresh()` triggers an explicit poll.
actor InAppManager {

    // MARK: - Construction

    /// Network transport. Constructed by `Pyrx.initialize` with the
    /// real `HTTPClient`; tests pass a mock-backed instance.
    private let httpClient: HTTPClient

    /// Logger — gated by `PyrxConfig.logLevel` upstream.
    private let logger: PyrxLogger

    /// Observer registry hook. Set during `Pyrx.initialize` so the
    /// manager can publish `.inAppMessageReceived` /
    /// `.inAppMessageDismissed` events without holding a strong
    /// reference to the `Pyrx` actor.
    private let observerPublisher: @Sendable (PyrxEvent) async -> Void

    init(
        httpClient: HTTPClient,
        logger: PyrxLogger,
        observerPublisher: @escaping @Sendable (PyrxEvent) async -> Void
    ) {
        self.httpClient = httpClient
        self.logger = logger
        self.observerPublisher = observerPublisher
    }

    // MARK: - Bound state

    /// Bound identity snapshot. Re-set by `bindTracker(_:)` on every
    /// identity transition. `nil` until first bind.
    private var bound: BoundInAppTracker?

    // MARK: - Cache

    /// In-memory cache of currently-active messages, keyed by
    /// assignment id. Populated by `/v1/in-app/poll` responses;
    /// entries evicted on dismiss, expiry, or server-authoritative
    /// replacement (lifecycle rule 5).
    private var activeMessages: [String: InAppMessage] = [:]

    /// Per-placement render callbacks. A placement can have multiple
    /// callbacks (defensive — host apps that hot-reload might
    /// double-register; dedupe is a host concern). The Int key is a
    /// monotonic subscription id so a `ShowToken` can remove the
    /// exact callback it registered, not "any callback for this
    /// placement".
    private var renderCallbacks: [String: [(id: Int, callback: @Sendable (InAppMessage) -> Void)]] = [:]

    /// Monotonic counter for per-callback ids.
    private var nextCallbackId: Int = 0

    /// Track which assignment ids have already fired
    /// `inAppMessageReceived` — prevents re-firing on every poll
    /// for the same message (lifecycle rule 6). Sized by the
    /// active-cache; bounded.
    private var firedReceivedIds: Set<String> = []

    // MARK: - Polling state

    /// In-flight poll task — coalesces concurrent triggers
    /// (lifecycle rule 4).
    private var inFlightPoll: Task<Void, Never>?

    /// Current effective polling interval (ms). Doubles to
    /// `defaultMs * degradedMultiplier` when the backend signals
    /// `soft_degraded`; resets on the next 200 without
    /// `soft_degraded` (lifecycle rule 8).
    private var currentPollIntervalMs: Int = InAppPollIntervals.defaultMs

    /// Background poll timer Task. Created on first `show()`
    /// registration; cancelled when the last placement unregisters.
    private var pollTimerTask: Task<Void, Never>?

    /// Last poll timestamp. Used to honor the `max-age` cache window
    /// when a track-call refresh hint arrives too soon (lifecycle
    /// rule 3). Optional so the first poll always proceeds.
    private var lastPollAt: Date?

    // MARK: - Offline log queue

    /// A telemetry event awaiting flush.
    private struct QueuedLogEvent: Sendable {
        let assignmentId: String
        let event: String
        let ctaId: String?
    }

    /// Offline log queue. Bounded (drops oldest at cap) so a
    /// permanently offline device doesn't OOM.
    private var logQueue: [QueuedLogEvent] = []

    // MARK: - Identity binding

    /// Re-bind to the latest tracker snapshot. Called by `Pyrx` on
    /// every identity transition (identify / alias / logout).
    ///
    /// When `contactId` transitions from nil → set, kick off an
    /// immediate poll if any placements are already registered
    /// (lifecycle rule 2 — the host app may have called
    /// `Synapse.InApp.show` BEFORE identify).
    ///
    /// Identity changed (set → different set) clears the dedupe set
    /// so messages re-eligible for the new contact fire receive
    /// callbacks. Cache itself is safe to keep; the next poll will
    /// rewrite it server-authoritatively.
    func bindTracker(_ snapshot: BoundInAppTracker) {
        let wasIdentified = bound?.contactId != nil
        let previousContactId = bound?.contactId
        bound = snapshot

        if snapshot.contactId != nil && !wasIdentified {
            if !renderCallbacks.isEmpty {
                triggerPoll()
            }
        }

        if wasIdentified && snapshot.contactId != previousContactId {
            firedReceivedIds.removeAll()
        }
    }

    // MARK: - Public surface (called via Synapse.InApp facade)

    /// Register a render callback for a placement. Returns a
    /// subscription id the caller wraps in a `ShowToken` to unregister.
    ///
    /// Also triggers an immediate poll if the SDK has been identified
    /// (lifecycle rule 2 follow-up).
    func registerShow(
        placement: String,
        callback: @escaping @Sendable (InAppMessage) -> Void
    ) -> Int {
        guard !placement.isEmpty else {
            logger.warning("inApp.show: placement must be a non-empty string")
            return -1
        }

        nextCallbackId += 1
        let id = nextCallbackId
        var list = renderCallbacks[placement] ?? []
        list.append((id: id, callback: callback))
        renderCallbacks[placement] = list

        // Replay any already-cached messages for this placement so a
        // late-registering host doesn't miss a message that arrived
        // on a prior poll. The dedupe key for `inAppMessageReceived`
        // is assignment id, so replaying here doesn't double-fire
        // the global observer event.
        for msg in activeMessages.values where msg.placement == placement {
            safeInvokeCallback(callback, msg)
        }

        ensurePollTimer()

        // First registration after identity → trigger an immediate
        // poll so the host doesn't wait the default interval.
        if bound?.contactId != nil {
            triggerPoll()
        }

        return id
    }

    /// Unregister a render callback by its subscription id.
    /// Idempotent.
    func unregisterShow(placement: String, id: Int) {
        guard var list = renderCallbacks[placement] else { return }
        list.removeAll { $0.id == id }
        if list.isEmpty {
            renderCallbacks.removeValue(forKey: placement)
        } else {
            renderCallbacks[placement] = list
        }
        if renderCallbacks.isEmpty {
            stopPollTimer()
        }
    }

    /// Sync read of currently-active messages from the in-memory cache.
    /// Optional placement filter narrows to one placement.
    ///
    /// Does NOT trigger a poll — the cache is populated by background
    /// polling and explicit `refresh()`. Returns a sorted copy
    /// (priority desc, then expiry asc) so host apps see the same
    /// "most important first" order across SDKs.
    func getActive(placement: String?) -> [InAppMessage] {
        let all = Array(activeMessages.values)
        let filtered: [InAppMessage]
        if let placement = placement {
            filtered = all.filter { $0.placement == placement }
        } else {
            filtered = all
        }
        return filtered.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            let lhsExpiry = lhs.expiresAt ?? Date.distantFuture
            let rhsExpiry = rhs.expiresAt ?? Date.distantFuture
            return lhsExpiry < rhsExpiry
        }
    }

    /// Mark a message dismissed. Evicts from cache, fires the
    /// `.inAppMessageDismissed` observer event, and POSTs the
    /// telemetry event.
    ///
    /// `reason` is HOST-SIDE OBSERVER ONLY — NOT placed on the wire
    /// (PR-1 `/v1/in-app/log` schema does not carry it; PR-1 would
    /// 422 with an unknown field). Reserved for forward-compat per
    /// the task brief.
    ///
    /// Safe to call with an unknown id — the SDK still attempts the
    /// telemetry POST.
    func dismiss(messageId: String, reason: String?) async {
        guard !messageId.isEmpty else {
            logger.warning("inApp.dismiss: messageId must be a non-empty string")
            return
        }

        // Evict from cache FIRST so further `getActive` calls reflect
        // the dismissal even if the telemetry round-trip is in flight.
        activeMessages.removeValue(forKey: messageId)
        firedReceivedIds.remove(messageId)

        // Fire observer event synchronously — host apps may want to
        // react to expiry-driven auto-dismiss (future) the same way
        // they react to user-initiated dismiss.
        await observerPublisher(.inAppMessageDismissed(messageId: messageId, reason: reason))

        await sendLog(InAppLogRequest(assignmentId: messageId, event: "dismissed"))
    }

    /// Mark a message interacted (a CTA was tapped). POSTs the
    /// `interacted` telemetry event with the `ctaId` set.
    ///
    /// Does NOT evict from cache — the host app decides whether
    /// interaction implies dismissal (a `dismiss`-action CTA would
    /// call `dismiss(messageId:reason:)` separately).
    ///
    /// Per ADR-0009 D5: there is NO `inAppMessageInteracted` observer
    /// event (the host app already knows when its own CTA was
    /// tapped — it triggered this call).
    func markInteracted(messageId: String, ctaId: String) async {
        guard !messageId.isEmpty else {
            logger.warning("inApp.markInteracted: messageId must be a non-empty string")
            return
        }
        guard !ctaId.isEmpty else {
            // Backend's model_validator enforces cta_id is required
            // when event='interacted'. Validate client-side to avoid
            // the round-trip.
            logger.warning("inApp.markInteracted: ctaId is required when calling markInteracted")
            return
        }
        await sendLog(InAppLogRequest(
            assignmentId: messageId,
            event: "interacted",
            ctaId: ctaId
        ))
    }

    /// Explicit poll trigger. Coalesces with any in-flight poll
    /// (returns immediately if one is in flight, awaiting its
    /// completion).
    func refresh() async {
        await poll()
    }

    /// Tracker integration: called by `Pyrx.track` after each track
    /// event. Triggers a poll IF the cache window has elapsed
    /// (lifecycle rule 3 — track-call refresh within max-age
    /// short-circuits). Fire-and-forget.
    func notifyTracked() {
        if renderCallbacks.isEmpty { return }
        if bound?.contactId == nil { return }
        if let last = lastPollAt {
            let elapsedMs = Int(Date().timeIntervalSince(last) * 1000)
            if elapsedMs < currentPollIntervalMs { return }
        }
        triggerPoll()
    }

    // MARK: - Internal: polling

    /// Single poll cycle. Coalesces concurrent callers via
    /// `inFlightPoll` (lifecycle rule 4). Catches all network errors
    /// and degrades to a debug log; the host keeps seeing the
    /// last-cached messages so the UI doesn't go blank on transient
    /// failures.
    private func poll() async {
        if let existing = inFlightPoll {
            await existing.value
            return
        }
        guard let bound = bound else {
            logger.debug("inApp.poll: not initialized")
            return
        }
        guard bound.contactId != nil else {
            // Lifecycle rule 1: poll only after identity. The backend
            // requires a contact_id query param — without an identity
            // we have nothing to send.
            logger.debug("inApp.poll: skipped — no identified user yet")
            return
        }
        guard !renderCallbacks.isEmpty else {
            // Nothing registered — pointless to poll.
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            await self?.executePoll()
        }
        inFlightPoll = task
        await task.value
        inFlightPoll = nil
    }

    /// Fire-and-forget poll trigger that does not block the caller
    /// on the in-flight task. Used by `bindTracker` /
    /// `registerShow` / `notifyTracked` — the call path can return
    /// before the poll finishes.
    private func triggerPoll() {
        Task { [weak self] in
            await self?.poll()
        }
    }

    private func executePoll() async {
        guard let bound = bound, let contactId = bound.contactId else { return }

        let placements = Array(renderCallbacks.keys)
        // `placement` is REPEATABLE — same as the browser SDK
        // (`?contact_id=…&placement=a&placement=b`), NOT comma-joined.
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "contact_id", value: contactId)
        ]
        queryItems.append(contentsOf: placements.map { URLQueryItem(name: "placement", value: $0) })

        defer { lastPollAt = Date() }

        let response: InAppPollResponse
        do {
            response = try await httpClient.get(
                .inAppPoll,
                queryItems: queryItems,
                responseType: InAppPollResponse.self
            )
        } catch {
            logger.debug("inApp.poll: network/decode error — \(error.localizedDescription)")
            return
        }

        await applyPollResult(response.messages)

        // Opportunistic offline-queue flush — connection looks healthy.
        if !logQueue.isEmpty {
            await flushLogQueue()
        }
    }

    /// Reconcile poll result with the in-memory cache.
    ///
    /// For each message in the response:
    ///   - If new (assignment id not in cache): add, fire received
    ///     event, dispatch to placement render callbacks,
    ///     auto-impression (lifecycle rule 7).
    ///   - If known: update cache (in case the payload changed).
    ///
    /// Messages absent from the response that were in the cache are
    /// evicted — the backend's eligibility check is authoritative
    /// (lifecycle rule 5).
    private func applyPollResult(_ messages: [InAppMessage]) async {
        var incomingIds: Set<String> = []

        for msg in messages {
            incomingIds.insert(msg.id)
            let isNew = activeMessages[msg.id] == nil
            activeMessages[msg.id] = msg

            if isNew {
                // Fire global observer FIRST (analytics middleware
                // can hook here before the host app's per-placement
                // render runs).
                if !firedReceivedIds.contains(msg.id) {
                    firedReceivedIds.insert(msg.id)
                    await observerPublisher(.inAppMessageReceived(msg))
                }
                await dispatchToPlacementCallbacks(msg)
            }
        }

        // Evict cache entries no longer eligible (server-authoritative
        // per lifecycle rule 5).
        for cachedId in Array(activeMessages.keys) where !incomingIds.contains(cachedId) {
            activeMessages.removeValue(forKey: cachedId)
            firedReceivedIds.remove(cachedId)
        }
    }

    /// Invoke every render callback registered for this placement.
    /// Auto-impression fires AFTER the callback returns — the
    /// billable event per ADR-0008 D4 (lifecycle rule 7).
    private func dispatchToPlacementCallbacks(_ msg: InAppMessage) async {
        let callbacks = renderCallbacks[msg.placement] ?? []
        for entry in callbacks {
            safeInvokeCallback(entry.callback, msg)
        }
        // Auto-impression after callback dispatch.
        await sendLog(InAppLogRequest(assignmentId: msg.id, event: "impressed"))
    }

    /// Call a render callback, isolating host-app exceptions.
    /// Swift closures can't throw arbitrarily, but a host callback
    /// CAN trap (force-unwrap, precondition). We can't catch traps,
    /// but we can at least log on the way out so a future logging
    /// hook sees the flow.
    private func safeInvokeCallback(
        _ callback: @Sendable (InAppMessage) -> Void,
        _ msg: InAppMessage
    ) {
        callback(msg)
    }

    // MARK: - Internal: telemetry

    /// Send a single telemetry event to `/v1/in-app/log`. Honors the
    /// `soft_degraded` response signal by doubling the polling
    /// interval until the next non-degraded 200 (lifecycle rule 8).
    /// `plan_limit_reached` emits a warning log (lifecycle rule 9)
    /// but does NOT block the host's render.
    ///
    /// Failures queue the event for later retry — the SDK does NOT
    /// block the host on telemetry round-trips.
    private func sendLog(_ event: InAppLogRequest) async {
        guard bound != nil else {
            queueLog(event)
            return
        }

        do {
            let response = try await httpClient.post(
                .inAppLog,
                body: event,
                responseType: InAppLogResponse.self
            )
            handleLogResponse(response, event: event)
        } catch let PyrxError.network(.httpStatus(statusCode, _)) {
            logger.debug("inApp.log: non-2xx \(statusCode) for event=\(event.event)")
            // 4xx is permanent — don't queue. 5xx might be transient.
            if statusCode >= 500 {
                queueLog(event)
            }
        } catch {
            logger.debug("inApp.log: network error — queued for retry. \(error.localizedDescription)")
            queueLog(event)
        }
    }

    /// Honor the soft_degraded / plan_limit_reached signals from the
    /// log response.
    private func handleLogResponse(_ response: InAppLogResponse, event: InAppLogRequest) {
        if response.planLimitReached {
            // Lifecycle rule 9: informational — host already saw the
            // message; billing is at cap. SDK does NOT stop polling.
            logger.warning(
                "inApp.log: plan_limit_reached — tenant at 100% of monthly_in_app_messages_limit"
            )
        }

        if response.softDegraded {
            let wanted = InAppPollIntervals.defaultMs * InAppPollIntervals.degradedMultiplier
            if currentPollIntervalMs != wanted {
                currentPollIntervalMs = wanted
                restartPollTimer()
                logger.info("inApp.log: soft_degraded — polling interval doubled to \(wanted)ms")
            }
        } else if currentPollIntervalMs != InAppPollIntervals.defaultMs {
            currentPollIntervalMs = InAppPollIntervals.defaultMs
            restartPollTimer()
            logger.info("inApp.log: degrade cleared — polling interval reset")
        }
    }

    /// Append to the offline queue, dropping oldest at cap.
    private func queueLog(_ event: InAppLogRequest) {
        if logQueue.count >= InAppPollIntervals.logQueueCap {
            logQueue.removeFirst()
        }
        logQueue.append(QueuedLogEvent(
            assignmentId: event.assignmentId,
            event: event.event,
            ctaId: event.ctaId
        ))
    }

    /// Drain the offline log queue best-effort. Re-enters `sendLog`
    /// so the soft_degraded signal is honored on flushed events too.
    private func flushLogQueue() async {
        let drained = logQueue
        logQueue.removeAll()
        for queued in drained {
            await sendLog(InAppLogRequest(
                assignmentId: queued.assignmentId,
                event: queued.event,
                ctaId: queued.ctaId
            ))
        }
    }

    // MARK: - Internal: timer management

    /// Start the background poll timer if it isn't already running.
    /// The timer is a long-lived Task that sleeps for
    /// `currentPollIntervalMs` between iterations.
    private func ensurePollTimer() {
        if pollTimerTask != nil { return }
        pollTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                let intervalNs: UInt64
                if let self = self {
                    intervalNs = UInt64(await self.currentPollIntervalMs) * 1_000_000
                } else {
                    return
                }
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { return }
                await self?.poll()
            }
        }
    }

    /// Cancel the background poll timer (last placement unregistered).
    private func stopPollTimer() {
        pollTimerTask?.cancel()
        pollTimerTask = nil
    }

    /// Restart the timer to pick up a new interval. Called when
    /// `soft_degraded` toggles.
    private func restartPollTimer() {
        guard pollTimerTask != nil else { return }
        stopPollTimer()
        ensurePollTimer()
    }

    // MARK: - Test seams (internal — not part of the public SDK surface)
    //
    // Mirrors the existing `_pushHandlersForTests` convention on the
    // `Pyrx` actor (see `Pyrx.swift:_pushHandlersForTests`) — leading
    // underscore signals "do not call from production code". SwiftLint
    // identifier_name rejects the leading underscore; we disable it
    // for this block by intent (cross-codebase convention).

    // swiftlint:disable identifier_name

    /// Test-only: current poll interval in ms.
    func _testCurrentPollIntervalMs() -> Int {
        currentPollIntervalMs
    }

    /// Test-only: snapshot of the offline log queue. Returns a
    /// flat array of tuples (assignmentId, event, ctaId) so test
    /// code can compare with simple equality.
    func _testQueuedLogs() -> [QueuedLogSnapshot] {
        logQueue.map { QueuedLogSnapshot(assignmentId: $0.assignmentId, event: $0.event, ctaId: $0.ctaId) }
    }

    /// Test-only: number of cached active messages.
    func _testActiveCount() -> Int {
        activeMessages.count
    }

    /// Test-only: number of registered placements.
    func _testPlacementCount() -> Int {
        renderCallbacks.count
    }

    /// Test-only: snapshot of fired-received ids.
    func _testFiredReceivedIds() -> Set<String> {
        firedReceivedIds
    }

    /// Test-only: stop the background poll timer (so tests with
    /// long-lived managers don't leak Tasks).
    func _testStopPollTimer() {
        stopPollTimer()
    }

    // swiftlint:enable identifier_name
}

/// Test-only snapshot of a queued offline log entry. Surfaced as a
/// named struct (instead of a 3-tuple) to keep `_testQueuedLogs()`
/// under SwiftLint's `large_tuple` ceiling.
struct QueuedLogSnapshot: Sendable, Equatable {
    let assignmentId: String
    let event: String
    let ctaId: String?
}
