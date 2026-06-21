//
//  PushPermission.swift
//  PYRXSynapse
//
//  Thin wrapper around `UNUserNotificationCenter.requestAuthorization` that
//  surfaces the result as a Swift `PushPermissionStatus` enum and triggers
//  APNs registration on `.authorized` / `.provisional` outcomes.
//
//  Why a wrapper?
//  ==============
//
//  1. The system API returns `(Bool, Error?)` which collapses the four
//     possible outcomes (authorized, denied, notDetermined, provisional)
//     into a binary signal — callers need finer-grained branching for
//     diagnostics ("the user pressed Don't Allow" vs. "we couldn't ask").
//
//  2. The bridge from "user said yes" → "OS hands us a device token" is
//     two-step: `requestAuthorization` then `registerForRemoteNotifications`.
//     The second call MUST be issued on the main thread (UIApplication is
//     `@MainActor`-isolated on iOS 14+). Bundling both inside this wrapper
//     means callers don't need to know that dance.
//
//  3. Testability — we accept an injectable `PushPermissionRequester` and
//     `PushRegistrar` so unit tests in `Tests/PYRXSynapseTests/PushPermissionTests`
//     can mock the OS and assert the wrapper's behaviour without hitting
//     real APNs.
//
//  Concurrency model
//  -----------------
//  `Pyrx.requestPushPermission(...)` is async and re-entrant — calls from
//  multiple Tasks serialise through the Pyrx actor. The OS-facing
//  registration call is dispatched to `MainActor` because
//  `UIApplication.shared.registerForRemoteNotifications()` is
//  `@MainActor`-isolated.
//
//  Platform walls
//  --------------
//  `UNUserNotificationCenter` is available on iOS / iPadOS / tvOS / watchOS /
//  macOS 10.14+ / visionOS — but the `registerForRemoteNotifications` call
//  lives on `UIApplication`, which is UIKit-only. We gate the registration
//  call on `#if canImport(UIKit)` so the SDK still builds on macOS-only SPM
//  consumers (and the Linux CI lane, though we don't ship there).
//

import Foundation
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public outcome enum

/// User-facing outcome of `Pyrx.requestPushPermission(options:)`. Mirrors
/// `UNAuthorizationStatus` so callers don't need to import
/// `UserNotifications` just to switch on the result.
public enum PushPermissionStatus: String, Sendable, Equatable {
    /// User granted the prompt. APNs registration has been triggered.
    case authorized

    /// User explicitly denied. SDK will NOT retry — re-prompting requires
    /// the user to flip the toggle in Settings → Notifications.
    case denied

    /// User has not yet been asked. `requestAuthorization` was not called
    /// (or returned without flipping the underlying status). Callers can
    /// re-invoke `requestPushPermission` to try again.
    case notDetermined

    /// iOS 12+ provisional / Quiet Notifications. The app may post
    /// notifications that appear in Notification Center without a prompt
    /// — the user must promote them to banners themselves. APNs
    /// registration IS triggered for this status.
    case provisional

    /// iOS 14+ ephemeral / App Clip. The clip has a limited authorization
    /// that expires when it terminates. APNs registration IS NOT useful
    /// here (clips can't receive remote pushes), but we surface the status
    /// for completeness.
    case ephemeral

    init(from authorization: UNAuthorizationStatus) {
        switch authorization {
        case .notDetermined: self = .notDetermined
        case .denied:        self = .denied
        case .authorized:    self = .authorized
        case .provisional:   self = .provisional
        case .ephemeral:     self = .ephemeral
        @unknown default:    self = .notDetermined
        }
    }
}

// MARK: - Internal seams (for testability)

/// Seam over `UNUserNotificationCenter.requestAuthorization` + `notificationSettings`.
/// Production conformance lives on `UNUserNotificationCenter` (extension below).
/// Tests inject a stub that returns canned authorization outcomes.
protocol PushPermissionRequester: Sendable {
    /// Mirrors `UNUserNotificationCenter.requestAuthorization(options:)`. Returns
    /// the `granted` bool and any error the system surfaced.
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool

    /// Mirrors `UNUserNotificationCenter.notificationSettings()`. We read the
    /// status after `requestAuthorization` to disambiguate `.provisional` /
    /// `.ephemeral` (both return `granted=true` from the request call).
    func currentAuthorizationStatus() async -> UNAuthorizationStatus
}

/// Seam over `UIApplication.shared.registerForRemoteNotifications()`. The
/// production conformance is `UIApplicationRegistrar` (below, UIKit-gated).
/// Tests inject `MockPushRegistrar` to assert the call happened without
/// touching APNs.
protocol PushRegistrar: Sendable {
    /// Called on `.authorized` / `.provisional` to ask the OS for an APNs
    /// device token. The token arrives asynchronously via the AppDelegate
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// callback (handled by `PushRegistration.handleDeviceToken`).
    func registerForRemoteNotifications() async
}

// MARK: - Production conformances

extension UNUserNotificationCenter: PushPermissionRequester {
    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await notificationSettings()
        return settings.authorizationStatus
    }
}

#if canImport(UIKit)
/// Thin shim that forwards `registerForRemoteNotifications` to UIApplication
/// on the main actor. UIApplication is `@MainActor`-isolated on iOS 14+ so
/// the call MUST hop to the main thread.
final class UIApplicationRegistrar: PushRegistrar, @unchecked Sendable {
    func registerForRemoteNotifications() async {
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
}
#else
/// Non-UIKit no-op (pure-macOS / Linux SPM builds). Logs and returns —
/// `registerForRemoteNotifications` doesn't exist outside UIKit, and there
/// is no useful fallback. APNs is iOS / iPadOS / tvOS / watchOS / visionOS
/// only; macOS uses a different code path that this SDK does not support.
final class NoopRegistrar: PushRegistrar, @unchecked Sendable {
    func registerForRemoteNotifications() async {
        // No-op. macOS push registration uses NSApplication and a different
        // entitlement model — out of scope for the iOS SDK.
    }
}
#endif

// MARK: - PushPermission

/// Internal façade that the `Pyrx` actor calls into for `requestPushPermission`.
/// Owns the requester + registrar seams and translates `UNAuthorizationStatus`
/// into the public `PushPermissionStatus`.
final class PushPermission: @unchecked Sendable {

    private let requester: PushPermissionRequester
    private let registrar: PushRegistrar
    private let logger: PyrxLogger

    init(
        requester: PushPermissionRequester = UNUserNotificationCenter.current(),
        registrar: PushRegistrar = PushPermission.defaultRegistrar(),
        logger: PyrxLogger = .shared
    ) {
        self.requester = requester
        self.registrar = registrar
        self.logger = logger
    }

    /// Resolve the production registrar based on what UIKit is available
    /// at compile time. Pulled out so we can keep `init` clean.
    static func defaultRegistrar() -> PushRegistrar {
        #if canImport(UIKit)
        return UIApplicationRegistrar()
        #else
        return NoopRegistrar()
        #endif
    }

    /// Ask the user for push permission. On `.authorized` / `.provisional`
    /// outcomes, also triggers APNs registration so the OS hands us a
    /// device token on the next `didRegisterForRemoteNotificationsWithDeviceToken`
    /// callback.
    ///
    /// - Parameter options: `UNAuthorizationOptions` mask. Defaults to
    ///   `[.alert, .sound, .badge]` — the standard set for transactional
    ///   apps. Apps that want provisional / quiet authorization should
    ///   pass `[.provisional, .alert, .sound, .badge]`.
    /// - Returns: A `PushPermissionStatus` reflecting the OS's final state.
    func request(options: UNAuthorizationOptions) async -> PushPermissionStatus {
        // Capture pre-request status so we can detect the "user previously
        // denied — system silently returns granted=false" case and surface
        // it as `.denied` (not `.notDetermined`).
        let before = await requester.currentAuthorizationStatus()
        if before == .denied {
            logger.info("requestPushPermission: pre-existing .denied — not re-prompting.")
            return .denied
        }

        let granted: Bool
        do {
            granted = try await requester.requestAuthorization(options: options)
        } catch {
            // `requestAuthorization` throws only when the system fails to
            // present the prompt (rare). Map to `.notDetermined` so the
            // caller can decide whether to retry.
            logger.warning("requestPushPermission: requestAuthorization threw — \(error)")
            return .notDetermined
        }

        // Re-read settings to disambiguate `.provisional` and `.ephemeral`
        // from `.authorized` — `requestAuthorization` returns `granted=true`
        // for all three.
        let after = await requester.currentAuthorizationStatus()
        let status = PushPermissionStatus(from: after)

        logger.info(
            "requestPushPermission: granted=\(granted) status=\(status.rawValue)"
        )

        // Trigger APNs registration on authorized / provisional. Ephemeral
        // (App Clips) cannot receive remote pushes — skip it.
        if status == .authorized || status == .provisional {
            await registrar.registerForRemoteNotifications()
            logger.debug("requestPushPermission: registerForRemoteNotifications dispatched.")
        }

        return status
    }
}
