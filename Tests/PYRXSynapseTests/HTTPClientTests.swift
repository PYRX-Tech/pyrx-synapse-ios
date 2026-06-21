//
//  HTTPClientTests.swift
//  PYRXSynapseTests
//
//  Exercises the wire-surface contract that Android PR 2 will mirror:
//
//    1. Five required headers are present on every request
//    2. JSON body is encoded with snake_case keys
//    3. 2xx responses round-trip through the Decodable types
//    4. Non-2xx responses surface as PyrxError.network(.httpStatus(...))
//    5. Transport errors surface as PyrxError.network(.transport(...))
//
//  No real network — `MockHTTPSession` injects canned responses.
//

import XCTest
@testable import PYRXSynapse

final class HTTPClientTests: XCTestCase {

    // MARK: - Fixtures

    private let workspaceId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let apiKey = "psk_test_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let baseUrl = URL(string: "https://synapse-events.pyrx.tech")!

    private func makeClient(session: MockHTTPSession) -> HTTPClient {
        let config = PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: .production,
            baseUrl: baseUrl
        )
        return HTTPClient(config: config, session: session)
    }

    // MARK: - Header injection

    func test_post_injectsAllFiveRequiredHeaders() async throws {
        let session = MockHTTPSession()
        session.enqueueJSONSuccess(json: #"{"status":"accepted","envelope_id":null,"reason":null}"#)
        let client = makeClient(session: session)

        let body = PushOpenedRequest(pushLogId: UUID())
        _ = try await client.post(.pushOpened, body: body, responseType: PushTelemetryResponse.self)

        XCTAssertEqual(session.requests.count, 1)
        let headers = session.requests[0].request.allHTTPHeaderFields ?? [:]

        XCTAssertEqual(headers["X-WORKSPACE-ID"], workspaceId.uuidString)
        XCTAssertEqual(headers["X-API-KEY"], apiKey)
        XCTAssertEqual(headers["X-PYRX-SDK-VERSION"], PyrxConstants.sdkVersion)
        XCTAssertEqual(headers["X-PYRX-SDK-PLATFORM"], "ios")
        XCTAssertEqual(headers["Content-Type"], "application/json")
    }

    func test_post_setsPostMethodAndCorrectURLPath() async throws {
        let session = MockHTTPSession()
        session.enqueueJSONSuccess(json: """
        {"contact_id":"22222222-2222-2222-2222-222222222222","path":"no_anonymous",\
        "aliased_external_id":null,"events_reattributed":0,"devices_reattributed":0,\
        "anonymous_contact_tombstoned":false}
        """)
        let client = makeClient(session: session)

        let body = IdentifyRequest(anonymousId: nil, externalId: "user_42")
        _ = try await client.post(.identify, body: body, responseType: IdentifyResponse.self)

        let recorded = session.requests[0].request
        XCTAssertEqual(recorded.httpMethod, "POST")
        XCTAssertEqual(recorded.url?.path, "/v1/identify")
        XCTAssertEqual(recorded.url?.host, "synapse-events.pyrx.tech")
    }

    // MARK: - Snake-case JSON body encoding

    func test_identifyRequest_encodesSnakeCaseKeys() async throws {
        let session = MockHTTPSession()
        session.enqueueJSONSuccess(json: """
        {"contact_id":"22222222-2222-2222-2222-222222222222","path":"first_sighting",\
        "aliased_external_id":"anon-xyz","events_reattributed":0,"devices_reattributed":0,\
        "anonymous_contact_tombstoned":false}
        """)
        let client = makeClient(session: session)

        let body = IdentifyRequest(
            anonymousId: "anon-xyz",
            externalId: "user_42",
            traits: ["email": .string("a@b.co"), "plan": .string("pro")],
            environment: .test
        )
        _ = try await client.post(.identify, body: body, responseType: IdentifyResponse.self)

        // Decode the request body back into a generic dict so we can assert
        // wire-shape independent of property ordering.
        let raw = try XCTUnwrap(session.requests[0].body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["anonymous_id"] as? String, "anon-xyz")
        XCTAssertEqual(json?["external_id"] as? String, "user_42")
        XCTAssertEqual(json?["environment"] as? String, "test")
        let traits = json?["traits"] as? [String: Any]
        XCTAssertEqual(traits?["email"] as? String, "a@b.co")
        XCTAssertEqual(traits?["plan"] as? String, "pro")
    }

    func test_aliasRequest_encodesSnakeCaseKeys() async throws {
        let session = MockHTTPSession()
        session.enqueueJSONSuccess(json: """
        {"contact_id":"22222222-2222-2222-2222-222222222222","path":"known_exists",\
        "aliased_external_id":"anon-xyz","events_reattributed":3,"devices_reattributed":1,\
        "anonymous_contact_tombstoned":true}
        """)
        let client = makeClient(session: session)

        let body = AliasRequest(anonymousId: "anon-xyz", externalId: "user_42")
        _ = try await client.post(.alias, body: body, responseType: AliasResponse.self)

        let raw = try XCTUnwrap(session.requests[0].body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(json?["anonymous_id"] as? String, "anon-xyz")
        XCTAssertEqual(json?["external_id"] as? String, "user_42")
        XCTAssertEqual(json?["environment"] as? String, "live")
    }

    // MARK: - Response decoding round-trip

    func test_identifyResponse_decodesAllFields() async throws {
        let session = MockHTTPSession()
        session.enqueueJSONSuccess(json: """
        {"contact_id":"22222222-2222-2222-2222-222222222222","path":"known_exists",\
        "aliased_external_id":"anon-xyz","events_reattributed":47,"devices_reattributed":1,\
        "anonymous_contact_tombstoned":true}
        """)
        let client = makeClient(session: session)

        let response = try await client.post(
            .identify,
            body: IdentifyRequest(anonymousId: "anon-xyz", externalId: "user_42"),
            responseType: IdentifyResponse.self
        )

        XCTAssertEqual(response.contactId.uuidString, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(response.path, .knownExists)
        XCTAssertEqual(response.aliasedExternalId, "anon-xyz")
        XCTAssertEqual(response.eventsReattributed, 47)
        XCTAssertEqual(response.devicesReattributed, 1)
        XCTAssertTrue(response.anonymousContactTombstoned)
    }

    // MARK: - Error mapping

    func test_post_returns_httpStatus_onNon2xx() async throws {
        let session = MockHTTPSession()
        session.enqueue(.success(
            statusCode: 403,
            body: Data(#"{"detail":{"message":"forbidden","code":"scope_forbidden"}}"#.utf8),
            headers: ["Content-Type": "application/json"]
        ))
        let client = makeClient(session: session)

        do {
            _ = try await client.post(
                .identify,
                body: IdentifyRequest(anonymousId: nil, externalId: "user_42"),
                responseType: IdentifyResponse.self
            )
            XCTFail("expected .httpStatus")
        } catch let PyrxError.network(.httpStatus(statusCode, body)) {
            XCTAssertEqual(statusCode, 403)
            XCTAssertGreaterThan(body.count, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_post_returns_transport_onSessionError() async throws {
        let session = MockHTTPSession()
        session.enqueue(.failure(URLError(.notConnectedToInternet)))
        let client = makeClient(session: session)

        do {
            _ = try await client.post(
                .identify,
                body: IdentifyRequest(anonymousId: nil, externalId: "user_42"),
                responseType: IdentifyResponse.self
            )
            XCTFail("expected .transport")
        } catch let PyrxError.network(.transport(underlying)) {
            XCTAssertTrue(underlying is URLError)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_post_returns_decode_onMalformedJSON() async throws {
        let session = MockHTTPSession()
        // Status is 200 but the body is not a valid IdentifyResponse — should
        // surface as a decode failure, not a status failure.
        session.enqueueJSONSuccess(json: #"{"unexpected":"shape"}"#)
        let client = makeClient(session: session)

        do {
            _ = try await client.post(
                .identify,
                body: IdentifyRequest(anonymousId: nil, externalId: "user_42"),
                responseType: IdentifyResponse.self
            )
            XCTFail("expected .decode")
        } catch PyrxError.network(.decode) {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Endpoint coverage

    func test_endpointPaths_areLockedToWireContract() {
        // Triple-guard the path strings. Changing these is a wire-breaking
        // change that requires a coordinated Android PR.
        XCTAssertEqual(HTTPClient.Endpoint.devicesRegister.rawValue, "/v1/devices")
        XCTAssertEqual(HTTPClient.Endpoint.identify.rawValue, "/v1/identify")
        XCTAssertEqual(HTTPClient.Endpoint.alias.rawValue, "/v1/alias")
        XCTAssertEqual(HTTPClient.Endpoint.events.rawValue, "/v1/events")
        XCTAssertEqual(HTTPClient.Endpoint.pushOpened.rawValue, "/v1/push/opened")
        XCTAssertEqual(HTTPClient.Endpoint.pushClick.rawValue, "/v1/push/click")
    }

    func test_headerNames_areLockedToWireContract() {
        XCTAssertEqual(HTTPClient.HeaderName.workspaceId, "X-WORKSPACE-ID")
        XCTAssertEqual(HTTPClient.HeaderName.apiKey, "X-API-KEY")
        XCTAssertEqual(HTTPClient.HeaderName.sdkVersion, "X-PYRX-SDK-VERSION")
        XCTAssertEqual(HTTPClient.HeaderName.sdkPlatform, "X-PYRX-SDK-PLATFORM")
        XCTAssertEqual(HTTPClient.HeaderName.contentType, "Content-Type")
    }

    // MARK: - Void response variant

    func test_post_voidResponse_succeedsOn2xxWithEmptyBody() async throws {
        let session = MockHTTPSession()
        session.enqueueJSONSuccess(statusCode: 202, json: "")
        let client = makeClient(session: session)

        // Should not throw — we don't decode anything.
        try await client.post(.events, body: EventIngestRequest(
            externalId: "user_42",
            eventName: "ping"
        ))

        XCTAssertEqual(session.requests.count, 1)
    }

    func test_post_voidResponse_throwsOnNon2xx() async throws {
        let session = MockHTTPSession()
        session.enqueue(.success(
            statusCode: 500,
            body: Data("oops".utf8),
            headers: [:]
        ))
        let client = makeClient(session: session)

        do {
            try await client.post(.events, body: EventIngestRequest(
                externalId: "user_42",
                eventName: "ping"
            ))
            XCTFail("expected .httpStatus")
        } catch let PyrxError.network(.httpStatus(statusCode, _)) {
            XCTAssertEqual(statusCode, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
