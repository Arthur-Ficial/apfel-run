import Foundation

/// Token persistence seam. The real implementation is Keychain-backed
/// (`KeychainTokenStore`); unit tests use in-memory fakes.
public protocol TokenStoring: Sendable {
    func load(server: String) throws -> StoredCredential?
    func save(_ credential: StoredCredential, server: String) throws
    /// Returns false when nothing was stored for the server.
    @discardableResult
    func delete(server: String) throws -> Bool
    /// Normalized server URLs with stored credentials.
    func list() throws -> [String]
}

/// Canonical keychain-account key for an MCP server URL:
/// lowercased scheme+host, default port stripped, path kept,
/// trailing slash stripped.
public func normalizeServerKey(_ url: String) -> String {
    guard let parsed = URL(string: url),
          let scheme = parsed.scheme?.lowercased(),
          let host = parsed.host?.lowercased() else {
        return url
    }
    var out = "\(scheme)://\(host)"
    if let port = parsed.port {
        let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        if !isDefault { out += ":\(port)" }
    }
    var path = parsed.path
    while path.hasSuffix("/") { path = String(path.dropLast()) }
    if !path.isEmpty { out += path }
    return out
}

/// Expiry classification for a stored credential.
public enum TokenValidity: Equatable, Sendable {
    case valid(until: Date?)
    case expired(refreshable: Bool)
    case none
}

/// Classify a credential against the clock with a safety skew (default 60 s):
/// a token inside the skew window counts as expired so a launch never hands
/// apfel a token that dies mid-request.
public func validity(of credential: StoredCredential?,
                     clock: AuthClock,
                     skew: TimeInterval = 60) -> TokenValidity {
    guard let credential else { return .none }
    guard let expiresAt = credential.expiresAt else { return .valid(until: nil) }
    if clock.now < expiresAt.addingTimeInterval(-skew) {
        return .valid(until: expiresAt)
    }
    return .expired(refreshable: credential.refreshToken != nil)
}
