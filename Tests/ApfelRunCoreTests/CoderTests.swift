import Foundation
import Testing
@testable import ApfelRunCore

@Suite("TOMLCoder")
struct TOMLCoderTests {
    @Test("Encode empty config produces empty string")
    func encodeEmpty() throws {
        let s = try TOMLCoder.encode(ApfelConfig())
        #expect(s.isEmpty || s == "\n")
    }

    @Test("Decode empty string produces empty config")
    func decodeEmpty() throws {
        let cfg = try TOMLCoder.decode(ApfelConfig.self, from: "")
        #expect(cfg.profiles.isEmpty)
    }

    @Test("Round-trip a single default profile")
    func roundTripDefault() throws {
        let original = ApfelConfig(profiles: [
            "default": Profile(mode: .serve,
                               systemPrompt: "be terse",
                               quiet: true,
                               generation: GenerationSettings(temperature: 0.7, maxTokens: 500))
        ])
        let text = try TOMLCoder.encode(original)
        let decoded = try TOMLCoder.decode(ApfelConfig.self, from: text)
        #expect(decoded.profiles["default"]?.mode == .serve)
        #expect(decoded.profiles["default"]?.systemPrompt == "be terse")
        #expect(decoded.profiles["default"]?.quiet == true)
        #expect(decoded.profiles["default"]?.generation?.temperature == 0.7)
        #expect(decoded.profiles["default"]?.generation?.maxTokens == 500)
    }

    @Test("TOML decode honours [profile.NAME] sections")
    func decodesProfileSections() throws {
        let toml = """
        [profile.default]
        system_prompt = "Hello"
        quiet = true
        """
        let cfg = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        let p = try #require(cfg.profiles["default"])
        #expect(p.systemPrompt == "Hello")
        #expect(p.quiet == true)
    }

    @Test("TOML nested table decodes generation settings")
    func decodesNested() throws {
        let toml = """
        [profile.default.generation]
        temperature = 0.3
        max_tokens = 100
        """
        let cfg = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        let g = try #require(cfg.profiles["default"]?.generation)
        #expect(g.temperature == 0.3)
        #expect(g.maxTokens == 100)
    }

    @Test("TOML array of tables for mcp servers")
    func arrayOfTables() throws {
        let toml = """
        [profile.default.mcp]
        timeout_seconds = 30

        [[profile.default.mcp.server]]
        path = "/calc.py"

        [[profile.default.mcp.server]]
        path = "/web.py"
        enabled = false
        """
        let cfg = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        let mcp = try #require(cfg.profiles["default"]?.mcp)
        #expect(mcp.timeoutSeconds == 30)
        #expect(mcp.servers.count == 2)
        #expect(mcp.servers[0].path == "/calc.py")
        #expect(mcp.servers[0].enabled == true)
        #expect(mcp.servers[1].path == "/web.py")
        #expect(mcp.servers[1].enabled == false)
    }

    @Test("Malformed TOML throws decoding error")
    func malformedTOMLThrows() {
        let toml = "[unterminated"
        do {
            _ = try TOMLCoder.decode(ApfelConfig.self, from: toml)
            Issue.record("expected decode to throw")
        } catch {
            // success - any error is acceptable here
        }
    }

    @Test("Enum string values round-trip")
    func enumRoundTrip() throws {
        let toml = """
        [profile.default]
        mode = "chat"
        output_format = "json"

        [profile.default.context]
        strategy = "sliding-window"
        """
        let cfg = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        let p = try #require(cfg.profiles["default"])
        #expect(p.mode == .chat)
        #expect(p.outputFormat == .json)
        #expect(p.context?.strategy == .slidingWindow)
    }

    @Test("Server allowed_origins array decodes")
    func serverAllowedOrigins() throws {
        let toml = """
        [profile.default.server]
        port = 11500
        allowed_origins = ["https://a", "https://b"]
        """
        let cfg = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        let s = try #require(cfg.profiles["default"]?.server)
        #expect(s.port == 11500)
        #expect(s.allowedOrigins == ["https://a", "https://b"])
    }
}

@Suite("JSONCoder")
struct JSONCoderTests {
    @Test("Round-trip through JSON preserves fields")
    func jsonRoundTrip() throws {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mode: .serve,
                               server: ServerSettings(port: 11434, allowedOrigins: ["https://x"])),
            "chat": Profile(mode: .chat,
                            context: ContextSettings(strategy: .slidingWindow, maxTurns: 8))
        ])
        let data = try JSONCoder.encode(cfg)
        let decoded = try JSONCoder.decode(ApfelConfig.self, from: data)
        #expect(decoded.profiles["default"]?.server?.port == 11434)
        #expect(decoded.profiles["chat"]?.context?.maxTurns == 8)
    }
}
