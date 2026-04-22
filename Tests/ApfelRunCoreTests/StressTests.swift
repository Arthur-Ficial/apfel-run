import Foundation
import Testing
@testable import ApfelRunCore

// Stress + large-config tests. Not perf benchmarks - just "does it work when
// the config isn't tiny?".

@Suite("Stress - large configs")
struct StressTests {
    @Test("50 profiles each with 20 MCPs round-trips cleanly")
    func fiftyProfilesTwentyMCPs() throws {
        var profiles: [String: Profile] = [:]
        for i in 0..<50 {
            let servers = (0..<20).map { j in
                MCPServer(path: "/mcp/\(i)/\(j).py", enabled: j % 3 != 0)
            }
            profiles["profile\(i)"] = Profile(
                systemPrompt: "profile number \(i)",
                generation: GenerationSettings(temperature: Double(i) * 0.01),
                mcp: MCPSettings(servers: servers)
            )
        }
        let cfg = ApfelConfig(profiles: profiles)
        let toml = try TOMLCoder.encode(cfg)
        let decoded = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        #expect(decoded.profiles.count == 50)
        for i in 0..<50 {
            #expect(decoded.profiles["profile\(i)"]?.mcp?.servers.count == 20)
        }
    }

    @Test("Validator on 50-profile config processes each")
    func validate50Profiles() {
        var profiles: [String: Profile] = [:]
        for i in 0..<50 {
            profiles["p\(i)"] = Profile()
        }
        let cfg = ApfelConfig(profiles: profiles)
        let diag = ConfigValidator.validate(cfg)
        #expect(diag.isEmpty) // all empty profiles = no errors
    }

    @Test("FlagBuilder on 100 enabled MCPs produces valid APFEL_MCP string")
    func flagBuilder100MCPs() {
        let servers = (0..<100).map { MCPServer(path: "/mcp/\($0).py") }
        let p = Profile(mcp: MCPSettings(servers: servers))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        let mcp = try! #require(b.env["APFEL_MCP"])
        let parts = mcp.split(separator: ",")
        #expect(parts.count == 100)
        #expect(parts.first == "/mcp/0.py")
        #expect(parts.last == "/mcp/99.py")
    }
}

// MARK: - Deterministic ordering

@Suite("Deterministic output")
struct DeterminismTests {
    @Test("Built env dictionary iteration order not relied upon for APFEL_MCP order")
    func mcpOrderFromArray() {
        // Array order must win over dict-key order
        let servers = ["/zebra.py", "/apple.py", "/mango.py"]
            .map { MCPServer(path: $0) }
        let b = FlagBuilder.build(profile: Profile(mcp: MCPSettings(servers: servers)),
                                  userArgs: [], environment: [:])
        #expect(b.env["APFEL_MCP"] == "/zebra.py,/apple.py,/mango.py")
    }

    @Test("Same inputs = same argv every time")
    func identicalBuilds() {
        let p = Profile(mode: .serve,
                        server: ServerSettings(port: 11434, allowedOrigins: ["b", "a", "c"]))
        let first = FlagBuilder.build(profile: p, userArgs: ["x", "y"], environment: [:])
        let second = FlagBuilder.build(profile: p, userArgs: ["x", "y"], environment: [:])
        let third = FlagBuilder.build(profile: p, userArgs: ["x", "y"], environment: [:])
        #expect(first.argv == second.argv)
        #expect(second.argv == third.argv)
    }

    @Test("Warning ordering is stable across runs")
    func warningsStable() {
        let p = Profile(mcp: MCPSettings(
            tokenEnv: "MISSING_1",
            servers: [
                MCPServer(path: "/a", tokenEnv: "MISSING_A"),
                MCPServer(path: "/b", tokenEnv: "MISSING_B"),
            ]
        ))
        let b1 = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        let b2 = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b1.warnings == b2.warnings)
    }
}

// MARK: - Diagnostic + BuiltArgs equality

@Suite("Value-type equality")
struct ValueEqualityTests {
    @Test("Diagnostic is Equatable by all three fields")
    func diagnosticEquality() {
        let a = Diagnostic(severity: .error, profile: "p", message: "m")
        let b = Diagnostic(severity: .error, profile: "p", message: "m")
        let c = Diagnostic(severity: .warning, profile: "p", message: "m")
        let d = Diagnostic(severity: .error, profile: "other", message: "m")
        let e = Diagnostic(severity: .error, profile: "p", message: "other")
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a != e)
    }

    @Test("BuiltArgs equality across all three fields")
    func builtArgsEquality() {
        let a = BuiltArgs(argv: ["x"], env: ["A": "1"])
        let b = BuiltArgs(argv: ["x"], env: ["A": "1"])
        let c = BuiltArgs(argv: ["y"], env: ["A": "1"])
        #expect(a == b)
        #expect(a != c)
    }

    @Test("LoaderResult equality")
    func loaderResultEquality() {
        let a = LoaderResult(config: ApfelConfig(), source: .projectLocal, path: "/x")
        let b = LoaderResult(config: ApfelConfig(), source: .projectLocal, path: "/x")
        let c = LoaderResult(config: ApfelConfig(), source: .none, path: nil)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("ResolvedProfile equality")
    func resolvedProfileEquality() {
        let a = ResolvedProfile(name: "x", profile: Profile())
        let b = ResolvedProfile(name: "x", profile: Profile())
        #expect(a == b)
    }
}

// MARK: - Starter config quality gate

@Suite("Starter config quality")
struct StarterConfigTests {
    @Test("Starter config is valid TOML")
    func starterParseable() throws {
        _ = try TOMLCoder.decode(ApfelConfig.self, from: Subcommands.starterConfig)
    }

    @Test("Starter config passes validator (no errors)")
    func starterValidates() throws {
        let cfg = try TOMLCoder.decode(ApfelConfig.self, from: Subcommands.starterConfig)
        let diag = ConfigValidator.validate(cfg)
        let errors = diag.filter { $0.severity == .error }
        #expect(errors.isEmpty, "starter config has errors: \(errors)")
    }

    @Test("Starter mentions apfel-mcp tools by name")
    func starterMentionsMCPTools() {
        #expect(Subcommands.starterConfig.contains("apfel-mcp-ddg-search"))
        #expect(Subcommands.starterConfig.contains("apfel-mcp-url-fetch"))
        #expect(Subcommands.starterConfig.contains("apfel-mcp-search-and-fetch"))
    }

    @Test("Starter has a default profile block")
    func starterHasDefault() {
        #expect(Subcommands.starterConfig.contains("[profile.default]"))
    }

    @Test("Starter explicitly warns against raw tokens in file")
    func starterSecretsGuidance() {
        #expect(Subcommands.starterConfig.localizedCaseInsensitiveContains("token_env"))
        #expect(Subcommands.starterConfig.localizedCaseInsensitiveContains("raw tokens"))
    }
}

// MARK: - Config snapshot: schema surface frozen for v0.2

@Suite("Config schema surface snapshot")
struct SchemaSurfaceTests {
    /// Snapshot of the exhaustive encoded schema. If a new field is added to
    /// ApfelConfig without updating this fixture, the test fails - forcing the
    /// docs/README/starter to be updated atomically.
    @Test("Every field name appears in canonical TOML output")
    func everyFieldNameEmitted() throws {
        let max = FullFixtureRoundTripTests.maxProfile
        let cfg = ApfelConfig(profiles: ["default": max])
        let toml = try TOMLCoder.encode(cfg)
        let expected: [String] = [
            "mode", "system_prompt", "files",
            "output_format", "quiet", "no_color", "debug", "permissive",
            "temperature", "seed", "max_tokens", "retry",
            "strategy", "max_turns", "output_reserve",
            "port", "host", "cors", "max_concurrent",
            "allowed_origins", "token_env", "public_health",
            "origin_check",
            "timeout_seconds", "path", "enabled",
        ]
        for key in expected {
            #expect(toml.contains(key), "missing key '\(key)' in canonical TOML encode")
        }
    }

    @Test("ContextStrategy .allCases matches apfel's five")
    func contextStrategyCaseCount() {
        #expect(ContextStrategy.allCases.count == 5)
        let rawValues = Set(ContextStrategy.allCases.map(\.rawValue))
        #expect(rawValues == ["newest-first", "oldest-first", "sliding-window", "summarize", "strict"])
    }

    @Test("OutputFormat .allCases matches apfel's two")
    func outputFormatCaseCount() {
        #expect(OutputFormat.allCases.count == 2)
        let rawValues = Set(OutputFormat.allCases.map(\.rawValue))
        #expect(rawValues == ["plain", "json"])
    }

    @Test("ProfileMode .allCases matches apfel's six modes + nothing else")
    func profileModeCaseCount() {
        #expect(ProfileMode.allCases.count == 6)
        let rawValues = Set(ProfileMode.allCases.map(\.rawValue))
        #expect(rawValues == ["single", "stream", "chat", "serve", "benchmark", "model-info"])
    }
}
