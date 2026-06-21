//
//  Pyrx.swift
//  PYRXSynapse
//
//  Public entry point for the PYRX Synapse iOS SDK. Implemented as a Swift
//  `actor` so all mutable state is serialized through the actor's executor —
//  callers can safely invoke methods from any thread/task.
//
//  PR 1 surface (Foundation):
//    - `initialize(config:)` — validate + persist config, generate anonymousId
//    - `setLogLevel(_:)`     — adjust runtime verbosity
//    - `debugInfo()`         — snapshot for diagnostics
//
//  PR 2 surface (Network + Identity):
//    - `identify(externalId:traits:)` — anonymous → known merge
//    - `alias(newExternalId:)`        — explicit anonymous → known merge
//    - `logout()`                     — client-side identity clear
//
//  PR 3 surface (Events + Offline Queue):
//    - `track(eventName:properties:)`  — custom event, enqueued + drained
//    - `screen(screenName:properties:)` — `$screen` event with screen_name
//
//  PR 4 surface (Push Registration + Delivery Handlers):
//    - `requestPushPermission(options:)`         — UN authorization prompt
//                                                  + APNs registration
//    - `handleDeviceToken(_:)`                   — bridge from AppDelegate's
//                                                  didRegisterForRemoteNotifications
//                                                  callback → POST /v1/devices
//    - `handleRegistrationError(_:)`             — diagnostic-only failure log
//    - `handleForegroundNotification(_:)`        — willPresent presentation
//                                                  options
//    - `handleBackgroundNotification(...)`       — silent push → $push_received
//                                                  + APNs ack
//    - `handleNotificationResponse(...)`         — tap / custom action /
//                                                  dismiss → /v1/push/opened
//                                                  or /v1/push/click + deep link
//
//  Subsequent PRs (attribution, privacy) extend this actor in place rather
//  than introducing new top-level types.
//

import Foundation
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

public actor Pyrx {
    /// Shared singleton. Apps should always use `Pyrx.shared`.
    public static let shared = Pyrx()

    // MARK: - State

    private var config: PyrxConfig?
    private let storage: PyrxStorage
    private let logger: PyrxLogger
    private var anonymousId: String?

    /// Injectable transport — only the test path supplies a non-default value.
    /// In production, `HTTPClient` is built with `URLSession.shared` once
    /// `initialize(config:)` succeeds.
    private let session: HTTPSession

    /// Optional override of the on-disk queue store. Production passes nil
    /// (`EventQueue` builds a `FileSystemQueueStore` under `<Caches>`).
    /// Tests inject an in-memory or temp-directory store so they never
    /// touch the real Caches directory.
    private let queueStoreOverride: QueueFileStore?

    /// Optional override of the reachability source. Production passes nil
    /// (`EventQueue` wires `NWPathReachability`). Tests pass a mock that
    /// emits `.satisfied` on demand so drain triggers are deterministic.
    private let reachabilityOverride: Reachability?

    /// Optional override of the clock used by `EventQueue` for backoff
    /// sleeps. Tests inject a no-op clock so retry sequences complete
    /// instantly instead of pausing for 1+ seconds per attempt.
    private let queueClockOverride: QueueClock?

    /// Built during `initialize(config:)` from the validated config.
    private var httpClient: HTTPClient?

    /// Built during `initialize(config:)` once httpClient is ready.
    private var identityManager: IdentityManager?

    /// Built during `initialize(config:)` once httpClient + anonymousId are
    /// ready. Owns the on-disk JSONL queue and retry loop.
    private var eventQueue: EventQueue?

    /// Built during `initialize(config:)` — surfaces `track` / `screen`.
    private var eventsManager: EventsManager?

    /// Built during `initialize(config:)` — owns `POST /v1/devices` on
    /// `handleDeviceToken(_:)`. (PR 4)
    private var pushRegistration: PushRegistration?

    /// Built during `initialize(config:)` — owns foreground / background /
    /// response delegate plumbing + `/v1/push/{opened,click}` telemetry. (PR 4)
    private var pushHandlers: PushHandlers?

    // MARK: - Push seam overrides (test-only)

    /// Test override of the UN authorization requester + UIApplication
    /// registrar. Production passes nil (`PushPermission` builds the
    /// real `UNUserNotificationCenter` + `UIApplicationRegistrar`).
    /// Tests inject a mock so `requestPushPermission` can be asserted
    /// without a real UI prompt or APNs round trip.
    private let pushPermissionOverride: PushPermission?

    /// Test override of the URL opener used by deep-link routing. Production
    /// passes nil. Tests inject a mock that records the URL.
    private let urlOpenerOverride: PushURLOpener?

    // MARK: - Init

    /// Designated initializer — internal so the shared singleton is the only
    /// production path. Tests in `PYRXSynapseTests` can build a fresh actor
    /// with an injected storage + HTTPSession + queue dependencies.
    init(
        storage: PyrxStorage = KeychainStore(),
        session: HTTPSession = URLSession.shared,
        queueStore: QueueFileStore? = nil,
        reachability: Reachability? = nil,
        queueClock: QueueClock? = nil,
        pushPermission: PushPermission? = nil,
        urlOpener: PushURLOpener? = nil,
        logger: PyrxLogger = .shared
    ) {
        self.storage = storage
        self.session = session
        self.queueStoreOverride = queueStore
        self.reachabilityOverride = reachability
        self.queueClockOverride = queueClock
        self.pushPermissionOverride = pushPermission
        self.urlOpenerOverride = urlOpener
        self.logger = logger
    }

    // MARK: - Public API

    /// Initialize the SDK. Must be called exactly once before any other API.
    ///
    /// - Parameter config: validated `PyrxConfig`.
    /// - Throws: `PyrxError.alreadyInitialized` if called twice with different
    ///   values; `PyrxError.invalidConfig(reason:)` if validation fails;
    ///   `PyrxError.keychainFailure(...)` if anonymousId persistence fails.
    public func initialize(config: PyrxConfig) async throws {
        if let existing = self.config {
            if existing == config {
                logger.info("initialize(config:) called twice with identical config — no-op.")
                return
            }
            throw PyrxError.alreadyInitialized
        }

        try config.validate()

        logger.setLevel(config.logLevel)

        // Generate-or-restore anonymousId. Errors propagate — without a stable
        // anonymousId the SDK cannot reliably attribute events.
        let anon = try ensureAnonymousId()

        self.config = config
        self.anonymousId = anon

        // Build the network + identity layer NOW (not lazily) so the first
        // call to identify() / track() / alias() pays no construction cost
        // on the request path.
        let client = HTTPClient(config: config, session: session)
        self.httpClient = client
        self.identityManager = IdentityManager(
            storage: storage,
            httpClient: client,
            environment: config.environment.wireEnvironment,
            logger: logger
        )

        // Build the events queue + manager. The queue store either comes
        // from the test override or resolves to `<Caches>/com.pyrx.synapse/
        // event_queue.jsonl` (failure to resolve falls back to disabling
        // persistence — events go to a transient in-memory file URL so the
        // SDK still functions, but offline durability is lost).
        let store: QueueFileStore
        if let override = queueStoreOverride {
            store = override
        } else {
            do {
                store = try FileSystemQueueStore()
            } catch {
                logger.error("EventQueue: cannot resolve Caches dir — \(error). Offline durability disabled.")
                // Best-effort fallback: write to a tmp file that lives for
                // this process. Avoids crashing the SDK; the queue still
                // works in-memory + retries until the process ends.
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("com.pyrx.synapse.fallback")
                    .appendingPathComponent("event_queue.jsonl")
                store = FileSystemQueueStore(fileURL: tmp)
            }
        }

        let queue = EventQueue(
            httpClient: client,
            store: store,
            maxQueueSize: config.maxQueueSize,
            logger: logger,
            clock: queueClockOverride ?? SystemClock()
        )
        self.eventQueue = queue
        let manager = EventsManager(
            queue: queue,
            storage: storage,
            anonymousId: anon,
            logger: logger
        )
        self.eventsManager = manager

        // PR 4 — push registration + delivery handlers. Construction is
        // free (no I/O); the handlers stay idle until the AppDelegate
        // routes a callback into them.
        self.pushRegistration = PushRegistration(
            storage: storage,
            httpClient: client,
            environment: config.environment.wireEnvironment,
            logger: logger
        )
        self.pushHandlers = PushHandlers(
            httpClient: client,
            eventsManager: manager,
            urlOpener: urlOpenerOverride ?? PushHandlers.defaultURLOpener(),
            logger: logger
        )

        // Wire reachability and drain pre-existing events on launch.
        let reachability: Reachability = reachabilityOverride ?? NWPathReachability()
        await queue.bindReachability(reachability)
        await queue.drainNow()

        logger.info(
            "Initialized PYRXSynapse v\(PyrxConstants.sdkVersion) " +
            "(workspace=\(config.workspaceId), env=\(config.environment.rawValue))"
        )
    }

    // MARK: - Identity API (PR 2)

    /// Identify an anonymous SDK session into a known contact.
    ///
    /// - Parameters:
    ///   - externalId: canonical user identifier (e.g. your user id from
    ///                 pyrx.auth, your CRM, or your DB).
    ///   - traits:     optional contact attributes — shallow-merged into
    ///                 `Contact.properties` server-side.
    /// - Returns: the server's `IdentityResult` so callers can log which
    ///            merge branch ran (debug menus, support investigations).
    /// - Throws: `PyrxError.notInitialized` if `initialize(config:)` has not
    ///           completed; `PyrxError.invalidConfig` for empty externalId;
    ///           `PyrxError.network(...)` on transport / HTTP / decode failure.
    @discardableResult
    public func identify(
        externalId: String,
        traits: [String: JSONValue]? = nil
    ) async throws -> IdentityResult {
        guard let manager = identityManager else { throw PyrxError.notInitialized }
        return try await manager.identify(externalId: externalId, traits: traits)
    }

    /// Explicitly merge an anonymous session into a known contact.
    ///
    /// Use when you have a separate user id you want to attach to all prior
    /// anonymous activity (e.g., the user signs up — your backend mints a
    /// permanent user id distinct from any device-local identifier).
    @discardableResult
    public func alias(newExternalId: String) async throws -> IdentityResult {
        guard let manager = identityManager else { throw PyrxError.notInitialized }
        return try await manager.alias(newExternalId: newExternalId)
    }

    /// Client-side identity clear. Does NOT call the server.
    ///
    /// After `logout()`:
    ///   - `externalId` is removed from the Keychain.
    ///   - `anonymousId` is preserved (subsequent events flow as
    ///     `external_id = anonymousId`).
    ///   - `deviceToken` is preserved (the device row remains valid; the
    ///     server will re-attribute it to the next identify call).
    public func logout() async throws {
        guard let manager = identityManager else { throw PyrxError.notInitialized }
        try await manager.logout()
    }

    // MARK: - Events API (PR 3)

    /// Track a custom event.
    ///
    /// Persists to the disk-backed offline queue and triggers a non-blocking
    /// drain attempt. Returns once the event is durably on disk — the actual
    /// network call happens asynchronously and is retried with exponential
    /// backoff on transport / 5xx errors. HTTP 4xx responses cause the
    /// event to be DROPPED with a warning log (no infinite retry of bad
    /// events).
    ///
    /// `external_id` resolution: uses the externalId set by `identify()` if
    /// present, otherwise the SDK's `anonymousId`. Always at least one is
    /// present once `initialize(config:)` has completed.
    ///
    /// - Parameters:
    ///   - eventName: caller-defined event name (e.g. `"order_placed"`).
    ///                Must not be empty / whitespace-only.
    ///   - properties: optional event attributes. Forwarded onto the wire
    ///                 `attributes` field; the backend stores them on
    ///                 `events.attributes` (jsonb) verbatim.
    /// - Throws: `PyrxError.notInitialized` if `initialize(config:)` has not
    ///           completed; `PyrxError.invalidConfig` for empty event name.
    public func track(
        eventName: String,
        properties: [String: JSONValue]? = nil
    ) async throws {
        guard let manager = eventsManager else { throw PyrxError.notInitialized }
        try await manager.track(eventName: eventName, properties: properties)
    }

    /// Track a screen view.
    ///
    /// Wire shape: `event_name = "$screen"` with `attributes.screen_name =
    /// screenName`. Caller `properties` are merged into the same
    /// attributes bag (caller values cannot overwrite the SDK-stamped
    /// `screen_name`). Same queue + retry semantics as `track`.
    ///
    /// - Parameters:
    ///   - screenName: the screen the user is viewing
    ///                 (e.g. `"home"`, `"cart"`, `"product_detail"`).
    ///                 Must not be empty / whitespace-only.
    ///   - properties: optional additional attributes (e.g. product_id,
    ///                 referrer screen).
    public func screen(
        screenName: String,
        properties: [String: JSONValue]? = nil
    ) async throws {
        guard let manager = eventsManager else { throw PyrxError.notInitialized }
        try await manager.screen(screenName: screenName, properties: properties)
    }

    // MARK: - Push API (PR 4)

    /// Ask the user for push notification permission and, on success, trigger
    /// APNs registration so the OS hands us a device token on the next
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// callback.
    ///
    /// Idempotent — re-invoking after the user already authorized is a
    /// no-op on the UI side (the system does NOT re-prompt) but DOES
    /// re-trigger APNs registration, which is the correct behaviour after
    /// a backgrounded fetch or token refresh.
    ///
    /// The status returned reflects the user's choice as the system sees
    /// it AFTER the call:
    ///
    ///   - `.authorized`  — full authorization. Token incoming.
    ///   - `.provisional` — quiet authorization. Token incoming.
    ///   - `.denied`      — user declined. No token will arrive.
    ///   - `.notDetermined` — system failed to present the prompt. Retry
    ///                        later (rare; typically transient).
    ///   - `.ephemeral`   — App Clip context. Token not requested.
    ///
    /// - Parameter options: `UNAuthorizationOptions` mask. Defaults to
    ///   `[.alert, .sound, .badge]`.
    /// - Returns: the resolved `PushPermissionStatus`.
    public func requestPushPermission(
        options: UNAuthorizationOptions = [.alert, .sound, .badge]
    ) async -> PushPermissionStatus {
        let permission = pushPermissionOverride ?? PushPermission(logger: logger)
        return await permission.request(options: options)
    }

    /// Bridge `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// into a `POST /v1/devices` registration with the Synapse backend.
    ///
    /// The device token is converted to a lowercase-hex string, persisted to
    /// the Keychain (so subsequent boots can short-circuit the OS round
    /// trip), and POSTed to `/v1/devices` with a full identifying metadata
    /// snapshot (bundle id, app version, OS version, device model, locale,
    /// timezone, SDK fields). The server upserts by `(tenant_id,
    /// environment, platform, push_token)` so duplicate calls are
    /// idempotent.
    ///
    /// `external_id` resolution mirrors `track` / `screen`: uses the
    /// externalId set by `identify()` if present, otherwise the SDK's
    /// `anonymousId`.
    ///
    /// - Throws: `PyrxError.notInitialized` before `initialize(config:)`
    ///           has completed; `PyrxError.network(...)` on transport / HTTP
    ///           failure; `PyrxError.keychainFailure(...)` on persist
    ///           failure.
    @discardableResult
    public func handleDeviceToken(_ deviceToken: Data) async throws -> DeviceResponse {
        guard let registration = pushRegistration else { throw PyrxError.notInitialized }
        let external = try resolveExternalIdForPush()
        return try await registration.registerToken(deviceToken, externalId: external)
    }

    /// Bridge `application(_:didFailToRegisterForRemoteNotificationsWithError:)`
    /// into the SDK's logger. Fire-and-forget — no retry, no network call.
    /// Apps that want to retry should fix the underlying issue (missing
    /// entitlement, APNs throttling) and re-invoke `requestPushPermission`.
    public func handleRegistrationError(_ error: Error) {
        pushRegistration?.registrationFailed(error) ?? logger.warning(
            "handleRegistrationError called before initialize — \(error.localizedDescription)"
        )
    }

    /// Return the presentation options the OS should apply while the app is
    /// in the foreground (defaults to `[.banner, .sound, .badge]` on iOS 14+,
    /// `[.alert, .sound, .badge]` on older). Also fires `$push_received`
    /// telemetry so foreground deliveries are counted.
    ///
    /// Returns `[]` (suppress) if `initialize(config:)` hasn't run — callers
    /// must initialise the SDK before forwarding the delegate callback.
    public func handleForegroundNotification(
        _ notification: UNNotification
    ) -> UNNotificationPresentationOptions {
        guard let handlers = pushHandlers else {
            logger.warning("handleForegroundNotification before initialize — suppressing.")
            return []
        }
        return handlers.foregroundPresentationOptions(for: notification)
    }

    /// Bridge `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
    /// into a `$push_received` event + the OS-level background-fetch ack.
    ///
    /// The callback is invoked exactly once. The discriminator passed to
    /// the OS reflects whether the SDK had anything actionable to do:
    ///
    ///   - `.newData` — SDK enqueued a `$push_received` event.
    ///   - `.noData`  — SDK couldn't resolve a pyrx payload or initialize
    ///                  hadn't run.
    ///
    /// Both cases are valid completions per Apple's contract — the SDK
    /// does NOT call `.failed` because we have nothing to fail at this
    /// layer (the event-queue retry loop handles any subsequent network
    /// blip).
    ///
    /// Apps that want to do additional work in the same callback should
    /// chain into this method, not the other way around — the SDK invokes
    /// `completion` itself once telemetry is enqueued.
    public func handleBackgroundNotification(
        userInfo: [AnyHashable: Any],
        completion: @Sendable @escaping (PyrxBackgroundFetchResult) -> Void
    ) {
        guard let handlers = pushHandlers else {
            logger.warning("handleBackgroundNotification before initialize — calling completion(.noData).")
            completion(.noData)
            return
        }
        handlers.handleBackground(userInfo: userInfo, completion: completion)
    }

    /// Bridge `UNUserNotificationCenter.userNotificationCenter(_:didReceive:withCompletionHandler:)`
    /// into push telemetry + deep-link routing.
    ///
    /// The dispatch is:
    ///
    ///   - tap on notification body         → `/v1/push/opened` + deep link
    ///   - tap on a custom action button    → `/v1/push/click` (with the
    ///                                        actionIdentifier as `click_url`)
    ///                                        + per-action deep link override
    ///                                        if present
    ///   - swipe to dismiss                 → no telemetry (backend does not
    ///                                        expose `/v1/push/dismissed`
    ///                                        today)
    ///
    /// The callback is invoked exactly once, regardless of which branch
    /// runs. Apps should NOT call `completion` themselves on top of this
    /// — the SDK owns the lifecycle.
    public func handleNotificationResponse(
        _ response: UNNotificationResponse,
        completion: @Sendable @escaping () -> Void
    ) async {
        guard let handlers = pushHandlers else {
            logger.warning("handleNotificationResponse before initialize — calling completion().")
            completion()
            return
        }
        await handlers.handleResponse(response, completion: completion)
    }

    /// Adjust the runtime log level. Safe to call before or after `initialize`.
    public func setLogLevel(_ level: LogLevel) {
        logger.setLevel(level)
    }

    /// Test-only: await any in-flight queue drain. Production callers do
    /// not need this — `track` / `screen` return as soon as the event is
    /// durably on disk, and the drain proceeds asynchronously. Tests use
    /// this to wait for the drain Task spawned by `enqueue` so they can
    /// deterministically inspect the mock session's recorded requests.
    ///
    /// Internal scope (not part of the public API surface).
    func testAwaitQueueDrain() async {
        await eventQueue?.drainNow()
    }

    /// Snapshot of the SDK's internal state. Useful for debug menus and
    /// support bundles.
    public func debugInfo() -> PyrxDebugInfo {
        // `try?` already returns Optional<Optional<String>>.flatten == Optional<String>,
        // so no `?? nil` is needed.
        let externalId = try? storage.get(.externalId)
        let deviceToken = try? storage.get(.deviceToken)
        return PyrxDebugInfo(
            sdkVersion: PyrxConstants.sdkVersion,
            platform: PyrxConstants.platform,
            initialized: config != nil,
            workspaceId: config?.workspaceId,
            logLevel: logger.level,
            anonymousId: anonymousId,
            hasExternalId: externalId != nil,
            hasDeviceToken: deviceToken != nil
        )
    }

    // MARK: - Private

    /// Returns the persisted anonymousId, generating + persisting a fresh
    /// UUIDv4 if none exists. Mirrors the browser SDK pattern in
    /// `pyrx-synapse-browser/src/index.ts:getOrCreateAnonymousId`.
    private func ensureAnonymousId() throws -> String {
        if let existing = try storage.get(.anonymousId) {
            return existing
        }
        let fresh = UUID().uuidString
        try storage.set(.anonymousId, value: fresh)
        return fresh
    }

    /// Resolve the active external_id for the push registration POST. Same
    /// shape as `EventsManager.resolveExternalId`: prefer the identify-set
    /// externalId, fall back to the in-actor anonymousId. Throws
    /// `.notInitialized` if BOTH are unset (programmer error — initialize
    /// must have run by the time we get here).
    private func resolveExternalIdForPush() throws -> String {
        if let external = try storage.get(.externalId), !external.isEmpty {
            return external
        }
        if let anon = anonymousId, !anon.isEmpty {
            return anon
        }
        throw PyrxError.notInitialized
    }
}
