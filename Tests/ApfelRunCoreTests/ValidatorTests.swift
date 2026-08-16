import Foundation
import Testing
@testable import ApfelRunCore

@Suite("ConfigValidator")
struct ValidatorTests {
    @Test("Empty config is valid")
    func emptyValid() {
        let errors = ConfigValidator.validate(ApfelConfig())
        #expect(errors.isEmpty)
    }

    @Test("system_prompt and system_prompt_file both set -> error")
    func systemPromptConflict() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(systemPrompt: "hi", systemPromptFile: "/x.txt")
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("system_prompt") && $0.message.contains("system_prompt_file") })
        #expect(errors.contains { $0.profile == "default" })
    }

    @Test("Port below 1 -> error")
    func portTooLow() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(server: ServerSettings(port: 0))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("port") })
    }

    @Test("Port above 65535 -> error")
    func portTooHigh() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(server: ServerSettings(port: 70000))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("port") })
    }

    @Test("Valid port 11434 -> no port error")
    func portValid() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(server: ServerSettings(port: 11434))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(!errors.contains { $0.message.contains("port") })
    }

    @Test("Negative temperature -> error")
    func negativeTemperature() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(generation: GenerationSettings(temperature: -0.1))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("temperature") })
    }

    @Test("Negative retry -> error")
    func negativeRetry() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(generation: GenerationSettings(retry: -1))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("retry") })
    }

    @Test("Zero retry is valid (disabled)")
    func zeroRetryOK() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(generation: GenerationSettings(retry: 0))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(!errors.contains { $0.message.contains("retry") })
    }

    @Test("Negative maxTokens -> error")
    func negativeMaxTokens() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(generation: GenerationSettings(maxTokens: -5))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("max_tokens") })
    }

    @Test("Negative max_concurrent -> error")
    func negativeMaxConcurrent() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(server: ServerSettings(maxConcurrent: 0))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("max_concurrent") })
    }

    @Test("Negative mcp timeout_seconds -> error")
    func negativeMCPTimeout() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(timeoutSeconds: -1))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("timeout_seconds") })
    }

    @Test("mcp timeout clamped range 1-300 enforced")
    func mcpTimeoutRange() {
        let over = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(timeoutSeconds: 500))
        ])
        let errors = ConfigValidator.validate(over)
        #expect(errors.contains { $0.message.contains("timeout_seconds") })
    }

    @Test("Negative context.max_turns -> error")
    func negativeMaxTurns() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(context: ContextSettings(maxTurns: 0))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("max_turns") })
    }

    @Test("Negative output_reserve -> error")
    func negativeOutputReserve() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(context: ContextSettings(outputReserve: -1))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("output_reserve") })
    }

    @Test("Empty MCP server path -> error")
    func emptyMCPPath() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(servers: [MCPServer(path: "")]))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("mcp") && $0.message.contains("path") })
    }

    @Test("mcp server with http (not https) token -> error")
    func httpWithTokenEnvError() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(
                servers: [MCPServer(path: "http://insecure.example/mcp",
                                    tokenEnv: "MY_TOKEN")]))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.message.contains("http://") || $0.message.contains("plaintext") })
    }

    @Test("Multiple profiles independently validated")
    func multipleProfiles() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(server: ServerSettings(port: 11434)),
            "bad": Profile(server: ServerSettings(port: -1))
        ])
        let errors = ConfigValidator.validate(cfg)
        #expect(errors.contains { $0.profile == "bad" })
        #expect(!errors.contains { $0.profile == "default" })
    }

    @Test("footgun + origin_check true is inconsistent -> warning")
    func footgunInconsistency() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(server: ServerSettings(originCheck: true, footgun: true))
        ])
        let diagnostics = ConfigValidator.validate(cfg)
        #expect(diagnostics.contains { $0.severity == .warning && $0.message.contains("footgun") })
    }

    // MARK: - auth = "oauth" (apfel-run#1)

    @Test("auth=oauth on non-https path -> error")
    func oauthNonHTTPS() {
        // Local path
        let localCfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(servers: [
                MCPServer(path: "/local/mcp.py", auth: .oauth)
            ]))
        ])
        let localErrors = ConfigValidator.validate(localCfg).filter { $0.severity == .error }
        #expect(localErrors.contains { $0.message.contains("oauth") && $0.message.contains("https") })

        // Plain http (non-loopback)
        let httpCfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(servers: [
                MCPServer(path: "http://insecure.example/mcp", auth: .oauth)
            ]))
        ])
        let httpErrors = ConfigValidator.validate(httpCfg).filter { $0.severity == .error }
        #expect(httpErrors.contains { $0.message.contains("oauth") && $0.message.contains("https") })

        // https is fine
        let httpsCfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(servers: [
                MCPServer(path: "https://mcp.example.com/mcp", auth: .oauth)
            ]))
        ])
        #expect(ConfigValidator.validate(httpsCfg).filter { $0.severity == .error }.isEmpty)
    }

    @Test("two enabled auth=oauth servers -> error mentioning apfel#386")
    func twoOAuthServersError() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(servers: [
                MCPServer(path: "https://a.example/mcp", auth: .oauth),
                MCPServer(path: "https://b.example/mcp", auth: .oauth),
            ]))
        ])
        let errors = ConfigValidator.validate(cfg).filter { $0.severity == .error }
        #expect(errors.contains { $0.message.contains("apfel#386") })
    }

    @Test("one enabled + one disabled oauth server -> no error")
    func disabledOAuthOK() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(servers: [
                MCPServer(path: "https://a.example/mcp", auth: .oauth),
                MCPServer(path: "https://b.example/mcp", enabled: false, auth: .oauth),
            ]))
        ])
        #expect(ConfigValidator.validate(cfg).filter { $0.severity == .error }.isEmpty)
    }

    @Test("auth=oauth with token_env -> warning about precedence")
    func oauthWithTokenEnvWarns() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(servers: [
                MCPServer(path: "https://a.example/mcp", tokenEnv: "MY_TOKEN", auth: .oauth)
            ]))
        ])
        let diagnostics = ConfigValidator.validate(cfg)
        #expect(diagnostics.contains {
            $0.severity == .warning && $0.message.contains("token_env") && $0.message.contains("OAuth")
        })
    }
}
