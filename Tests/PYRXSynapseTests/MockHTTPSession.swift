//
//  MockHTTPSession.swift
//  PYRXSynapseTests
//
//  In-process `HTTPSession` stub. Records every request the SDK makes and
//  replays canned (Data, URLResponse) tuples. Tests never touch the real
//  network — `swift test` is hermetic and stays under the 30s timeout the
//  parent agent enforces.
//

import Foundation
@testable import PYRXSynapse

/// Recorded request + the canned response the mock returned.
struct RecordedRequest: Sendable {
    let request: URLRequest
    let body: Data?
}

/// A canned response. Either a success tuple OR an error to throw on
/// `data(for:)`. The mock pops responses in FIFO order — tests that issue
/// multiple requests should `enqueue` multiple responses.
enum CannedResponse {
    case success(statusCode: Int, body: Data, headers: [String: String])
    case failure(Error)
}

final class MockHTTPSession: HTTPSession, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [CannedResponse] = []
    private(set) var requests: [RecordedRequest] = []

    /// Enqueue a JSON success response. Body is serialised to UTF-8 bytes.
    func enqueueJSONSuccess(statusCode: Int = 200, json: String) {
        let data = Data(json.utf8)
        enqueue(.success(
            statusCode: statusCode,
            body: data,
            headers: ["Content-Type": "application/json"]
        ))
    }

    /// Enqueue a raw response — used to test non-2xx and decode failures.
    func enqueue(_ response: CannedResponse) {
        lock.lock(); defer { lock.unlock() }
        queued.append(response)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let popped: CannedResponse = try {
            lock.lock(); defer { lock.unlock() }
            guard !queued.isEmpty else {
                throw NSError(
                    domain: "MockHTTPSession",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "no canned response queued"]
                )
            }
            requests.append(RecordedRequest(request: request, body: request.httpBody))
            return queued.removeFirst()
        }()

        switch popped {
        case let .success(statusCode, body, headers):
            guard let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                throw NSError(domain: "MockHTTPSession", code: -2, userInfo: nil)
            }
            return (body, response)
        case let .failure(error):
            throw error
        }
    }
}
