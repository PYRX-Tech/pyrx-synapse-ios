//
//  InAppMessageCodableTests.swift
//  PYRXSynapseTests
//
//  Phase 10 PR-2b iOS — wire-shape round-trip coverage for the
//  in-app messaging types. The browser SDK uses snake_case verbatim;
//  the iOS SDK exposes camelCase Swift idiomatic field names and
//  bridges via `CodingKeys`. These tests pin the wire ⇄ Swift
//  translation so a future field rename can't silently break
//  cross-SDK symmetry.
//
//  Authority: `synapse-api/app/schemas/in_app.py` (backend wire
//  shape) + `packages/sdk/src/types.ts` (browser SDK reference).
//

import XCTest
@testable import PYRXSynapse

final class InAppMessageCodableTests: XCTestCase {

    // MARK: - InAppMessage

    func test_decode_inAppMessage_fromBackendWireShape() throws {
        let json = """
        {
          "id": "a1111111-1111-1111-1111-111111111111",
          "message_id": "b2222222-2222-2222-2222-222222222222",
          "placement_key": "home_banner",
          "title": "Welcome back, Alex",
          "body": "Your cart is waiting",
          "image_url": "https://cdn.example.com/banner.png",
          "ctas": [
            {
              "id": "cta_view",
              "label": "View cart",
              "action_type": "deep_link",
              "action_payload": "myapp://cart"
            },
            {
              "id": "cta_dismiss",
              "label": "Not now",
              "action_type": "dismiss",
              "action_payload": null
            }
          ],
          "custom": {"campaign_id": "abandoned_cart_2026", "score": 7},
          "expires_at": "2026-07-01T12:00:00.000Z",
          "priority": 10
        }
        """
        let message = try JSONDecoder().decode(InAppMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.id, "a1111111-1111-1111-1111-111111111111")
        XCTAssertEqual(message.messageId, "b2222222-2222-2222-2222-222222222222")
        XCTAssertEqual(message.placement, "home_banner")
        XCTAssertEqual(message.title, "Welcome back, Alex")
        XCTAssertEqual(message.body, "Your cart is waiting")
        XCTAssertEqual(message.imageUrl, "https://cdn.example.com/banner.png")
        XCTAssertEqual(message.priority, 10)
        XCTAssertNotNil(message.expiresAt)

        XCTAssertEqual(message.ctas.count, 2)
        XCTAssertEqual(message.ctas[0].id, "cta_view")
        XCTAssertEqual(message.ctas[0].label, "View cart")
        XCTAssertEqual(message.ctas[0].actionType, .deepLink)
        XCTAssertEqual(message.ctas[0].actionPayload, "myapp://cart")
        XCTAssertEqual(message.ctas[1].actionType, .dismiss)
        XCTAssertNil(message.ctas[1].actionPayload)

        XCTAssertEqual(message.customData?["campaign_id"], .string("abandoned_cart_2026"))
        XCTAssertEqual(message.customData?["score"], .int(7))
    }

    func test_decode_inAppMessage_handlesMissingOptionalFields() throws {
        let json = """
        {
          "id": "a1",
          "message_id": "b1",
          "placement_key": "settings_modal",
          "title": "Title",
          "body": "Body"
        }
        """
        let message = try JSONDecoder().decode(InAppMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.id, "a1")
        XCTAssertNil(message.imageUrl)
        XCTAssertEqual(message.ctas, [])
        XCTAssertNil(message.customData)
        XCTAssertNil(message.expiresAt)
        XCTAssertEqual(message.priority, 0)
    }

    func test_decode_inAppMessage_handlesIso8601WithoutFractionalSeconds() throws {
        let json = """
        {
          "id": "a1",
          "message_id": "b1",
          "placement_key": "p",
          "title": "T",
          "body": "B",
          "expires_at": "2026-07-01T12:00:00Z"
        }
        """
        let message = try JSONDecoder().decode(InAppMessage.self, from: Data(json.utf8))
        XCTAssertNotNil(message.expiresAt)
    }

    func test_encode_decode_inAppMessage_roundTrips() throws {
        let original = InAppMessage(
            id: "a1",
            messageId: "b1",
            placement: "home_banner",
            title: "T",
            body: "B",
            imageUrl: "https://example.com/x.png",
            ctas: [
                InAppCta(id: "c1", label: "Go", actionType: .webview, actionPayload: "https://x")
            ],
            customData: ["k": .string("v")],
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            priority: 5
        )
        let data = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(InAppMessage.self, from: data)

        XCTAssertEqual(roundTripped.id, original.id)
        XCTAssertEqual(roundTripped.messageId, original.messageId)
        XCTAssertEqual(roundTripped.placement, original.placement)
        XCTAssertEqual(roundTripped.title, original.title)
        XCTAssertEqual(roundTripped.body, original.body)
        XCTAssertEqual(roundTripped.imageUrl, original.imageUrl)
        XCTAssertEqual(roundTripped.ctas, original.ctas)
        XCTAssertEqual(roundTripped.customData, original.customData)
        XCTAssertEqual(roundTripped.priority, original.priority)
        // Allow a small delta on the timestamp round-trip — ISO8601
        // strings drop sub-millisecond precision.
        if let originalDate = original.expiresAt, let rtDate = roundTripped.expiresAt {
            XCTAssertEqual(originalDate.timeIntervalSince1970, rtDate.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    // MARK: - InAppCtaActionType

    func test_inAppCtaActionType_wireValues_matchBrowserSDK() throws {
        // Wire values verified against `packages/sdk/src/types.ts:143`
        XCTAssertEqual(InAppCtaActionType.deepLink.rawValue, "deep_link")
        XCTAssertEqual(InAppCtaActionType.dismiss.rawValue, "dismiss")
        XCTAssertEqual(InAppCtaActionType.webview.rawValue, "webview")
        XCTAssertEqual(InAppCtaActionType.callback.rawValue, "callback")
    }

    // MARK: - InAppLogRequest

    func test_encode_inAppLogRequest_impressedEvent() throws {
        let req = InAppLogRequest(assignmentId: "a1", event: "impressed")
        let data = try JSONEncoder().encode(req)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(parsed?["assignment_id"] as? String, "a1")
        XCTAssertEqual(parsed?["event"] as? String, "impressed")
        // ctaId + deviceId are nil → omitted from wire (Swift's
        // default for `encodeIfPresent`-style optional fields).
        XCTAssertFalse(parsed?.keys.contains("cta_id") ?? true)
    }

    func test_encode_inAppLogRequest_interactedEvent_includesCta() throws {
        let req = InAppLogRequest(assignmentId: "a1", event: "interacted", ctaId: "cta_view")
        let data = try JSONEncoder().encode(req)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(parsed?["cta_id"] as? String, "cta_view")
    }

    // MARK: - InAppLogResponse

    func test_decode_inAppLogResponse() throws {
        let json = """
        {
          "log_id": "log_abc",
          "billable": true,
          "plan_limit_reached": false,
          "soft_degraded": true
        }
        """
        let response = try JSONDecoder().decode(InAppLogResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.logId, "log_abc")
        XCTAssertTrue(response.billable)
        XCTAssertFalse(response.planLimitReached)
        XCTAssertTrue(response.softDegraded)
    }
}
