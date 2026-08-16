import Foundation
@testable import ApfelRunCore

/// Scripted HTTP transport: maps "<METHOD> <absolute-url>" to a canned
/// response and records every request it saw, in order.
///
/// Test-only fixture; mutated from a single test thread, hence the
/// @unchecked Sendable (no concurrent access happens in the suites).
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private(set) var sentRequests: [HTTPRequestData] = []
    var responses: [String: HTTPResponseData]
    /// Response used when no key matches (default: 404).
    var fallback: HTTPResponseData

    init(responses: [String: HTTPResponseData] = [:],
         fallback: HTTPResponseData = HTTPResponseData(status: 404)) {
        self.responses = responses
        self.fallback = fallback
    }

    func send(_ request: HTTPRequestData) async throws -> HTTPResponseData {
        sentRequests.append(request)
        let key = "\(request.method) \(request.url.absoluteString)"
        return responses[key] ?? fallback
    }

    // MARK: - Helpers

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponseData {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return HTTPResponseData(status: status,
                                headers: ["Content-Type": "application/json"],
                                body: data)
    }
}

// MARK: - Canned metadata builders

enum Fixtures {
    static let mcpURL = URL(string: "https://mcp.example.com/mcp")!
    static let asURL = "https://as.example.com"

    static func prmJSON(authServers: [String] = [asURL],
                        scopes: [String]? = nil) -> HTTPResponseData {
        var obj: [String: Any] = [
            "resource": mcpURL.absoluteString,
            "authorization_servers": authServers,
        ]
        if let scopes { obj["scopes_supported"] = scopes }
        return FakeTransport.json(200, obj)
    }

    static func asMetadataJSON(issuer: String = asURL,
                               authorizationEndpoint: String = "\(asURL)/authorize",
                               tokenEndpoint: String = "\(asURL)/token",
                               registrationEndpoint: String? = "\(asURL)/register",
                               codeChallengeMethods: [String]? = ["S256"]) -> HTTPResponseData {
        var obj: [String: Any] = [
            "issuer": issuer,
            "authorization_endpoint": authorizationEndpoint,
            "token_endpoint": tokenEndpoint,
        ]
        if let registrationEndpoint { obj["registration_endpoint"] = registrationEndpoint }
        if let codeChallengeMethods { obj["code_challenge_methods_supported"] = codeChallengeMethods }
        return FakeTransport.json(200, obj)
    }

    static func challenge401(resourceMetadata: String) -> HTTPResponseData {
        HTTPResponseData(status: 401,
                         headers: ["WWW-Authenticate": "Bearer resource_metadata=\"\(resourceMetadata)\""],
                         body: Data())
    }
}
