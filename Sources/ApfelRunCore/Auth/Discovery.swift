import Foundation

/// Which rung of the discovery ladder produced the result.
/// Pinned to MCP auth spec rev 2025-06-18 (RFC 9728 + RFC 8414 + RFC 8707).
/// The legacy 2025-03-26 "MCP origin IS the AS" rung is deliberately absent
/// (trim3) - re-adding it is a new probe descriptor + one test.
public enum DiscoveryRung: Equatable, Sendable {
    case wwwAuthenticate
    case pathAwarePRM
    case originPRM
    case oidcDiscovery
}

public struct DiscoveryResult: Equatable, Sendable {
    public var resourceMetadata: ProtectedResourceMetadata?
    public var authServer: AuthServerMetadata
    public var rung: DiscoveryRung

    public init(resourceMetadata: ProtectedResourceMetadata?,
                authServer: AuthServerMetadata,
                rung: DiscoveryRung) {
        self.resourceMetadata = resourceMetadata
        self.authServer = authServer
        self.rung = rung
    }
}

/// Metadata discovery ladder (pure, transport-injected).
///
/// Stage 1 - find the protected-resource metadata (PRM):
///   1. unauthenticated `initialize` POST -> 401 + `WWW-Authenticate:
///      Bearer resource_metadata="<url>"` -> GET that PRM
///   2. path-aware `/.well-known/oauth-protected-resource/<mcp-path>` (RFC 9728)
///   3. origin-level `/.well-known/oauth-protected-resource`
///
/// Stage 2 - resolve AS metadata from `authorization_servers[0]`:
///   4. RFC 8414 `/.well-known/oauth-authorization-server` (path-aware, RFC 8414 3.1)
///   5. OIDC `/.well-known/openid-configuration` (F2, same path-aware insertion)
///
/// Post-conditions: RFC 8414 3.3 issuer check (F11) and endpoint https
/// validation (F1) - both enforced before returning.
public enum Discovery {
    public static func discover(mcpURL: URL, transport: HTTPTransport) async throws -> DiscoveryResult {
        guard isSecureOrLoopback(mcpURL) else {
            throw AuthError.notHTTPS(url: mcpURL.absoluteString)
        }

        // Stage 1: protected-resource metadata
        let (prm, rung) = try await findPRM(mcpURL: mcpURL, transport: transport)

        guard let asString = prm.authorizationServers.first,
              let asURL = URL(string: asString) else {
            throw AuthError.discoveryFailed(
                rung: "authorization-server metadata",
                detail: "protected-resource metadata lists no authorization_servers")
        }

        // Stage 2: authorization-server metadata
        let (metadata, viaOIDC) = try await findASMetadata(asURL: asURL, transport: transport)

        // F11: RFC 8414 3.3 mix-up defense - issuer must equal the AS URL
        // the metadata was requested for.
        guard normalizedIssuer(metadata.issuer) == normalizedIssuer(asString) else {
            throw AuthError.discoveryFailed(
                rung: "authorization-server metadata",
                detail: "metadata issuer '\(metadata.issuer)' does not match requested authorization server '\(asString)' (RFC 8414 section 3.3)")
        }

        // F1: https required on all advertised endpoints (loopback exempt).
        try metadata.validateEndpoints()

        return DiscoveryResult(resourceMetadata: prm,
                               authServer: metadata,
                               rung: viaOIDC ? .oidcDiscovery : rung)
    }

    // MARK: - Stage 1

    static func findPRM(mcpURL: URL, transport: HTTPTransport) async throws
        -> (ProtectedResourceMetadata, DiscoveryRung) {
        // Preferred: unauthenticated initialize -> 401 + WWW-Authenticate
        let initBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: String](),
                "clientInfo": ["name": "apfel-run", "version": "auth-discovery"],
            ],
        ])
        let probe = try await transport.send(HTTPRequestData(
            method: "POST", url: mcpURL,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: initBody))

        if let header = probe.header("WWW-Authenticate"),
           let prmURL = WWWAuthenticate.resourceMetadataURL(fromHeader: header),
           let prm = try await fetchPRM(url: prmURL, transport: transport) {
            return (prm, .wwwAuthenticate)
        }

        // Fallback: RFC 9728 well-known probes - NEVER leave the MCP origin.
        var probed: [String] = []
        var candidates: [(URL, DiscoveryRung)] = []
        let path = mcpURL.path
        if !path.isEmpty, path != "/" {
            if let u = URL(string: wellKnown(origin: mcpURL, suffix: "oauth-protected-resource", path: path)) {
                candidates.append((u, .pathAwarePRM))
            }
        }
        if let u = URL(string: wellKnown(origin: mcpURL, suffix: "oauth-protected-resource", path: nil)) {
            candidates.append((u, .originPRM))
        }
        for (url, rung) in candidates {
            probed.append(url.absoluteString)
            if let prm = try await fetchPRM(url: url, transport: transport) {
                return (prm, rung)
            }
        }
        throw AuthError.discoveryFailed(
            rung: "protected-resource metadata",
            detail: "no protected-resource metadata found (probed: \(probed.joined(separator: ", ")))")
    }

    static func fetchPRM(url: URL, transport: HTTPTransport) async throws -> ProtectedResourceMetadata? {
        let response = try await transport.send(HTTPRequestData(
            method: "GET", url: url, headers: ["Accept": "application/json"]))
        guard (200..<300).contains(response.status) else { return nil }
        return try? JSONDecoder().decode(ProtectedResourceMetadata.self, from: response.body)
    }

    // MARK: - Stage 2

    static func findASMetadata(asURL: URL, transport: HTTPTransport) async throws
        -> (AuthServerMetadata, viaOIDC: Bool) {
        let issuerPath = asURL.path
        let path: String? = (issuerPath.isEmpty || issuerPath == "/") ? nil : issuerPath
        let candidates: [(String, Bool)] = [
            (wellKnown(origin: asURL, suffix: "oauth-authorization-server", path: path), false),
            (wellKnown(origin: asURL, suffix: "openid-configuration", path: path), true),
        ]
        var attempts: [String] = []
        for (urlString, viaOIDC) in candidates {
            guard let url = URL(string: urlString) else { continue }
            let response = try await transport.send(HTTPRequestData(
                method: "GET", url: url, headers: ["Accept": "application/json"]))
            guard (200..<300).contains(response.status) else {
                attempts.append("\(urlString) -> HTTP \(response.status)")
                continue
            }
            do {
                let metadata = try JSONDecoder().decode(AuthServerMetadata.self, from: response.body)
                return (metadata, viaOIDC)
            } catch {
                attempts.append("\(urlString) -> invalid metadata (\(error.localizedDescription))")
            }
        }
        throw AuthError.discoveryFailed(
            rung: "authorization-server metadata",
            detail: "no usable authorization-server metadata: \(attempts.joined(separator: "; "))")
    }

    // MARK: - Helpers

    /// RFC 8414 3.1 / RFC 9728 well-known insertion: the well-known segment
    /// goes between the origin and the (optional) path component.
    static func wellKnown(origin url: URL, suffix: String, path: String?) -> String {
        var base = "\(url.scheme ?? "https")://\(url.host ?? "")"
        if let port = url.port { base += ":\(port)" }
        var out = base + "/.well-known/" + suffix
        if let path, !path.isEmpty, path != "/" {
            out += path.hasPrefix("/") ? path : "/" + path
        }
        return out
    }

    /// Issuer comparison normalization: trailing slash stripped, scheme+host
    /// lowercased (URL string compare is otherwise byte-exact).
    static func normalizedIssuer(_ s: String) -> String {
        guard let url = URL(string: s), let scheme = url.scheme, let host = url.host else {
            return s
        }
        var out = "\(scheme.lowercased())://\(host.lowercased())"
        if let port = url.port { out += ":\(port)" }
        let path = url.path
        if !path.isEmpty, path != "/" {
            out += path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return out
    }
}
