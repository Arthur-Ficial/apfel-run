import Foundation

public struct Diagnostic: Equatable, Sendable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let severity: Severity
    public let profile: String
    public let message: String

    public init(severity: Severity, profile: String, message: String) {
        self.severity = severity
        self.profile = profile
        self.message = message
    }
}

public enum ConfigValidator {
    public static func validate(_ config: ApfelConfig) -> [Diagnostic] {
        var out: [Diagnostic] = []
        for (name, profile) in config.profiles.sorted(by: { $0.key < $1.key }) {
            validateProfile(name: name, profile: profile, into: &out)
        }
        return out
    }

    static func validateProfile(name: String, profile: Profile, into out: inout [Diagnostic]) {
        // system_prompt xor system_prompt_file
        if profile.systemPrompt != nil, profile.systemPromptFile != nil,
           !(profile.systemPrompt?.isEmpty ?? true),
           !(profile.systemPromptFile?.isEmpty ?? true) {
            out.append(.init(severity: .error, profile: name,
                             message: "system_prompt and system_prompt_file are mutually exclusive"))
        }

        if let gen = profile.generation {
            if let temp = gen.temperature, temp < 0 {
                out.append(.init(severity: .error, profile: name,
                                 message: "temperature must be >= 0 (got \(temp))"))
            }
            if let maxTok = gen.maxTokens, maxTok < 1 {
                out.append(.init(severity: .error, profile: name,
                                 message: "max_tokens must be >= 1 (got \(maxTok))"))
            }
            if let retry = gen.retry, retry < 0 {
                out.append(.init(severity: .error, profile: name,
                                 message: "retry must be >= 0 (got \(retry))"))
            }
        }

        if let ctx = profile.context {
            if let maxTurns = ctx.maxTurns, maxTurns < 1 {
                out.append(.init(severity: .error, profile: name,
                                 message: "context.max_turns must be >= 1 (got \(maxTurns))"))
            }
            if let reserve = ctx.outputReserve, reserve < 1 {
                out.append(.init(severity: .error, profile: name,
                                 message: "context.output_reserve must be >= 1 (got \(reserve))"))
            }
        }

        if let srv = profile.server {
            if let port = srv.port, !(1...65535).contains(port) {
                out.append(.init(severity: .error, profile: name,
                                 message: "server.port must be 1-65535 (got \(port))"))
            }
            if let mc = srv.maxConcurrent, mc < 1 {
                out.append(.init(severity: .error, profile: name,
                                 message: "server.max_concurrent must be >= 1 (got \(mc))"))
            }
            // footgun with origin_check still on = user mistake
            if srv.footgun, srv.originCheck {
                out.append(.init(severity: .warning, profile: name,
                                 message: "server.footgun is set but origin_check is also on - footgun already implies origin_check=false"))
            }
        }

        if let mcp = profile.mcp {
            if let ts = mcp.timeoutSeconds, !(1...300).contains(ts) {
                out.append(.init(severity: .error, profile: name,
                                 message: "mcp.timeout_seconds must be 1-300 (got \(ts))"))
            }
            for (i, srv) in mcp.servers.enumerated() {
                if srv.path.isEmpty {
                    out.append(.init(severity: .error, profile: name,
                                     message: "mcp.server[\(i)].path is empty"))
                }
                if srv.tokenEnv != nil,
                   srv.path.lowercased().hasPrefix("http://") {
                    out.append(.init(severity: .error, profile: name,
                                     message: "mcp.server[\(i)] refuses to send token_env over plaintext http:// URL"))
                }
                if srv.auth == .oauth {
                    let secure = URL(string: srv.path).map(isSecureOrLoopback(_:)) ?? false
                    if !secure {
                        out.append(.init(severity: .error, profile: name,
                                         message: "mcp.server[\(i)] auth = \"oauth\" requires an https:// URL (got '\(srv.path)')"))
                    }
                    if srv.tokenEnv != nil {
                        out.append(.init(severity: .warning, profile: name,
                                         message: "mcp.server[\(i)] sets both auth = \"oauth\" and token_env - token_env overrides the stored OAuth token"))
                    }
                }
            }
            let oauthCount = mcp.servers.filter { $0.enabled && $0.auth == .oauth }.count
            if oauthCount > 1 {
                out.append(.init(severity: .error, profile: name,
                                 message: "profile enables \(oauthCount) OAuth MCP servers but apfel supports one MCP token today (apfel#386) - disable one or move it to its own profile"))
            }
        }
    }
}
