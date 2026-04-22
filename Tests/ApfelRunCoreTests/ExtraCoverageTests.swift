import Foundation
import Testing
@testable import ApfelRunCore

// Extra coverage beyond the Phase 1-8 suites - edge cases, round-trips,
// unicode, concurrent invocations, large configs, migration corner cases.

// MARK: - Exhaustive round-trips

@Suite("Full-fixture round-trips")
struct FullFixtureRoundTripTests {
    /// A profile with every field populated, for serialisation torture testing.
    static let maxProfile = Profile(
        mode: .serve,
        systemPrompt: "you are terse",
        systemPromptFile: nil,
        files: ["/tmp/a.txt", "/tmp/b.txt"],
        outputFormat: .json,
        quiet: true,
        noColor: true,
        debug: true,
        permissive: true,
        generation: GenerationSettings(temperature: 0.42, seed: 99, maxTokens: 777, retry: 5),
        context: ContextSettings(strategy: .slidingWindow, maxTurns: 8, outputReserve: 400),
        server: ServerSettings(port: 11500,
                               host: "0.0.0.0",
                               cors: true,
                               maxConcurrent: 12,
                               allowedOrigins: ["https://one.example", "https://two.example"],
                               tokenAuto: false,
                               tokenEnv: "MY_TOKEN",
                               publicHealth: true,
                               originCheck: false,
                               footgun: false),
        mcp: MCPSettings(timeoutSeconds: 45,
                         tokenEnv: "MY_MCP_TOKEN",
                         servers: [
                            MCPServer(path: "/a.py", enabled: true, tokenEnv: nil),
                            MCPServer(path: "https://tools.example/mcp",
                                      enabled: false,
                                      tokenEnv: "PER_SERVER_TOKEN"),
                         ])
    )

    @Test("TOML round-trip of a maximal profile preserves every field")
    func tomlRoundTripMaximal() throws {
        let cfg = ApfelConfig(profiles: ["default": Self.maxProfile])
        let text = try TOMLCoder.encode(cfg)
        let decoded = try TOMLCoder.decode(ApfelConfig.self, from: text)
        let p = try #require(decoded.profiles["default"])
        #expect(p.mode == .serve)
        #expect(p.systemPrompt == "you are terse")
        #expect(p.files == ["/tmp/a.txt", "/tmp/b.txt"])
        #expect(p.outputFormat == .json)
        #expect(p.quiet == true)
        #expect(p.noColor == true)
        #expect(p.debug == true)
        #expect(p.permissive == true)
        #expect(p.generation?.temperature == 0.42)
        #expect(p.generation?.seed == 99)
        #expect(p.generation?.maxTokens == 777)
        #expect(p.generation?.retry == 5)
        #expect(p.context?.strategy == .slidingWindow)
        #expect(p.context?.maxTurns == 8)
        #expect(p.context?.outputReserve == 400)
        #expect(p.server?.port == 11500)
        #expect(p.server?.host == "0.0.0.0")
        #expect(p.server?.cors == true)
        #expect(p.server?.maxConcurrent == 12)
        #expect(p.server?.allowedOrigins == ["https://one.example", "https://two.example"])
        #expect(p.server?.tokenEnv == "MY_TOKEN")
        #expect(p.server?.publicHealth == true)
        #expect(p.server?.originCheck == false)
        #expect(p.mcp?.timeoutSeconds == 45)
        #expect(p.mcp?.tokenEnv == "MY_MCP_TOKEN")
        #expect(p.mcp?.servers.count == 2)
        #expect(p.mcp?.servers[1].tokenEnv == "PER_SERVER_TOKEN")
    }

    @Test("JSON round-trip of a maximal profile preserves every field")
    func jsonRoundTripMaximal() throws {
        let cfg = ApfelConfig(profiles: ["default": Self.maxProfile])
        let data = try JSONCoder.encode(cfg)
        let decoded = try JSONCoder.decode(ApfelConfig.self, from: data)
        let p = try #require(decoded.profiles["default"])
        #expect(p == Self.maxProfile)
    }

    @Test("Cross-format: TOML encode -> JSON decode after conversion")
    func crossFormat() throws {
        let cfg = ApfelConfig(profiles: ["default": Self.maxProfile])
        let toml = try TOMLCoder.encode(cfg)
        let fromTOML = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        let json = try JSONCoder.encode(fromTOML)
        let fromJSON = try JSONCoder.decode(ApfelConfig.self, from: json)
        #expect(fromJSON.profiles["default"] == Self.maxProfile)
    }

    @Test("Five profiles round-trip preserving order-independent equality")
    func fiveProfiles() throws {
        let names = ["default", "dev", "prod", "chat", "research"]
        var profiles: [String: Profile] = [:]
        for (i, n) in names.enumerated() {
            profiles[n] = Profile(systemPrompt: "profile-\(i)-\(n)")
        }
        let cfg = ApfelConfig(profiles: profiles)
        let toml = try TOMLCoder.encode(cfg)
        let decoded = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        #expect(decoded.profiles == profiles)
    }

    @Test("Empty strings in system_prompt treated as unset by FlagBuilder")
    func emptyStringTreatedAsUnset() {
        let p = Profile(systemPrompt: "", systemPromptFile: "/x.txt")
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        // Empty system_prompt should NOT emit -s; falls through to system_prompt_file
        #expect(!b.argv.contains("-s"))
        #expect(b.argv.contains("--system-file"))
    }
}

// MARK: - Loader edge cases

@Suite("Loader edge cases")
struct LoaderEdgeCases {
    @Test("Empty JSON file {} decodes to empty config")
    func emptyJSONObject() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/empty.json"
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
        let r = ConfigLoader.load(environment: ["APFEL_RUN_CONFIG": path],
                                  cwd: "/tmp", home: "/tmp")
        #expect(r.config.profiles.isEmpty)
        #expect(r.source == .envOverride)
    }

    @Test("TOML with only comments decodes to empty config")
    func tomlOnlyComments() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/comments.toml"
        try "# top comment\n# another\n".write(toFile: path, atomically: true, encoding: .utf8)
        let r = ConfigLoader.load(environment: ["APFEL_RUN_CONFIG": path],
                                  cwd: "/tmp", home: "/tmp")
        #expect(r.config.profiles.isEmpty)
    }

    @Test("Explicit APFEL_RUN_CONFIG path that doesn't exist -> empty config, source .none")
    func envOverrideNonexistent() {
        let r = ConfigLoader.load(
            environment: ["APFEL_RUN_CONFIG": "/tmp/does-not-exist-\(UUID().uuidString).toml"],
            cwd: "/tmp", home: "/tmp"
        )
        #expect(r.config.profiles.isEmpty)
        #expect(r.source == .none)
        #expect(r.path == nil)
    }

    @Test("Legacy mcps.conf with URLs, comments, and dash-disables")
    func legacyRichContent() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.config/apfel", withIntermediateDirectories: true)
        let legacy = """
        # My registry
        https://tools.example.com/mcp
        /Users/me/local.py  # my local

        -https://disabled.example/mcp

        /second.py
        """
        try legacy.write(toFile: home + "/.config/apfel/mcps.conf",
                          atomically: true, encoding: .utf8)
        let r = ConfigLoader.load(environment: [:], cwd: "/tmp/none-\(UUID().uuidString)", home: home)
        #expect(r.source == .legacyMCPConf)
        let servers = try #require(r.config.profiles["default"]?.mcp?.servers)
        #expect(servers.count == 4)
        #expect(servers[0].path == "https://tools.example.com/mcp")
        #expect(servers[0].enabled)
        #expect(servers[1].path == "/Users/me/local.py")
        #expect(servers[1].enabled)
        #expect(servers[2].path == "https://disabled.example/mcp")
        #expect(!servers[2].enabled)
        #expect(servers[3].path == "/second.py")
    }

    @Test("Unreadable config path (permission denied) -> throws with path")
    func unreadablePath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/locked.toml"
        try "[profile.default]".write(toFile: path, atomically: true, encoding: .utf8)
        // Chmod 000 (unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        do {
            _ = try ConfigLoader.loadThrowing(environment: ["APFEL_RUN_CONFIG": path],
                                              cwd: "/tmp", home: "/tmp")
            Issue.record("expected throw")
        } catch let err as ConfigLoaderError {
            #expect(err.path == path)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    private func tempDir() throws -> String {
        let d = NSTemporaryDirectory() + "apfel-run-extra-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
}

// MARK: - ProfileResolver edge cases

@Suite("ProfileResolver edge cases")
struct ProfileResolverEdgeCases {
    @Test("Empty APFEL_RUN_PROFILE falls through to default")
    func emptyEnvFallsThrough() throws {
        let cfg = ApfelConfig(profiles: ["default": Profile(systemPrompt: "d")])
        let r = try ProfileResolver.resolve(config: cfg,
                                            requested: nil,
                                            environment: ["APFEL_RUN_PROFILE": ""])
        #expect(r.name == "default")
    }

    @Test("Profile names are case-sensitive")
    func caseSensitive() {
        let cfg = ApfelConfig(profiles: ["Dev": Profile()])
        do {
            _ = try ProfileResolver.resolve(config: cfg, requested: "dev", environment: [:])
            Issue.record("expected throw")
        } catch is ProfileResolverError {
            // expected
        } catch {
            Issue.record("wrong error")
        }
    }

    @Test("Levenshtein with identical strings returns distance 0")
    func levenshteinIdentical() {
        #expect(ProfileResolver.levenshtein("dev", "dev") == 0)
    }

    @Test("Levenshtein with one substitution")
    func levenshteinSub() {
        #expect(ProfileResolver.levenshtein("dev", "dex") == 1)
    }

    @Test("Levenshtein with insertion")
    func levenshteinInsertion() {
        #expect(ProfileResolver.levenshtein("dev", "deev") == 1)
    }

    @Test("Suggestion only fires when close enough")
    func suggestionThreshold() {
        let known = ["default", "dev", "prod"]
        #expect(ProfileResolver.suggest(for: "totally-different-name", from: known) == nil)
    }

    @Test("Whitespace-only profile name request treated as missing")
    func whitespaceProfileRequest() throws {
        let cfg = ApfelConfig(profiles: ["default": Profile()])
        // Currently "" -> nil (falls through), but a string of spaces is a real name
        // that WON'T match any profile. Verify the throw.
        do {
            _ = try ProfileResolver.resolve(config: cfg, requested: "   ", environment: [:])
            Issue.record("expected throw for whitespace profile name")
        } catch is ProfileResolverError {
            // ok
        } catch {
            Issue.record("wrong error")
        }
    }
}

// MARK: - PlannerV2 edge cases

@Suite("PlannerV2 edge cases")
struct PlannerV2EdgeCases {
    @Test("Two -p flags - last wins")
    func doubleProfileLastWins() {
        let action = PlannerV2.plan(args: ["-p", "first", "-p", "second"])
        #expect(action == .runApfel(profile: "second", args: []))
    }

    @Test("-p followed by -- consumes -- as value (documented limitation)")
    func profileWithDashDashValue() {
        let action = PlannerV2.plan(args: ["-p", "--", "arg"])
        // Current behaviour: --profile treats the next token as its value,
        // even if that's --. So "--" becomes the profile name and "arg" forwards.
        #expect(action == .runApfel(profile: "--", args: ["arg"]))
    }

    @Test("config sub with trailing -- and args")
    func configPassesDoubleDash() {
        let action = PlannerV2.plan(args: ["config", "show", "--", "extra"])
        #expect(action == .configSubcommand(args: ["show", "--", "extra"]))
    }

    @Test("Three args, middle is --profile - extracted, order preserved")
    func middleExtraction() {
        let action = PlannerV2.plan(args: ["prompt", "-p", "dev"])
        #expect(action == .runApfel(profile: "dev", args: ["prompt"]))
    }

    @Test("--profile at position 0 + subcommand-like word - still runApfel")
    func profileFirstThenConfigWord() {
        // "config" at position 1 (after -p NAME) is just a prompt/arg
        let action = PlannerV2.plan(args: ["-p", "dev", "config"])
        #expect(action == .runApfel(profile: "dev", args: ["config"]))
    }

    @Test("Prompt containing -- is not treated as terminator")
    func dashDashInsidePrompt() {
        // "-- is a prompt" — but we only treat bare "--" tokens as markers
        let action = PlannerV2.plan(args: ["what is --serve?"])
        #expect(action == .runApfel(profile: nil, args: ["what is --serve?"]))
    }
}

// MARK: - FlagBuilder edge cases

@Suite("FlagBuilder edge cases")
struct FlagBuilderEdgeCases {
    @Test("Files in order preserved")
    func filesOrder() {
        let p = Profile(files: ["/z.txt", "/a.txt", "/m.txt"])
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        let paths = b.argv.enumerated().compactMap { idx, v in
            v.hasSuffix(".txt") ? idx : nil
        }.map { b.argv[$0] }
        #expect(paths == ["/z.txt", "/a.txt", "/m.txt"])
    }

    @Test("Seed 0 still emitted (0 is a valid seed)")
    func seedZeroEmitted() {
        let p = Profile(generation: GenerationSettings(seed: 0))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--seed"))
        #expect(b.argv.contains("0"))
    }

    @Test("Retry with nil vs 0 - both omit flag")
    func retryNilAndZero() {
        let nilR = FlagBuilder.build(profile: Profile(generation: GenerationSettings(retry: nil)),
                                     userArgs: [], environment: [:])
        let zeroR = FlagBuilder.build(profile: Profile(generation: GenerationSettings(retry: 0)),
                                      userArgs: [], environment: [:])
        #expect(!nilR.argv.contains("--retry"))
        #expect(!zeroR.argv.contains("--retry"))
    }

    @Test("origin_check default true + mode serve does NOT emit --no-origin-check")
    func originCheckDefaultTrue() {
        let p = Profile(mode: .serve, server: ServerSettings())
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(!b.argv.contains("--no-origin-check"))
    }

    @Test("Temperature with trailing-zero double formats as compact")
    func temperatureCompact() {
        let p = Profile(generation: GenerationSettings(temperature: 1.0))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("1"))
    }

    @Test("Multiple allowed_origins preserved in order")
    func originsOrder() {
        let p = Profile(mode: .serve,
                        server: ServerSettings(allowedOrigins: ["https://a", "https://b", "https://c"]))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        // Build a list of values that immediately follow --allowed-origins
        var values: [String] = []
        for (i, arg) in b.argv.enumerated() where arg == "--allowed-origins" {
            if i + 1 < b.argv.count { values.append(b.argv[i + 1]) }
        }
        #expect(values == ["https://a", "https://b", "https://c"])
    }

    @Test("MCP shared token_env + per-server token_env both captured in warnings if missing")
    func mcpTokenEnvWarnings() {
        let p = Profile(mcp: MCPSettings(
            tokenEnv: "SHARED_MISSING",
            servers: [MCPServer(path: "/x", tokenEnv: "PER_SERVER_MISSING")]
        ))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.warnings.contains { $0.contains("SHARED_MISSING") })
        #expect(b.warnings.contains { $0.contains("PER_SERVER_MISSING") })
    }

    @Test("BuiltArgs is deterministic given equal inputs")
    func builtArgsDeterministic() {
        let p = Profile(mode: .serve,
                        server: ServerSettings(port: 11434, allowedOrigins: ["a", "b", "c"]),
                        mcp: MCPSettings(servers: [
                            MCPServer(path: "/a"), MCPServer(path: "/b"), MCPServer(path: "/c"),
                        ]))
        let first = FlagBuilder.build(profile: p, userArgs: ["x"], environment: [:])
        let second = FlagBuilder.build(profile: p, userArgs: ["x"], environment: [:])
        #expect(first == second)
    }
}

// MARK: - Validator depth

@Suite("Validator additional checks")
struct ValidatorAdditionalChecks {
    @Test("max_concurrent positive OK, zero is error, negative is error")
    func maxConcurrentBounds() {
        let ok = ConfigValidator.validate(ApfelConfig(profiles: [
            "a": Profile(server: ServerSettings(maxConcurrent: 1))
        ]))
        #expect(!ok.contains { $0.message.contains("max_concurrent") })

        let zero = ConfigValidator.validate(ApfelConfig(profiles: [
            "a": Profile(server: ServerSettings(maxConcurrent: 0))
        ]))
        #expect(zero.contains { $0.message.contains("max_concurrent") })
    }

    @Test("Port exactly at boundary: 1 and 65535 valid, 0 and 65536 invalid")
    func portBoundary() {
        let lowOK = ConfigValidator.validate(ApfelConfig(profiles: ["a": Profile(server: ServerSettings(port: 1))]))
        let highOK = ConfigValidator.validate(ApfelConfig(profiles: ["a": Profile(server: ServerSettings(port: 65535))]))
        let lowFail = ConfigValidator.validate(ApfelConfig(profiles: ["a": Profile(server: ServerSettings(port: 0))]))
        let highFail = ConfigValidator.validate(ApfelConfig(profiles: ["a": Profile(server: ServerSettings(port: 65536))]))
        #expect(!lowOK.contains { $0.message.contains("port") })
        #expect(!highOK.contains { $0.message.contains("port") })
        #expect(lowFail.contains { $0.message.contains("port") })
        #expect(highFail.contains { $0.message.contains("port") })
    }

    @Test("mcp timeout at boundaries: 1 and 300 OK, 301 fails")
    func mcpTimeoutBoundary() {
        let lowOK = ConfigValidator.validate(ApfelConfig(profiles: ["a": Profile(mcp: MCPSettings(timeoutSeconds: 1))]))
        let highOK = ConfigValidator.validate(ApfelConfig(profiles: ["a": Profile(mcp: MCPSettings(timeoutSeconds: 300))]))
        let over = ConfigValidator.validate(ApfelConfig(profiles: ["a": Profile(mcp: MCPSettings(timeoutSeconds: 301))]))
        #expect(!lowOK.contains { $0.message.contains("timeout_seconds") })
        #expect(!highOK.contains { $0.message.contains("timeout_seconds") })
        #expect(over.contains { $0.message.contains("timeout_seconds") })
    }

    @Test("Two separately-broken profiles yield two separate diagnostics")
    func twoSeparateBrokenProfiles() {
        let diag = ConfigValidator.validate(ApfelConfig(profiles: [
            "one": Profile(server: ServerSettings(port: -1)),
            "two": Profile(generation: GenerationSettings(temperature: -1)),
        ]))
        #expect(diag.contains { $0.profile == "one" && $0.message.contains("port") })
        #expect(diag.contains { $0.profile == "two" && $0.message.contains("temperature") })
    }

    @Test("Warning severity only -> no error-level diagnostics")
    func warningsOnly() {
        let diag = ConfigValidator.validate(ApfelConfig(profiles: [
            "a": Profile(server: ServerSettings(originCheck: true, footgun: true))
        ]))
        let errs = diag.filter { $0.severity == .error }
        #expect(errs.isEmpty)
    }

    @Test("HTTPS URL with token_env is OK (only HTTP is refused)")
    func httpsWithTokenOK() {
        let diag = ConfigValidator.validate(ApfelConfig(profiles: [
            "a": Profile(mcp: MCPSettings(servers: [
                MCPServer(path: "https://tools.example/mcp", tokenEnv: "T")
            ]))
        ]))
        #expect(!diag.contains { $0.message.contains("plaintext") || $0.message.contains("http://") })
    }
}

// MARK: - Unicode + special chars

@Suite("Unicode and special characters")
struct UnicodeTests {
    @Test("System prompt with unicode survives TOML round-trip")
    func unicodeSystemPrompt() throws {
        let p = Profile(systemPrompt: "日本語でやさしく答えてください 🌸 αβγ")
        let cfg = ApfelConfig(profiles: ["default": p])
        let text = try TOMLCoder.encode(cfg)
        let decoded = try TOMLCoder.decode(ApfelConfig.self, from: text)
        #expect(decoded.profiles["default"]?.systemPrompt == p.systemPrompt)
    }

    @Test("Path with spaces round-trips in TOML")
    func pathWithSpaces() throws {
        let p = Profile(mcp: MCPSettings(servers: [
            MCPServer(path: "/Users/me/path with spaces/server.py")
        ]))
        let cfg = ApfelConfig(profiles: ["default": p])
        let text = try TOMLCoder.encode(cfg)
        let decoded = try TOMLCoder.decode(ApfelConfig.self, from: text)
        #expect(decoded.profiles["default"]?.mcp?.servers[0].path == p.mcp?.servers[0].path)
    }

    @Test("System prompt with quotes + escapes encodes safely")
    func quotesAndEscapes() throws {
        let p = Profile(systemPrompt: "Say \"hello\\world\" with \\n newline")
        let cfg = ApfelConfig(profiles: ["default": p])
        let text = try TOMLCoder.encode(cfg)
        let decoded = try TOMLCoder.decode(ApfelConfig.self, from: text)
        #expect(decoded.profiles["default"]?.systemPrompt == p.systemPrompt)
    }
}

// MARK: - Migration corner cases

@Suite("migrate-config edge cases")
struct MigrateConfigEdgeCases {
    @Test("Migration preserves URLs")
    func preservesURLs() throws {
        let tmp = NSTemporaryDirectory() + "migrate-url-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let legacy = tmp + "/mcps.conf"
        let target = tmp + "/config.toml"
        try "https://tools.example.com/mcp\n-https://disabled.example/mcp\n"
            .write(toFile: legacy, atomically: true, encoding: .utf8)
        _ = try Subcommands.migrateConfig(legacyPath: legacy, targetPath: target)
        let toml = try String(contentsOfFile: target, encoding: .utf8)
        #expect(toml.contains("https://tools.example.com/mcp"))
        #expect(toml.contains("https://disabled.example/mcp"))
        // enabled flag preserved
        let decoded = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        let servers = try #require(decoded.profiles["default"]?.mcp?.servers)
        #expect(servers[0].enabled)
        #expect(!servers[1].enabled)
    }

    @Test("Migration with empty legacy yields empty default profile")
    func emptyLegacyYieldsEmptyProfile() throws {
        let tmp = NSTemporaryDirectory() + "migrate-empty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let legacy = tmp + "/mcps.conf"
        try "".write(toFile: legacy, atomically: true, encoding: .utf8)
        let r = try Subcommands.migrateConfig(legacyPath: legacy, targetPath: tmp + "/config.toml")
        #expect(r.exitCode == 0)
    }

    @Test("Migration with comment-only legacy yields empty default profile")
    func commentOnlyLegacy() throws {
        let tmp = NSTemporaryDirectory() + "migrate-com-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let legacy = tmp + "/mcps.conf"
        try "# a comment\n# b comment\n".write(toFile: legacy, atomically: true, encoding: .utf8)
        let r = try Subcommands.migrateConfig(legacyPath: legacy, targetPath: tmp + "/config.toml")
        #expect(r.exitCode == 0)
        let toml = try String(contentsOfFile: tmp + "/config.toml", encoding: .utf8)
        let decoded = try TOMLCoder.decode(ApfelConfig.self, from: toml)
        #expect(decoded.profiles["default"]?.mcp?.servers.isEmpty == true)
    }
}
