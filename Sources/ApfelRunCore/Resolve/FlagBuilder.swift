import Foundation

public struct BuiltArgs: Equatable, Sendable {
    public var argv: [String]
    public var env: [String: String]
    public var warnings: [String]

    public init(argv: [String], env: [String: String], warnings: [String] = []) {
        self.argv = argv
        self.env = env
        self.warnings = warnings
    }
}

public enum FlagBuilder {
    /// Translate a profile + user args into the final argv+env pair for apfel.
    /// User args always append LAST so CLI flags override profile defaults.
    public static func build(profile: Profile,
                             userArgs: [String],
                             environment: [String: String]) -> BuiltArgs {
        var argv: [String] = []
        var env = environment
        var warnings: [String] = []

        // Mode flag (if any)
        switch profile.mode {
        case .serve: argv.append("--serve")
        case .chat: argv.append("--chat")
        case .stream: argv.append("--stream")
        case .benchmark: argv.append("--benchmark")
        case .modelInfo: argv.append("--model-info")
        case .single, nil: break
        }

        // System prompt
        if let prompt = profile.systemPrompt, !prompt.isEmpty {
            argv.append(contentsOf: ["-s", prompt])
        } else if let file = profile.systemPromptFile, !file.isEmpty {
            argv.append(contentsOf: ["--system-file", file])
        }

        // Files
        for f in profile.files {
            argv.append(contentsOf: ["--file", f])
        }

        // Output format
        if let fmt = profile.outputFormat {
            argv.append(contentsOf: ["--output", fmt.rawValue])
        }

        if profile.quiet { argv.append("-q") }
        if profile.noColor { argv.append("--no-color") }
        if profile.debug { argv.append("--debug") }
        if profile.permissive { argv.append("--permissive") }

        // Generation
        if let g = profile.generation {
            if let t = g.temperature {
                argv.append(contentsOf: ["--temperature", formatDouble(t)])
            }
            if let s = g.seed {
                argv.append(contentsOf: ["--seed", String(s)])
            }
            if let m = g.maxTokens {
                argv.append(contentsOf: ["--max-tokens", String(m)])
            }
            if let r = g.retry, r > 0 {
                argv.append(contentsOf: ["--retry", String(r)])
            }
        }

        // Context
        if let c = profile.context {
            if let s = c.strategy {
                argv.append(contentsOf: ["--context-strategy", s.rawValue])
            }
            if let mt = c.maxTurns {
                argv.append(contentsOf: ["--context-max-turns", String(mt)])
            }
            if let or = c.outputReserve {
                argv.append(contentsOf: ["--context-output-reserve", String(or)])
            }
        }

        // Server (only for serve mode)
        if profile.mode == .serve, let s = profile.server {
            if let port = s.port { argv.append(contentsOf: ["--port", String(port)]) }
            if let host = s.host { argv.append(contentsOf: ["--host", host]) }
            if s.cors { argv.append("--cors") }
            if let mc = s.maxConcurrent { argv.append(contentsOf: ["--max-concurrent", String(mc)]) }
            for origin in s.allowedOrigins {
                argv.append(contentsOf: ["--allowed-origins", origin])
            }
            if s.tokenAuto {
                argv.append("--token-auto")
            } else if let tokenEnv = s.tokenEnv {
                if let val = environment[tokenEnv], !val.isEmpty {
                    env["APFEL_TOKEN"] = val
                } else {
                    warnings.append("server.token_env '\(tokenEnv)' is empty or not set - skipping APFEL_TOKEN")
                }
            }
            if s.publicHealth { argv.append("--public-health") }
            if !s.originCheck { argv.append("--no-origin-check") }
            if s.footgun { argv.append("--footgun") }
        }

        // MCP - these go via environment, not CLI flags
        if let m = profile.mcp {
            let enabled = m.servers.filter(\.enabled).map(\.path)
            if !enabled.isEmpty {
                let configPart = enabled.joined(separator: ",")
                if let existing = env["APFEL_MCP"], !existing.isEmpty {
                    env["APFEL_MCP"] = existing + "," + configPart
                } else {
                    env["APFEL_MCP"] = configPart
                }
            }
            if let ts = m.timeoutSeconds {
                env["APFEL_MCP_TIMEOUT"] = String(ts)
            }
            if let tokenEnv = m.tokenEnv {
                if let val = environment[tokenEnv], !val.isEmpty {
                    env["APFEL_MCP_TOKEN"] = val
                } else {
                    warnings.append("mcp.token_env '\(tokenEnv)' is empty or not set")
                }
            }
            // Per-server token_env overrides are noted in warnings if we can't resolve
            for (i, server) in m.servers.enumerated() where server.enabled {
                if let tokenEnv = server.tokenEnv {
                    if environment[tokenEnv]?.isEmpty ?? true {
                        warnings.append("mcp.server[\(i)].token_env '\(tokenEnv)' is empty or not set")
                    }
                    // Note: apfel itself uses a single APFEL_MCP_TOKEN today - per-server
                    // tokens will be threaded once apfel supports per-MCP auth. Recorded
                    // here for forward-compat.
                }
            }
        }

        // User CLI args appended last - they override profile defaults.
        argv.append(contentsOf: userArgs)

        return BuiltArgs(argv: argv, env: env, warnings: warnings)
    }

    static func formatDouble(_ d: Double) -> String {
        // Trim trailing zeros, keep "0.7" etc. compact
        if d.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(d))
        }
        return String(d)
    }
}
