//
//  PushHandlers.swift
//  PYRXSynapse
//
//  Foreground / background / tap / dismiss handlers for incoming pushes
//  (Phase 8.4a Task 8.4a.8). Three concerns, kept side-by-side:
//
//    1. Foreground presentation     — decide what to show while the app is
//                                     in the foreground.
//    2. Background delivery         — fire `$push_received` telemetry and
//                                     ack APNs with `.newData`.
//    3. Notification response       — tap on body → `/v1/push/opened`;
//                                     tap on custom action → `/v1/push/click`.
//
//  These three callbacks bridge `UNUserNotificationCenterDelegate` callbacks
//  in the host app to the Synapse wire surface. The host AppDelegate code
//  looks like:
//
//      class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
//
//          func userNotificationCenter(
//              _ center: UNUserNotificationCenter,
//              willPresent notification: UNNotification,
//              withCompletionHandler completionHandler:
//                  @escaping (UNNotificationPresentationOptions) -> Void
//          ) {
//              completionHandler(Pyrx.shared.handleForegroundNotification(notification))
//          }
//
//          func application(
//              _ application: UIApplication,
//              didReceiveRemoteNotification userInfo: [AnyHashable: Any],
//              fetchCompletionHandler completionHandler:
//                  @escaping (UIBackgroundFetchResult) -> Void
//          ) {
//              Pyrx.shared.handleBackgroundNotification(
//                  userInfo: userInfo,
//                  completion: completionHandler
//              )
//          }
//
//          func userNotificationCenter(
//              _ center: UNUserNotificationCenter,
//              didReceive response: UNNotificationResponse,
//              withCompletionHandler completionHandler: @escaping () -> Void
//          ) {
//              Task {
//                  await Pyrx.shared.handleNotificationResponse(
//                      response,
//                      completion: completionHandler
//                  )
//              }
//          }
//      }
//
//  Payload contract
//  ================
//
//  PYRX pushes carry a `pyrx` namespace inside the APNs custom payload
//  (NOT inside `aps`). Today's contract (matched against
//  `app/services/push_dispatcher.py::build_apns_payload`):
//
//      {
//        "aps": { "alert": {...}, "sound": "default", "mutable-content": 1 },
//        "pyrx": {
//          "push_log_id":  "9b1c8f4a-3a3e-4e1d-9b7f-1c2e3d4e5f6a",
//          "tenant_id":    "…",
//          "deep_link":    "pyrx://contacts/abc"     // optional
//        },
//        "pyrx_attrs": { … arbitrary key/values forwarded into the
//                        $push_received event's `attributes` … }
//      }
//
//  We treat the `pyrx` block as the source of truth for telemetry IDs and
//  the deep link. The `pyrx_attrs` block is opt-in metadata the campaign
//  emitter can attach; we forward it verbatim onto the `$push_received`
//  event so analytics consumers can join by `attributes.campaign_id` etc.
//
//  We are deliberately lax about MISSING keys — pushes that don't carry a
//  `push_log_id` (e.g. legacy server-test pushes) are silently ignored on
//  the telemetry side; the foreground presentation / deep-link logic still
//  runs.
//
//  Platform walls
//  --------------
//  Most of the API surface (UNNotification, UNNotificationResponse,
//  UNNotificationPresentationOptions) is in `UserNotifications` — available
//  on every Apple platform. The deep-link routing path needs `UIApplication`
//  which is UIKit-only, so we gate it with `#if canImport(UIKit)`.
//

import Foundation
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Background fetch result shim

/// Mirror of `UIBackgroundFetchResult` so the SDK can compile on non-UIKit
/// platforms (CI lint, macOS-only SPM consumers). On iOS / iPadOS / tvOS
/// the public API surface uses `UIBackgroundFetchResult` directly via the
/// `#if canImport(UIKit)`-walled `handleBackgroundNotification` overload.
public enum PyrxBackgroundFetchResult: Int, Sendable {
    case newData = 0
    case noData = 1
    case failed = 2
}

// MARK: - PushHandlers façade

/// Internal façade owned by `Pyrx`. The public API (on Pyrx) is the thin
/// surface; everything below stays internal so a future schema change
/// stays a non-breaking SDK update.
final class PushHandlers: @unchecked Sendable {

    private let httpClient: HTTPClient
    private let eventsManager: EventsManager
    private let urlOpener: PushURLOpener
    private let logger: PyrxLogger

    /// `pyrx`-namespace keys inside the APNs payload — pulled into a single
    /// place so renaming is grep-friendly.
    enum PayloadKey {
        static let pyrxNamespace = "pyrx"
        static let pyrxAttrs = "pyrx_attrs"
        static let pushLogId = "push_log_id"
        static let deepLink = "deep_link"
        static let actionUrl = "action_url"  // optional per-action override on custom actions
    }

    init(
        httpClient: HTTPClient,
        eventsManager: EventsManager,
        urlOpener: PushURLOpener = PushHandlers.defaultURLOpener(),
        logger: PyrxLogger = .shared
    ) {
        self.httpClient = httpClient
        self.eventsManager = eventsManager
        self.urlOpener = urlOpener
        self.logger = logger
    }

    static func defaultURLOpener() -> PushURLOpener {
        #if canImport(UIKit)
        return UIApplicationURLOpener()
        #else
        return NoopURLOpener()
        #endif
    }

    // MARK: - Foreground

    /// Return the presentation options the OS should apply while the app is
    /// in the foreground. Defaults to `[.banner, .sound]` (iOS 14+) so
    /// the notification surfaces visibly even when the user is using the app
    /// — the most common product expectation.
    ///
    /// Apps that want different behaviour should override this in their
    /// `UNUserNotificationCenterDelegate` directly rather than passing
    /// through the SDK.
    func foregroundPresentationOptions(
        for notification: UNNotification
    ) -> UNNotificationPresentationOptions {
        // Track `$push_received` for foreground deliveries too — otherwise
        // analytics under-counts campaigns that fire while users have the
        // app open.
        let userInfo = notification.request.content.userInfo
        Task { [weak self] in
            await self?.recordPushReceived(userInfo: userInfo)
        }

        if #available(iOS 14.0, tvOS 14.0, watchOS 7.0, macOS 11.0, *) {
            return [.banner, .sound, .badge]
        } else {
            return [.alert, .sound, .badge]
        }
    }

    // MARK: - Background

    /// Process a silent / background push: fire `$push_received` and ack APNs.
    /// The completion is invoked with `.newData` on success and `.noData` if
    /// the SDK had nothing actionable to do (the OS still acks the push
    /// either way; the discriminator only affects iOS's background-fetch
    /// heuristics).
    func handleBackground(
        userInfo: [AnyHashable: Any],
        completion: @Sendable @escaping (PyrxBackgroundFetchResult) -> Void
    ) {
        Task { [weak self] in
            guard let self else {
                completion(.noData)
                return
            }
            let recorded = await self.recordPushReceived(userInfo: userInfo)
            completion(recorded ? .newData : .noData)
        }
    }

    // MARK: - Notification response

    /// Handle a tap (default action), a custom action, or a dismiss.
    ///
    /// - Default action (`UNNotificationDefaultActionIdentifier`): fires
    ///   `/v1/push/opened` if a `push_log_id` is present, then opens the
    ///   deep link if one is attached.
    /// - Custom action: fires `/v1/push/click` carrying the `actionIdentifier`
    ///   as the `click_url` field (we don't have a separate `action_id`
    ///   field on the wire today — the backend stores it inside
    ///   `attributes.click_url`).
    /// - Dismiss (`UNNotificationDismissActionIdentifier`): no telemetry
    ///   endpoint exists today (backend does not expose
    ///   `/v1/push/dismissed`). We just log and return.
    ///
    /// `completion` is invoked once, regardless of which branch ran.
    func handleResponse(
        _ response: UNNotificationResponse,
        completion: @Sendable @escaping () -> Void
    ) async {
        // Always invoke completion exactly once — wrap everything in a
        // defer-like local function so an early return / thrown error
        // doesn't leave the OS waiting.
        let userInfo = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier

        switch actionId {
        case UNNotificationDefaultActionIdentifier:
            // Body tap → push_opened + deep-link.
            await emitOpened(userInfo: userInfo)
            await routeDeepLink(userInfo: userInfo, overrideKey: nil)

        case UNNotificationDismissActionIdentifier:
            // No telemetry endpoint for dismiss today. Log + ack.
            logger.debug("handleNotificationResponse: dismiss — no telemetry to emit.")

        default:
            // Custom action → push_click + optional action-scoped deep link.
            await emitClicked(userInfo: userInfo, actionId: actionId)
            // Custom actions may carry a per-action URL override under
            // `pyrx_attrs.<actionId>_url` — we look for that first, else
            // fall back to the default `deep_link`.
            await routeDeepLink(userInfo: userInfo, overrideKey: "\(actionId)_url")
        }

        completion()
    }

    // MARK: - Telemetry

    /// Fire `$push_received` through the events queue (offline-durable,
    /// retried automatically). Returns true if an event was actually enqueued
    /// — false means the payload didn't carry the `pyrx` namespace we use
    /// to identify Synapse-originated pushes (legacy / cross-vendor pushes
    /// pass through silently so analytics doesn't over-count them).
    @discardableResult
    private func recordPushReceived(userInfo: [AnyHashable: Any]) async -> Bool {
        // Gate on `push_log_id` — that's the canonical "this push came from
        // Synapse" marker. Without it, we have nothing useful to attribute
        // the open to, and firing a bare `$push_received` would skew the
        // received → opened conversion funnel.
        guard pushLogId(from: userInfo) != nil else {
            logger.debug("recordPushReceived: no pyrx.push_log_id — skipping $push_received.")
            return false
        }
        let attrs = pyrxAttributes(from: userInfo)
        do {
            try await eventsManager.track(
                eventName: "$push_received",
                properties: attrs
            )
            return true
        } catch {
            logger.warning("recordPushReceived: track failed — \(error.localizedDescription)")
            return false
        }
    }

    /// Fire `/v1/push/opened` with the `push_log_id` extracted from the
    /// `pyrx` namespace. No-op (with a warning log) if the payload doesn't
    /// carry one — legacy / cross-vendor pushes simply skip telemetry.
    ///
    /// Internal (not private) so the test target can exercise the same
    /// code path without instantiating a real `UNNotificationResponse`
    /// (which has no public initialiser).
    func emitOpened(userInfo: [AnyHashable: Any]) async {
        guard let pushLogId = pushLogId(from: userInfo) else {
            logger.warning("handleNotificationResponse: missing push_log_id — skipping /v1/push/opened.")
            return
        }
        let body = PushOpenedRequest(
            pushLogId: pushLogId,
            occurredAt: Self.iso8601Now()
        )
        do {
            let response: PushTelemetryResponse = try await httpClient.post(
                .pushOpened,
                body: body,
                responseType: PushTelemetryResponse.self
            )
            logger.info("push/opened: status=\(response.status.rawValue) envelope=\(response.envelopeId?.uuidString ?? "nil")")
        } catch {
            logger.warning("push/opened: failed — \(error.localizedDescription)")
        }
    }

    /// Fire `/v1/push/click` carrying the actionIdentifier as the
    /// `click_url` discriminator. Backend stores this on
    /// `attributes.click_url` per push SDK plan §6.5.
    ///
    /// Internal (not private) so the test target can exercise the same
    /// code path without instantiating a real `UNNotificationResponse`.
    func emitClicked(
        userInfo: [AnyHashable: Any],
        actionId: String
    ) async {
        guard let pushLogId = pushLogId(from: userInfo) else {
            logger.warning("handleNotificationResponse: missing push_log_id — skipping /v1/push/click.")
            return
        }
        let body = PushClickedRequest(
            pushLogId: pushLogId,
            occurredAt: Self.iso8601Now(),
            clickUrl: actionId
        )
        do {
            let response: PushTelemetryResponse = try await httpClient.post(
                .pushClick,
                body: body,
                responseType: PushTelemetryResponse.self
            )
            logger.info("push/click: status=\(response.status.rawValue) action=\(actionId)")
        } catch {
            logger.warning("push/click: failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Deep link

    /// Extract a deep link from the `pyrx` namespace and open it. The
    /// `overrideKey` parameter lets custom actions specify a per-action URL
    /// override (looked up first under `pyrx_attrs`).
    ///
    /// Internal (not private) so the test target can exercise the same
    /// code path without instantiating a real `UNNotificationResponse`.
    func routeDeepLink(
        userInfo: [AnyHashable: Any],
        overrideKey: String?
    ) async {
        guard let url = deepLink(from: userInfo, overrideKey: overrideKey) else {
            return
        }
        await urlOpener.open(url)
        logger.debug("routeDeepLink: opened \(url.absoluteString)")
    }

    // MARK: - Payload parsers

    /// Parse the `pyrx.push_log_id` UUID. Returns nil on missing / malformed.
    func pushLogId(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard
            let pyrxBlock = userInfo[PayloadKey.pyrxNamespace] as? [String: Any],
            let raw = pyrxBlock[PayloadKey.pushLogId] as? String
        else { return nil }
        return UUID(uuidString: raw)
    }

    /// Snapshot the `pyrx_attrs` block as `[String: JSONValue]` for the
    /// `$push_received` event's `properties`. Returns `nil` (not an empty
    /// dict) if the block is absent — callers pass the nil through to
    /// `track(properties:)` which preserves the "no attributes" semantic.
    func pyrxAttributes(from userInfo: [AnyHashable: Any]) -> [String: JSONValue]? {
        guard let block = userInfo[PayloadKey.pyrxAttrs] as? [String: Any] else {
            // Even with no `pyrx_attrs`, we can still attach the push_log_id
            // so analytics can join across $push_received and the open/click
            // telemetry rows. Surface a minimal dict in that case.
            if let logId = pushLogId(from: userInfo) {
                return ["push_log_id": .string(logId.uuidString)]
            }
            return nil
        }
        var converted: [String: JSONValue] = [:]
        for (key, value) in block {
            if let json = Self.toJSONValue(value) {
                converted[key] = json
            }
        }
        if let logId = pushLogId(from: userInfo) {
            // SDK-stamped — last write wins so a campaign cannot spoof the id.
            converted["push_log_id"] = .string(logId.uuidString)
        }
        return converted.isEmpty ? nil : converted
    }

    /// Extract a URL from `pyrx.deep_link` (the campaign-level default) with
    /// an optional override key checked first against `pyrx_attrs`. The
    /// override is how custom action handlers can route to action-specific
    /// destinations without changing the default deep link.
    func deepLink(
        from userInfo: [AnyHashable: Any],
        overrideKey: String?
    ) -> URL? {
        // 1. action-scoped override under pyrx_attrs
        if let key = overrideKey,
           let attrs = userInfo[PayloadKey.pyrxAttrs] as? [String: Any],
           let raw = attrs[key] as? String,
           let url = URL(string: raw) {
            return url
        }
        // 2. campaign-level default under pyrx.deep_link
        if let pyrxBlock = userInfo[PayloadKey.pyrxNamespace] as? [String: Any],
           let raw = pyrxBlock[PayloadKey.deepLink] as? String,
           let url = URL(string: raw) {
            return url
        }
        return nil
    }

    // MARK: - Codec helpers

    /// Cheap recursive `Any` → `JSONValue` converter. Anything we can't
    /// represent gets dropped (silently) — the campaign emitter should not
    /// be sending non-JSON-able values into `pyrx_attrs` in the first place.
    static func toJSONValue(_ value: Any) -> JSONValue? {
        switch value {
        case let null as NSNull:
            _ = null
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let number as NSNumber:
            // NSNumber straddles Bool / Int / Double — disambiguate by
            // CFNumberType so 1 stays Int and 1.0 stays Double.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .double(number.doubleValue)
            }
            return .int(number.int64Value)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.compactMap(toJSONValue))
        case let dict as [String: Any]:
            var converted: [String: JSONValue] = [:]
            for (key, inner) in dict {
                if let json = toJSONValue(inner) {
                    converted[key] = json
                }
            }
            return .object(converted)
        default:
            return nil
        }
    }

    /// ISO-8601 wall clock timestamp for the `occurred_at` field on the
    /// telemetry calls. Constructed per-call rather than cached because
    /// these handlers fire on user interaction (tap / dismiss) — the
    /// formatter cost is negligible vs. the network round trip.
    static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - URL opener seam

/// Thin abstraction over `UIApplication.open(_:)`. Production uses
/// `UIApplicationURLOpener` on UIKit platforms; tests inject a
/// `MockURLOpener` to assert the URL without spawning a real Safari.
protocol PushURLOpener: Sendable {
    func open(_ url: URL) async
}

#if canImport(UIKit)
final class UIApplicationURLOpener: PushURLOpener, @unchecked Sendable {
    func open(_ url: URL) async {
        await MainActor.run {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
#else
final class NoopURLOpener: PushURLOpener, @unchecked Sendable {
    func open(_ url: URL) async {
        // No-op on non-UIKit platforms; the SDK does not ship there.
    }
}
#endif
