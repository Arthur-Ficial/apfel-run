import Foundation
import Testing
@testable import ApfelRunCore

@Suite("LaunchTokenResolver - refresh-on-launch + precedence")
struct LaunchTokenResolverTests {
    let serverURL = "https://mcp.example.com/mcp"
    let tokenEndpoint = URL(string: "https://as.example.com/token")!
    let now = Date(timeIntervalSince1970: 1_755_000_000)

    func oauthProfile(tokenEnv: String? = nil,
                      sharedTokenEnv: String? = nil,
                      mode: ProfileMode? = nil,
                      servers: [MCPServer]? = nil) -> Profile {
        let list = servers ?? [MCPServer(path: serverURL, enabled: true, tokenEnv: tokenEnv, auth: .oauth)]
        return Profile(mode: mode, mcp: MCPSettings(tokenEnv: sharedTokenEnv, servers: list))
    }

    func flow(_ t: FakeTransport = FakeTransport()) -> OAuthFlow {
        OAuthFlow(transport: t, clock: FixedClock(now: now), random: SystemRandomBytes())
    }

    func credential(accessToken: String = "kc-at",
                    refreshToken: String? = "kc-rt",
                    expiresAt: Date?) -> StoredCredential {
        StoredCredential(accessToken: accessToken,
                         refreshToken: refreshToken,
                         expiresAt: expiresAt,
                         tokenEndpoint: tokenEndpoint,
                         clientID: "c1",
                         resource: serverURL,
                         obtainedAt: now.addingTimeInterval(-1000))
    }

    @Test("no oauth servers -> nil (no store access)")
    func noOAuthServers() async throws {
        let store = InMemoryTokenStore()
        let profile = Profile(mcp: MCPSettings(servers: [MCPServer(path: "/plain/mcp.py")]))
        let resolved = try await LaunchTokenResolver.resolve(profile: profile,
                                                             environment: [:],
                                                             store: store,
                                                             flow: flow(),
                                                             clock: FixedClock(now: now))
        #expect(resolved == nil)
        #expect(store.loadCount == 0)
    }

    @Test("one oauth server, valid token -> .keychain token")
    func validKeychainToken() async throws {
        let store = InMemoryTokenStore()
        try store.save(credential(expiresAt: now.addingTimeInterval(3600)), server: serverURL)
        let resolved = try await LaunchTokenResolver.resolve(profile: oauthProfile(),
                                                             environment: [:],
                                                             store: store,
                                                             flow: flow(),
                                                             clock: FixedClock(now: now))
        #expect(resolved?.token == "kc-at")
        #expect(resolved?.server == normalizeServerKey(serverURL))
        #expect(resolved?.source == .keychain)
    }

    @Test("one oauth server, expired+refreshable -> refreshes, persists rotated credential, returns .refreshedKeychain")
    func expiredRefreshes() async throws {
        let store = InMemoryTokenStore()
        try store.save(credential(expiresAt: now.addingTimeInterval(-10)), server: serverURL)
        let t = FakeTransport(responses: [
            "POST \(tokenEndpoint.absoluteString)": FakeTransport.json(200, [
                "access_token": "fresh-at", "token_type": "Bearer",
                "expires_in": 3600, "refresh_token": "rotated-rt",
            ]),
        ])
        let resolved = try await LaunchTokenResolver.resolve(profile: oauthProfile(),
                                                             environment: [:],
                                                             store: store,
                                                             flow: flow(t),
                                                             clock: FixedClock(now: now))
        #expect(resolved?.token == "fresh-at")
        #expect(resolved?.source == .refreshedKeychain)
        // Rotation persisted BEFORE execve: store now holds new access AND new refresh token.
        #expect(store.saveCount == 2)
        let persisted = try store.load(server: serverURL)
        #expect(persisted?.accessToken == "fresh-at")
        #expect(persisted?.refreshToken == "rotated-rt")
    }

    @Test("expired, refresh fails -> throws refreshFailed with server url in message")
    func refreshFails() async throws {
        let store = InMemoryTokenStore()
        try store.save(credential(expiresAt: now.addingTimeInterval(-10)), server: serverURL)
        let t = FakeTransport(responses: [
            "POST \(tokenEndpoint.absoluteString)": FakeTransport.json(400, ["error": "invalid_grant"]),
        ])
        do {
            _ = try await LaunchTokenResolver.resolve(profile: oauthProfile(),
                                                      environment: [:],
                                                      store: store,
                                                      flow: flow(t),
                                                      clock: FixedClock(now: now))
            Issue.record("expected refreshFailed")
        } catch let e as AuthError {
            guard case .refreshFailed = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            #expect(e.message.contains(serverURL))
            #expect(e.message.contains("invalid_grant"))
        }
    }

    @Test("expired, no refresh token -> throws noCredential-style error telling user to re-login")
    func expiredNoRefresh() async throws {
        let store = InMemoryTokenStore()
        try store.save(credential(refreshToken: nil, expiresAt: now.addingTimeInterval(-10)),
                       server: serverURL)
        do {
            _ = try await LaunchTokenResolver.resolve(profile: oauthProfile(),
                                                      environment: [:],
                                                      store: store,
                                                      flow: flow(),
                                                      clock: FixedClock(now: now))
            Issue.record("expected error")
        } catch let e as AuthError {
            #expect(e.message.contains("apfel-run auth login"))
        }
    }

    @Test("oauth server with per-server token_env set and non-empty -> .perServerEnv wins, no keychain read")
    func perServerEnvWins() async throws {
        let store = InMemoryTokenStore()
        let resolved = try await LaunchTokenResolver.resolve(profile: oauthProfile(tokenEnv: "MY_MCP_TOKEN"),
                                                             environment: ["MY_MCP_TOKEN": "env-token"],
                                                             store: store,
                                                             flow: flow(),
                                                             clock: FixedClock(now: now))
        #expect(resolved?.token == "env-token")
        #expect(resolved?.source == .perServerEnv("MY_MCP_TOKEN"))
        #expect(store.loadCount == 0)
    }

    @Test("oauth server, nothing in keychain, shared mcp.token_env set -> .sharedEnv fallback")
    func sharedEnvFallback() async throws {
        let store = InMemoryTokenStore()
        let resolved = try await LaunchTokenResolver.resolve(profile: oauthProfile(sharedTokenEnv: "SHARED_TOKEN"),
                                                             environment: ["SHARED_TOKEN": "shared-token"],
                                                             store: store,
                                                             flow: flow(),
                                                             clock: FixedClock(now: now))
        #expect(resolved?.token == "shared-token")
        #expect(resolved?.source == .sharedEnv("SHARED_TOKEN"))
    }

    @Test("oauth server, nothing anywhere -> throws noCredential with 'apfel-run auth login' hint")
    func nothingAnywhere() async throws {
        let store = InMemoryTokenStore()
        do {
            _ = try await LaunchTokenResolver.resolve(profile: oauthProfile(),
                                                      environment: [:],
                                                      store: store,
                                                      flow: flow(),
                                                      clock: FixedClock(now: now))
            Issue.record("expected noCredential")
        } catch let e as AuthError {
            guard case .noCredential(let server) = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            #expect(server == serverURL)
            #expect(e.message.contains("apfel-run auth login"))
        }
    }

    @Test("two enabled oauth servers -> throws multipleOAuthServers listing both urls")
    func twoOAuthServers() async throws {
        let servers = [
            MCPServer(path: "https://a.example/mcp", enabled: true, auth: .oauth),
            MCPServer(path: "https://b.example/mcp", enabled: true, auth: .oauth),
        ]
        do {
            _ = try await LaunchTokenResolver.resolve(profile: oauthProfile(servers: servers),
                                                      environment: [:],
                                                      store: InMemoryTokenStore(),
                                                      flow: flow(),
                                                      clock: FixedClock(now: now))
            Issue.record("expected multipleOAuthServers")
        } catch let e as AuthError {
            #expect(e == .multipleOAuthServers(["https://a.example/mcp", "https://b.example/mcp"]))
        }
    }

    @Test("disabled oauth server does not count toward the >1 rule")
    func disabledDoesNotCount() async throws {
        let store = InMemoryTokenStore()
        try store.save(credential(expiresAt: now.addingTimeInterval(3600)), server: serverURL)
        let servers = [
            MCPServer(path: serverURL, enabled: true, auth: .oauth),
            MCPServer(path: "https://b.example/mcp", enabled: false, auth: .oauth),
        ]
        let resolved = try await LaunchTokenResolver.resolve(profile: oauthProfile(servers: servers),
                                                             environment: [:],
                                                             store: store,
                                                             flow: flow(),
                                                             clock: FixedClock(now: now))
        #expect(resolved?.source == .keychain)
    }

    // MARK: - F12: serve-mode expiry warning

    @Test("serve mode with expiring credential -> warning string with ISO8601 expiry and restart hint")
    func serveExpiryWarning() {
        let expiry = Date(timeIntervalSince1970: 1_755_003_600)
        let token = ResolvedLaunchToken(token: "t", server: serverURL,
                                        source: .keychain, expiresAt: expiry)
        let warning = LaunchTokenResolver.serveExpiryWarning(mode: .serve, launchToken: token)
        #expect(warning != nil)
        #expect(warning?.contains(serverURL) == true)
        #expect(warning?.contains("restart apfel-run to refresh") == true)
        // ISO8601 UTC timestamp
        #expect(warning?.contains("Z") == true)
    }

    @Test("non-serve mode or nil expiresAt -> no warning")
    func noWarningOutsideServe() {
        let expiry = Date(timeIntervalSince1970: 1_755_003_600)
        let withExpiry = ResolvedLaunchToken(token: "t", server: serverURL,
                                             source: .keychain, expiresAt: expiry)
        let withoutExpiry = ResolvedLaunchToken(token: "t", server: serverURL,
                                                source: .keychain, expiresAt: nil)
        #expect(LaunchTokenResolver.serveExpiryWarning(mode: .single, launchToken: withExpiry) == nil)
        #expect(LaunchTokenResolver.serveExpiryWarning(mode: nil, launchToken: withExpiry) == nil)
        #expect(LaunchTokenResolver.serveExpiryWarning(mode: .serve, launchToken: withoutExpiry) == nil)
        #expect(LaunchTokenResolver.serveExpiryWarning(mode: .serve, launchToken: nil) == nil)
    }
}
