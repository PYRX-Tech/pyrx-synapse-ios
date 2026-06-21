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
//  Subsequent PRs (HTTP, identity, events, push, attribution) extend this
//  actor in place rather than introducing new top-level types.
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

    // MARK: - Init

    /// Designated initializer — internal so the shared singleton is the only
    /// production path. Tests in `PYRXSynapseTests` can build a fresh actor
    /// via `Pyrx.testInstance(storage:)` (see test helpers).
    init(storage: PyrxStorage = KeychainStore(), logger: PyrxLogger = .shared) {
        self.storage = storage
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

        logger.info(
            "Initialized PYRXSynapse v\(PyrxConstants.sdkVersion) " +
            "(workspace=\(config.workspaceId), env=\(config.environment.rawValue))"
        )
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
