//
//  DeviceMetadata.swift
//  PYRXSynapse
//
//  Helpers that snapshot the host device's identifying metadata for the
//  `POST /v1/devices` payload (Phase 8.4a Task 8.4a.7).
//
//  Why these values, in this shape?
//  ================================
//
//  The backend `DeviceRegister` schema (synapse-api/app/schemas/device.py)
//  accepts these fields verbatim — we mirror them on the Swift side via
//  `DeviceRegisterRequest`. Concretely we capture:
//
//    - bundle_id     : Bundle.main.bundleIdentifier ?? "unknown"
//    - app_version   : CFBundleShortVersionString ?? "unknown"
//    - sdk_version   : PyrxConstants.sdkVersion (compile-time)
//    - sdk_platform  : PyrxConstants.platform   (always "ios")
//    - os_version    : "iOS 17.4.1" / "iPadOS 17.4.1" / "tvOS 17.0" / "macOS 14.4"
//    - device_model  : utsname.machine — "iPhone15,3" / "iPad13,1" /
//                      "arm64" on simulator builds
//    - locale        : Locale.current.identifier ("en_US" etc.)
//    - timezone      : TimeZone.current.identifier ("America/Los_Angeles")
//
//  Why the `#if canImport(UIKit)` walls?
//  -------------------------------------
//  Swift Package Manager builds on Linux (and some CI macOS-only checks)
//  do NOT have `UIKit`. We let those builds resolve by collapsing the
//  UIKit-derived values to "unknown" / "macOS …" so the SDK still compiles
//  cleanly. iOS / iPadOS / tvOS / watchOS Simulator + Device builds (where
//  the SDK actually ships) use the real UIDevice / UIApplication values.
//
//  Tests
//  -----
//  All helpers are pure — `deviceModel()` reads `utsname` directly, no
//  injection seam needed. Tests assert the shape is well-formed (non-empty,
//  matches a reasonable format) rather than pinning a literal value, so the
//  test stays green across simulator OS bumps.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Snapshot of identifying device metadata for `/v1/devices` registration.
/// All fields are optional in the wire schema; we fill what we can and
/// surface the request-builder with sensible defaults for the rest.
enum DeviceMetadata {

    /// Bundle identifier of the host app, e.g. `"tech.pyrx.crm.ios"`.
    /// Falls back to `"unknown"` if the runtime cannot resolve one — which
    /// only happens for some Swift Package Manager test targets running
    /// without a host application.
    static func bundleId() -> String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    /// Marketing version of the host app, e.g. `"2.4.1"`. Falls back to
    /// `"unknown"` if `CFBundleShortVersionString` is not set (some unit
    /// test bundles).
    static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        return "unknown"
    }

    /// SDK semantic version — compile-time constant from `PyrxConstants`.
    static func sdkVersion() -> String {
        PyrxConstants.sdkVersion
    }

    /// SDK platform identifier — always `"ios"`. Phase-9 Android port mirrors
    /// the same field as `"android"` on its `DeviceRegisterRequest`.
    static func sdkPlatform() -> String {
        PyrxConstants.platform
    }

    /// SDK platform identifier with an optional wrapper-variant suffix —
    /// e.g. `"ios"` (no variant) or `"ios+rn"` (React Native wrapper).
    ///
    /// The suffix is **telemetry-only**: the backend's push dispatcher
    /// routes on `Device.platform` (`"ios"` / `"android"`), not on
    /// `sdk_platform`, so a variant value can never break delivery.
    /// Wrappers pass their identifier via `PyrxConfig.sdkVariant`; the
    /// `PushRegistration` initializer threads that value through to this
    /// helper.
    static func sdkPlatform(variant: String?) -> String {
        let base = PyrxConstants.platform
        guard let variant = variant?.trimmingCharacters(in: .whitespacesAndNewlines),
              !variant.isEmpty
        else {
            return base
        }
        return "\(base)+\(variant)"
    }

    /// Human-readable OS string, e.g. `"iOS 17.4.1"` or `"iPadOS 17.4.1"`.
    ///
    /// We deliberately prepend the platform name (iOS / iPadOS / tvOS / etc.)
    /// rather than sending the bare version number — the dashboard's Device
    /// Explorer (Phase 8 §8.3.7) groups by this string and the prefix makes
    /// the column readable without joining against `platform`.
    static func osVersion() -> String {
        #if canImport(UIKit)
        let device = UIDevice.current
        // `systemName` is "iOS" on iPhone, "iPadOS" on iPad (iOS 13+), "tvOS"
        // on Apple TV, "watchOS" on Apple Watch, "visionOS" on Vision Pro.
        return "\(device.systemName) \(device.systemVersion)"
        #else
        // SPM build on macOS (CI lint, library consumers that pull the SDK
        // into a macOS target). Surfaces something readable rather than a
        // raw kernel version.
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersion
        return "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        #endif
    }

    /// Hardware identifier from `uname(2)` — e.g. `"iPhone15,3"`, `"iPad13,1"`,
    /// `"arm64"` on a simulator. The dashboard Device Explorer maps these
    /// against a server-side lookup table to render `"iPhone 15 Pro Max"`,
    /// so the SDK does NOT do that translation itself.
    ///
    /// Uses `utsname` directly — works on every Apple platform without
    /// requiring UIKit. The byte-walking dance is the canonical idiom on
    /// Apple platforms; `Swift.String(cString:)` plus a `withUnsafePointer`
    /// to the `utsname.machine` tuple gives us the C string back.
    static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        // `utsname.machine` is a `(Int8, Int8, …)` tuple. Reflect over it
        // to assemble the C string, then stop at the first NUL terminator.
        // This is the same pattern Apple's own sample code uses.
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    /// Current user locale identifier, e.g. `"en_US"`, `"fr_FR"`, `"ja_JP"`.
    static func locale() -> String {
        Locale.current.identifier
    }

    /// Current device timezone identifier, e.g. `"America/Los_Angeles"`,
    /// `"Asia/Tokyo"`, `"UTC"`.
    static func timezone() -> String {
        TimeZone.current.identifier
    }
}
