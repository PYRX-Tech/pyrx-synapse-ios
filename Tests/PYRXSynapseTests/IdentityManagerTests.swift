//
//  IdentityManagerTests.swift
//  PYRXSynapseTests
//
//  Exercises the identity state machine (ARCHITECTURE.md §28.4 + push SDK
//  plan §5.3) end-to-end through `Pyrx.shared`. All HTTP goes through
//  `MockHTTPSession` — `swift test` performs no real network I/O.
//
//  Coverage:
//
//    1. First-launch anonymousId is generated and persisted
//    2. identify() — sends anonymousId + externalId, persists externalId
//    3. identify() — handles all three merge paths (known_exists,
//       first_sighting, no_anonymous)
//    4. alias() — sends both ids, persists newExternalId
//    5. alias() — requires anonymousId on disk
//    6. logout() — clears externalId, preserves anonymousId + deviceToken
//    7. identify() / alias() / logout() throw .notInitialized before init
//

import XCTest
@testable import PYRXSynapse

final class IdentityManagerTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    // MARK: - Helpers

    /// Bundles a `Pyrx` with the same `InMemoryStorage` + `MockHTTPSession`
    /// it was constructed with — so tests can introspect what landed where
    /// without juggling three separate variables at every call site.
    private struct Bench {
        let pyrx: Pyrx
        let storage: InMemoryStorage
        let session: MockHTTPSession
    }

    private func makeBench(
        storage: InMemoryStorage = InMemoryStorage(),
        session: MockHTTPSession = MockHTTPSession()
    ) -> Bench {
        Bench(pyrx: Pyrx(storage: storage, session: session), storage: storage, session: session)
    }

    private func makeConfig(environment: PyrxEnvironment = .production) -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: environment,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    private func enqueueIdentifyResponse(
        _ session: MockHTTPSession,
        contactId: String = "22222222-2222-2222-2222-222222222222",
        path: String = "first_sighting",
        aliased: String? = "fixture-anon",
        events: Int = 0,
        devices: Int = 0,
        tombstoned: Bool = false
    ) {
        let aliasedField = aliased.map { "\"\($0)\"" } ?? "null"
        session.enqueueJSONSuccess(json: """
        {"contact_id":"\(contactId)","path":"\(path)",\
        "aliased_external_id":\(aliasedField),\
        "events_reattributed":\(events),"devices_reattributed":\(devices),\
        "anonymous_contact_tombstoned":\(tombstoned)}
        """)
    }

    // MARK: - First-launch anonymousId

    func test_firstLaunch_generatesAnonymousId_andPersistsIt() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        // anonymousId persisted to storage on first launch
        let anon = try bench.storage.get(.anonymousId)
        XCTAssertNotNil(anon)
        XCTAssertFalse(anon!.isEmpty)
        XCTAssertNotNil(UUID(uuidString: anon!), "anonymousId should be a UUID v4")

        // debugInfo reflects the same value
        let info = await bench.pyrx.debugInfo()
        XCTAssertEqual(info.anonymousId, anon)
        XCTAssertFalse(info.hasExternalId)
    }

    func test_secondLaunch_reusesPersistedAnonymousId() async throws {
        let storage = InMemoryStorage()
        try storage.set(.anonymousId, value: "preexisting-anon")
        let bench = makeBench(storage: storage)
        try await bench.pyrx.initialize(config: makeConfig())

        let info = await bench.pyrx.debugInfo()
        XCTAssertEqual(info.anonymousId, "preexisting-anon")
    }

    // MARK: - identify state transitions

    func test_identify_sendsAnonymousIdAndExternalId_andPersistsExternalId() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        let anon = try XCTUnwrap(bench.storage.get(.anonymousId))

        enqueueIdentifyResponse(bench.session, path: "first_sighting", aliased: anon)

        let result = try await bench.pyrx.identify(externalId: "user_42")

        // Server result surfaced
        XCTAssertEqual(result.path, .firstSighting)
        XCTAssertEqual(result.aliasedExternalId, anon)

        // Wire body — both ids present + correct environment
        let raw = try XCTUnwrap(bench.session.requests[0].body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(json?["anonymous_id"] as? String, anon)
        XCTAssertEqual(json?["external_id"] as? String, "user_42")
        XCTAssertEqual(json?["environment"] as? String, "live")
        XCTAssertNil(json?["traits"])

        // externalId persisted client-side; anonymousId still on disk (audit)
        XCTAssertEqual(try bench.storage.get(.externalId), "user_42")
        XCTAssertEqual(try bench.storage.get(.anonymousId), anon)
    }

    func test_identify_carriesTraits_whenProvided() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        enqueueIdentifyResponse(bench.session, path: "no_anonymous", aliased: nil)

        _ = try await bench.pyrx.identify(
            externalId: "user_42",
            traits: ["email": .string("a@b.co"), "age": .int(31)]
        )

        let raw = try XCTUnwrap(bench.session.requests[0].body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        let traits = json?["traits"] as? [String: Any]
        XCTAssertEqual(traits?["email"] as? String, "a@b.co")
        XCTAssertEqual(traits?["age"] as? Int, 31)
    }

    func test_identify_sendsSandboxAsTestEnvironment() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig(environment: .sandbox))
        enqueueIdentifyResponse(bench.session, path: "no_anonymous", aliased: nil)

        _ = try await bench.pyrx.identify(externalId: "user_42")

        let raw = try XCTUnwrap(bench.session.requests[0].body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(json?["environment"] as? String, "test")
    }

    func test_identify_handlesAllThreeMergePaths() async throws {
        for (pathString, expectedCase) in [
            ("known_exists", IdentifyPath.knownExists),
            ("first_sighting", IdentifyPath.firstSighting),
            ("no_anonymous", IdentifyPath.noAnonymous),
        ] {
            let bench = makeBench()
            try await bench.pyrx.initialize(config: makeConfig())
            enqueueIdentifyResponse(bench.session, path: pathString, aliased: nil)

            let result = try await bench.pyrx.identify(externalId: "user_\(pathString)")
            XCTAssertEqual(result.path, expectedCase, "for path \(pathString)")
        }
    }

    func test_identify_rejectsEmptyExternalId() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        do {
            _ = try await bench.pyrx.identify(externalId: "   ")
            XCTFail("expected .invalidConfig")
        } catch PyrxError.invalidConfig {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - alias

    func test_alias_sendsBothIds_andPersistsNewExternalId() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        let anon = try XCTUnwrap(bench.storage.get(.anonymousId))

        enqueueIdentifyResponse(bench.session, path: "no_anonymous", aliased: anon)

        let result = try await bench.pyrx.alias(newExternalId: "user_42")

        XCTAssertEqual(result.path, .noAnonymous)

        let raw = try XCTUnwrap(bench.session.requests[0].body)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(json?["anonymous_id"] as? String, anon)
        XCTAssertEqual(json?["external_id"] as? String, "user_42")
        XCTAssertEqual(json?["environment"] as? String, "live")

        // newExternalId persisted
        XCTAssertEqual(try bench.storage.get(.externalId), "user_42")
    }

    func test_alias_targetsAliasEndpoint() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        enqueueIdentifyResponse(bench.session, path: "known_exists", aliased: "fixture")

        _ = try await bench.pyrx.alias(newExternalId: "user_42")

        let recorded = bench.session.requests[0].request
        XCTAssertEqual(recorded.url?.path, "/v1/alias")
    }

    func test_alias_rejectsEmptyNewExternalId() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())

        do {
            _ = try await bench.pyrx.alias(newExternalId: "")
            XCTFail("expected .invalidConfig")
        } catch PyrxError.invalidConfig {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - logout

    func test_logout_clearsExternalId_butKeepsAnonymousIdAndDeviceToken() async throws {
        let storage = InMemoryStorage()
        // Pre-populate as if PR 4 had registered a device.
        try storage.set(.deviceToken, value: "fixture-device-token")

        let bench = makeBench(storage: storage)
        try await bench.pyrx.initialize(config: makeConfig())
        let anonAfterInit = try XCTUnwrap(bench.storage.get(.anonymousId))

        // Identify once so externalId is on disk
        enqueueIdentifyResponse(bench.session, path: "first_sighting", aliased: anonAfterInit)
        _ = try await bench.pyrx.identify(externalId: "user_42")
        XCTAssertEqual(try bench.storage.get(.externalId), "user_42")

        // Logout
        try await bench.pyrx.logout()

        XCTAssertNil(try bench.storage.get(.externalId), "externalId must be cleared")
        XCTAssertEqual(
            try bench.storage.get(.anonymousId),
            anonAfterInit,
            "anonymousId must be preserved across logout"
        )
        XCTAssertEqual(
            try bench.storage.get(.deviceToken),
            "fixture-device-token",
            "deviceToken must be preserved across logout (device row stays valid)"
        )

        // logout() does NOT call the server — no new HTTP request beyond identify
        XCTAssertEqual(bench.session.requests.count, 1, "logout must not call the server")
    }

    // MARK: - notInitialized guard

    func test_identify_throwsNotInitialized_beforeInit() async throws {
        let bench = makeBench()

        do {
            _ = try await bench.pyrx.identify(externalId: "user_42")
            XCTFail("expected .notInitialized")
        } catch PyrxError.notInitialized {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_alias_throwsNotInitialized_beforeInit() async throws {
        let bench = makeBench()

        do {
            _ = try await bench.pyrx.alias(newExternalId: "user_42")
            XCTFail("expected .notInitialized")
        } catch PyrxError.notInitialized {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_logout_throwsNotInitialized_beforeInit() async throws {
        let bench = makeBench()

        do {
            try await bench.pyrx.logout()
            XCTFail("expected .notInitialized")
        } catch PyrxError.notInitialized {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - debugInfo reflects identify

    func test_debugInfo_reflectsExternalId_afterIdentify() async throws {
        let bench = makeBench()
        try await bench.pyrx.initialize(config: makeConfig())
        enqueueIdentifyResponse(bench.session, path: "first_sighting", aliased: nil)

        let infoBefore = await bench.pyrx.debugInfo()
        XCTAssertFalse(infoBefore.hasExternalId)

        _ = try await bench.pyrx.identify(externalId: "user_42")

        let infoAfter = await bench.pyrx.debugInfo()
        XCTAssertTrue(infoAfter.hasExternalId)
    }
}
