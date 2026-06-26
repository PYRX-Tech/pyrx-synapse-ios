//
//  PyrxConstants.swift
//  PYRXSynapse
//
//  Compile-time constants embedded into the SDK. Updated on release (PR 7
//  will wire a release script that bumps `sdkVersion` and the podspec
//  version together).
//

import Foundation

public enum PyrxConstants {
    /// SDK semantic version. Sent on `X-PYRX-SDK-VERSION` (header wired in PR 2).
    public static let sdkVersion: String = "0.1.1"

    /// Platform identifier. Sent on `X-PYRX-SDK-PLATFORM` (header wired in PR 2).
    /// Always `"ios"` regardless of underlying device class (iPad/iPhone/etc.).
    public static let platform: String = "ios"
}
