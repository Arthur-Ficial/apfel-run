import Foundation
import Testing
@testable import ApfelRunCore

@Suite("WWW-Authenticate - RFC 9728 resource_metadata extraction")
struct WWWAuthenticateTests {
    @Test("extracts resource_metadata URL from Bearer challenge")
    func extractsURL() {
        let header = #"Bearer realm="mcp", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#
        let url = WWWAuthenticate.resourceMetadataURL(fromHeader: header)
        #expect(url == URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
    }

    @Test("case-insensitive scheme and parameter order tolerated")
    func caseAndOrder() {
        let header = #"bearer resource_metadata="https://a.example/prm", realm="x""#
        let url = WWWAuthenticate.resourceMetadataURL(fromHeader: header)
        #expect(url == URL(string: "https://a.example/prm"))
    }

    @Test("rejects http:// resource_metadata")
    func rejectsHTTP() {
        let header = #"Bearer resource_metadata="http://evil.example/prm""#
        #expect(WWWAuthenticate.resourceMetadataURL(fromHeader: header) == nil)
        // F13: loopback hosts are exempt (mirrors apfel MCPClient's rule)
        let loopback = #"Bearer resource_metadata="http://127.0.0.1:8080/prm""#
        #expect(WWWAuthenticate.resourceMetadataURL(fromHeader: loopback)
                == URL(string: "http://127.0.0.1:8080/prm"))
    }

    @Test("missing parameter -> nil")
    func missingParameter() {
        #expect(WWWAuthenticate.resourceMetadataURL(fromHeader: #"Bearer realm="mcp""#) == nil)
    }

    @Test("garbage header -> nil")
    func garbageHeader() {
        #expect(WWWAuthenticate.resourceMetadataURL(fromHeader: "Basic realm=nope") == nil)
        #expect(WWWAuthenticate.resourceMetadataURL(fromHeader: "") == nil)
        #expect(WWWAuthenticate.resourceMetadataURL(fromHeader: #"Bearer resource_metadata="not a url""#) == nil)
    }
}
