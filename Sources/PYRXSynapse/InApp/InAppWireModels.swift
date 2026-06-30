//
//  InAppWireModels.swift
//  PYRXSynapse
//
//  Phase 10 PR-2b iOS — wire models for `/v1/in-app/poll` +
//  `/v1/in-app/log`. Mirrors `synapse-api/app/schemas/in_app.py`
//  (InAppPollResponse, InAppLogRequest, InAppLogResponse) verbatim.
//
//  Internal — the public surface is `InAppMessage` + the
//  `Synapse.InApp.*` namespace. These structs are the request /
//  response envelopes between the SDK and the backend; they never
//  leak to host apps.
//

import Foundation

/// Response body for `GET /v1/in-app/poll`. Mirrors
/// `InAppPollResponse` in `synapse-api/app/schemas/in_app.py`.
struct InAppPollResponse: Decodable, Sendable {
    let messages: [InAppMessage]
}

/// Request body for `POST /v1/in-app/log`. Mirrors `InAppLogRequest`
/// in `synapse-api/app/schemas/in_app.py`.
///
/// `event` is one of `"impressed"`, `"dismissed"`, `"interacted"`.
/// `ctaId` is REQUIRED by the backend when `event == "interacted"`
/// (server-side `model_validator`); the SDK enforces this client-side
/// in `InAppManager.markInteracted` to avoid the round-trip.
///
/// `deviceId` is reserved for forward-compat (the browser SDK does
/// not send it today). iOS leaves it `nil` for parity until a
/// later PR adds device-id wiring to the in-app log path.
struct InAppLogRequest: Encodable, Sendable, Equatable {
    let assignmentId: String
    let event: String
    let ctaId: String?
    let deviceId: String?

    init(
        assignmentId: String,
        event: String,
        ctaId: String? = nil,
        deviceId: String? = nil
    ) {
        self.assignmentId = assignmentId
        self.event = event
        self.ctaId = ctaId
        self.deviceId = deviceId
    }

    private enum CodingKeys: String, CodingKey {
        case assignmentId = "assignment_id"
        case event
        case ctaId = "cta_id"
        case deviceId = "device_id"
    }
}

/// Response body for `POST /v1/in-app/log`. Mirrors `InAppLogResponse`
/// in `synapse-api/app/schemas/in_app.py`.
///
/// The SDK honors `softDegraded` by doubling the polling interval
/// (lifecycle rule 8); `planLimitReached` is informational only — the
/// SDK still surfaces the message to the host callback (lifecycle
/// rule 9) and emits a warning log.
struct InAppLogResponse: Decodable, Sendable, Equatable {
    let logId: String
    let billable: Bool
    let planLimitReached: Bool
    let softDegraded: Bool

    private enum CodingKeys: String, CodingKey {
        case logId = "log_id"
        case billable
        case planLimitReached = "plan_limit_reached"
        case softDegraded = "soft_degraded"
    }
}
