# Quickstart

Get the PYRX Synapse iOS SDK installed, initialised, identifying users, tracking events, and registered for push notifications in roughly five minutes.

This guide assumes a SwiftUI app on iOS 14+. UIKit-only apps follow the same shape — initialise from `application(_:didFinishLaunchingWithOptions:)` instead of `App.init`.

---

## 1. Get your workspace credentials

You'll need two values from your PYRX dashboard:

- **Workspace ID** — a UUID v4. Visible at `synapse-app.pyrx.tech/settings/workspace`.
- **API key** — formatted `psk_live_…` (production) or `psk_test_…` (sandbox). Create one at `synapse-app.pyrx.tech/settings/api-keys` with the `data` scope (sufficient for events + identity + push registration).

> **Never ship a key with the `management` or `full` scope in your iOS app.** Those scopes can read PII and rotate other keys. The SDK only needs `data`.

---

## 2. Add the SDK via Swift Package Manager

In Xcode:

1. **File → Add Package Dependencies…**
2. Paste: `https://github.com/PYRX-Tech/pyrx-synapse-ios.git`
3. Choose **Up to Next Major Version** from `1.0.0`.
4. Add `PYRXSynapse` to your app target.

CocoaPods alternative:

```ruby
# Podfile
target 'YourApp' do
  use_frameworks!
  pod 'PYRXSynapse', '~> 1.0'
end
```

```bash
pod install
```

---

## 3. Initialise the SDK

Call `Pyrx.shared.initialize(config:)` as early as possible in your app lifecycle — typically from your `@main App.init()`.

```swift
import SwiftUI
import PYRXSynapse

@main
struct MyApp: App {
    init() {
        Task {
            do {
                try await Pyrx.shared.initialize(
                    config: PyrxConfig(
                        workspaceId: UUID(uuidString: "<YOUR_WORKSPACE_UUID>")!,
                        apiKey: "psk_live_<YOUR_API_KEY>",
                        environment: .production,
                        logLevel: .info
                    )
                )
            } catch {
                // Log + continue. Subsequent SDK calls will throw `.notInitialized`
                // until you call `initialize` successfully.
                NSLog("PYRX initialize failed: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

The SDK generates and persists an anonymous ID on first launch, so events flow even before you call `identify`.

> Calling `initialize` a second time with the same config is a no-op. Calling with a **different** config throws `PyrxError.alreadyInitialized` — pick one config per launch.

---

## 4. Identify users

Once you know who the user is (after sign-in, on app launch if you have a session, etc.), call `identify`:

```swift
try await Pyrx.shared.identify(
    externalId: "user_123",
    traits: [
        "email": .string("jane@example.com"),
        "first_name": .string("Jane"),
        "plan": .string("pro")
    ]
)
```

The SDK:

1. Resolves the anonymous ID created at `initialize` time.
2. POSTs `/v1/identify` so the server merges the anonymous contact into the known contact and re-attributes past events + device rows.
3. Persists the `externalId` to the Keychain. All future events and push registrations use it automatically.

On sign-out, call `logout` to clear the local externalId. The anonymous ID and APNs device token are preserved so the next `identify` can re-attribute cleanly:

```swift
try await Pyrx.shared.logout()
```

---

## 5. Track events

```swift
try await Pyrx.shared.track(
    eventName: "order_placed",
    properties: [
        "order_id": .string("ord_abc123"),
        "total": .number(49.99),
        "currency": .string("USD"),
        "items": .number(3)
    ]
)
```

Track returns once the event is durably on disk. The SDK drains the queue in the background with exponential-backoff retry. You don't need to await delivery.

For screen views, use `screen` — it sets `event_name = "$screen"` and stamps `attributes.screen_name = screenName`:

```swift
try await Pyrx.shared.screen(screenName: "product_detail", properties: [
    "product_id": .string("prod_42")
])
```

---

## 6. Request push notification permission

```swift
let status = await Pyrx.shared.requestPushPermission()

switch status {
case .authorized, .provisional:
    // OS will call your AppDelegate's
    // `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` next.
    print("Push enabled")
case .denied:
    print("User declined — show in-app explainer or skip")
case .notDetermined, .ephemeral:
    print("Try again later")
}
```

Pre-prompt with rationale BEFORE calling `requestPushPermission` whenever possible — once denied, the user must visit Settings to re-enable push.

---

## 7. Handle the APNs device token

SwiftUI's `App` lifecycle does not surface `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Use `@UIApplicationDelegateAdaptor`:

```swift
// SwiftUIDemoApp.swift
@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() { /* …initialize SDK as in step 3… */ }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

```swift
// AppDelegate.swift
import UIKit
import UserNotifications
import PYRXSynapse

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Cold-start attribution: if the app was launched by a push tap.
        let push = launchOptions?[.remoteNotification] as? [AnyHashable: Any]
        Task { await Pyrx.shared.recordColdStartLaunch(userInfo: push) }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            do { try await Pyrx.shared.handleDeviceToken(deviceToken) }
            catch { NSLog("PYRX handleDeviceToken failed: \(error.localizedDescription)") }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Pyrx.shared.handleRegistrationError(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Pyrx.shared.handleBackgroundNotification(userInfo: userInfo) { result in
            switch result {
            case .newData: completionHandler(.newData)
            case .noData:  completionHandler(.noData)
            case .failed:  completionHandler(.failed)
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Pyrx.shared.handleForegroundNotification(notification))
    }

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
```

---

## 8. Enable the Push Notifications capability

In Xcode, open your target → **Signing & Capabilities** → **+ Capability** → **Push Notifications**.

This adds `com.apple.developer.aps-environment` to your entitlements (`development` in Debug, `production` in App Store / TestFlight builds).

---

## 9. Provision APNs with PYRX

Push delivery requires PYRX to talk to APNs on your behalf. Follow [docs/PUSH_SETUP.md](PUSH_SETUP.md) to:

1. Create an APNs Auth Key (.p8) in the Apple Developer portal.
2. Upload the .p8, Team ID, Key ID, and Bundle ID to your PYRX workspace at `synapse-app.pyrx.tech/settings/push-credentials`.
3. Send a test push from the dashboard and confirm it lands on a real device.

---

## You're done

Verify everything is working:

- Open the **Network** tab in the Xcode debugger and confirm `POST /v1/events`, `POST /v1/identify`, and `POST /v1/devices` requests return 2xx.
- Visit your PYRX dashboard → **Contacts** → search for your external ID → confirm events appear in the activity timeline.
- Trigger a test push from your PYRX dashboard and confirm it lands on your device.

For diagnostics, call `await Pyrx.shared.debugInfo()` and surface the result in a debug menu (the SwiftUI sample app has a ready-to-copy implementation in `Examples/SwiftUIDemo/SwiftUIDemo/DebugInfoView.swift`).

---

## Where to go next

- [API Reference](API_REFERENCE.md) — every public type and method.
- [Push Setup](PUSH_SETUP.md) — full APNs + PYRX provisioning walkthrough.
- [Sample app](../Examples/SwiftUIDemo) — every SDK surface in a runnable SwiftUI project.
