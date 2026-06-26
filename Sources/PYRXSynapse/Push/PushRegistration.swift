//
//  PushRegistration.swift
//  PYRXSynapse
//
//  Owns the bridge from the AppDelegate APNs callback to a `POST /v1/devices`
//  registration with the Synapse backend (Phase 8.4a Task 8.4a.7).
//
//  Callsite shape
//  ==============
//
//  In the host app's `AppDelegate`:
//
//      func application(
//          _ application: UIApplication,
//          didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
//      ) {
//          Task {
//              try? await Pyrx.shared.handleDeviceToken(deviceToken)
//          }
//      }
//
//      func application(
//          _ application: UIApplication,
//          didFailToRegisterForRemoteNotificationsWithError error: Error
//      ) {
//          Pyrx.shared.handleRegistrationError(error)
//      }
//
//  This module:
//
//   1. Converts the opaque `Data` token to the canonical lowercase-hex string
//      the Synapse backend stores (`push_token` column on `devices`).
//   2. Persists it to the Keychain via `PyrxStorage` (slot reserved in PR 1).
//   3. POSTs to `/v1/devices` with the full metadata snapshot — bundle id,
//      app version, OS version, device model, locale, timezone, SDK
//      identifying fields — so the dashboard Device Explorer (§8.3.7) has
//      everything it needs to triage delivery without a follow-up call.
//   4. Logs the response (or surfaces the error) so debug menus can show it.
//
//  The DeviceRegisterRequest schema is defined in `Network/Codables.swift`
//  (added in PR 2 specifically so PR 4 wouldn't need a schema change).
//
//  Token de-duplication
//  --------------------
//  We POST every time `handleDeviceToken` is invoked, even if the token is
//  unchanged. The server upserts by `(tenant_id, environment, platform,
//  push_token)` so a duplicate POST is idempotent. We rely on that rather
//  than gating client-side — if the user uninstalls + reinstalls, the
//  Keychain may still carry the OLD token while the OS issues a NEW one,
//  and we want the SDK to re-register unconditionally.
//
//  Concurrency
//  -----------
//  `handleDeviceToken` is `async throws` and runs inside the Pyrx actor.
//  `handleRegistrationError` is fire-and-forget (logs only) so it can be
//  called from any thread.
//

import Foundation

/// Internal helper owned by `Pyrx`. Forwards a freshly minted device token
/// (or a registration error) into the backend / logger. Not part of the
/// public API surface — callers invoke the public `Pyrx.handleDeviceToken`
/// / `Pyrx.handleRegistrationError` methods which delegate into this class.
final class PushRegistration: @unchecked Sendable {

    private let storage: PyrxStorage
    private let httpClient: HTTPClient
    private let logger: PyrxLogger
    private let environment: WireEnvironment
    /// Optional wrapper-variant marker (e.g. `"rn"`) appended to the wire
    /// `sdk_platform` field as `"ios+<variant>"`. Telemetry-only; never
    /// influences dispatch routing. Threaded from `PyrxConfig.sdkVariant`
    /// at construction time so the variant doesn't have to be re-resolved
    /// on every registration.
    private let sdkVariant: String?

    init(
        storage: PyrxStorage,
        httpClient: HTTPClient,
        environment: WireEnvironment,
        sdkVariant: String? = nil,
        logger: PyrxLogger = .shared
    ) {
        self.storage = storage
        self.httpClient = httpClient
        self.environment = environment
        self.sdkVariant = sdkVariant
        self.logger = logger
    }

    // MARK: - Token registration

    /// Convert APNs `Data` → hex string, persist, and POST to `/v1/devices`.
    ///
    /// - Parameters:
    ///   - deviceToken:  raw `Data` from `application(_:didRegister…
    ///                   WithDeviceToken:)`.
    ///   - externalId:   the active contact identity (externalId if set by
    ///                   `identify()`, otherwise the SDK's anonymousId).
    /// - Returns: the server's `DeviceResponse` so debug menus can surface
    ///            the device id.
    /// - Throws: `PyrxError.invalidConfig` if `externalId` is empty,
    ///           `PyrxError.network(...)` on transport / HTTP failure,
    ///           `PyrxError.keychainFailure` on persist failure.
    @discardableResult
    func registerToken(
        _ deviceToken: Data,
        externalId: String
    ) async throws -> DeviceResponse {
        let trimmed = externalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PyrxError.invalidConfig(reason: "externalId must not be empty")
        }
        guard !deviceToken.isEmpty else {
            throw PyrxError.invalidConfig(reason: "deviceToken must not be empty")
        }

        let hex = Self.hexString(from: deviceToken)
        logger.debug("handleDeviceToken: token=\(Self.fingerprint(hex)) (len=\(hex.count))")

        // Persist BEFORE the network call so a transient failure still
        // leaves the SDK's local state pointing at the most recent token.
        // Diagnostic surfaces (`debugInfo`) then accurately report
        // `hasDeviceToken=true`.
        try storage.set(.deviceToken, value: hex)

        let request = DeviceRegisterRequest(
            externalId: trimmed,
            platform: "ios",
            pushToken: hex,
            bundleId: DeviceMetadata.bundleId(),
            appVersion: DeviceMetadata.appVersion(),
            sdkVersion: DeviceMetadata.sdkVersion(),
            sdkPlatform: DeviceMetadata.sdkPlatform(variant: sdkVariant),
            osVersion: DeviceMetadata.osVersion(),
            deviceModel: DeviceMetadata.deviceModel(),
            locale: DeviceMetadata.locale(),
            timezone: DeviceMetadata.timezone(),
            environment: environment,
            pushEnabled: true,
            metadata: [:]
        )

        let response: DeviceResponse = try await httpClient.post(
            .devicesRegister,
            body: request,
            responseType: DeviceResponse.self
        )

        logger.info(
            "handleDeviceToken: registered device=\(response.id) contact=\(response.contactId)"
        )
        return response
    }

    /// Log a registration failure surfaced by the AppDelegate. Fire-and-forget
    /// — no network call. Apps that want to retry should re-invoke
    /// `Pyrx.shared.requestPushPermission` once the underlying issue is
    /// fixed (typically: missing entitlement, network outage, APNs
    /// throttling).
    func registrationFailed(_ error: Error) {
        logger.error(
            "handleRegistrationError: APNs registration failed — \(error.localizedDescription)"
        )
    }

    // MARK: - Hex helpers

    /// Convert APNs `Data` → canonical lowercase-hex string.
    ///
    /// Apple's APNs tokens are 32 bytes (legacy) or 32 bytes (modern). We
    /// emit them as 64-character lowercase hex without separators — matching
    /// what `synapse-api/app/models/device.py::Device.push_token` stores and
    /// what `app/services/push_dispatcher.py` passes to APNs/HTTP/2.
    ///
    /// Internal access so tests can pin the exact conversion without
    /// going through `registerToken`.
    static func hexString(from data: Data) -> String {
        // `map { String(format: "%02x", $0) }.joined()` is the canonical
        // Swift idiom. We avoid `data.hexEncodedString()` because it doesn't
        // exist on Foundation; we don't want to add CryptoKit just for hex.
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Diagnostic-only short form of a hex token: last 8 chars with a leading
    /// horizontal-ellipsis (matching the dashboard's
    /// `push_token_fingerprint`). Never written to disk; only used in logs.
    private static func fingerprint(_ hex: String) -> String {
        guard hex.count >= 8 else { return "…\(hex)" }
        return "…\(hex.suffix(8))"
    }
}
