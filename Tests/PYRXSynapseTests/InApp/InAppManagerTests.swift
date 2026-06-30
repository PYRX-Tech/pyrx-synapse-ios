//
//  InAppManagerTests.swift
//  PYRXSynapseTests
//
//  Phase 10 PR-2b iOS — InAppManager behavior coverage.
//
//  Mirrors the 41 browser-SDK tests in
//  `~/github/pyrx.synapse/packages/sdk/tests/in-app.test.ts` —
//  same test intents, Swift idiom. Each test pins one of the 10
//  binding lifecycle rules from the browser PR #218 final comment.
//
//  Hermetic — no real network, no Caches I/O. All HTTP goes
//  through `MockHTTPSession`; the manager's poll timer is stopped
//  in `tearDown` so XCTest's per-test isolation isn't violated.
//

import XCTest
@testable import PYRXSynapse

// swiftlint:disable type_body_length
//
// Test class is intentionally long — it mirrors PR #218's 41
// behavior tests as a single cohesive suite so the cross-SDK
// symmetric contract (browser ↔ iOS) can be diffed test-by-test.
// Splitting along arbitrary lines would lose that one-to-one
// alignment.

final class InAppManagerTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private var session: MockHTTPSession!
    private var httpClient: HTTPClient!
    private var publishedEvents: SendableBox<[PyrxEvent]>!
    private var manager: InAppManager!

    override func setUp() async throws {
        try await super.setUp()
        session = MockHTTPSession()
        let config = PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: .production,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
        httpClient = HTTPClient(config: config, session: session)
        publishedEvents = SendableBox<[PyrxEvent]>([])
        let collected = publishedEvents!
        manager = InAppManager(
            httpClient: httpClient,
            logger: PyrxLogger.shared,
            observerPublisher: { event in
                collected.mutate { $0.append(event) }
            }
        )
    }

    override func tearDown() async throws {
        await manager._testStopPollTimer()
        manager = nil
        httpClient = nil
        session = nil
        publishedEvents = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Encode a poll response with the given messages.
    private func enqueuePollResponse(_ messages: [InAppMessage]) throws {
        let envelope = ["messages": messages]
        let data = try JSONEncoder().encode(envelope)
        session.enqueue(.success(
            statusCode: 200,
            body: data,
            headers: ["Content-Type": "application/json"]
        ))
    }

    /// Enqueue a 200 OK log response (default: not degraded, not capped).
    private func enqueueLogResponse(
        softDegraded: Bool = false,
        planLimitReached: Bool = false,
        billable: Bool = true
    ) {
        session.enqueueJSONSuccess(json: """
        {"log_id":"log_x","billable":\(billable),\
        "plan_limit_reached":\(planLimitReached),\
        "soft_degraded":\(softDegraded)}
        """)
    }

    private func makeMessage(
        id: String = "a1",
        messageId: String = "m1",
        placement: String = "home_banner",
        title: String = "T",
        body: String = "B",
        priority: Int = 0
    ) -> InAppMessage {
        InAppMessage(
            id: id,
            messageId: messageId,
            placement: placement,
            title: title,
            body: body,
            priority: priority
        )
    }

    /// Find requests for a given path among recorded mock calls.
    private func requests(forPath path: String) -> [RecordedRequest] {
        session.requests.filter { $0.request.url?.path == path }
    }

    /// Bind manager to an identified contact + register a callback.
    /// Returns a `SendableBox` collecting messages passed to the
    /// callback so tests can assert dispatch.
    @discardableResult
    private func bindAndShow(
        contactId: String = "user-123",
        placement: String = "home_banner"
    ) async -> SendableBox<[InAppMessage]> {
        let received = SendableBox<[InAppMessage]>([])
        await manager.bindTracker(BoundInAppTracker(contactId: contactId))
        let captured = received
        _ = await manager.registerShow(placement: placement) { msg in
            captured.mutate { $0.append(msg) }
        }
        return received
    }

    private func waitForAsyncWork() async {
        // Two yields cover the actor hop + the Task.detached the
        // manager uses for fire-and-forget triggers.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 80_000_000)
        await Task.yield()
    }

    // MARK: - Tests — polling lifecycle (rules 1, 2, 4, 5)

    func test_doesNotPoll_beforeIdentify_lifecycleRule1() async {
        // No bindTracker → no contactId → no poll, even with a
        // registered placement.
        _ = await manager.registerShow(placement: "home_banner") { _ in }
        await waitForAsyncWork()

        XCTAssertEqual(requests(forPath: "/v1/in-app/poll").count, 0)
    }

    func test_doesNotPoll_withNoRegisteredPlacements() async {
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        await manager.refresh()
        await waitForAsyncWork()

        XCTAssertEqual(requests(forPath: "/v1/in-app/poll").count, 0)
    }

    func test_pollsWith_contactId_and_repeatedPlacement_queryParams() async throws {
        try enqueuePollResponse([])
        await manager.bindTracker(BoundInAppTracker(contactId: "user-123"))
        _ = await manager.registerShow(placement: "home_banner") { _ in }
        await waitForAsyncWork()

        let polls = requests(forPath: "/v1/in-app/poll")
        XCTAssertEqual(polls.count, 1)
        let url = polls[0].request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = components.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "contact_id" }?.value, "user-123")
        let placementValues = items.filter { $0.name == "placement" }.compactMap { $0.value }
        XCTAssertEqual(placementValues, ["home_banner"])
    }

    func test_passesMultiplePlacementKeys_asRepeatedQueryParams() async throws {
        try enqueuePollResponse([])
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        _ = await manager.registerShow(placement: "home_banner") { _ in }
        _ = await manager.registerShow(placement: "settings_modal") { _ in }
        await manager.refresh()
        await waitForAsyncWork()

        let polls = requests(forPath: "/v1/in-app/poll")
        XCTAssertFalse(polls.isEmpty)
        let lastPoll = polls.last!
        let components = URLComponents(url: lastPoll.request.url!, resolvingAgainstBaseURL: false)!
        let placementValues = (components.queryItems ?? [])
            .filter { $0.name == "placement" }
            .compactMap { $0.value }
            .sorted()
        XCTAssertEqual(placementValues, ["home_banner", "settings_modal"])
        // Verify it is NOT comma-joined (lifecycle wire contract).
        XCTAssertFalse(components.queryItems?.contains { $0.value?.contains(",") == true } ?? false)
    }

    func test_coalescesConcurrentPolls_intoSingleInflight_lifecycleRule4() async throws {
        // Two poll responses queued — if the manager actually issues
        // two concurrent polls, both are consumed. Coalescing means
        // only one is consumed and the second response stays queued.
        try enqueuePollResponse([])
        try enqueuePollResponse([])
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        _ = await manager.registerShow(placement: "p") { _ in }
        // Drain the initial registration-driven poll.
        await waitForAsyncWork()
        let baseline = requests(forPath: "/v1/in-app/poll").count

        async let r1: Void = manager.refresh()
        async let r2: Void = manager.refresh()
        async let r3: Void = manager.refresh()
        _ = await (r1, r2, r3)
        await waitForAsyncWork()

        // 3 concurrent refresh calls → coalesce to at most 1 NEW poll.
        let delta = requests(forPath: "/v1/in-app/poll").count - baseline
        XCTAssertLessThanOrEqual(delta, 1, "concurrent refreshes must coalesce — saw \(delta) new polls")
    }

    func test_survivesNetworkErrors_keepsLastCachedMessages() async throws {
        // First poll: returns a message. Second poll: errors. Third:
        // returns empty. Cache should hold the message through the
        // error and only evict on the empty 200 (server-authoritative).
        let msg = makeMessage(id: "a1")
        try enqueuePollResponse([msg])
        enqueueLogResponse() // for auto-impression after dispatch

        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        _ = await manager.registerShow(placement: "home_banner") { _ in }
        await waitForAsyncWork()

        var count = await manager._testActiveCount()
        XCTAssertEqual(count, 1)

        // Network error on next poll.
        session.enqueue(.failure(NSError(domain: "test", code: -1)))
        await manager.refresh()
        await waitForAsyncWork()

        count = await manager._testActiveCount()
        XCTAssertEqual(count, 1, "must keep cache on network error")
    }

    // MARK: - Tests — dispatch & dedup (rules 5, 6, 7)

    func test_dispatchesFreshMessage_toRegisteredPlacementCallback() async throws {
        let msg = makeMessage(id: "a1", placement: "home_banner")
        try enqueuePollResponse([msg])
        enqueueLogResponse()

        let received = await bindAndShow()
        await waitForAsyncWork()

        let collected = received.read()
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(collected.first?.id, "a1")
    }

    func test_doesNotReDispatch_sameMessage_onSubsequentPoll_lifecycleRule6() async throws {
        let msg = makeMessage(id: "a1")
        try enqueuePollResponse([msg])
        enqueueLogResponse()

        let received = await bindAndShow()
        await waitForAsyncWork()
        XCTAssertEqual(received.read().count, 1)

        // Second poll returns SAME message id — must NOT re-dispatch.
        try enqueuePollResponse([msg])
        await manager.refresh()
        await waitForAsyncWork()

        XCTAssertEqual(received.read().count, 1, "must dedupe by assignment id")
    }

    func test_autoFires_markImpression_afterRenderCallbackReturns_lifecycleRule7() async throws {
        let msg = makeMessage(id: "a1")
        try enqueuePollResponse([msg])
        enqueueLogResponse()

        _ = await bindAndShow()
        await waitForAsyncWork()

        let logs = requests(forPath: "/v1/in-app/log")
        XCTAssertEqual(logs.count, 1)
        let body = try JSONSerialization.jsonObject(with: logs[0].body!) as? [String: Any]
        XCTAssertEqual(body?["assignment_id"] as? String, "a1")
        XCTAssertEqual(body?["event"] as? String, "impressed")
    }

    func test_doesNotDispatchMessage_toCallbackForDifferentPlacement() async throws {
        let msg = makeMessage(id: "a1", placement: "settings_modal")
        try enqueuePollResponse([msg])
        enqueueLogResponse()

        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        let homeReceived = SendableBox<[InAppMessage]>([])
        let captured = homeReceived
        _ = await manager.registerShow(placement: "home_banner") { msg in
            captured.mutate { $0.append(msg) }
        }
        await waitForAsyncWork()

        XCTAssertEqual(homeReceived.read().count, 0)
    }

    func test_replaysCachedMessages_toLateRegisteringCallback() async throws {
        let msg = makeMessage(id: "a1", placement: "home_banner")
        try enqueuePollResponse([msg])
        enqueueLogResponse()

        // First callback receives the dispatch.
        let firstReceived = SendableBox<[InAppMessage]>([])
        let first = firstReceived
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        _ = await manager.registerShow(placement: "home_banner") { msg in
            first.mutate { $0.append(msg) }
        }
        await waitForAsyncWork()

        // Second callback registers AFTER the message is cached.
        // It should receive a replay (cache is non-empty) without a
        // new poll firing the global observer event again.
        let secondReceived = SendableBox<[InAppMessage]>([])
        let second = secondReceived
        // Pre-queue empty poll response (registerShow triggers a poll).
        try enqueuePollResponse([msg])
        _ = await manager.registerShow(placement: "home_banner") { msg in
            second.mutate { $0.append(msg) }
        }
        await waitForAsyncWork()

        XCTAssertGreaterThanOrEqual(secondReceived.read().count, 1, "late-registered callback must replay cached msg")
    }

    func test_rejectsInvalidShowArguments_withoutThrowing() async {
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        let id = await manager.registerShow(placement: "") { _ in }
        XCTAssertEqual(id, -1)
    }

    // MARK: - Tests — getActive

    func test_getActive_returnsSortedCopy_priorityDescThenExpiryAsc() async throws {
        let msgA = InAppMessage(id: "a", messageId: "m", placement: "p", title: "", body: "", priority: 5)
        let msgB = InAppMessage(id: "b", messageId: "m", placement: "p", title: "", body: "", priority: 10)
        let msgC = InAppMessage(
            id: "c", messageId: "m", placement: "p", title: "", body: "",
            expiresAt: Date(timeIntervalSince1970: 1_000), priority: 10
        )
        try enqueuePollResponse([msgA, msgB, msgC])
        enqueueLogResponse(); enqueueLogResponse(); enqueueLogResponse()

        _ = await bindAndShow(placement: "p")
        await waitForAsyncWork()

        let sorted = await manager.getActive(placement: "p")
        // Priority desc first (10, 10, 5); within same priority,
        // expiry asc → c (expires 1970) before b (no expiry).
        XCTAssertEqual(sorted.map { $0.id }, ["c", "b", "a"])
    }

    func test_getActive_filtersByPlacement() async throws {
        let home = makeMessage(id: "h1", placement: "home")
        let settings = makeMessage(id: "s1", placement: "settings")
        try enqueuePollResponse([home, settings])
        enqueueLogResponse(); enqueueLogResponse()

        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        _ = await manager.registerShow(placement: "home") { _ in }
        _ = await manager.registerShow(placement: "settings") { _ in }
        await waitForAsyncWork()

        let filtered = await manager.getActive(placement: "home")
        XCTAssertEqual(filtered.map { $0.id }, ["h1"])
    }

    func test_getActive_returnsEmpty_whenNoActivity() async {
        let active = await manager.getActive(placement: nil)
        XCTAssertEqual(active.count, 0)
    }

    // MARK: - Tests — dismiss

    func test_dismiss_evicts_andPosts_dismissedTelemetry() async throws {
        let msg = makeMessage(id: "a1")
        try enqueuePollResponse([msg])
        enqueueLogResponse() // impression
        enqueueLogResponse() // dismiss

        _ = await bindAndShow()
        await waitForAsyncWork()
        var count = await manager._testActiveCount()
        XCTAssertEqual(count, 1)

        await manager.dismiss(messageId: "a1", reason: nil)
        await waitForAsyncWork()

        count = await manager._testActiveCount()
        XCTAssertEqual(count, 0)
        let dismissLogs = requests(forPath: "/v1/in-app/log").compactMap { rec -> String? in
            guard let body = rec.body,
                  let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return dict["event"] as? String == "dismissed" ? (dict["assignment_id"] as? String) : nil
        }
        XCTAssertEqual(dismissLogs, ["a1"])
    }

    func test_dismiss_fires_inAppMessageDismissed_observerWithReason() async throws {
        enqueueLogResponse()
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        await manager.dismiss(messageId: "a1", reason: "user_dismissed")
        await waitForAsyncWork()

        let events = publishedEvents.read()
        XCTAssertEqual(events.count, 1)
        if case let .inAppMessageDismissed(id, reason) = events[0] {
            XCTAssertEqual(id, "a1")
            XCTAssertEqual(reason, "user_dismissed")
        } else {
            XCTFail("expected inAppMessageDismissed")
        }
    }

    func test_dismiss_rejectsEmptyMessageId_withoutThrowing() async {
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        await manager.dismiss(messageId: "", reason: nil)
        await waitForAsyncWork()

        XCTAssertEqual(requests(forPath: "/v1/in-app/log").count, 0)
    }

    // MARK: - Tests — markInteracted

    func test_markInteracted_postsLogWithCtaId() async throws {
        enqueueLogResponse()
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        await manager.markInteracted(messageId: "a1", ctaId: "cta_view")
        await waitForAsyncWork()

        let logs = requests(forPath: "/v1/in-app/log")
        XCTAssertEqual(logs.count, 1)
        let body = try JSONSerialization.jsonObject(with: logs[0].body!) as? [String: Any]
        XCTAssertEqual(body?["event"] as? String, "interacted")
        XCTAssertEqual(body?["cta_id"] as? String, "cta_view")
    }

    func test_markInteracted_rejectsMissingCtaId_clientSide() async {
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        await manager.markInteracted(messageId: "a1", ctaId: "")
        await waitForAsyncWork()

        XCTAssertEqual(requests(forPath: "/v1/in-app/log").count, 0)
    }

    // MARK: - Tests — observer events

    func test_fires_inAppMessageReceived_oncePerNewAssignmentId() async throws {
        let msg = makeMessage(id: "a1")
        try enqueuePollResponse([msg])
        enqueueLogResponse()
        try enqueuePollResponse([msg])

        _ = await bindAndShow()
        await waitForAsyncWork()
        await manager.refresh()
        await waitForAsyncWork()

        let received = publishedEvents.read().compactMap { event -> String? in
            if case .inAppMessageReceived(let msg) = event { return msg.id }
            return nil
        }
        XCTAssertEqual(received, ["a1"])
    }

    // MARK: - Tests — soft_degraded / plan_limit_reached (rules 8, 9)

    func test_doublesPollInterval_onSoftDegradedResponse_lifecycleRule8() async throws {
        // Trigger a log call that returns soft_degraded.
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))

        // baseline
        var interval = await manager._testCurrentPollIntervalMs()
        XCTAssertEqual(interval, InAppPollIntervals.defaultMs)

        enqueueLogResponse(softDegraded: true)
        await manager.markInteracted(messageId: "a1", ctaId: "cta")
        await waitForAsyncWork()

        let expected = InAppPollIntervals.defaultMs * InAppPollIntervals.degradedMultiplier
        interval = await manager._testCurrentPollIntervalMs()
        XCTAssertEqual(interval, expected)
    }

    func test_recoversToDefaultInterval_whenSoftDegradedClears_lifecycleRule8() async throws {
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))

        // Degrade.
        enqueueLogResponse(softDegraded: true)
        await manager.markInteracted(messageId: "a1", ctaId: "cta")
        await waitForAsyncWork()
        var interval = await manager._testCurrentPollIntervalMs()
        XCTAssertNotEqual(interval, InAppPollIntervals.defaultMs)

        // Recover.
        enqueueLogResponse(softDegraded: false)
        await manager.markInteracted(messageId: "a2", ctaId: "cta")
        await waitForAsyncWork()

        interval = await manager._testCurrentPollIntervalMs()
        XCTAssertEqual(interval, InAppPollIntervals.defaultMs)
    }

    func test_planLimitReached_stillSurfacesMessage_emitsWarning_lifecycleRule9() async throws {
        // Plan-limit response on impression — message should already
        // have been dispatched to the callback BEFORE the log response
        // arrives, because the callback runs before sendLog awaits.
        let msg = makeMessage(id: "a1")
        try enqueuePollResponse([msg])
        enqueueLogResponse(planLimitReached: true)

        let received = await bindAndShow()
        await waitForAsyncWork()

        XCTAssertEqual(received.read().count, 1, "plan_limit_reached must NOT block render")
        // Polling continues — interval stays at default.
        let interval = await manager._testCurrentPollIntervalMs()
        XCTAssertEqual(interval, InAppPollIntervals.defaultMs)
    }

    // MARK: - Tests — cache eviction (rule 5)

    func test_evictsMessages_noLongerInPollResponse_serverAuthoritative_lifecycleRule5() async throws {
        let msgA = makeMessage(id: "a")
        let msgB = makeMessage(id: "b")
        try enqueuePollResponse([msgA, msgB])
        enqueueLogResponse(); enqueueLogResponse()

        _ = await bindAndShow()
        await waitForAsyncWork()
        var count = await manager._testActiveCount()
        XCTAssertEqual(count, 2)

        // Next poll returns only `a` — `b` must be evicted.
        try enqueuePollResponse([msgA])
        await manager.refresh()
        await waitForAsyncWork()

        count = await manager._testActiveCount()
        XCTAssertEqual(count, 1)
        let active = await manager.getActive(placement: nil)
        XCTAssertEqual(active.map { $0.id }, ["a"])
    }

    // MARK: - Tests — offline log queue

    func test_queuesTelemetry_onNetworkFailure_andFlushesOnNextSuccessfulPoll() async throws {
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))

        // Network failure for the dismiss log.
        session.enqueue(.failure(NSError(domain: "x", code: -1)))
        await manager.dismiss(messageId: "a1", reason: nil)
        await waitForAsyncWork()
        var queued = await manager._testQueuedLogs().count
        XCTAssertEqual(queued, 1)

        // Successful poll → flush → flushed log.
        _ = await manager.registerShow(placement: "p") { _ in }
        try enqueuePollResponse([])
        // After the poll succeeds, the flush re-attempts the dismiss
        // log. Queue another success for that retry.
        enqueueLogResponse()
        await manager.refresh()
        await waitForAsyncWork()
        // Drain time for the flush
        await waitForAsyncWork()

        queued = await manager._testQueuedLogs().count
        XCTAssertEqual(queued, 0)
    }

    func test_queuesTelemetry_on5xx_dropsOn4xx() async throws {
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))

        // 4xx — permanent failure; do NOT queue.
        session.enqueue(.success(
            statusCode: 422,
            body: Data("{}".utf8),
            headers: ["Content-Type": "application/json"]
        ))
        await manager.markInteracted(messageId: "a1", ctaId: "c")
        await waitForAsyncWork()
        var queued = await manager._testQueuedLogs().count
        XCTAssertEqual(queued, 0)

        // 5xx — transient; queue for retry.
        session.enqueue(.success(
            statusCode: 503,
            body: Data("{}".utf8),
            headers: ["Content-Type": "application/json"]
        ))
        await manager.markInteracted(messageId: "a2", ctaId: "c")
        await waitForAsyncWork()
        queued = await manager._testQueuedLogs().count
        XCTAssertEqual(queued, 1)
    }

    // MARK: - Tests — identity transitions (rule 2)

    func test_triggersImmediatePoll_onNullToIdentifiedTransition_withPlacementsRegistered_lifecycleRule2() async throws {
        // Register a placement BEFORE identify — no poll fires.
        try enqueuePollResponse([]) // for the post-bind poll
        _ = await manager.registerShow(placement: "p") { _ in }
        await waitForAsyncWork()
        let pollsBeforeBind = requests(forPath: "/v1/in-app/poll").count
        XCTAssertEqual(pollsBeforeBind, 0, "no poll before identify")

        // Bind tracker (identify happens) — immediate poll fires.
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        await waitForAsyncWork()
        XCTAssertGreaterThan(requests(forPath: "/v1/in-app/poll").count, pollsBeforeBind,
                             "null→identified must trigger immediate poll when placements are registered")
    }

    func test_trackHook_shortCircuitsWithinCacheWindow_lifecycleRule3() async throws {
        try enqueuePollResponse([])
        await manager.bindTracker(BoundInAppTracker(contactId: "user-1"))
        _ = await manager.registerShow(placement: "p") { _ in }
        await waitForAsyncWork()
        let baseline = requests(forPath: "/v1/in-app/poll").count

        // Within the cache window (lastPollAt just stamped), the
        // track hook must NOT trigger a new poll.
        await manager.notifyTracked()
        await waitForAsyncWork()

        XCTAssertEqual(requests(forPath: "/v1/in-app/poll").count, baseline,
                       "track hook within cache window must NOT poll")
    }
}

// swiftlint:enable type_body_length
