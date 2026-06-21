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
//  Subsequent PRs (push, attribution) extend this actor in place rather
//  than introducing new top-level types.
//

import Foundation

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
        logger: PyrxLogger = .shared
    ) {
        self.storage = storage
        self.session = session
        self.queueStoreOverride = queueStore
        self.reachabilityOverride = reachability
        self.queueClockOverride = queueClock
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
        self.eventsManager = EventsManager(
            queue: queue,
            storage: storage,
            anonymousId: anon,
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
}
