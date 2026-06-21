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
//  Subsequent PRs (events, push, attribution) extend this actor in place
//  rather than introducing new top-level types.
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

    /// Built during `initialize(config:)` from the validated config.
    private var httpClient: HTTPClient?

    /// Built during `initialize(config:)` once httpClient is ready.
    private var identityManager: IdentityManager?

    // MARK: - Init

    /// Designated initializer — internal so the shared singleton is the only
    /// production path. Tests in `PYRXSynapseTests` can build a fresh actor
    /// with an injected storage + HTTPSession.
    init(
        storage: PyrxStorage = KeychainStore(),
        session: HTTPSession = URLSession.shared,
        logger: PyrxLogger = .shared
    ) {
        self.storage = storage
        self.session = session
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

    /// Adjust the runtime log level. Safe to call before or after `initialize`.
    public func setLogLevel(_ level: LogLevel) {
        logger.setLevel(level)
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
