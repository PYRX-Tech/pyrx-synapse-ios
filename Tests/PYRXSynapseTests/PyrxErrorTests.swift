//
//  PyrxErrorTests.swift
//  PYRXSynapseTests
//

import XCTest
@testable import PYRXSynapse

final class PyrxErrorTests: XCTestCase {
    func test_errorDescription_isNonEmpty_forEveryCase() {
        let cases: [PyrxError] = [
            .alreadyInitialized,
            .notInitialized,
            .invalidConfig(reason: "missing apiKey"),
            .keychainFailure(status: -25300, operation: "get(anonymous_id)"),
        ]
        for error in cases {
            XCTAssertNotNil(error.errorDescription, "\(error) must have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func test_equatable() {
        XCTAssertEqual(PyrxError.alreadyInitialized, .alreadyInitialized)
        XCTAssertEqual(PyrxError.invalidConfig(reason: "x"), .invalidConfig(reason: "x"))
        XCTAssertNotEqual(PyrxError.invalidConfig(reason: "x"), .invalidConfig(reason: "y"))
        XCTAssertNotEqual(PyrxError.alreadyInitialized, .notInitialized)
    }
}
