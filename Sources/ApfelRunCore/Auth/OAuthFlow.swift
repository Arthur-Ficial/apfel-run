import Foundation

/// OAuth 2.1 protocol steps: dynamic client registration (RFC 7591),
/// authorization URL construction, authorization-code exchange, and refresh.
/// Pure request/response logic over the injected `HTTPTransport`.
public struct OAuthFlow: Sendable {
    public let transport: HTTPTransport
    public let clock: AuthClock
    public let random: RandomBytesProviding

    public init(transport: HTTPTransport, clock: AuthClock, random: RandomBytesProviding) {
        self.transport = transport
        self.clock = clock
        self.random = random
    }

    // MARK: - PKCE support gate

    /// S256-only stance: refuse ASs that explicitly advertise a method list
    /// without S256. An ABSENT list is fine (F10 - the field is OPTIONAL in
    /// RFC 8414; S256 is assumed).
    public static func checkPKCESupport(_ metadata: AuthServerMetadata) throws {
        if let methods = metadata.codeChallengeMethodsSupported, !methods.contains("S256") {
            throw AuthError.pkceUnsupported
        }
    }

    // MARK: - Dynamic client registration (RFC 7591)

    public func register(metadata: AuthServerMetadata,
                         redirectURI: String) async throws -> ClientRegistrationResponse {
        guard let registrationEndpoint = metadata.registrationEndpoint,
              let url = URL(string: registrationEndpoint) else {
            throw AuthError.registrationFailed(detail:
                "authorization server publishes no registration_endpoint - apfel-run cannot self-register; a pre-provisioned client_id escape hatch is future work (file an issue with the server name)")
        }
        let request = ClientRegistrationRequest(redirectURIs: [redirectURI])
        let body = try JSONEncoder().encode(request)
        let response = try await transport.send(HTTPRequestData(
            method: "POST", url: url,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: body))
        guard (200..<300).contains(response.status) else {
            let serverText = String(data: response.body, encoding: .utf8) ?? ""
            throw AuthError.registrationFailed(detail: "HTTP \(response.status) \(serverText)")
        }
        do {
            return try JSONDecoder().decode(ClientRegistrationResponse.self, from: response.body)
        } catch {
            throw AuthError.registrationFailed(detail: "registration response had no client_id")
        }
    }

    // MARK: - Authorization URL (pure)

    public func authorizationURL(metadata: AuthServerMetadata,
                                 clientID: String,
                                 redirectURI: String,
                                 pkce: PKCE,
                                 state: String,
                                 resource: String,
                                 scope: String?) -> URL {
        var components = URLComponents(string: metadata.authorizationEndpoint)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource),  // RFC 8707
        ]
        if let scope, !scope.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url!
    }

    // MARK: - Code exchange

    public func exchangeCode(_ code: String,
                             metadata: AuthServerMetadata,
                             clientID: String,
                             clientSecret: String?,
                             redirectURI: String,
                             pkce: PKCE,
                             resource: String) async throws -> TokenResponse {
        var form: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", pkce.verifier),
            ("client_id", clientID),
            ("resource", resource),  // RFC 8707
        ]
        if let clientSecret {
            form.append(("client_secret", clientSecret))  // R7: client_secret_post
        }
        let response = try await postForm(urlString: metadata.tokenEndpoint, form: form)
        return try parseTokenResponse(response) { oauthError in
            AuthError.exchangeFailed(oauthError: oauthError)
        }
    }

    // MARK: - Refresh

    public func refresh(credential: StoredCredential,
                        resource: String?) async throws -> TokenResponse {
        let server = credential.resource ?? credential.tokenEndpoint.absoluteString
        guard let refreshToken = credential.refreshToken else {
            throw AuthError.refreshFailed(server: server, oauthError: "no refresh token stored")
        }
        var form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", credential.clientID),
        ]
        if let resource {
            form.append(("resource", resource))  // RFC 8707
        }
        if let clientSecret = credential.clientSecret {
            form.append(("client_secret", clientSecret))
        }
        let response = try await postForm(urlString: credential.tokenEndpoint.absoluteString, form: form)
        return try parseTokenResponse(response) { oauthError in
            AuthError.refreshFailed(server: server, oauthError: oauthError)
        }
    }

    // MARK: - Credential construction

    /// Build a StoredCredential from a token response. OAuth 2.1 rotation:
    /// a new refresh_token replaces the old one; an absent refresh_token in
    /// the response keeps the previous one.
    public func credential(from response: TokenResponse,
                           tokenEndpoint: URL,
                           clientID: String,
                           clientSecret: String? = nil,
                           resource: String?,
                           previous: StoredCredential? = nil) -> StoredCredential {
        StoredCredential(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? previous?.refreshToken,
            expiresAt: response.expiresIn.map { clock.now.addingTimeInterval(TimeInterval($0)) },
            tokenEndpoint: tokenEndpoint,
            clientID: clientID,
            clientSecret: clientSecret ?? previous?.clientSecret,
            scope: response.scope ?? previous?.scope,
            resource: resource ?? previous?.resource,
            obtainedAt: clock.now)
    }

    // MARK: - Internals

    func postForm(urlString: String, form: [(String, String)]) async throws -> HTTPResponseData {
        guard let url = URL(string: urlString) else {
            throw AuthError.discoveryFailed(rung: "token endpoint", detail: "invalid URL: \(urlString)")
        }
        let body = form.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&")
        return try await transport.send(HTTPRequestData(
            method: "POST", url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded",
                      "Accept": "application/json"],
            body: Data(body.utf8)))
    }

    func parseTokenResponse(_ response: HTTPResponseData,
                            makeError: (String) -> AuthError) throws -> TokenResponse {
        guard (200..<300).contains(response.status) else {
            if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: response.body) {
                throw makeError(oauthError.error)
            }
            throw makeError("HTTP \(response.status)")
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
            throw makeError("unparseable token response")
        }
        guard token.tokenType.lowercased() == "bearer" else {
            throw makeError("unsupported token_type \(token.tokenType)")
        }
        return token
    }

    /// application/x-www-form-urlencoded value encoding.
    func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
