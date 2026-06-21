//
//  PyrxConfigTests.swift
//  PYRXSynapseTests
//

import XCTest
@testable import PYRXSynapse

final class PyrxConfigTests: XCTestCase {
    let validWorkspace = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let validKey = "psk_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    func test_defaults_applied() {
        let config = PyrxConfig(workspaceId: validWorkspace, apiKey: validKey)
        XCTAssertEqual(config.environment, .production)
        XCTAssertEqual(config.baseUrl, PyrxConfig.defaultBaseUrl)
        XCTAssertEqual(config.logLevel, .info)
    }

    func test_defaultBaseUrl_isHttpsIngestionEndpoint() {
        XCTAssertEqual(PyrxConfig.defaultBaseUrl.absoluteString, "https://synapse-events.pyrx.tech")
    }

    func test_validate_acceptsWellFormedConfig() {
        let config = PyrxConfig(workspaceId: validWorkspace, apiKey: validKey)
        XCTAssertNoThrow(try config.validate())
    }

    func test_validate_rejectsEmptyApiKey() {
        let config = PyrxConfig(workspaceId: validWorkspace, apiKey: "")
        XCTAssertThrowsError(try config.validate()) { error in
            guard case let PyrxError.invalidConfig(reason) = error else {
                return XCTFail("expected .invalidConfig, got \(error)")
            }
            XCTAssertTrue(reason.contains("apiKey"))
        }
    }

    func test_validate_rejectsWhitespaceApiKey() {
        let config = PyrxConfig(workspaceId: validWorkspace, apiKey: "   \n\t")
        XCTAssertThrowsError(try config.validate())
    }

    func test_validate_rejectsApiKeyWithoutPskPrefix() {
        let config = PyrxConfig(workspaceId: validWorkspace, apiKey: "sk_live_xxxxxxxxxxxx")
        XCTAssertThrowsError(try config.validate()) { error in
            guard case let PyrxError.invalidConfig(reason) = error else {
                return XCTFail("expected .invalidConfig, got \(error)")
            }
            XCTAssertTrue(reason.contains("psk_"))
        }
    }

    func test_validate_rejectsNonHttpScheme() throws {
        let badUrl = try XCTUnwrap(URL(string: "ftp://example.com"))
        let config = PyrxConfig(
            workspaceId: validWorkspace,
            apiKey: validKey,
            baseUrl: badUrl
        )
        XCTAssertThrowsError(try config.validate())
    }

    func test_equatable() {
        let lhs = PyrxConfig(workspaceId: validWorkspace, apiKey: validKey)
        let rhs = PyrxConfig(workspaceId: validWorkspace, apiKey: validKey)
        XCTAssertEqual(lhs, rhs)

        let other = PyrxConfig(workspaceId: validWorkspace, apiKey: validKey, logLevel: .debug)
        XCTAssertNotEqual(lhs, other)
    }

    func test_logLevel_isComparable() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.info)
        XCTAssertLessThan(LogLevel.info, LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.error)
        XCTAssertLessThan(LogLevel.error, LogLevel.none)
    }
}
