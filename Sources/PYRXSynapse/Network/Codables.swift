//
//  Codables.swift
//  PYRXSynapse
//
//  Swift Codables that mirror the FastAPI Pydantic schemas in
//  `synapse-api/app/schemas/{device,identify,alias,event,push_telemetry}.py`
//  **byte-for-byte on the wire**. Android PR 2 will mirror these shapes
//  verbatim — any change here MUST be paired with an Android change.
//
//  Naming: Swift convention is camelCase; the backend uses snake_case. We
//  emit / accept snake_case on the wire via explicit `CodingKeys`. Public
//  Swift property names stay camelCase so call sites read naturally.
//
//  All response types are explicit `Decodable` (not `Codable`) — the SDK
//  never re-serialises a server response back onto the wire. All request
//  types are explicit `Encodable` for the same reason.
//
//  References:
//    - app/schemas/device.py       (DeviceRegister, DeviceResponse)
//    - app/schemas/identify.py     (IdentifyRequest, IdentifyResponse)
//    - app/schemas/alias.py        (AliasRequest, AliasResponse)
//    - app/schemas/event.py        (EventIngest, EventAccepted, ContactOverride)
//    - app/schemas/push_telemetry.py (PushOpenedRequest, PushClickedRequest,
//                                     PushTelemetryResponse)
//    - ARCHITECTURE.md §28.4 / §28.7 / §28.9
//

import Foundation

// MARK: - Shared

/// SDK-level environment selector. Wire shape matches the backend
/// `EnvLiteral = Literal["live", "test"]` exactly.
///
/// Distinct from `PyrxEnvironment` (which is the runtime SDK target —
/// `.production` / `.sandbox`). `WireEnvironment` is what we send in
/// JSON request bodies that accept an explicit `environment` field
/// (identify, alias, devices). Events derive their environment from the
/// API key prefix (`psk_live_…` / `psk_test_…`) on the server side, so
/// they do not carry an `environment` field.
public enum WireEnvironment: String, Codable, Sendable {
    case live
    case test
}

/// Discriminator returned by `/v1/identify` and `/v1/alias`. Mirrors the
/// backend `PathLiteral = Literal["known_exists", "first_sighting", "no_anonymous"]`.
public enum IdentifyPath: String, Codable, Sendable {
    case knownExists = "known_exists"
    case firstSighting = "first_sighting"
    case noAnonymous = "no_anonymous"
}

/// Status discriminator on push telemetry responses. Mirrors the backend
/// `PushTelemetryStatus = Literal["accepted", "ignored"]`.
public enum PushTelemetryStatus: String, Codable, Sendable {
    case accepted
    case ignored
}

// MARK: - /v1/identify

/// Body for `POST /v1/identify`. Mirrors `app/schemas/identify.py::IdentifyRequest`.
///
/// `traits` accepts arbitrary JSON values via `JSONValue` so callers can pass
/// any combination of `String`, `Bool`, `Int`, `Double`, `null`, nested
/// objects, and arrays — matching the backend's `dict[str, Any]`.
public struct IdentifyRequest: Encodable, Sendable, Equatable {
    public let anonymousId: String?
    public let externalId: String
    public let traits: [String: JSONValue]?
    public let environment: WireEnvironment

    enum CodingKeys: String, CodingKey {
        case anonymousId = "anonymous_id"
        case externalId = "external_id"
        case traits
        case environment
    }

    public init(
        anonymousId: String?,
        externalId: String,
        traits: [String: JSONValue]? = nil,
        environment: WireEnvironment = .live
    ) {
        self.anonymousId = anonymousId
        self.externalId = externalId
        self.traits = traits
        self.environment = environment
    }
}

/// Response from `POST /v1/identify`. Mirrors `IdentifyResponse`.
public struct IdentifyResponse: Decodable, Sendable, Equatable {
    public let contactId: UUID
    public let path: IdentifyPath
    public let aliasedExternalId: String?
    public let eventsReattributed: Int
    public let devicesReattributed: Int
    public let anonymousContactTombstoned: Bool

    enum CodingKeys: String, CodingKey {
        case contactId = "contact_id"
        case path
        case aliasedExternalId = "aliased_external_id"
        case eventsReattributed = "events_reattributed"
        case devicesReattributed = "devices_reattributed"
        case anonymousContactTombstoned = "anonymous_contact_tombstoned"
    }
}

// MARK: - /v1/alias

/// Body for `POST /v1/alias`. Mirrors `app/schemas/alias.py::AliasRequest`.
///
/// Both ids are required by the backend (no Optional on either) — if the
/// caller doesn't know the anonymousId, they should use `/v1/identify`.
public struct AliasRequest: Encodable, Sendable, Equatable {
    public let anonymousId: String
    public let externalId: String
    public let environment: WireEnvironment

    enum CodingKeys: String, CodingKey {
        case anonymousId = "anonymous_id"
        case externalId = "external_id"
        case environment
    }

    public init(
        anonymousId: String,
        externalId: String,
        environment: WireEnvironment = .live
    ) {
        self.anonymousId = anonymousId
        self.externalId = externalId
        self.environment = environment
    }
}

/// Response from `POST /v1/alias`. Wire shape is identical to
/// `IdentifyResponse` (deliberately so the SDK can share the decoder).
public typealias AliasResponse = IdentifyResponse

// MARK: - /v1/devices

/// Body for `POST /v1/devices`. Mirrors `app/schemas/device.py::DeviceRegister`.
///
/// `platform` is wire-`String` (one of `"ios"`, `"android"`, `"web"`, `"huawei"`)
/// rather than a Swift `enum` so adding a platform on the server does not
/// require a forced SDK upgrade. The iOS SDK only ever sends `"ios"`.
public struct DeviceRegisterRequest: Encodable, Sendable, Equatable {
    public let externalId: String
    public let platform: String
    public let pushToken: String
    public let bundleId: String?
    public let appVersion: String?
    public let sdkVersion: String?
    public let sdkPlatform: String?
    public let osVersion: String?
    public let deviceModel: String?
    public let locale: String?
    public let timezone: String?
    public let environment: WireEnvironment
    public let pushEnabled: Bool
    public let metadata: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case platform
        case pushToken = "push_token"
        case bundleId = "bundle_id"
        case appVersion = "app_version"
        case sdkVersion = "sdk_version"
        case sdkPlatform = "sdk_platform"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case locale
        case timezone
        case environment
        case pushEnabled = "push_enabled"
        case metadata
    }

    public init(
        externalId: String,
        platform: String,
        pushToken: String,
        bundleId: String? = nil,
        appVersion: String? = nil,
        sdkVersion: String? = nil,
        sdkPlatform: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        environment: WireEnvironment = .live,
        pushEnabled: Bool = true,
        metadata: [String: JSONValue] = [:]
    ) {
        self.externalId = externalId
        self.platform = platform
        self.pushToken = pushToken
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.sdkVersion = sdkVersion
        self.sdkPlatform = sdkPlatform
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.locale = locale
        self.timezone = timezone
        self.environment = environment
        self.pushEnabled = pushEnabled
        self.metadata = metadata
    }
}

/// Response from `POST /v1/devices`. Mirrors `DeviceResponse`.
///
/// Phase-8.4a-PR-2 only requires this for the `register` call — full push
/// registration lives in PR 4. We decode every field returned today so the
/// shape can be inspected from a debug menu without another schema round-trip.
public struct DeviceResponse: Decodable, Sendable, Equatable {
    public let id: UUID
    public let contactId: UUID
    public let platform: String
    public let pushToken: String
    public let bundleId: String?
    public let appVersion: String?
    public let sdkVersion: String?
    public let sdkPlatform: String?
    public let osVersion: String?
    public let deviceModel: String?
    public let locale: String?
    public let timezone: String?
    public let environment: String
    public let pushEnabled: Bool
    public let lastSeenAt: String
    public let registeredAt: String
    public let revokedAt: String?
    public let metadata: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case contactId = "contact_id"
        case platform
        case pushToken = "push_token"
        case bundleId = "bundle_id"
        case appVersion = "app_version"
        case sdkVersion = "sdk_version"
        case sdkPlatform = "sdk_platform"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case locale
        case timezone
        case environment
        case pushEnabled = "push_enabled"
        case lastSeenAt = "last_seen_at"
        case registeredAt = "registered_at"
        case revokedAt = "revoked_at"
        case metadata
    }
}

// MARK: - /v1/events

/// Contact fields embeddable into an event upsert. Mirrors
/// `app/schemas/contact.py::ContactOverride`. Optional everywhere — only
/// non-nil fields are applied by the server.
public struct ContactOverride: Encodable, Sendable, Equatable {
    public let email: String?
    public let phone: String?
    public let firstName: String?
    public let lastName: String?
    public let timezone: String?
    public let locale: String?
    public let properties: [String: JSONValue]?
    public let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case email
        case phone
        case firstName = "first_name"
        case lastName = "last_name"
        case timezone
        case locale
        case properties
        case tags
    }

    public init(
        email: String? = nil,
        phone: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        timezone: String? = nil,
        locale: String? = nil,
        properties: [String: JSONValue]? = nil,
        tags: [String]? = nil
    ) {
        self.email = email
        self.phone = phone
        self.firstName = firstName
        self.lastName = lastName
        self.timezone = timezone
        self.locale = locale
        self.properties = properties
        self.tags = tags
    }
}

/// Body for `POST /v1/events`. Mirrors `app/schemas/event.py::EventIngest`.
///
/// We deliberately only emit the **preferred** field names (`external_id`,
/// `contact`) and never the deprecated `user_id` / `contact_overrides`
/// aliases — new SDKs do not need to carry the legacy hump.
///
/// `environment` is NOT a field here — the server derives it from the API
/// key prefix (`psk_live_` / `psk_test_`). See `app/auth/api_key.py`.
public struct EventIngestRequest: Encodable, Sendable, Equatable {
    public let externalId: String
    public let eventName: String
    public let attributes: [String: JSONValue]
    public let idempotencyKey: String?
    public let contact: ContactOverride?
    public let occurredAt: String?

    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case eventName = "event_name"
        case attributes
        case idempotencyKey = "idempotency_key"
        case contact
        case occurredAt = "occurred_at"
    }

    public init(
        externalId: String,
        eventName: String,
        attributes: [String: JSONValue] = [:],
        idempotencyKey: String? = nil,
        contact: ContactOverride? = nil,
        occurredAt: String? = nil
    ) {
        self.externalId = externalId
        self.eventName = eventName
        self.attributes = attributes
        self.idempotencyKey = idempotencyKey
        self.contact = contact
        self.occurredAt = occurredAt
    }
}

/// Response from `POST /v1/events`. Mirrors `EventAccepted`.
public struct EventAcceptedResponse: Decodable, Sendable, Equatable {
    public let eventId: UUID
    public let status: String

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case status
    }
}

// MARK: - /v1/push/opened + /v1/push/click

/// Body for `POST /v1/push/opened`. Mirrors `PushOpenedRequest`.
public struct PushOpenedRequest: Encodable, Sendable, Equatable {
    public let pushLogId: UUID
    public let occurredAt: String?

    enum CodingKeys: String, CodingKey {
        case pushLogId = "push_log_id"
        case occurredAt = "occurred_at"
    }

    public init(pushLogId: UUID, occurredAt: String? = nil) {
        self.pushLogId = pushLogId
        self.occurredAt = occurredAt
    }
}

/// Body for `POST /v1/push/click`. Mirrors `PushClickedRequest`.
public struct PushClickedRequest: Encodable, Sendable, Equatable {
    public let pushLogId: UUID
    public let occurredAt: String?
    public let clickUrl: String?

    enum CodingKeys: String, CodingKey {
        case pushLogId = "push_log_id"
        case occurredAt = "occurred_at"
        case clickUrl = "click_url"
    }

    public init(pushLogId: UUID, occurredAt: String? = nil, clickUrl: String? = nil) {
        self.pushLogId = pushLogId
        self.occurredAt = occurredAt
        self.clickUrl = clickUrl
    }
}

/// Response from both push telemetry endpoints. Mirrors `PushTelemetryResponse`.
public struct PushTelemetryResponse: Decodable, Sendable, Equatable {
    public let status: PushTelemetryStatus
    public let envelopeId: UUID?
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case status
        case envelopeId = "envelope_id"
        case reason
    }
}

// MARK: - JSONValue

/// A type-erased JSON value the SDK can ferry into / out of `dict[str, Any]`
/// fields on the backend (event `attributes`, identify `traits`, device
/// `metadata`, contact `properties`).
///
/// Mirrors what the browser SDK puts on the wire — we keep the same union
/// (null / bool / number / string / array / object) so Android can adopt
/// the same shape in its own port.
///
/// Trade-off: this is verbose at the call site compared to `Any`, but `Any`
/// is not `Sendable` and cannot cross actor boundaries — we'd lose Swift
/// 6 concurrency guarantees throughout the SDK. The verbosity is the price
/// of correctness here.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONValue: not one of null/bool/number/string/array/object"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
