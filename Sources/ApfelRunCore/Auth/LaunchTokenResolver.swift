import Foundation

/// The MCP token apfel-run resolved for this launch, and where it came from.
public struct ResolvedLaunchToken: Equatable, Sendable {
    public var token: String
    public var server: String              // normalized server URL
    public var source: Source
    public var expiresAt: Date?            // for the F12 serve-mode warning

    public enum Source: Equatable, Sendable {
        case perServerEnv(String)
        case keychain
        case refreshedKeychain
        case sharedEnv(String)
    }

    public init(token: String, server: String, source: Source, expiresAt: Date? = nil) {
        self.token = token
        self.server = server
        self.source = source
        self.expiresAt = expiresAt
    }
}

/// Launch-time token resolution: refresh-before-execve, precedence rules,
/// and the >1-OAuth hard error. Pure over the injected store/flow/clock.
public enum LaunchTokenResolver {
    /// Precedence for the single enabled `auth = "oauth"` server:
    ///   1. per-server `token_env` (non-empty) - explicit override, no keychain read
    ///   2. Keychain credential (refreshed first when expired + refreshable;
    ///      the rotated credential is persisted BEFORE returning)
    ///   3. shared `mcp.token_env` (non-empty)
    ///   4. throw `noCredential` with the `apfel-run auth login` hint
    ///
    /// Returns nil when the profile has no enabled OAuth server (no store access).
    /// Throws `multipleOAuthServers` when more than one is enabled (apfel core
    /// has a single APFEL_MCP_TOKEN today - apfel#386).
    public static func resolve(profile: Profile,
                               environment: [String: String],
                               store: TokenStoring,
                               flow: OAuthFlow?,
                               clock: AuthClock) async throws -> ResolvedLaunchToken? {
        guard let mcp = profile.mcp else { return nil }
        let oauthServers = mcp.servers.filter { $0.enabled && $0.auth == .oauth }
        guard !oauthServers.isEmpty else { return nil }
        guard oauthServers.count == 1 else {
            throw AuthError.multipleOAuthServers(oauthServers.map(\.path))
        }
        let server = oauthServers[0]
        let key = normalizeServerKey(server.path)

        // 1. Per-server env override - wins, no keychain read.
        if let name = server.tokenEnv, let value = environment[name], !value.isEmpty {
            return ResolvedLaunchToken(token: value, server: key, source: .perServerEnv(name))
        }

        // 2. Keychain credential.
        let credential = try store.load(server: server.path)
        switch validity(of: credential, clock: clock) {
        case .valid(let until):
            guard let credential else { throw AuthError.noCredential(server: server.path) }
            return ResolvedLaunchToken(token: credential.accessToken, server: key,
                                       source: .keychain, expiresAt: until)

        case .expired(refreshable: true):
            guard let credential, let flow else {
                throw AuthError.refreshFailed(server: server.path,
                                              oauthError: "no refresh flow available")
            }
            do {
                let response = try await flow.refresh(credential: credential,
                                                      resource: credential.resource ?? key)
                let updated = flow.credential(from: response,
                                              tokenEndpoint: credential.tokenEndpoint,
                                              clientID: credential.clientID,
                                              clientSecret: credential.clientSecret,
                                              resource: credential.resource,
                                              previous: credential)
                // Persist rotation BEFORE execve - a lost rotated refresh
                // token bricks the grant on reuse-detecting ASs.
                try store.save(updated, server: server.path)
                return ResolvedLaunchToken(token: updated.accessToken, server: key,
                                           source: .refreshedKeychain,
                                           expiresAt: updated.expiresAt)
            } catch AuthError.refreshFailed(_, let oauthError) {
                throw AuthError.refreshFailed(server: server.path, oauthError: oauthError)
            }

        case .expired(refreshable: false):
            // No refresh token: only a fresh login can fix this.
            throw AuthError.noCredential(server: server.path)

        case .none:
            // 3. Shared env fallback.
            if let name = mcp.tokenEnv, let value = environment[name], !value.isEmpty {
                return ResolvedLaunchToken(token: value, server: key, source: .sharedEnv(name))
            }
            // 4. Nothing anywhere - fail loudly with the login hint.
            throw AuthError.noCredential(server: server.path)
        }
    }

    /// F12: serve mode outlives the token (apfel-run refreshes before execve
    /// and then ceases to exist). Surface the cliff up front.
    public static func serveExpiryWarning(mode: ProfileMode?,
                                          launchToken: ResolvedLaunchToken?) -> String? {
        guard mode == .serve, let launchToken, let expiresAt = launchToken.expiresAt else {
            return nil
        }
        return "token for \(launchToken.server) expires at \(AuthSubcommands.iso8601(expiresAt)); restart apfel-run to refresh"
    }
}
