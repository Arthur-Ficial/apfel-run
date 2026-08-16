import Foundation
import Security

// MARK: - Protocol seams
//
// Every seam exists so the OAuth state machine is a pure function of injected
// effects and the whole protocol dance is unit-testable with fakes. The
// executable target owns the only impure implementations (URLSession, browser,
// loopback socket); unit tests never touch the network or the real Keychain.

/// Minimal HTTP transport. Own types, not URLRequest, so fakes are trivial
/// and ApfelRunCore does not force URLSession into unit tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequestData) async throws -> HTTPResponseData
}

public struct HTTPRequestData: Equatable, Sendable {
    public var method: String          // "GET" | "POST"
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponseData: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup (HTTP header names are case-insensitive).
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// Time seam - expiry math must be deterministic in tests.
public protocol AuthClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: AuthClock {
    public var now: Date { Date() }
    public init() {}
}

/// CSPRNG seam - PKCE verifier + state must be assertable in tests.
public protocol RandomBytesProviding: Sendable {
    func randomBytes(_ count: Int) -> [UInt8]
}

public struct SystemRandomBytes: RandomBytesProviding {
    public init() {}
    public func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }
}

// MARK: - Loopback exception (F13)

/// apfel core's exact unconditional loopback rule (apfel MCPClient.swift:258-266):
/// `127.0.0.1`, `::1`, and `localhost` may use plain http. No override knob.
public func isLoopbackHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "127.0.0.1" || host == "::1" || host == "localhost"
}

/// True when the URL is https, or http to a loopback host (F13).
public func isSecureOrLoopback(_ url: URL) -> Bool {
    switch url.scheme?.lowercased() {
    case "https": return true
    case "http": return isLoopbackHost(url.host)
    default: return false
    }
}

// MARK: - Errors

/// Typed OAuth errors. Cases carry server URLs and OAuth error codes,
/// never token material (enforced by construction).
public enum AuthError: Error, Equatable, Sendable {
    case notHTTPS(url: String)
    case endpointsNotHTTPS(which: String)
    case discoveryFailed(rung: String, detail: String)
    case registrationFailed(detail: String)
    case stateMismatch
    case exchangeFailed(oauthError: String)
    case refreshFailed(server: String, oauthError: String)
    case noCredential(server: String)
    case multipleOAuthServers([String])
    case callbackTimeout
    case pkceUnsupported
    case callbackError(oauthError: String)
    case notCallback
    case keychainError(status: Int32)

    /// One-line human message (stderr surface).
    public var message: String {
        switch self {
        case .notHTTPS(let url):
            return "refusing non-https MCP URL: \(url)"
        case .endpointsNotHTTPS(let which):
            return "authorization server metadata advertises a non-https \(which) - refusing"
        case .discoveryFailed(let rung, let detail):
            return "discovery failed (\(rung)): \(detail)"
        case .registrationFailed(let detail):
            return "dynamic client registration failed: \(detail)"
        case .stateMismatch:
            return "OAuth callback state mismatch - possible CSRF, aborting login"
        case .exchangeFailed(let oauthError):
            return "authorization code exchange failed (\(oauthError))"
        case .refreshFailed(let server, let oauthError):
            return "token for \(server) expired and refresh failed (\(oauthError)) - run: apfel-run auth login \(server)"
        case .noCredential(let server):
            return "no OAuth credential stored for \(server) - run: apfel-run auth login \(server)"
        case .multipleOAuthServers(let servers):
            return "profile enables \(servers.count) OAuth MCP servers but apfel supports one MCP token today (apfel#386) - disable one or move it to its own profile: \(servers.joined(separator: ", "))"
        case .callbackTimeout:
            return "timed out waiting for the OAuth callback - re-run: apfel-run auth login"
        case .pkceUnsupported:
            return "authorization server does not support PKCE S256 - refusing (S256 is mandatory)"
        case .callbackError(let oauthError):
            return "authorization was not granted (\(oauthError))"
        case .notCallback:
            return "not an OAuth callback request"
        case .keychainError(let status):
            return "keychain operation failed (OSStatus \(status))"
        }
    }
}

// MARK: - Wire types (RFC 9728 / RFC 8414 / RFC 7591 / RFC 6749)

/// RFC 9728 protected-resource metadata.
public struct ProtectedResourceMetadata: Codable, Equatable, Sendable {
    public var resource: String?
    public var authorizationServers: [String]
    public var scopesSupported: [String]?

    public init(resource: String? = nil,
                authorizationServers: [String] = [],
                scopesSupported: [String]? = nil) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resource = try c.decodeIfPresent(String.self, forKey: .resource)
        self.authorizationServers = try c.decodeIfPresent([String].self, forKey: .authorizationServers) ?? []
        self.scopesSupported = try c.decodeIfPresent([String].self, forKey: .scopesSupported)
    }
}

/// RFC 8414 authorization-server metadata (also matches OIDC discovery).
public struct AuthServerMetadata: Codable, Equatable, Sendable {
    public var issuer: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var registrationEndpoint: String?
    public var codeChallengeMethodsSupported: [String]?
    public var grantTypesSupported: [String]?

    public init(issuer: String,
                authorizationEndpoint: String,
                tokenEndpoint: String,
                registrationEndpoint: String? = nil,
                codeChallengeMethodsSupported: [String]? = nil,
                grantTypesSupported: [String]? = nil) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.grantTypesSupported = grantTypesSupported
    }

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case grantTypesSupported = "grant_types_supported"
    }

    /// F1: https required on authorization/token/registration endpoints.
    /// Loopback hosts over http are exempt (F13, mirrors apfel MCPClient).
    public func validateEndpoints() throws {
        let endpoints: [(String, String?)] = [
            ("authorization_endpoint", authorizationEndpoint),
            ("token_endpoint", tokenEndpoint),
            ("registration_endpoint", registrationEndpoint),
        ]
        for (name, value) in endpoints {
            guard let value else { continue }
            guard let url = URL(string: value), isSecureOrLoopback(url) else {
                throw AuthError.endpointsNotHTTPS(which: name)
            }
        }
    }
}

/// RFC 7591 dynamic client registration request.
public struct ClientRegistrationRequest: Codable, Equatable, Sendable {
    public var redirectURIs: [String]
    public var clientName: String
    public var grantTypes: [String]
    public var responseTypes: [String]
    public var tokenEndpointAuthMethod: String

    public init(redirectURIs: [String],
                clientName: String = "apfel-run",
                grantTypes: [String] = ["authorization_code", "refresh_token"],
                responseTypes: [String] = ["code"],
                tokenEndpointAuthMethod: String = "none") {
        self.redirectURIs = redirectURIs
        self.clientName = clientName
        self.grantTypes = grantTypes
        self.responseTypes = responseTypes
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
    }

    enum CodingKeys: String, CodingKey {
        case redirectURIs = "redirect_uris"
        case clientName = "client_name"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
    }
}

/// RFC 7591 dynamic client registration response.
public struct ClientRegistrationResponse: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

/// RFC 6749 token endpoint response.
public struct TokenResponse: Codable, Equatable, Sendable {
    public var accessToken: String
    public var tokenType: String
    public var expiresIn: Int?
    public var refreshToken: String?
    public var scope: String?

    public init(accessToken: String,
                tokenType: String = "Bearer",
                expiresIn: Int? = nil,
                refreshToken: String? = nil,
                scope: String? = nil) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

/// RFC 6749 error response body.
public struct OAuthErrorResponse: Codable, Equatable, Sendable {
    public var error: String
    public var errorDescription: String?

    public init(error: String, errorDescription: String? = nil) {
        self.error = error
        self.errorDescription = errorDescription
    }

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

// MARK: - Stored credential

public struct StoredCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?            // nil = server sent no expires_in
    public var tokenEndpoint: URL
    public var clientID: String
    public var clientSecret: String?       // R7: only when the AS issued one despite auth method "none"
    public var scope: String?
    public var resource: String?           // RFC 8707 value used at issue time
    public var obtainedAt: Date

    public init(accessToken: String,
                refreshToken: String? = nil,
                expiresAt: Date? = nil,
                tokenEndpoint: URL,
                clientID: String,
                clientSecret: String? = nil,
                scope: String? = nil,
                resource: String? = nil,
                obtainedAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.resource = resource
        self.obtainedAt = obtainedAt
    }
}
