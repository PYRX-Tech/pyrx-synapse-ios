//
//  AppDelegate.swift
//  SwiftUIDemo
//
//  UIApplicationDelegate adapter that forwards push-related callbacks
//  into the Synapse SDK. SwiftUI App lifecycle does not surface these
//  callbacks natively — the recommended pattern (Apple HIG + Apple's own
//  `@UIApplicationDelegateAdaptor` propertyWrapper) is to keep a thin
//  AppDelegate for legacy delegate methods.
//

import UIKit
import UserNotifications
import PYRXSynapse

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Become the UN delegate so foreground / response callbacks land here.
        UNUserNotificationCenter.current().delegate = self

        // Cold-start attribution: if the app was launched via a push tap,
        // forward the payload to the SDK so it emits `$app_opened_from_push`.
        // Safe to call before `initialize(config:)` — the SDK buffers and
        // replays the payload after initialise lands.
        if let push = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Task { await Pyrx.shared.recordColdStartLaunch(userInfo: push) }
        } else {
            Task { await Pyrx.shared.recordColdStartLaunch(userInfo: nil) }
        }
        return true
    }

    // MARK: - APNs token / registration error

    /// Bridge `didRegisterForRemoteNotificationsWithDeviceToken` → SDK.
    /// The SDK converts the raw `Data` to canonical lowercase hex, persists
    /// it to Keychain, and POSTs `/v1/devices`.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            do {
                try await Pyrx.shared.handleDeviceToken(deviceToken)
            } catch {
                NSLog("PYRX handleDeviceToken failed: \(error.localizedDescription)")
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Pyrx.shared.handleRegistrationError(error)
    }

    // MARK: - Background push delivery

    /// Bridge background / silent pushes → SDK. The SDK fires
    /// `$push_received` telemetry and acks APNs with `.newData` / `.noData`.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Pyrx.shared.handleBackgroundNotification(userInfo: userInfo) { result in
            // Map the SDK's shim back to UIBackgroundFetchResult.
            switch result {
            case .newData:
                completionHandler(.newData)
            case .noData:
                completionHandler(.noData)
            case .failed:
                completionHandler(.failed)
            }
        }
    }

    // MARK: - Foreground presentation + tap response (UN delegate)

    /// Decide what to show while the app is in the foreground. The SDK's
    /// default is `[.banner, .sound, .badge]` — surfaces the notification
    /// even while the user is using the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Pyrx.shared.handleForegroundNotification(notification))
    }

    /// Tap / dismiss / custom-action handler. The SDK fires `/v1/push/opened`
    /// or `/v1/push/click` and routes deep links via `UIApplication.open`.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task {
            await Pyrx.shared.handleNotificationResponse(response, completion: completionHandler)
        }
    }
}
