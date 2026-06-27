//
//  IdentityEventsTests.swift
//  PYRXSynapseTests
//
//  Phase 9.2.1 PR-1 — Observer API identity events.
//
//  Verifies the before/after snapshot semantics around identify, alias,
//  and logout. Each test:
//   1. Initializes Pyrx (which generates anonymousId)
//   2. Subscribes to events
//   3. Drives the identity mutation through the public API
//   4. Asserts the published .identityChanged(before:after:) payload
//
//  Anonymous-user IS a state — the `before` snapshot is never absent
//  (every snapshot has an anonymousId after initialize).
//
//  Coverage:
//
//   1. identify() — before(externalId: nil) → after(externalId: set)
//   2. alias()    — before(externalId: previous) → after(externalId: new)
//   3. logout()   — before(externalId: set)      → after(externalId: nil)
//   4. Failed identify — no observer event fires (network failure path)
//   5. anonymousId is preserved across every transition
//

import XCTest
@testable import PYRXSynapse

final class IdentityEventsTests: XCTestCase {

    private let workspaceId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let apiKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private struct Bench {
        let pyrx: Pyrx
        let storage: InMemoryStorage
        let session: MockHTTPSession
    }

    private func makeBench() -> Bench {
        let storage = InMemoryStorage()
        let session = MockHTTPSession()
        let pyrx = Pyrx(storage: storage, session: session)
        return Bench(pyrx: pyrx, storage: storage, session: session)
    }

    private func makeConfig() -> PyrxConfig {
        PyrxConfig(
            workspaceId: workspaceId,
            apiKey: apiKey,
            environment: .production,
            baseUrl: URL(string: "https://synapse-events.pyrx.tech")!
        )
    }

    private func enqueueIdentifySuccess(
        _ session: MockHTTPSession,
        contactId: String = "22222222-2222-2222-2222-222222222222"
    ) {
        session.enqueueJSONSuccess(json: """
        {"contact_id":"\(contactId)","path":"first_sighting",\
        "aliased_external_id":null,\
        "events_reattributed":0,"devices_reattributed":0,\
        "anonymous_contact_tombstoned":false}
        """)
    }

    private func waitForObservers() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 80_000_000)
        await Task.yield()
    }

    // MARK: - identify

    func test_identify_emitsBeforeNilExternal_andAfterSetExternal() async throws {
        let bench = makeBench()
        let pyrx = bench.pyrx
        let session = bench.session
        try await pyrx.initialize(config: makeConfig())

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        enqueueIdentifySuccess(session)
        _ = try await pyrx.identify(externalId: "user-123")
        await waitForObservers()

        let changes = collected.read().compactMap { event -> (IdentitySnapshot, IdentitySnapshot)? in
            if case let .identityChanged(before, after) = event { return (before, after) }
            return nil
        }
        XCTAssertEqual(changes.count, 1, "identify must publish exactly one .identityChanged")
        let (before, after) = changes[0]
        XCTAssertNil(before.externalId, "before snapshot has no externalId")
        XCTAssertEqual(after.externalId, "user-123", "after snapshot has the newly-set externalId")
        XCTAssertEqual(before.anonymousId, after.anonymousId, "anonymousId is preserved across identify")
        XCTAssertNotNil(before.anonymousId)
    }

    // MARK: - alias

    func test_alias_emitsBeforePreviousExternal_andAfterNewExternal() async throws {
        let bench = makeBench()
        let pyrx = bench.pyrx
        let session = bench.session
        try await pyrx.initialize(config: makeConfig())

        // Drive an initial identify first so externalId is already set.
        enqueueIdentifySuccess(session)
        _ = try await pyrx.identify(externalId: "user-old")

        // Now subscribe so we ONLY observe the alias publication.
        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }
        // Drain replay buffer first (already had 1 identify event).
        await waitForObservers()
        collected.mutate { $0.removeAll() }

        enqueueIdentifySuccess(session, contactId: "55555555-5555-5555-5555-555555555555")
        _ = try await pyrx.alias(newExternalId: "user-new")
        await waitForObservers()

        let changes = collected.read().compactMap { event -> (IdentitySnapshot, IdentitySnapshot)? in
            if case let .identityChanged(before, after) = event { return (before, after) }
            return nil
        }
        XCTAssertEqual(changes.count, 1, "alias must publish exactly one .identityChanged")
        XCTAssertEqual(changes[0].0.externalId, "user-old")
        XCTAssertEqual(changes[0].1.externalId, "user-new")
    }

    // MARK: - logout

    func test_logout_emitsBeforeSetExternal_andAfterNilExternal() async throws {
        let bench = makeBench()
        let pyrx = bench.pyrx
        let session = bench.session
        try await pyrx.initialize(config: makeConfig())

        enqueueIdentifySuccess(session)
        _ = try await pyrx.identify(externalId: "user-x")

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }
        await waitForObservers()
        collected.mutate { $0.removeAll() }

        try await pyrx.logout()
        await waitForObservers()

        let changes = collected.read().compactMap { event -> (IdentitySnapshot, IdentitySnapshot)? in
            if case let .identityChanged(before, after) = event { return (before, after) }
            return nil
        }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].0.externalId, "user-x")
        XCTAssertNil(changes[0].1.externalId, "logout must clear externalId in after snapshot")
        XCTAssertEqual(changes[0].0.anonymousId, changes[0].1.anonymousId)
    }

    // MARK: - Failed identify

    func test_failedIdentify_doesNotEmitObserverEvent() async throws {
        let bench = makeBench()
        let pyrx = bench.pyrx
        let session = bench.session
        try await pyrx.initialize(config: makeConfig())

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        // Enqueue an error so the identify call throws.
        session.enqueue(.failure(NSError(
            domain: "test", code: 500,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )))

        do {
            _ = try await pyrx.identify(externalId: "user-fails")
            XCTFail("expected identify to throw")
        } catch {
            // expected
        }
        await waitForObservers()

        let changes = collected.read().filter { event in
            if case .identityChanged = event { return true }
            return false
        }
        XCTAssertEqual(changes.count, 0, "failed identify must not publish an observer event")
    }

    // MARK: - anonymousId preservation across all transitions

    func test_anonymousIdPreserved_acrossIdentifyAliasLogout() async throws {
        let bench = makeBench()
        let pyrx = bench.pyrx
        let storage = bench.storage
        let session = bench.session
        try await pyrx.initialize(config: makeConfig())

        let originalAnon = try storage.get(.anonymousId)
        XCTAssertNotNil(originalAnon)

        let collected = SendableBox<[PyrxEvent]>([])
        let token = await pyrx.observe(on: .main) { event in
            collected.mutate { $0.append(event) }
        }
        defer { token.cancel() }

        enqueueIdentifySuccess(session)
        _ = try await pyrx.identify(externalId: "u1")
        enqueueIdentifySuccess(session)
        _ = try await pyrx.alias(newExternalId: "u2")
        try await pyrx.logout()
        await waitForObservers()

        let changes = collected.read().compactMap { event -> (IdentitySnapshot, IdentitySnapshot)? in
            if case let .identityChanged(before, after) = event { return (before, after) }
            return nil
        }
        XCTAssertEqual(changes.count, 3)
        for (idx, change) in changes.enumerated() {
            XCTAssertEqual(change.0.anonymousId, originalAnon,
                           "transition \(idx) before.anonymousId drifted")
            XCTAssertEqual(change.1.anonymousId, originalAnon,
                           "transition \(idx) after.anonymousId drifted")
        }
    }
}
