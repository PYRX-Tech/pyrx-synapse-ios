# Push Notification Setup

End-to-end guide for wiring iOS push notifications through PYRX Synapse. You'll do this once per app, and then PYRX can deliver push from your dashboard, Flows, or the API.

There are five sides to push setup:

1. **Apple Developer Program** — enrollment and team membership.
2. **APNs Auth Key (.p8)** — token-based credential for PYRX to talk to APNs.
3. **PYRX dashboard** — upload the .p8 + Team ID + Key ID + Bundle ID.
4. **Xcode capability** — enable Push Notifications on your app target.
5. **AppDelegate adapter** — bridge UIKit callbacks into the SDK.

The first four are one-time provisioning. The fifth is code.

---

## 1. Apple Developer Program enrollment

You need an active [Apple Developer Program](https://developer.apple.com/programs/) membership (US$99/yr). Free Apple IDs cannot create production push capabilities.

If you're shipping a sandbox/test build only, the Personal Team that comes with any Apple ID will work for `aps-environment = development`, but you cannot send pushes to TestFlight or App Store builds without a paid membership.

---

## 2. Create an APNs Auth Key

PYRX uses **token-based authentication** (recommended over legacy certificates — one key covers all your apps, never expires, and rotates without breaking production).

1. Visit [developer.apple.com/account/resources/authkeys/list](https://developer.apple.com/account/resources/authkeys/list).
2. Click the **+** button next to **Keys**.
3. Name the key (e.g. `PYRX Synapse APNs`).
4. Check **Apple Push Notifications service (APNs)**.
5. Click **Continue** → **Register**.
6. Click **Download** to get the `.p8` file. **This is your only chance to download it** — save it somewhere safe.
7. Note the **Key ID** (10 characters, e.g. `ABC123XYZ4`) shown on the confirmation page.

You also need your **Team ID** (10 characters, e.g. `2A2B3C4D5E`):

- Visit [developer.apple.com/account](https://developer.apple.com/account).
- Look under **Membership** → **Team ID**.

And your app's **Bundle ID** (e.g. `com.example.myapp`):

- In Xcode: target → **General** → **Bundle Identifier**.

---

## 3. Upload credentials to PYRX

1. Sign in at [synapse-app.pyrx.tech](https://synapse-app.pyrx.tech).
2. Go to **Settings → Push credentials** (`/settings/push-credentials`).
3. Click **Add iOS credentials**.
4. Upload the `.p8` file, paste your **Team ID**, **Key ID**, and **Bundle ID**.
5. Choose the environment(s) this credential covers:
   - **Sandbox** — Debug builds and TestFlight internal testing.
   - **Production** — App Store and TestFlight external testing.
   - You can register the same credential for both.
6. Save.

PYRX validates the credential by signing a JWT and presenting it to APNs. If validation fails, you'll see the specific reason (invalid key, wrong Team ID, etc.).

> Full user-guide walkthrough with screenshots: [synapse.pyrx.tech/docs/user-guide/push-credentials](https://synapse.pyrx.tech/docs/user-guide/push-credentials).

---

## 4. Enable the Push Notifications capability in Xcode

1. Open your project in Xcode.
2. Select your app target → **Signing & Capabilities**.
3. Click **+ Capability** → **Push Notifications**.

This adds `com.apple.developer.aps-environment` to your entitlements file. Xcode picks the value automatically based on build configuration:
- Debug → `development` (uses APNs sandbox gateway).
- App Store / TestFlight → `production` (uses APNs production gateway).

If you also want silent / background pushes (recommended for `$push_received` telemetry):

5. Click **+ Capability** → **Background Modes**.
6. Check **Remote notifications**.

---

## 5. Wire the AppDelegate adapter

SwiftUI's `App` lifecycle does NOT surface the UIKit delegate methods that deliver the APNs device token. Use `@UIApplicationDelegateAdaptor` to attach a thin adapter:

```swift
// MyApp.swift
import SwiftUI
import PYRXSynapse

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Task {
            try? await Pyrx.shared.initialize(
                config: PyrxConfig(
                    workspaceId: UUID(uuidString: "<YOUR_WORKSPACE_UUID>")!,
                    apiKey: "psk_live_<YOUR_API_KEY>"
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
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
        // Become the UN delegate so foreground / response callbacks land here.
        UNUserNotificationCenter.current().delegate = self

        // Cold-start attribution: forward the launch options if the app was
        // opened by a push tap. Safe to call before SDK initialize().
        let push = launchOptions?[.remoteNotification] as? [AnyHashable: Any]
        Task { await Pyrx.shared.recordColdStartLaunch(userInfo: push) }
        return true
    }

    // MARK: - APNs registration

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

    // MARK: - Background / silent push

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

    // MARK: - Foreground presentation + tap

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

Once this is in place, call `await Pyrx.shared.requestPushPermission()` from your UI when it's time to prompt the user (after sign-in, after onboarding — NOT on first launch with no context).

---

## 6. Test a push from the PYRX dashboard

1. Run your app on a real device (push does not work in the Simulator for production environment; sandbox push works in Xcode 14+ Simulator on Apple Silicon Macs).
2. Tap through the permission prompt → allow notifications.
3. In Xcode's debug console, confirm a log line that mentions `Initialized PYRXSynapse v…` and that no `handleDeviceToken failed` errors appeared.
4. In your PYRX dashboard, go to **Contacts** → find the contact for the device's external ID (or anonymous ID).
5. Click **Send test push** → fill title + body → **Send**.
6. The push lands on your device within a couple of seconds.

You can also send via the API for scripted testing:

```bash
curl -X POST https://synapse-events.pyrx.tech/v1/push/test \
  -H "X-WORKSPACE-ID: <workspace-uuid>" \
  -H "X-API-KEY: psk_live_..." \
  -H "Content-Type: application/json" \
  -d '{
    "external_id": "user_123",
    "title": "Hello from PYRX",
    "body": "Test push from the API."
  }'
```

---

## Troubleshooting

### "No valid 'aps-environment' entitlement found"

- Confirm the Push Notifications capability is enabled on your target.
- Clean build folder (`Shift+Cmd+K`) and rebuild.
- Check that the active provisioning profile includes the Push Notifications capability — if you regenerated the profile in the Developer portal, re-download it in Xcode.

### Device token registers but pushes don't arrive

- Verify the credential is uploaded for the right environment (Debug builds use `development`, App Store/TestFlight use `production`).
- Verify the Bundle ID on the credential matches your app's Bundle ID exactly (case-sensitive).
- Check the PYRX dashboard's **Push delivery logs** for the specific failure (`InvalidProviderToken`, `BadDeviceToken`, `Unregistered`, etc.).

### `handleDeviceToken` throws `PyrxError.network(.httpStatus(401, …))`

- The API key is invalid, expired, or has the wrong scope. Recreate the key in the dashboard with the `data` scope.

### Cold-start attribution not firing

- Confirm `recordColdStartLaunch(userInfo:)` is called from `application(_:didFinishLaunchingWithOptions:)`.
- This event only fires when the app was COLD-launched by a push tap (not when the user opens the app manually, then a push arrives).

---

## What to read next

- [API Reference](API_REFERENCE.md) — full push API surface.
- [Quickstart](QUICKSTART.md) — five-minute end-to-end setup.
- [Sample app](../Examples/SwiftUIDemo) — runnable SwiftUI app with the full AppDelegate adapter and a PushView UI for live testing.
