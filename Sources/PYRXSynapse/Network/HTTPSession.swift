//
//  HTTPSession.swift
//  PYRXSynapse
//
//  Minimal abstraction over `URLSession.data(for:)` so unit tests can swap
//  in a mock without going over the wire. Production uses `URLSession.shared`
//  via the default conformance below; tests use `MockHTTPSession` (defined
//  in the test target).
//
//  Kept deliberately thin — one method, one shape — so we do not have to
//  re-implement URLSession in tests. The whole HTTP surface of the SDK
//  goes through `HTTPClient` (this PR) which in turn calls this protocol.
//

import Foundation

/// Network transport seam. Implementations must be thread-safe.
///
/// The production conformance is on `URLSession` (below). Tests pass a
/// `MockHTTPSession` so no real network calls happen in `swift test`.
public protocol HTTPSession: Sendable {
    /// Perform `request` and return the response data + metadata.
    ///
    /// Mirrors `URLSession.data(for:)` so the production conformance is a
    /// one-line forward. Errors thrown here propagate to `HTTPClient` which
    /// maps them to `PyrxError.network(...)`.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}
