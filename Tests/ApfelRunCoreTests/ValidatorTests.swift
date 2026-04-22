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
}
