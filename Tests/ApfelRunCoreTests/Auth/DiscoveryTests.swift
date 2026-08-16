import Foundation
import Testing
@testable import ApfelRunCore

@Suite("Discovery - MCP auth metadata ladder (spec rev 2025-06-18)")
struct DiscoveryTests {
    let mcp = Fixtures.mcpURL                       // https://mcp.example.com/mcp
    let asOrigin = Fixtures.asURL                   // https://as.example.com
    let rfc8414 = "\(Fixtures.asURL)/.well-known/oauth-authorization-server"
    let oidc = "\(Fixtures.asURL)/.well-known/openid-configuration"
    let pathAwarePRM = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
    let originPRM = "https://mcp.example.com/.well-known/oauth-protected-resource"

    @Test("rung 1: 401 WWW-Authenticate resource_metadata wins")
    func rung1WWWAuthenticate() async throws {
        let prmURL = "https://mcp.example.com/custom/prm"
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": Fixtures.challenge401(resourceMetadata: prmURL),
            "GET \(prmURL)": Fixtures.prmJSON(),
            "GET \(rfc8414)": Fixtures.asMetadataJSON(),
        ])
        let result = try await Discovery.discover(mcpURL: mcp, transport: t)
        #expect(result.rung == .wwwAuthenticate)
        #expect(result.authServer.tokenEndpoint == "\(asOrigin)/token")
        #expect(result.authServer.authorizationEndpoint == "\(asOrigin)/authorize")
        #expect(result.resourceMetadata?.authorizationServers == [asOrigin])
        // Exact request sequence
        let sequence = t.sentRequests.map { "\($0.method) \($0.url.absoluteString)" }
        #expect(sequence == [
            "POST \(mcp.absoluteString)",
            "GET \(prmURL)",
            "GET \(rfc8414)",
        ])
    }

    @Test("rung 2: path-aware protected-resource fallback")
    func rung2PathAware() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),  // no usable header
            "GET \(pathAwarePRM)": HTTPResponseData(status: 404),
            "GET \(originPRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": Fixtures.asMetadataJSON(),
        ])
        let result = try await Discovery.discover(mcpURL: mcp, transport: t)
        #expect(result.rung == .originPRM)
        let sequence = t.sentRequests.map { "\($0.method) \($0.url.absoluteString)" }
        // Path-aware RFC 9728 well-known is tried BEFORE the origin-level one.
        #expect(sequence[1] == "GET \(pathAwarePRM)")
        #expect(sequence[2] == "GET \(originPRM)")
    }

    @Test("rung 2: path-aware PRM hit resolves with pathAwarePRM rung")
    func rung2PathAwareHit() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": Fixtures.asMetadataJSON(),
        ])
        let result = try await Discovery.discover(mcpURL: mcp, transport: t)
        #expect(result.rung == .pathAwarePRM)
    }

    @Test("no PRM anywhere -> discoveryFailed (legacy AS-on-origin deliberately not probed)")
    func noPRMAnywhere() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
        ])
        do {
            _ = try await Discovery.discover(mcpURL: mcp, transport: t)
            Issue.record("expected discoveryFailed")
        } catch let e as AuthError {
            guard case .discoveryFailed(_, let detail) = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            // Failure lists the probed URLs
            #expect(detail.contains(pathAwarePRM))
            #expect(detail.contains(originPRM))
        }
        // trim3 pin: NO legacy AS-on-origin probe on the MCP origin
        let urls = t.sentRequests.map(\.url.absoluteString)
        #expect(!urls.contains { $0.contains("mcp.example.com/.well-known/oauth-authorization-server") })
    }

    @Test("http mcp URL refused before any request")
    func httpRefused() async throws {
        let t = FakeTransport()
        let httpURL = URL(string: "http://mcp.example.com/mcp")!
        do {
            _ = try await Discovery.discover(mcpURL: httpURL, transport: t)
            Issue.record("expected notHTTPS")
        } catch let e as AuthError {
            #expect(e == .notHTTPS(url: httpURL.absoluteString))
        }
        #expect(t.sentRequests.isEmpty)
    }

    @Test("http mcp URL on 127.0.0.1/::1/localhost is accepted")
    func loopbackAccepted() async throws {
        // F13: mirrors apfel MCPClient.swift:258-266; enables the fake-AS
        // smoke test with no override knob.
        let loop = URL(string: "http://127.0.0.1:9999/mcp")!
        let origin = "http://127.0.0.1:9999"
        let t = FakeTransport(responses: [
            "POST \(loop.absoluteString)": Fixtures.challenge401(resourceMetadata: "\(origin)/prm"),
            "GET \(origin)/prm": Fixtures.prmJSON(authServers: [origin]),
            "GET \(origin)/.well-known/oauth-authorization-server": Fixtures.asMetadataJSON(
                issuer: origin,
                authorizationEndpoint: "\(origin)/authorize",
                tokenEndpoint: "\(origin)/token",
                registrationEndpoint: "\(origin)/register"),
        ])
        let result = try await Discovery.discover(mcpURL: loop, transport: t)
        #expect(result.rung == .wwwAuthenticate)
        #expect(result.authServer.tokenEndpoint == "\(origin)/token")
    }

    @Test("AS metadata missing token_endpoint -> discoveryFailed")
    func missingTokenEndpoint() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": FakeTransport.json(200, [
                "issuer": asOrigin,
                "authorization_endpoint": "\(asOrigin)/authorize",
                // no token_endpoint
            ]),
        ])
        await #expect(throws: AuthError.self) {
            _ = try await Discovery.discover(mcpURL: mcp, transport: t)
        }
    }

    @Test("authorization_servers empty -> discoveryFailed with rung detail")
    func emptyAuthorizationServers() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(authServers: []),
        ])
        do {
            _ = try await Discovery.discover(mcpURL: mcp, transport: t)
            Issue.record("expected discoveryFailed")
        } catch let e as AuthError {
            guard case .discoveryFailed(let rung, let detail) = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            #expect(rung.contains("authorization-server"))
            #expect(detail.contains("authorization_servers"))
        }
    }

    @Test("PRM on different origin than MCP is accepted only via WWW-Authenticate rung")
    func foreignPRMOnlyViaHeader() async throws {
        // Scenario A: header-delivered foreign-origin PRM is trusted.
        let foreignPRM = "https://cdn.other.example/prm"
        let tA = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": Fixtures.challenge401(resourceMetadata: foreignPRM),
            "GET \(foreignPRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": Fixtures.asMetadataJSON(),
        ])
        let resultA = try await Discovery.discover(mcpURL: mcp, transport: tA)
        #expect(resultA.rung == .wwwAuthenticate)

        // Scenario B: fallback probes never leave the MCP origin.
        let tB = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
        ])
        _ = try? await Discovery.discover(mcpURL: mcp, transport: tB)
        let fallbackGETs = tB.sentRequests.filter { $0.method == "GET" }
        #expect(!fallbackGETs.isEmpty)
        #expect(fallbackGETs.allSatisfy { $0.url.host == "mcp.example.com" })
    }

    @Test("non-2xx AS metadata -> discoveryFailed carries HTTP status")
    func asMetadataHTTPError() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": HTTPResponseData(status: 500),
            "GET \(oidc)": HTTPResponseData(status: 500),
        ])
        do {
            _ = try await Discovery.discover(mcpURL: mcp, transport: t)
            Issue.record("expected discoveryFailed")
        } catch let e as AuthError {
            guard case .discoveryFailed(_, let detail) = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            #expect(detail.contains("500"))
        }
    }

    // MARK: - F2: OIDC rung

    @Test("AS serving only openid-configuration resolves via oidcDiscovery rung")
    func oidcOnly() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": HTTPResponseData(status: 404),
            "GET \(oidc)": Fixtures.asMetadataJSON(),
        ])
        let result = try await Discovery.discover(mcpURL: mcp, transport: t)
        #expect(result.rung == .oidcDiscovery)
        #expect(result.authServer.tokenEndpoint == "\(asOrigin)/token")
    }

    @Test("RFC 8414 well-known is tried before openid-configuration")
    func rfc8414First() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": HTTPResponseData(status: 404),
            "GET \(oidc)": Fixtures.asMetadataJSON(),
        ])
        _ = try await Discovery.discover(mcpURL: mcp, transport: t)
        let urls = t.sentRequests.map(\.url.absoluteString)
        let rfcIndex = urls.firstIndex(of: rfc8414)
        let oidcIndex = urls.firstIndex(of: oidc)
        #expect(rfcIndex != nil && oidcIndex != nil)
        #expect(rfcIndex! < oidcIndex!)
    }

    // MARK: - F11: mix-up defense + path-aware AS issuer

    @Test("issuer mismatch with requested AS URL -> discoveryFailed (RFC 8414 section 3.3)")
    func issuerMismatch() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": Fixtures.asMetadataJSON(issuer: "https://evil.example"),
        ])
        do {
            _ = try await Discovery.discover(mcpURL: mcp, transport: t)
            Issue.record("expected discoveryFailed")
        } catch let e as AuthError {
            guard case .discoveryFailed(_, let detail) = e else {
                Issue.record("wrong error: \(e)")
                return
            }
            #expect(detail.contains("issuer"))
        }
    }

    @Test("AS issuer with a path uses path-aware well-known insertion")
    func pathAwareASIssuer() async throws {
        let tenant = "https://as.example/tenant1"
        let rfc8414Tenant = "https://as.example/.well-known/oauth-authorization-server/tenant1"
        let oidcTenant = "https://as.example/.well-known/openid-configuration/tenant1"
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(authServers: [tenant]),
            "GET \(rfc8414Tenant)": HTTPResponseData(status: 404),
            "GET \(oidcTenant)": Fixtures.asMetadataJSON(
                issuer: tenant,
                authorizationEndpoint: "https://as.example/tenant1/authorize",
                tokenEndpoint: "https://as.example/tenant1/token",
                registrationEndpoint: nil),
        ])
        let result = try await Discovery.discover(mcpURL: mcp, transport: t)
        #expect(result.rung == .oidcDiscovery)
        let urls = t.sentRequests.map(\.url.absoluteString)
        #expect(urls.contains(rfc8414Tenant))
        #expect(urls.contains(oidcTenant))
    }

    // MARK: - F1: endpoint https validation

    @Test("http authorization_endpoint -> endpointsNotHTTPS")
    func httpAuthorizationEndpoint() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": Fixtures.asMetadataJSON(authorizationEndpoint: "http://as.example.com/authorize"),
        ])
        do {
            _ = try await Discovery.discover(mcpURL: mcp, transport: t)
            Issue.record("expected endpointsNotHTTPS")
        } catch let e as AuthError {
            #expect(e == .endpointsNotHTTPS(which: "authorization_endpoint"))
        }
    }

    @Test("http token_endpoint -> endpointsNotHTTPS")
    func httpTokenEndpoint() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": Fixtures.asMetadataJSON(tokenEndpoint: "http://as.example.com/token"),
        ])
        do {
            _ = try await Discovery.discover(mcpURL: mcp, transport: t)
            Issue.record("expected endpointsNotHTTPS")
        } catch let e as AuthError {
            #expect(e == .endpointsNotHTTPS(which: "token_endpoint"))
        }
    }

    @Test("http registration_endpoint -> endpointsNotHTTPS before any DCR request")
    func httpRegistrationEndpoint() async throws {
        let t = FakeTransport(responses: [
            "POST \(mcp.absoluteString)": HTTPResponseData(status: 401),
            "GET \(pathAwarePRM)": Fixtures.prmJSON(),
            "GET \(rfc8414)": Fixtures.asMetadataJSON(registrationEndpoint: "http://as.example.com/register"),
        ])
        do {
            _ = try await Discovery.discover(mcpURL: mcp, transport: t)
            Issue.record("expected endpointsNotHTTPS")
        } catch let e as AuthError {
            #expect(e == .endpointsNotHTTPS(which: "registration_endpoint"))
        }
        // Proof no registration POST was ever attempted
        #expect(!t.sentRequests.contains { $0.method == "POST" && $0.url.absoluteString.contains("register") })

        // Second scenario: loopback-host endpoints pass (F13)
        let meta = AuthServerMetadata(issuer: "http://127.0.0.1:9",
                                      authorizationEndpoint: "http://127.0.0.1:9/a",
                                      tokenEndpoint: "http://localhost:9/t",
                                      registrationEndpoint: "http://[::1]:9/r")
        #expect(throws: Never.self) { try meta.validateEndpoints() }
    }
}
