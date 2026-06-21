//
//  IdentityManager.swift
//  PYRXSynapse
//
//  Anonymous-merge state machine per ARCHITECTURE.md §28.4 + push SDK plan
//  §5.3. Owned solely by the `Pyrx` actor — never instantiated by callers.
//
//  State held on disk (PyrxStorage / KeychainStore):
//
//    .anonymousId  — generated UUIDv4 at first launch, persists forever
//                    (PR 1 / Pyrx.ensureAnonymousId)
//    .externalId   — set by identify(externalId:traits:), cleared by logout()
//    .deviceToken  — set by PR 4 push registration, NOT cleared by logout()
//
//  Lifecycle:
//
//    1. First launch — anonymousId is minted by PR 1; nothing else exists.
//       Events flow as `external_id = anonymousId` until identify is called.
//
//    2. identify(externalId:) — POST /v1/identify with both ids; server
//       performs the merge (known_exists / first_sighting / no_anonymous).
//       Client persists externalId. anonymousId is NOT cleared (audit /
//       diagnostics; the server is the source of truth for the merge).
//
//    3. alias(newExternalId:) — POST /v1/alias linking an already-known
//       external_id to a new external_id. Caller must already be identified;
//       fails with .notInitialized otherwise (we still require initialize()
//       but also need an externalId to alias from).
//
//    4. logout() — purely client-side. Clears externalId from Keychain so
//       subsequent events fall back to anonymousId. KEEPS anonymousId +
//       deviceToken so the device row stays valid for re-attribution.
//       NO server call (the server cannot tell us to forget — the SDK
//       owns the local identity).
//
//  Concurrency: every public method is `async throws`. The `Pyrx` actor
//  serializes calls into the manager via actor isolation; the manager
//  itself is `final` + `@unchecked Sendable` (it only forwards into the
//  thread-safe storage and stateless HTTPClient).
//

import Foundation

/// Per-call return shape for `identify()` and `alias()`. Wraps the server
/// response so callers can log which merge branch ran for support cases.
public struct IdentityResult: Sendable, Equatable {
    public let contactId: UUID
    public let path: IdentifyPath
    public let aliasedExternalId: String?
    public let eventsReattributed: Int
    public let devicesReattributed: Int
    public let anonymousContactTombstoned: Bool

    init(from response: IdentifyResponse) {
        self.contactId = response.contactId
        self.path = response.path
        self.aliasedExternalId = response.aliasedExternalId
        self.eventsReattributed = response.eventsReattributed
        self.devicesReattributed = response.devicesReattributed
        self.anonymousContactTombstoned = response.anonymousContactTombstoned
    }
}

/// Identity state machine. Owned by `Pyrx`; not constructed by callers.
final class IdentityManager: @unchecked Sendable {

    private let storage: PyrxStorage
    private let httpClient: HTTPClient
    private let logger: PyrxLogger
    private let environment: WireEnvironment

    init(
        storage: PyrxStorage,
        httpClient: HTTPClient,
        environment: WireEnvironment,
        logger: PyrxLogger = .shared
    ) {
        self.storage = storage
        self.httpClient = httpClient
        self.environment = environment
        self.logger = logger
    }

    // MARK: - identify

    /// Identify an anonymous SDK session into a known contact.
    ///
    /// Server-side state machine (push SDK plan §5.3):
    ///
    ///   * **known_exists**   — both contacts already exist; server merges
    ///                          anonymous → canonical, re-attributes
    ///                          events + devices, tombstones anonymous.
    ///   * **first_sighting** — only the anonymous contact exists; rename
    ///                          in place.
    ///   * **no_anonymous**   — no anonymous contact; plain upsert.
    ///
    /// Client-side after success: persists `externalId` to Keychain. Keeps
    /// `anonymousId` for audit (server is authoritative for the merge).
    ///
    /// - Parameters:
    ///   - externalId: canonical contact identity (e.g. your user id).
    ///   - traits:     optional shallow-merge into Contact.properties.
    /// - Throws: `PyrxError.invalidConfig` on empty externalId,
    ///           `PyrxError.network(...)` on transport / HTTP failure,
    ///           `PyrxError.keychainFailure` on persist failure.
    @discardableResult
    func identify(
        externalId: String,
        traits: [String: JSONValue]? = nil
    ) async throws -> IdentityResult {
        let trimmed = externalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PyrxError.invalidConfig(reason: "externalId must not be empty")
        }

        // anonymousId is set by Pyrx.ensureAnonymousId during initialize().
        // If somehow missing at this point, send nil — the server tolerates
        // it (path C: no_anonymous) and we recover by generating one on
        // the next event flow (PR 3).
        let anonymousId = try storage.get(.anonymousId)

        let request = IdentifyRequest(
            anonymousId: anonymousId,
            externalId: trimmed,
            traits: traits,
            environment: environment
        )

        let response: IdentifyResponse = try await httpClient.post(
            .identify,
            body: request,
            responseType: IdentifyResponse.self
        )

        // Persist the externalId. Keep anonymousId — it is audit-only after
        // the merge; the server has already re-attributed history.
        try storage.set(.externalId, value: trimmed)

        logger.info("identify completed — path=\(response.path.rawValue) contact=\(response.contactId)")
        return IdentityResult(from: response)
    }

    // MARK: - alias

    /// Explicitly merge an anonymous external_id into a known external_id.
    ///
    /// Both ids are required by the backend. We pass the on-disk
    /// `anonymousId` as the prior id and `newExternalId` as the target.
    /// After success, `newExternalId` is persisted as the current externalId.
    ///
    /// - Parameter newExternalId: the canonical identity to merge into.
    /// - Throws: `PyrxError.invalidConfig` on empty newExternalId,
    ///           `PyrxError.notInitialized` if no anonymousId is on disk
    ///           (initialize() must have run),
    ///           `PyrxError.network(...)` on transport / HTTP failure,
    ///           `PyrxError.keychainFailure` on persist failure.
    @discardableResult
    func alias(newExternalId: String) async throws -> IdentityResult {
        let trimmed = newExternalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PyrxError.invalidConfig(reason: "newExternalId must not be empty")
        }

        // /v1/alias requires both ids — there must be an anonymousId on disk.
        // If a caller calls alias() without ever calling initialize(), this
        // is the failure mode they see.
        guard let anonymousId = try storage.get(.anonymousId), !anonymousId.isEmpty else {
            throw PyrxError.notInitialized
        }

        let request = AliasRequest(
            anonymousId: anonymousId,
            externalId: trimmed,
            environment: environment
        )

        let response: AliasResponse = try await httpClient.post(
            .alias,
            body: request,
            responseType: AliasResponse.self
        )

        try storage.set(.externalId, value: trimmed)

        logger.info("alias completed — path=\(response.path.rawValue) contact=\(response.contactId)")
        return IdentityResult(from: response)
    }

    // MARK: - logout

    /// Client-side identity clear. No server call.
    ///
    /// Preserves `anonymousId` and `deviceToken` so the device row stays
    /// valid for re-attribution. After logout, subsequent events flow with
    /// `external_id = anonymousId` (the same row prior to identify), and
    /// the server treats this as a new anonymous session reassigned to the
    /// same device.
    func logout() async throws {
        try storage.delete(.externalId)
        logger.info("logout — externalId cleared; anonymousId + deviceToken preserved")
    }
}
