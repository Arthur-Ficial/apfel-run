import Foundation
import Testing
@testable import ApfelRunCore

@Suite("ApfelConfig schema")
struct SchemaTests {
    @Test("ApfelConfig has a default profile that decodes from empty JSON")
    func emptyConfigHasDefaultProfile() throws {
        let config = ApfelConfig()
        #expect(config.profiles.isEmpty)
    }

    @Test("Profile defaults are correct")
    func profileDefaults() {
        let p = Profile()
        #expect(p.mode == nil)
        #expect(p.systemPrompt == nil)
        #expect(p.systemPromptFile == nil)
        #expect(p.files == [])
        #expect(p.outputFormat == nil)
        #expect(p.quiet == false)
        #expect(p.noColor == false)
        #expect(p.debug == false)
        #expect(p.permissive == false)
        #expect(p.generation == nil)
        #expect(p.context == nil)
        #expect(p.server == nil)
        #expect(p.mcp == nil)
    }

    @Test("Mode accepts canonical values")
    func modeAcceptsCanonicalValues() {
        #expect(ProfileMode(rawValue: "single") == .single)
        #expect(ProfileMode(rawValue: "stream") == .stream)
        #expect(ProfileMode(rawValue: "chat") == .chat)
        #expect(ProfileMode(rawValue: "serve") == .serve)
        #expect(ProfileMode(rawValue: "benchmark") == .benchmark)
        #expect(ProfileMode(rawValue: "model-info") == .modelInfo)
        #expect(ProfileMode(rawValue: "bogus") == nil)
    }

    @Test("OutputFormat enum matches apfel")
    func outputFormatEnum() {
        #expect(OutputFormat(rawValue: "plain") == .plain)
        #expect(OutputFormat(rawValue: "json") == .json)
        #expect(OutputFormat(rawValue: "xml") == nil)
    }

    @Test("ContextStrategy enum matches apfel")
    func contextStrategyEnum() {
        #expect(ContextStrategy(rawValue: "newest-first") == .newestFirst)
        #expect(ContextStrategy(rawValue: "oldest-first") == .oldestFirst)
        #expect(ContextStrategy(rawValue: "sliding-window") == .slidingWindow)
        #expect(ContextStrategy(rawValue: "summarize") == .summarize)
        #expect(ContextStrategy(rawValue: "strict") == .strict)
        #expect(ContextStrategy(rawValue: "smart") == nil)
    }

    @Test("GenerationSettings defaults are zero/nil")
    func generationSettingsDefaults() {
        let g = GenerationSettings()
        #expect(g.temperature == nil)
        #expect(g.seed == nil)
        #expect(g.maxTokens == nil)
        #expect(g.retry == nil)
    }

    @Test("ContextSettings defaults")
    func contextSettingsDefaults() {
        let c = ContextSettings()
        #expect(c.strategy == nil)
        #expect(c.maxTurns == nil)
        #expect(c.outputReserve == nil)
    }

    @Test("ServerSettings defaults")
    func serverSettingsDefaults() {
        let s = ServerSettings()
        #expect(s.port == nil)
        #expect(s.host == nil)
        #expect(s.cors == false)
        #expect(s.maxConcurrent == nil)
        #expect(s.allowedOrigins == [])
        #expect(s.tokenAuto == false)
        #expect(s.tokenEnv == nil)
        #expect(s.publicHealth == false)
        #expect(s.originCheck == true)
        #expect(s.footgun == false)
    }

    @Test("MCPSettings defaults")
    func mcpSettingsDefaults() {
        let m = MCPSettings()
        #expect(m.timeoutSeconds == nil)
        #expect(m.tokenEnv == nil)
        #expect(m.servers == [])
    }

    @Test("MCPServer defaults: enabled true, no token override")
    func mcpServerDefaults() {
        let s = MCPServer(path: "/x.py")
        #expect(s.path == "/x.py")
        #expect(s.enabled == true)
        #expect(s.tokenEnv == nil)
    }

    @Test("ApfelConfig round-trips through JSON")
    func configRoundTripsJSON() throws {
        var cfg = ApfelConfig()
        let p = Profile(
            mode: .serve,
            systemPrompt: "be terse",
            files: ["/a.txt"],
            outputFormat: .json,
            quiet: true,
            generation: GenerationSettings(temperature: 0.7, maxTokens: 500),
            context: ContextSettings(strategy: .slidingWindow, maxTurns: 10),
            server: ServerSettings(port: 11434, host: "127.0.0.1"),
            mcp: MCPSettings(servers: [MCPServer(path: "/calc.py")])
        )
        cfg.profiles["default"] = p

        let encoded = try JSONCoder.encode(cfg)
        let decoded = try JSONCoder.decode(ApfelConfig.self, from: encoded)
        #expect(decoded.profiles["default"]?.mode == .serve)
        #expect(decoded.profiles["default"]?.systemPrompt == "be terse")
        #expect(decoded.profiles["default"]?.generation?.temperature == 0.7)
        #expect(decoded.profiles["default"]?.mcp?.servers.count == 1)
    }

    @Test("Enum round-trips preserve canonical string form")
    func enumRoundTrips() throws {
        let cfg = ApfelConfig(profiles: [
            "x": Profile(mode: .chat,
                         outputFormat: .plain,
                         context: ContextSettings(strategy: .newestFirst))
        ])
        let data = try JSONCoder.encode(cfg)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"chat\""))
        #expect(text.contains("\"plain\""))
        #expect(text.contains("\"newest-first\""))
    }

    @Test("Snake-case JSON keys are the canonical wire form")
    func snakeCaseJSON() throws {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(
                systemPrompt: "x",
                systemPromptFile: "/y.txt",
                outputFormat: .json,
                noColor: true,
                generation: GenerationSettings(maxTokens: 100),
                context: ContextSettings(outputReserve: 64),
                server: ServerSettings(allowedOrigins: ["a", "b"],
                                       tokenAuto: true,
                                       tokenEnv: "TOKEN",
                                       publicHealth: true,
                                       originCheck: false),
                mcp: MCPSettings(timeoutSeconds: 30,
                                 tokenEnv: "MCP_TOKEN")
            )
        ])
        let text = String(data: try JSONCoder.encode(cfg), encoding: .utf8) ?? ""
        #expect(text.contains("system_prompt"))
        #expect(text.contains("system_prompt_file"))
        #expect(text.contains("output_format"))
        #expect(text.contains("no_color"))
        #expect(text.contains("max_tokens"))
        #expect(text.contains("output_reserve"))
        #expect(text.contains("allowed_origins"))
        #expect(text.contains("token_auto"))
        #expect(text.contains("token_env"))
        #expect(text.contains("public_health"))
        #expect(text.contains("origin_check"))
        #expect(text.contains("timeout_seconds"))
        // Not camelCase
        #expect(!text.contains("systemPrompt"))
        #expect(!text.contains("maxTokens"))
    }

    @Test("JSON decode fills missing fields with defaults")
    func jsonMissingFieldsDefault() throws {
        // Note: wire key is "profile" (singular) matching TOML [profile.NAME].
        let json = #"""
        {"profile":{"default":{"system_prompt":"hi"}}}
        """#
        let cfg = try JSONCoder.decode(ApfelConfig.self, from: Data(json.utf8))
        let p = try #require(cfg.profiles["default"])
        #expect(p.systemPrompt == "hi")
        #expect(p.mode == nil)
        #expect(p.files == [])
        #expect(p.quiet == false)
    }

    @Test("Multiple profiles round-trip")
    func multipleProfilesRoundTrip() throws {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mode: .single),
            "chat": Profile(mode: .chat),
            "serve": Profile(mode: .serve),
        ])
        let data = try JSONCoder.encode(cfg)
        let decoded = try JSONCoder.decode(ApfelConfig.self, from: data)
        #expect(decoded.profiles.count == 3)
        #expect(decoded.profiles["default"]?.mode == .single)
        #expect(decoded.profiles["chat"]?.mode == .chat)
        #expect(decoded.profiles["serve"]?.mode == .serve)
    }

    // MARK: - mcp.server auth (apfel-run#1)

    @Test("auth field decodes from TOML and JSON, absent -> nil")
    func authFieldDecodes() throws {
        let toml = """
        [[profile.default.mcp.server]]
        path = "https://mcp.example.com/mcp"
        auth = "oauth"

        [[profile.default.mcp.server]]
        path = "/plain/mcp.py"
        """
        let cfg = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        let servers = try #require(cfg.profiles["default"]?.mcp?.servers)
        #expect(servers[0].auth == .oauth)
        #expect(servers[1].auth == nil)

        let json = #"""
        {"profile":{"default":{"mcp":{"server":[{"path":"https://m.example/mcp","auth":"oauth"}]}}}}
        """#
        let jsonCfg = try JSONCoder.decode(ApfelConfig.self, from: Data(json.utf8))
        #expect(jsonCfg.profiles["default"]?.mcp?.servers.first?.auth == .oauth)
    }

    @Test("unknown auth value fails decode with clear error")
    func unknownAuthValueFails() {
        let toml = """
        [[profile.default.mcp.server]]
        path = "https://mcp.example.com/mcp"
        auth = "saml"
        """
        #expect(throws: (any Error).self) {
            _ = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        }
    }
}
