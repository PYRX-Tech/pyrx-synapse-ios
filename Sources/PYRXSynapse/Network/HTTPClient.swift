//
//  HTTPClient.swift
//  PYRXSynapse
//
//  Typed JSON HTTP client for the PYRX Synapse backend. Owns:
//
//    - URL construction from `PyrxConfig.baseUrl` + endpoint path
//    - Required-header injection on every request
//    - JSON encode of `Encodable` bodies
//    - JSON decode of `Decodable` responses
//    - HTTP status / transport / decode error mapping into `PyrxError.network`
//
//  Does NOT own:
//
//    - Retry / exponential backoff — PR 3 (offline queue) owns retries; this
//      client surfaces the error so the queue can decide.
//    - Auth state — `PyrxConfig` carries workspaceId + apiKey; the client
//      reads them from the config it was constructed with.
//    - Per-request idempotency keys — wired in PR 3 alongside the queue.
//
//  Headers (matches backend contract verbatim — see ARCHITECTURE.md §17.6
//  for auth headers and §28.7 for SDK telemetry headers):
//
//    X-WORKSPACE-ID:       <PyrxConfig.workspaceId.uuidString>
//    X-API-KEY:            <PyrxConfig.apiKey>            // psk_{env}_{hex32}
//    X-PYRX-SDK-VERSION:   <PyrxConstants.sdkVersion>
//    X-PYRX-SDK-PLATFORM:  ios
//    Content-Type:         application/json
//
//  Environment is NOT carried as a header — the server derives it from the
//  API key prefix (`psk_live_` vs `psk_test_`). Endpoints that need an
//  explicit `environment` field (identify, alias, devices) carry it in the
//  JSON body via the `WireEnvironment` codable.
//

import Foundation

/// Typed JSON HTTP client. Construct via `HTTPClient(config:session:)` and
/// keep the instance for the lifetime of the SDK (cheap — no state besides
/// the encoder / decoder pair). Thread-safe via `Sendable` conformance.
public final class HTTPClient: @unchecked Sendable {

    // MARK: - Endpoint paths
    //
    // Centralised so a future server-side rename only changes one constant.
    // These match `app/routers/*.py` route prefixes verbatim.
    public enum Endpoint: String, Sendable {
        case devicesRegister = "/v1/devices"
        case identify = "/v1/identify"
        case alias = "/v1/alias"
        case events = "/v1/events"
        case pushOpened = "/v1/push/opened"
        case pushClick = "/v1/push/click"
    }

    // MARK: - Header names (canonical wire surface)
    public enum HeaderName {
        public static let workspaceId = "X-WORKSPACE-ID"
        public static let apiKey = "X-API-KEY"
        public static let sdkVersion = "X-PYRX-SDK-VERSION"
        public static let sdkPlatform = "X-PYRX-SDK-PLATFORM"
        public static let contentType = "Content-Type"
    }

    // MARK: - State

    private let config: PyrxConfig
    private let session: HTTPSession
    private let timeout: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - config:  validated SDK configuration (carries workspaceId + apiKey + baseUrl).
    ///   - session: transport seam. Defaults to `URLSession.shared` in production;
    ///              tests inject a `MockHTTPSession`.
    ///   - timeout: per-request timeout in seconds. Defaults to 10s — short
    ///              enough that an offline device sees the failure quickly and
    ///              enqueues for retry (PR 3); long enough to survive a slow
    ///              3G handshake.
    public init(
        config: PyrxConfig,
        session: HTTPSession = URLSession.shared,
        timeout: TimeInterval = 10
    ) {
        self.config = config
        self.session = session
        self.timeout = timeout
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        // No date strategy — the wire format uses ISO-8601 strings for any
        // datetime field (occurred_at, last_seen_at, etc.) and we surface
        // them as `String` on Codables so callers can choose their own
        // ISO8601DateFormatter / DateFormatter without us picking one.
    }

    // MARK: - Public POST

    /// POST `endpoint` with an `Encodable` body and decode the response into `R`.
    ///
    /// - Throws: `PyrxError.network(.transport(...))` on URLSession failure,
    ///           `PyrxError.network(.httpStatus(...))` on non-2xx,
    ///           `PyrxError.network(.invalidResponse)` if the response is not
    ///           `HTTPURLResponse`,
    ///           `PyrxError.network(.decode(...))` on JSON decode failure.
    public func post<Body: Encodable, Response: Decodable>(
        _ endpoint: Endpoint,
        body: Body,
        responseType: Response.Type = Response.self
    ) async throws -> Response {
        let request = try buildRequest(endpoint: endpoint, body: body)
        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
        return try decode(data: data, as: Response.self)
    }

    /// POST `endpoint` with an `Encodable` body and discard the response body.
    /// Use for endpoints whose 200/202 response carries no info the SDK needs
    /// to surface (telemetry callbacks, ack-only writes).
    public func post<Body: Encodable>(
        _ endpoint: Endpoint,
        body: Body
    ) async throws {
        let request = try buildRequest(path: endpoint.rawValue, body: body)
        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
    }

    /// POST to an arbitrary path with an `Encodable` body and discard the
    /// response body. Used for endpoints whose path carries a dynamic
    /// component (e.g. `/v1/contacts/{external_id}/delete` for the GDPR
    /// cascade in `PrivacyManager.deleteUser`).
    ///
    /// Internal — public surface is `Endpoint`-typed. Callers responsible
    /// for URL-encoding any path segments they substitute in.
    func postPath<Body: Encodable>(
        _ path: String,
        body: Body
    ) async throws {
        let request = try buildRequest(path: path, body: body)
        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
    }

    // MARK: - Request construction

    /// Build a `URLRequest` for `endpoint` with `body` JSON-encoded.
    ///
    /// Internal access so unit tests can assert header injection without
    /// going through `perform(_:)`.
    func buildRequest<Body: Encodable>(
        endpoint: Endpoint,
        body: Body
    ) throws -> URLRequest {
        try buildRequest(path: endpoint.rawValue, body: body)
    }

    /// Path-based overload — used by `postPath` for dynamic endpoints.
    func buildRequest<Body: Encodable>(
        path: String,
        body: Body
    ) throws -> URLRequest {
        let url = config.baseUrl.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"

        // Required headers — every PYRX SDK call carries the same 5.
        request.setValue(config.workspaceId.uuidString, forHTTPHeaderField: HeaderName.workspaceId)
        request.setValue(config.apiKey, forHTTPHeaderField: HeaderName.apiKey)
        request.setValue(PyrxConstants.sdkVersion, forHTTPHeaderField: HeaderName.sdkVersion)
        request.setValue(PyrxConstants.platform, forHTTPHeaderField: HeaderName.sdkPlatform)
        request.setValue("application/json", forHTTPHeaderField: HeaderName.contentType)

        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            // Encode failure is an SDK bug (we control every Encodable shape)
            // — surface as a decode-ish error rather than crashing.
            throw PyrxError.network(.decode(underlying: error))
        }

        return request
    }

    // MARK: - Internals

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw PyrxError.network(.transport(underlying: error))
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PyrxError.network(.invalidResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PyrxError.network(.httpStatus(statusCode: http.statusCode, body: data))
        }
    }

    private func decode<R: Decodable>(data: Data, as: R.Type) throws -> R {
        do {
            return try decoder.decode(R.self, from: data)
        } catch {
            throw PyrxError.network(.decode(underlying: error))
        }
    }
}

// MARK: - Internal URL-extension diagnostic

extension URL {
    /// Convenience used in tests to compare path-only without the base host.
    func pathOnly() -> String {
        path
    }
}
