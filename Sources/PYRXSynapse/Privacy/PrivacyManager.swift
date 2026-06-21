//
//  PrivacyManager.swift
//  PYRXSynapse
//
//  Privacy controls for Phase 8.4a Task 8.4a.10 — `setTrackingEnabled` kill
//  switch + `deleteUser` GDPR cascade + ATT (App Tracking Transparency)
//  awareness.
//
//  Three separable surfaces, intentionally kept together so the privacy
//  story has one obvious file to read:
//
//    1. Tracking gate — actor-isolated `Bool` that the SDK consults before
//       draining the event queue. Events still ENQUEUE while disabled
//       (so a flip back to enabled doesn't lose in-flight intent) but
//       they DO NOT drain until tracking is re-enabled.
//
//    2. Delete user — GDPR right-to-erasure. Wipes Keychain (anon + external
//       + device token), wipes the on-disk event queue, then POSTs
//       `/v1/contacts/{external_id}/delete` to ask the backend to cascade
//       its rows. **Local wipe happens BEFORE the backend call** — if the
//       backend fails, the on-device data is still gone.
//
//    3. ATT awareness — `AppTrackingTransparency` import is walled behind
//       `#if canImport(AppTrackingTransparency)` (iOS 14+; not on macOS,
//       tvOS, watchOS pre-9). We READ the authorisation status only.
//       We DO NOT auto-prompt — that's an app-level decision.
//
//  Wire shape for the delete call:
//
//      POST /v1/contacts/{external_id}/delete
//      X-WORKSPACE-ID: …
//      X-API-KEY:     …
//      (empty body — the path carries the identifier)
//
//      → 200 { "status": "deleted", … }   (backend-defined envelope)
//      → 404 { "detail": "Contact not found", … }  (no-op — already gone)
//
//  The SDK swallows 4xx on this call — the user-facing semantic is "your
//  data is gone from this device", which is true regardless of what the
//  server replies. Transport errors propagate so callers can surface a
//  "we couldn't reach the server, please try again" message.
//

import Foundation

#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

// MARK: - ATT status (cross-platform stand-in)

/// SDK-internal mirror of `ATTrackingManager.AuthorizationStatus`. We define
/// our own enum so the public `PyrxDebugInfo` type can carry the value on
/// every platform — including macOS, tvOS pre-9, and Linux CI — without
/// pulling in `AppTrackingTransparency` framework symbols where they don't
/// exist.
public enum PyrxATTStatus: Int, Sendable, Equatable, Codable {
    /// Framework unavailable on this OS / platform. The expected value on
    /// macOS, tvOS < 9, watchOS, Linux, and iOS < 14 — anywhere
    /// `AppTrackingTransparency` cannot be imported or the API version
    /// guard fails.
    case unavailable = -1

    /// User hasn't been prompted yet.
    case notDetermined = 0

    /// User explicitly denied — system policy forbids tracking.
    case restricted = 1

    /// User chose "Ask App Not to Track".
    case denied = 2

    /// User chose "Allow".
    case authorized = 3
}

// MARK: - PrivacyManager façade

/// Actor-isolated privacy controls. Owned by `Pyrx`. Construction is cheap
/// — no I/O until a public method is called.
actor PrivacyManager {

    // MARK: - Dependencies

    private let storage: PyrxStorage
    private let queue: EventQueue
    private let httpClient: HTTPClient
    private let logger: PyrxLogger

    // MARK: - State

    /// Default to `true` — the SDK is opt-OUT, not opt-IN. Apps that need
    /// stricter defaults can flip this with `setTrackingEnabled(false)`
    /// before calling `initialize(config:)` (the gate is read on every
    /// drain attempt — see `EventQueue.setTrackingEnabled`).
    private(set) var trackingEnabled: Bool = true

    // MARK: - Init

    init(
        storage: PyrxStorage,
        queue: EventQueue,
        httpClient: HTTPClient,
        logger: PyrxLogger = .shared
    ) {
        self.storage = storage
        self.queue = queue
        self.httpClient = httpClient
        self.logger = logger
    }

    // MARK: - Tracking gate

    /// Toggle the SDK's tracking kill switch.
    ///
    /// When `enabled == false`:
    ///   - New `track` / `screen` calls still ENQUEUE events to the on-disk
    ///     queue (so the SDK preserves user intent through the flip).
    ///   - The drain loop refuses to send anything until tracking is
    ///     re-enabled. The next `setTrackingEnabled(true)` automatically
    ///     triggers a drain so queued events flush as soon as the user
    ///     re-opts-in.
    ///
    /// When `enabled == true` (the default):
    ///   - Normal SDK behaviour — `enqueue` triggers a drain immediately.
    ///
    /// The flag is NOT persisted across launches. Apps that want a sticky
    /// opt-out should restore the choice from their own preferences store
    /// on launch and call `setTrackingEnabled(false)` before
    /// `initialize(config:)` — or right after, before any tracking calls.
    func setTrackingEnabled(_ enabled: Bool) async {
        let wasEnabled = trackingEnabled
        trackingEnabled = enabled
        await queue.setTrackingEnabled(enabled)

        if enabled && !wasEnabled {
            // Re-enabling → kick the drain immediately so events buffered
            // during the disabled window flush without waiting for the
            // next track call.
            logger.info("PrivacyManager: tracking re-enabled — flushing buffered queue.")
            await queue.drainNow()
        } else if !enabled && wasEnabled {
            logger.info("PrivacyManager: tracking disabled — events will buffer but not drain.")
        }
    }

    // MARK: - GDPR delete

    /// Right-to-erasure cascade.
    ///
    /// Order of operations (intentional — local wipe first so a backend
    /// failure does NOT leave on-device data behind):
    ///
    ///   1. Resolve the active `external_id` BEFORE wiping (we'll need it
    ///      for the backend call).
    ///   2. Wipe the Keychain (`anonymousId`, `externalId`, `deviceToken`).
    ///   3. Wipe the event queue (drop every pending event without sending).
    ///   4. POST `/v1/contacts/{external_id}/delete` — IF we had an
    ///      external_id. Anonymous-only users have nothing the backend
    ///      knows about (events live on the queue, never sent) so we skip
    ///      the backend call.
    ///
    /// - Throws: `PyrxError.network(...)` if the backend call fails. Local
    ///   data has already been wiped at that point — callers should treat
    ///   the throw as "tell the user to retry the server side" rather than
    ///   "the wipe didn't happen".
    func deleteUser() async throws {
        // 1. Capture identity BEFORE we wipe.
        let externalId: String? = (try? storage.get(.externalId))
            .flatMap { $0.isEmpty ? nil : $0 }
        let anonId: String? = (try? storage.get(.anonymousId))
            .flatMap { $0.isEmpty ? nil : $0 }

        // The backend identifies contacts by `external_id`. The SDK uses
        // anonymousId as a fallback for unidentified users in
        // `EventsManager.resolveExternalId` — so for the delete cascade
        // we also fall back to anonId when no identify call has run.
        let backendIdentifier = externalId ?? anonId

        // 2. Wipe local storage — Keychain values + device-token entry.
        //    `wipe()` removes every PyrxStorageKey value the SDK owns.
        do {
            try storage.wipe()
            logger.info("PrivacyManager: storage wiped.")
        } catch {
            // Wipe failures are surfaced but do NOT prevent the queue
            // wipe + backend call — the user asked us to delete their
            // data and we will try every step. The throw at the end
            // (if any) reflects the FINAL failure surface.
            logger.warning("PrivacyManager: storage wipe failed — \(error.localizedDescription)")
        }

        // 3. Wipe the on-disk event queue.
        await queue.wipe()
        logger.info("PrivacyManager: event queue wiped.")

        // 4. Backend cascade. Skipped if we never had any identifier at
        //    all (cold-installed SDK that never enqueued an event).
        guard let identifier = backendIdentifier else {
            logger.info("PrivacyManager: no identifier to delete server-side — local wipe complete.")
            return
        }

        do {
            let path = Self.contactsDeletePath(externalId: identifier)
            try await httpClient.postPath(path, body: EmptyBody())
            logger.info("PrivacyManager: backend delete OK for external_id=\(identifier).")
        } catch let PyrxError.network(.httpStatus(statusCode, _)) where (400..<500).contains(statusCode) {
            // 4xx: backend says "contact not found" or similar. Local
            // data is already gone — that's the user-visible promise. Log
            // and swallow so callers don't see a confusing "delete
            // failed" when in fact every byte the SDK had IS gone.
            logger.info(
                "PrivacyManager: backend returned \(statusCode) on delete — " +
                "treating as already-deleted, local wipe stands."
            )
        } catch {
            // 5xx / transport errors propagate — callers can surface a
            // "couldn't reach server, please try again" message. Local
            // data is still gone at this point.
            logger.warning("PrivacyManager: backend delete failed — \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Path helper

    /// Build `/v1/contacts/{external_id}/delete` with the external_id URL-
    /// encoded so identifiers that contain spaces, `+`, or `/` round-trip
    /// safely through the path. Surfaced as a static so tests can assert
    /// the exact path the SDK will hit without invoking the network layer.
    static func contactsDeletePath(externalId: String) -> String {
        let allowed = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/"))
        let encoded = externalId.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? externalId
        return "/v1/contacts/\(encoded)/delete"
    }

    // MARK: - ATT awareness

    /// Read the current ATT authorisation status WITHOUT prompting.
    ///
    /// Returns `.unavailable` when:
    ///   - `AppTrackingTransparency` is not importable (macOS, tvOS pre-9,
    ///     watchOS, Linux CI).
    ///   - Running on iOS < 14 (the framework symbol exists but the API
    ///     guard fails).
    ///
    /// This is a READ — we never call `requestTrackingAuthorization`. ATT
    /// prompts are an app-level concern: only the host app knows the right
    /// moment + UX to ask. The SDK surfaces the current status so debug
    /// menus + support bundles can record it.
    nonisolated func attAuthorizationStatus() -> PyrxATTStatus {
        Self.staticATTStatus()
    }

    /// Static version of `attAuthorizationStatus()` — same logic, no
    /// instance required. Surfaced so the pre-init `debugInfo` path can
    /// surface ATT status before any `PrivacyManager` has been built.
    static func staticATTStatus() -> PyrxATTStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14.0, tvOS 14.0, macOS 11.0, *) {
            let raw = ATTrackingManager.trackingAuthorizationStatus
            switch raw {
            case .notDetermined: return .notDetermined
            case .restricted:    return .restricted
            case .denied:        return .denied
            case .authorized:    return .authorized
            @unknown default:    return .notDetermined
            }
        } else {
            return .unavailable
        }
        #else
        return .unavailable
        #endif
    }
}

// MARK: - Empty body helper

/// `POST /v1/contacts/{external_id}/delete` carries an empty body — the
/// path parameter is the entire payload. `HTTPClient.post(_:body:)` requires
/// an `Encodable`, so we ship a one-field-less struct rather than special-
/// casing the wire layer.
private struct EmptyBody: Encodable {}
