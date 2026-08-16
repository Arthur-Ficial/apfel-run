import Foundation
import Testing
@testable import ApfelRunCore

@Suite("OAuthFlow - DCR, authorization URL, code exchange, refresh")
struct OAuthFlowTests {
    let redirectURI = "http://127.0.0.1:49152/callback"
    let resource = "https://mcp.example.com/mcp"
    let metadata = AuthServerMetadata(issuer: Fixtures.asURL,
                                      authorizationEndpoint: "\(Fixtures.asURL)/authorize",
                                      tokenEndpoint: "\(Fixtures.asURL)/token",
                                      registrationEndpoint: "\(Fixtures.asURL)/register",
                                      codeChallengeMethodsSupported: ["S256"])

    func flow(_ t: FakeTransport,
              clock: AuthClock = FixedClock(),
              random: RandomBytesProviding = SystemRandomBytes()) -> OAuthFlow {
        OAuthFlow(transport: t, clock: clock, random: random)
    }

    func formBody(_ request: HTTPRequestData) -> [String: String] {
        guard let body = request.body, let s = String(data: body, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])
            out[key] = value
        }
        return out
    }

    // MARK: - DCR

    @Test("DCR sends RFC 7591 body with loopback redirect and token_endpoint_auth_method none")
    func dcrBody() async throws {
        let t = FakeTransport(responses: [
            "POST \(Fixtures.asURL)/register": FakeTransport.json(201, ["client_id": "c1"]),
        ])
        let response = try await flow(t).register(metadata: metadata, redirectURI: redirectURI)
        #expect(response.clientID == "c1")
        #expect(t.sentRequests.count == 1)
        let request = t.sentRequests[0]
        #expect(request.headers["Content-Type"] == "application/json")
        let json = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
        #expect(json?["redirect_uris"] as? [String] == [redirectURI])
        #expect((json?["grant_types"] as? [String] ?? []).contains("authorization_code"))
        #expect((json?["grant_types"] as? [String] ?? []).contains("refresh_token"))
        #expect(json?["client_name"] as? String == "apfel-run")
        #expect(json?["token_endpoint_auth_method"] as? String == "none")
    }

    @Test("DCR failure surfaces registrationFailed with server error body")
    func dcrFailure() async throws {
        let t = FakeTransport(responses: [
            "POST \(Fixtures.asURL)/register": FakeTransport.json(400, ["error": "invalid_client_metadata"]),
        ])
        do {
            _ = try await flow(t).register(metadata: metadata, redirectURI: redirectURI)
            Issue.record("expected registrationFailed")
        } catch let e as AuthError {
            guard case .registrationFailed(let detail) = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            #expect(detail.contains("invalid_client_metadata"))
        }
    }

    @Test("no registration_endpoint -> registrationFailed with actionable message")
    func noRegistrationEndpoint() async throws {
        var meta = metadata
        meta.registrationEndpoint = nil
        let t = FakeTransport()
        do {
            _ = try await flow(t).register(metadata: meta, redirectURI: redirectURI)
            Issue.record("expected registrationFailed")
        } catch let e as AuthError {
            guard case .registrationFailed(let detail) = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            #expect(detail.contains("registration_endpoint"))
        }
        #expect(t.sentRequests.isEmpty)
    }

    // MARK: - Authorization URL

    @Test("authorizationURL contains exact query set")
    func authorizationURLQuery() throws {
        let pkce = PKCE.generate(random: FixedRandom(bytes: [UInt8](repeating: 0x07, count: 32)))
        let url = flow(FakeTransport()).authorizationURL(metadata: metadata,
                                                         clientID: "c1",
                                                         redirectURI: redirectURI,
                                                         pkce: pkce,
                                                         state: "STATE1",
                                                         resource: resource,
                                                         scope: "notes.read")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(url.absoluteString.hasPrefix("\(Fixtures.asURL)/authorize?"))
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "c1")
        #expect(query["redirect_uri"] == redirectURI)
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "STATE1")
        #expect(query["resource"] == resource)
        #expect(query["scope"] == "notes.read")
        // Nothing else unexpected
        let expected: Set<String> = ["response_type", "client_id", "redirect_uri", "code_challenge",
                                     "code_challenge_method", "state", "resource", "scope"]
        #expect(Set(query.keys) == expected)
    }

    @Test("authorizationURL omits scope when nil")
    func authorizationURLNoScope() {
        let pkce = PKCE.generate(random: FixedRandom(bytes: [UInt8](repeating: 0x07, count: 32)))
        let url = flow(FakeTransport()).authorizationURL(metadata: metadata,
                                                         clientID: "c1",
                                                         redirectURI: redirectURI,
                                                         pkce: pkce,
                                                         state: "S",
                                                         resource: resource,
                                                         scope: nil)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(!(components?.queryItems ?? []).contains { $0.name == "scope" })
    }

    // MARK: - PKCE support gate

    @Test("metadata advertising only plain challenge -> pkceUnsupported")
    func pkcePlainOnly() {
        var meta = metadata
        meta.codeChallengeMethodsSupported = ["plain"]
        #expect(throws: AuthError.pkceUnsupported) {
            try OAuthFlow.checkPKCESupport(meta)
        }
    }

    @Test("absent code_challenge_methods_supported -> proceed with S256")
    func pkceAbsentList() {
        // F10: the field is OPTIONAL in RFC 8414; only an explicit list that
        // excludes S256 is refused.
        var meta = metadata
        meta.codeChallengeMethodsSupported = nil
        #expect(throws: Never.self) {
            try OAuthFlow.checkPKCESupport(meta)
        }
    }

    // MARK: - Code exchange

    @Test("exchangeCode posts urlencoded grant with verifier and resource")
    func exchangePostsForm() async throws {
        let t = FakeTransport(responses: [
            "POST \(Fixtures.asURL)/token": FakeTransport.json(200, [
                "access_token": "at1", "token_type": "Bearer", "expires_in": 3600,
                "refresh_token": "rt1",
            ]),
        ])
        let pkce = PKCE.generate(random: FixedRandom(bytes: [UInt8](repeating: 0x07, count: 32)))
        let response = try await flow(t).exchangeCode("CODE9",
                                                      metadata: metadata,
                                                      clientID: "c1",
                                                      clientSecret: nil,
                                                      redirectURI: redirectURI,
                                                      pkce: pkce,
                                                      resource: resource)
        #expect(response.accessToken == "at1")
        #expect(response.refreshToken == "rt1")
        let request = t.sentRequests[0]
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let form = formBody(request)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "CODE9")
        #expect(form["redirect_uri"] == redirectURI)
        #expect(form["code_verifier"] == pkce.verifier)
        #expect(form["client_id"] == "c1")
        #expect(form["resource"] == resource)
        #expect(form["client_secret"] == nil)
    }

    @Test("exchange sends client_secret when DCR issued one (client_secret_post)")
    func exchangeWithClientSecret() async throws {
        // R7: some ASs issue confidential clients from DCR despite auth method
        // "none" - store the secret and send client_secret_post.
        let t = FakeTransport(responses: [
            "POST \(Fixtures.asURL)/token": FakeTransport.json(200, [
                "access_token": "at1", "token_type": "Bearer",
            ]),
        ])
        let pkce = PKCE.generate(random: FixedRandom(bytes: [UInt8](repeating: 0x07, count: 32)))
        _ = try await flow(t).exchangeCode("CODE9",
                                          metadata: metadata,
                                          clientID: "c1",
                                          clientSecret: "sec1",
                                          redirectURI: redirectURI,
                                          pkce: pkce,
                                          resource: resource)
        #expect(formBody(t.sentRequests[0])["client_secret"] == "sec1")
    }

    @Test("exchange OAuth error json -> exchangeFailed(oauthError:)")
    func exchangeOAuthError() async throws {
        let t = FakeTransport(responses: [
            "POST \(Fixtures.asURL)/token": FakeTransport.json(400, ["error": "invalid_grant"]),
        ])
        let pkce = PKCE.generate(random: FixedRandom(bytes: [UInt8](repeating: 0x07, count: 32)))
        do {
            _ = try await flow(t).exchangeCode("CODE9",
                                              metadata: metadata,
                                              clientID: "c1",
                                              clientSecret: nil,
                                              redirectURI: redirectURI,
                                              pkce: pkce,
                                              resource: resource)
            Issue.record("expected exchangeFailed")
        } catch let e as AuthError {
            #expect(e == .exchangeFailed(oauthError: "invalid_grant"))
        }
    }

    @Test("token response with token_type != Bearer -> exchangeFailed")
    func nonBearerTokenType() async throws {
        let t = FakeTransport(responses: [
            "POST \(Fixtures.asURL)/token": FakeTransport.json(200, [
                "access_token": "at1", "token_type": "mac",
            ]),
        ])
        let pkce = PKCE.generate(random: FixedRandom(bytes: [UInt8](repeating: 0x07, count: 32)))
        do {
            _ = try await flow(t).exchangeCode("CODE9",
                                              metadata: metadata,
                                              clientID: "c1",
                                              clientSecret: nil,
                                              redirectURI: redirectURI,
                                              pkce: pkce,
                                              resource: resource)
            Issue.record("expected exchangeFailed")
        } catch let e as AuthError {
            guard case .exchangeFailed(let oauthError) = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            #expect(oauthError.contains("mac"))
        }
    }

    // MARK: - Refresh

    func storedCredential(refreshToken: String? = "r1") -> StoredCredential {
        StoredCredential(accessToken: "old-at",
                         refreshToken: refreshToken,
                         expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
                         tokenEndpoint: URL(string: "\(Fixtures.asURL)/token")!,
                         clientID: "c1",
                         resource: resource,
                         obtainedAt: Date(timeIntervalSince1970: 1_600_000_000))
    }

    @Test("refresh posts refresh_token grant and returns rotated refresh token")
    func refreshRotation() async throws {
        let t = FakeTransport(responses: [
            "POST \(Fixtures.asURL)/token": FakeTransport.json(200, [
                "access_token": "new-at", "token_type": "Bearer", "expires_in": 3600,
                "refresh_token": "r2",
            ]),
        ])
        let f = flow(t)
        let old = storedCredential()
        let response = try await f.refresh(credential: old, resource: resource)
        #expect(response.refreshToken == "r2")
        let form = formBody(t.sentRequests[0])
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["refresh_token"] == "r1")
        #expect(form["client_id"] == "c1")
        #expect(form["resource"] == resource)
        // OAuth 2.1 rotation: the rebuilt credential carries the NEW one.
        let updated = f.credential(from: response,
                                   tokenEndpoint: old.tokenEndpoint,
                                   clientID: old.clientID,
                                   resource: resource,
                                   previous: old)
        #expect(updated.refreshToken == "r2")
        #expect(updated.accessToken == "new-at")
    }

    @Test("refresh response without refresh_token keeps the old one")
    func refreshKeepsOldToken() async throws {
        let t = FakeTransport(responses: [
            "POST \(Fixtures.asURL)/token": FakeTransport.json(200, [
                "access_token": "new-at", "token_type": "Bearer",
            ]),
        ])
        let f = flow(t)
        let old = storedCredential()
        let response = try await f.refresh(credential: old, resource: resource)
        let updated = f.credential(from: response,
                                   tokenEndpoint: old.tokenEndpoint,
                                   clientID: old.clientID,
                                   resource: resource,
                                   previous: old)
        #expect(updated.refreshToken == "r1")
    }

    @Test("refresh invalid_grant -> refreshFailed")
    func refreshInvalidGrant() async throws {
        let t = FakeTransport(responses: [
            "POST \(Fixtures.asURL)/token": FakeTransport.json(400, ["error": "invalid_grant"]),
        ])
        do {
            _ = try await flow(t).refresh(credential: storedCredential(), resource: resource)
            Issue.record("expected refreshFailed")
        } catch let e as AuthError {
            guard case .refreshFailed(_, let oauthError) = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            #expect(oauthError == "invalid_grant")
        }
    }

    // MARK: - Credential construction

    @Test("credential(from:) computes expiresAt from clock.now + expires_in")
    func credentialExpiry() {
        let clock = FixedClock(now: Date(timeIntervalSince1970: 1_000_000))
        let f = OAuthFlow(transport: FakeTransport(), clock: clock, random: SystemRandomBytes())
        let response = TokenResponse(accessToken: "at", tokenType: "Bearer", expiresIn: 3600)
        let credential = f.credential(from: response,
                                      tokenEndpoint: URL(string: "\(Fixtures.asURL)/token")!,
                                      clientID: "c1",
                                      resource: resource,
                                      previous: nil)
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_003_600))
        #expect(credential.obtainedAt == clock.now)
        #expect(credential.accessToken == "at")
        #expect(credential.clientID == "c1")
        #expect(credential.resource == resource)
    }

    @Test("credential(from:) with no expires_in has nil expiresAt")
    func credentialNoExpiry() {
        let f = flow(FakeTransport())
        let response = TokenResponse(accessToken: "at", tokenType: "Bearer")
        let credential = f.credential(from: response,
                                      tokenEndpoint: URL(string: "\(Fixtures.asURL)/token")!,
                                      clientID: "c1",
                                      resource: nil,
                                      previous: nil)
        #expect(credential.expiresAt == nil)
    }
}
