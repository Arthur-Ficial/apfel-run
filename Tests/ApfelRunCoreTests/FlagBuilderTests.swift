import Foundation
import Testing
@testable import ApfelRunCore

@Suite("FlagBuilder - profile -> apfel argv + env")
struct FlagBuilderTests {
    let configPath = "/tmp/apfel.toml"

    // MARK: - Mode flags

    @Test("mode = serve emits --serve")
    func modeServe() {
        let p = Profile(mode: .serve)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--serve"))
    }

    @Test("mode = chat emits --chat")
    func modeChat() {
        let p = Profile(mode: .chat)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--chat"))
    }

    @Test("mode = stream emits --stream")
    func modeStream() {
        let p = Profile(mode: .stream)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--stream"))
    }

    @Test("mode = single emits no mode flag (apfel default)")
    func modeSingleEmitsNothing() {
        let p = Profile(mode: .single)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(!b.argv.contains("--single"))  // apfel has no --single flag
        #expect(!b.argv.contains("--serve"))
        #expect(!b.argv.contains("--chat"))
        #expect(!b.argv.contains("--stream"))
    }

    @Test("mode = benchmark emits --benchmark")
    func modeBenchmark() {
        let p = Profile(mode: .benchmark)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--benchmark"))
    }

    @Test("mode = model-info emits --model-info")
    func modeModelInfo() {
        let p = Profile(mode: .modelInfo)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--model-info"))
    }

    // MARK: - Basic settings

    @Test("system_prompt emits -s <value>")
    func systemPrompt() {
        let p = Profile(systemPrompt: "be terse")
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("-s"))
        #expect(b.argv.contains("be terse"))
    }

    @Test("system_prompt_file emits --system-file")
    func systemPromptFile() {
        let p = Profile(systemPromptFile: "/tmp/system.txt")
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--system-file"))
        #expect(b.argv.contains("/tmp/system.txt"))
    }

    @Test("files emit --file for each (preserve order)")
    func filesMultiple() {
        let p = Profile(files: ["/a.txt", "/b.txt"])
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        // Find positions
        let idxA = b.argv.firstIndex(of: "/a.txt")
        let idxB = b.argv.firstIndex(of: "/b.txt")
        #expect(idxA != nil && idxB != nil && idxA! < idxB!)
        #expect(b.argv.filter { $0 == "--file" }.count == 2)
    }

    @Test("output_format emits --output <value>")
    func outputFormat() {
        let p = Profile(outputFormat: .json)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--output"))
        #expect(b.argv.contains("json"))
    }

    @Test("quiet=true emits -q")
    func quiet() {
        let p = Profile(quiet: true)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("-q"))
    }

    @Test("no_color=true emits --no-color")
    func noColor() {
        let p = Profile(noColor: true)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--no-color"))
    }

    @Test("debug=true emits --debug")
    func debug() {
        let p = Profile(debug: true)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--debug"))
    }

    @Test("permissive=true emits --permissive")
    func permissive() {
        let p = Profile(permissive: true)
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--permissive"))
    }

    // MARK: - Generation

    @Test("generation.temperature emits --temperature <v>")
    func generationTemperature() {
        let p = Profile(generation: GenerationSettings(temperature: 0.7))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--temperature"))
        #expect(b.argv.contains("0.7"))
    }

    @Test("generation.seed emits --seed <v>")
    func generationSeed() {
        let p = Profile(generation: GenerationSettings(seed: 42))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--seed"))
        #expect(b.argv.contains("42"))
    }

    @Test("generation.max_tokens emits --max-tokens <v>")
    func generationMaxTokens() {
        let p = Profile(generation: GenerationSettings(maxTokens: 500))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--max-tokens"))
        #expect(b.argv.contains("500"))
    }

    @Test("generation.retry=0 does not emit --retry")
    func generationRetryZeroOmits() {
        let p = Profile(generation: GenerationSettings(retry: 0))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(!b.argv.contains("--retry"))
    }

    @Test("generation.retry>0 emits --retry <count>")
    func generationRetryPositive() {
        let p = Profile(generation: GenerationSettings(retry: 3))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        let idx = b.argv.firstIndex(of: "--retry")
        #expect(idx != nil)
        if let idx {
            #expect(b.argv[idx + 1] == "3")
        }
    }

    // MARK: - Context

    @Test("context.strategy emits --context-strategy <value>")
    func contextStrategy() {
        let p = Profile(context: ContextSettings(strategy: .slidingWindow))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--context-strategy"))
        #expect(b.argv.contains("sliding-window"))
    }

    @Test("context.max_turns emits --context-max-turns <v>")
    func contextMaxTurns() {
        let p = Profile(context: ContextSettings(maxTurns: 10))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--context-max-turns"))
        #expect(b.argv.contains("10"))
    }

    @Test("context.output_reserve emits --context-output-reserve <v>")
    func contextOutputReserve() {
        let p = Profile(context: ContextSettings(outputReserve: 256))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--context-output-reserve"))
        #expect(b.argv.contains("256"))
    }

    // MARK: - Server (only when mode=serve)

    @Test("server settings emitted when mode=serve")
    func serverFlagsWhenServeMode() {
        let p = Profile(mode: .serve,
                        server: ServerSettings(port: 11500,
                                               host: "0.0.0.0",
                                               cors: true,
                                               maxConcurrent: 10,
                                               allowedOrigins: ["https://x"],
                                               tokenAuto: true,
                                               publicHealth: true,
                                               originCheck: false))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--port"))
        #expect(b.argv.contains("11500"))
        #expect(b.argv.contains("--host"))
        #expect(b.argv.contains("0.0.0.0"))
        #expect(b.argv.contains("--cors"))
        #expect(b.argv.contains("--max-concurrent"))
        #expect(b.argv.contains("10"))
        #expect(b.argv.contains("--allowed-origins"))
        #expect(b.argv.contains("https://x"))
        #expect(b.argv.contains("--token-auto"))
        #expect(b.argv.contains("--public-health"))
        #expect(b.argv.contains("--no-origin-check"))
    }

    @Test("server settings ignored when mode != serve")
    func serverFlagsIgnoredOtherMode() {
        let p = Profile(mode: .chat, server: ServerSettings(port: 11500))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(!b.argv.contains("--port"))
    }

    @Test("server footgun emits --footgun")
    func serverFootgun() {
        let p = Profile(mode: .serve, server: ServerSettings(footgun: true))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--footgun"))
    }

    @Test("server token_env resolves to APFEL_TOKEN env var when present")
    func serverTokenEnvResolved() {
        let p = Profile(mode: .serve, server: ServerSettings(tokenEnv: "MY_TOKEN"))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: ["MY_TOKEN": "secret123"])
        #expect(b.env["APFEL_TOKEN"] == "secret123")
        #expect(!b.argv.contains("secret123"))  // never passed as CLI flag
    }

    @Test("server token_env missing -> no APFEL_TOKEN set + warning")
    func serverTokenEnvMissing() {
        let p = Profile(mode: .serve, server: ServerSettings(tokenEnv: "MISSING_VAR"))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.env["APFEL_TOKEN"] == nil)
        #expect(b.warnings.contains { $0.contains("MISSING_VAR") })
    }

    // MARK: - MCP

    @Test("MCP servers build APFEL_MCP env with enabled only")
    func mcpServersToEnv() {
        let p = Profile(mcp: MCPSettings(servers: [
            MCPServer(path: "/a.py", enabled: true),
            MCPServer(path: "/b.py", enabled: false),
            MCPServer(path: "/c.py", enabled: true),
        ]))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.env["APFEL_MCP"] == "/a.py,/c.py")
    }

    @Test("MCP timeout emits APFEL_MCP_TIMEOUT env")
    func mcpTimeout() {
        let p = Profile(mcp: MCPSettings(timeoutSeconds: 60))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.env["APFEL_MCP_TIMEOUT"] == "60")
    }

    @Test("MCP shared token_env resolves to APFEL_MCP_TOKEN")
    func mcpTokenEnvShared() {
        let p = Profile(mcp: MCPSettings(tokenEnv: "SHARED_TOKEN"))
        let b = FlagBuilder.build(profile: p, userArgs: [],
                                  environment: ["SHARED_TOKEN": "sk-xyz"])
        #expect(b.env["APFEL_MCP_TOKEN"] == "sk-xyz")
    }

    @Test("MCP all-disabled does not set APFEL_MCP env")
    func mcpAllDisabled() {
        let p = Profile(mcp: MCPSettings(servers: [MCPServer(path: "/a", enabled: false)]))
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.env["APFEL_MCP"] == nil)
    }

    @Test("Existing APFEL_MCP in env is prepended to config MCPs")
    func mcpEnvPrependsConfig() {
        let p = Profile(mcp: MCPSettings(servers: [MCPServer(path: "/cfg.py")]))
        let b = FlagBuilder.build(profile: p, userArgs: [],
                                  environment: ["APFEL_MCP": "/shell.py"])
        #expect(b.env["APFEL_MCP"] == "/shell.py,/cfg.py")
    }

    // MARK: - User CLI args forwarding + override

    @Test("userArgs appended after profile flags so they override")
    func userArgsAppended() {
        let p = Profile(mode: .serve, server: ServerSettings(port: 11434))
        let b = FlagBuilder.build(profile: p,
                                  userArgs: ["--port", "11500"],
                                  environment: [:])
        // Both --port 11434 and --port 11500 in argv; apfel uses the last one
        let portIndices = b.argv.enumerated().compactMap { $0.element == "--port" ? $0.offset : nil }
        #expect(portIndices.count == 2)
        // User override comes second
        #expect(b.argv[portIndices.last! + 1] == "11500")
    }

    @Test("User prompt appended at the end")
    func userPromptAppended() {
        let p = Profile(mode: .single)
        let b = FlagBuilder.build(profile: p,
                                  userArgs: ["what is 2+2?"],
                                  environment: [:])
        #expect(b.argv.last == "what is 2+2?")
    }

    // MARK: - Full realistic fixture

    @Test("Full fixture profile produces expected argv and env")
    func fullFixture() {
        let p = Profile(
            mode: .serve,
            systemPrompt: "be terse",
            quiet: true,
            generation: GenerationSettings(temperature: 0.3, maxTokens: 500),
            server: ServerSettings(port: 11434, host: "127.0.0.1",
                                   maxConcurrent: 5, tokenAuto: true),
            mcp: MCPSettings(timeoutSeconds: 30, servers: [
                MCPServer(path: "/calc.py"),
                MCPServer(path: "/web.py", enabled: false),
            ])
        )
        let b = FlagBuilder.build(profile: p, userArgs: [], environment: [:])
        #expect(b.argv.contains("--serve"))
        #expect(b.argv.contains("-s"))
        #expect(b.argv.contains("be terse"))
        #expect(b.argv.contains("-q"))
        #expect(b.argv.contains("--temperature"))
        #expect(b.argv.contains("0.3"))
        #expect(b.argv.contains("--max-tokens"))
        #expect(b.argv.contains("500"))
        #expect(b.argv.contains("--port"))
        #expect(b.argv.contains("11434"))
        #expect(b.argv.contains("--host"))
        #expect(b.argv.contains("127.0.0.1"))
        #expect(b.argv.contains("--max-concurrent"))
        #expect(b.argv.contains("5"))
        #expect(b.argv.contains("--token-auto"))
        #expect(b.env["APFEL_MCP"] == "/calc.py")
        #expect(b.env["APFEL_MCP_TIMEOUT"] == "30")
    }
}
