//
//  InAppMessage.swift
//  PYRXSynapse
//
//  Phase 10 PR-2b iOS — In-App Messaging public types.
//
//  Mirrors the browser SDK's `InAppMessage` / `InAppCta` shapes
//  (`packages/sdk/src/types.ts:159` / `:193`) and the backend
//  `InAppMessageSdkPayload` / `InAppCtaRendered` schemas
//  (`synapse-api/app/schemas/in_app.py`).
//
//  Wire shape is snake_case to match the backend response with no
//  client-side transforms; native Swift idiom is camelCase, so each
//  struct carries a `CodingKeys` to translate.
//
//  The host app NEVER receives a raw JSON dict — these typed structs
//  are the surface, per ADR-0008 D2 (rendering-callback contract) +
//  ADR-0009 D5 (cross-SDK symmetric shape).
//
//  No UI here. No SwiftUI / UIKit imports. The host app draws.
//

import Foundation

/// How the host app should handle a CTA tap.
///
/// Mirror of the browser SDK's `InAppCtaActionType` union
/// (`packages/sdk/src/types.ts:143`). Cross-SDK symmetric per
/// ADR-0009 D5.
public enum InAppCtaActionType: String, Codable, Sendable, Equatable {
    /// Open the URL via `UIApplication.open` (or host app deep-link
    /// router). `actionPayload` carries the URL.
    case deepLink = "deep_link"
    /// Treat as a dismissal — the host app should call
    /// `Synapse.InApp.dismiss(messageId:reason:)` (commonly with
    /// `reason: "cta_dismissed"`). `actionPayload` is typically nil.
    case dismiss
    /// Open the URL inside an in-app webview (e.g. `SFSafariViewController`
    /// or a custom `WKWebView`). `actionPayload` carries the URL.
    case webview
    /// Opaque callback — the host app interprets the `actionPayload`
    /// per its own routing convention. The SDK does not parse it.
    case callback
}

/// A rendered CTA delivered to the SDK.
///
/// NLT source has already been resolved against the current contact
/// at fetch time — `label` and `actionPayload` are ready to render
/// verbatim. Cross-SDK symmetric per ADR-0009 D5.
public struct InAppCta: Codable, Sendable, Equatable {
    /// Stable identifier passed back via `markInteracted` on tap.
    public let id: String

    /// NLT-rendered label text.
    public let label: String

    /// How the host app should handle the tap.
    public let actionType: InAppCtaActionType

    /// NLT-rendered action payload. URL string for `deepLink` / `webview`;
    /// opaque string for `callback`; `nil` for `dismiss`.
    public let actionPayload: String?

    public init(
        id: String,
        label: String,
        actionType: InAppCtaActionType,
        actionPayload: String? = nil
    ) {
        self.id = id
        self.label = label
        self.actionType = actionType
        self.actionPayload = actionPayload
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case actionType = "action_type"
        case actionPayload = "action_payload"
    }
}

/// The "InAppMessage struct" delivered to the host app's render
/// callback per ADR-0008 D2 (rendering-callback contract) +
/// ADR-0009 D5 (cross-SDK symmetric shape).
///
/// **The SDK does NOT render this message.** It hands the typed
/// struct to the host app's callback (registered via
/// `Synapse.InApp.show(placement:callback:)`); the host app draws
/// the UI in whatever style fits its design system. The SDK owns:
/// fetch, lifecycle, dismissal / impression telemetry, expiry. The
/// SDK does NOT own: pixels, animation, layout, accessibility.
/// PYRX UI Kit is deferred to Phase 10.x.
public struct InAppMessage: Codable, Sendable, Equatable {
    /// Server-issued assignment id. Pass back via `markInteracted`
    /// / `dismiss`. Stable across re-renders of the SAME assignment;
    /// different from `messageId` because the same `InAppMessage`
    /// template can be assigned multiple times (frequency caps).
    public let id: String

    /// The `in_app_messages.id` — stable across assignments. Use for
    /// host-side dedupe when the same template can be re-assigned.
    public let messageId: String

    /// Placement key the host app maps to a UI surface
    /// (e.g. `"home_banner"`, `"settings_modal"`).
    public let placement: String

    /// NLT-rendered title.
    public let title: String

    /// NLT-rendered body.
    public let body: String

    /// NLT-rendered image URL, or `nil`.
    public let imageUrl: String?

    /// 0–2 CTAs (Phase 10 v1 scope).
    public let ctas: [InAppCta]

    /// Host-app-driven custom JSON. Never NLT-rendered server-side;
    /// the host app uses these fields for custom analytics tags,
    /// structured product lists for host-rendered carousels, etc.
    /// `nil` when the backend sends an empty `custom` object — both
    /// `nil` and `[:]` are wire-equivalent here.
    public let customData: [String: JSONValue]?

    /// ISO-8601 expiry instant. Surfaced as `Date?` for ergonomics;
    /// the wire field is a JSON string. `nil` for no expiry.
    public let expiresAt: Date?

    /// Host-app sort / queue priority. Higher = more important.
    public let priority: Int

    public init(
        id: String,
        messageId: String,
        placement: String,
        title: String,
        body: String,
        imageUrl: String? = nil,
        ctas: [InAppCta] = [],
        customData: [String: JSONValue]? = nil,
        expiresAt: Date? = nil,
        priority: Int = 0
    ) {
        self.id = id
        self.messageId = messageId
        self.placement = placement
        self.title = title
        self.body = body
        self.imageUrl = imageUrl
        self.ctas = ctas
        self.customData = customData
        self.expiresAt = expiresAt
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case messageId = "message_id"
        case placement = "placement_key"
        case title
        case body
        case imageUrl = "image_url"
        case ctas
        case customData = "custom"
        case expiresAt = "expires_at"
        case priority
    }

    /// Custom decoder so `expiresAt` parses from the ISO-8601 wire
    /// string while keeping `Date?` ergonomics on the Swift side.
    /// The browser SDK leaves it as a string for symmetry across
    /// JS/TS consumers, but Swift callers expect a real `Date`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.messageId = try container.decode(String.self, forKey: .messageId)
        self.placement = try container.decode(String.self, forKey: .placement)
        self.title = try container.decode(String.self, forKey: .title)
        self.body = try container.decode(String.self, forKey: .body)
        self.imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        self.ctas = (try container.decodeIfPresent([InAppCta].self, forKey: .ctas)) ?? []
        self.customData = try container.decodeIfPresent([String: JSONValue].self, forKey: .customData)
        if let isoString = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            self.expiresAt = Self.iso8601.date(from: isoString)
                ?? Self.iso8601Fallback.date(from: isoString)
        } else {
            self.expiresAt = nil
        }
        self.priority = (try container.decodeIfPresent(Int.self, forKey: .priority)) ?? 0
    }

    /// Symmetric encoder so a `InAppMessage` round-trips losslessly
    /// through the SDK (used by the offline log queue + observer
    /// replay buffer).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(placement, forKey: .placement)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try container.encode(ctas, forKey: .ctas)
        try container.encodeIfPresent(customData, forKey: .customData)
        if let expiresAt = expiresAt {
            try container.encode(Self.iso8601.string(from: expiresAt), forKey: .expiresAt)
        }
        try container.encode(priority, forKey: .priority)
    }

    /// Primary ISO-8601 parser — fractional-seconds + Z timezone is
    /// the backend's `datetime.isoformat()` default for UTC.
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Fallback parser for payloads without fractional seconds (some
    /// orchestration paths drop them on serialise).
    private static let iso8601Fallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
