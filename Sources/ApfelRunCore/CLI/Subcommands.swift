import Foundation

/// Subcommand handlers - all pure functions that take resolved inputs and
/// produce text output + exit code. No I/O except file reads for migrate.
public enum Subcommands {
    public struct Result: Equatable, Sendable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32

        public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    // MARK: - config show

    public enum ShowFormat: String, Sendable {
        case toml
        case json
        case flags
    }

    public static func configShow(loaderResult: LoaderResult,
                                  profile: String?,
                                  format: ShowFormat,
                                  environment: [String: String]) -> Result {
        switch format {
        case .toml:
            do {
                let text = try TOMLCoder.encode(loaderResult.config)
                return Result(stdout: text)
            } catch {
                return Result(stderr: "encode error: \(error)\n", exitCode: 1)
            }
        case .json:
            do {
                let data = try JSONCoder.encode(loaderResult.config)
                return Result(stdout: (String(data: data, encoding: .utf8) ?? "") + "\n")
            } catch {
                return Result(stderr: "encode error: \(error)\n", exitCode: 1)
            }
        case .flags:
            do {
                let resolved = try ProfileResolver.resolve(config: loaderResult.config,
                                                           requested: profile,
                                                           environment: environment)
                let built = FlagBuilder.build(profile: resolved.profile,
                                              userArgs: [],
                                              environment: environment)
                var lines: [String] = []
                lines.append("# profile: \(resolved.name.isEmpty ? "(none)" : resolved.name)")
                lines.append("# argv:")
                for arg in built.argv {
                    lines.append("  " + arg)
                }
                // Only show APFEL_* env vars apfel-run controls, not the full
                // inherited environment. Also redact token-bearing ones.
                let apfelEnv = built.env.filter { $0.key.hasPrefix("APFEL_") }
                if !apfelEnv.isEmpty {
                    lines.append("# env:")
                    for (k, v) in apfelEnv.sorted(by: { $0.key < $1.key }) {
                        if k.lowercased().contains("token") {
                            lines.append("  \(k)=<redacted>")
                        } else {
                            lines.append("  \(k)=\(v)")
                        }
                    }
                }
                if !built.warnings.isEmpty {
                    lines.append("# warnings:")
                    for w in built.warnings {
                        lines.append("  " + w)
                    }
                }
                return Result(stdout: lines.joined(separator: "\n") + "\n")
            } catch {
                return Result(stderr: "\(error)\n", exitCode: 2)
            }
        }
    }

    // MARK: - config path

    public static func configPath(loaderResult: LoaderResult) -> Result {
        if let path = loaderResult.path {
            return Result(stdout: path + "\n")
        }
        return Result(stdout: "")
    }

    // MARK: - config validate

    public static func configValidate(loaderResult: LoaderResult) -> Result {
        let diagnostics = ConfigValidator.validate(loaderResult.config)
        let errors = diagnostics.filter { $0.severity == .error }
        let warnings = diagnostics.filter { $0.severity == .warning }

        var out = ""
        if errors.isEmpty && warnings.isEmpty {
            out = "✔ config is valid"
            if let path = loaderResult.path {
                out += " (\(path))"
            }
            out += "\n"
            return Result(stdout: out)
        }
        for e in errors {
            out += "error [\(e.profile)]: \(e.message)\n"
        }
        for w in warnings {
            out += "warning [\(w.profile)]: \(w.message)\n"
        }
        if !errors.isEmpty {
            return Result(stderr: out, exitCode: 1)
        }
        return Result(stdout: out)
    }

    // MARK: - config profiles

    public static func configProfiles(loaderResult: LoaderResult) -> Result {
        let names = loaderResult.config.profiles.keys.sorted()
        if names.isEmpty {
            return Result(stderr: "no profiles configured\n", exitCode: 0)
        }
        return Result(stdout: names.joined(separator: "\n") + "\n")
    }

    // MARK: - config init

    public static func configInit(targetPath: String,
                                  fileManager: FileManager = .default,
                                  existsOverride: ((String) -> Bool)? = nil) throws -> Result {
        let exists = existsOverride?(targetPath) ?? fileManager.fileExists(atPath: targetPath)
        if exists {
            return Result(stderr: "refusing to overwrite existing file: \(targetPath)\n", exitCode: 1)
        }
        let dir = (targetPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Self.starterConfig.write(toFile: targetPath, atomically: true, encoding: .utf8)
        return Result(stdout: "wrote starter config to \(targetPath)\n",
                      stderr: "next: $EDITOR \(targetPath)\n")
    }

    // MARK: - migrate-config

    public static func migrateConfig(legacyPath: String,
                                     targetPath: String,
                                     fileManager: FileManager = .default) throws -> Result {
        guard fileManager.fileExists(atPath: legacyPath) else {
            return Result(stderr: "no legacy config at \(legacyPath)\n", exitCode: 1)
        }
        let text = try String(contentsOfFile: legacyPath, encoding: .utf8)
        let parsed = ConfigParser.parse(text)
        let servers = parsed.entries.map { MCPServer(path: $0.path, enabled: $0.enabled) }
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mcp: MCPSettings(servers: servers))
        ])
        let toml = try TOMLCoder.encode(cfg)
        let dir = (targetPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try toml.write(toFile: targetPath, atomically: true, encoding: .utf8)

        // Rename legacy file to .v0.1.bak (don't delete)
        let backupPath = legacyPath + ".v0.1.bak"
        if fileManager.fileExists(atPath: backupPath) {
            try? fileManager.removeItem(atPath: backupPath)
        }
        try fileManager.moveItem(atPath: legacyPath, toPath: backupPath)

        return Result(stdout: """
        migrated:
          from: \(legacyPath)   (renamed to \(backupPath))
          to:   \(targetPath)
          profiles: default   (\(servers.filter(\.enabled).count) enabled, \(servers.count - servers.filter(\.enabled).count) disabled MCPs)

        """)
    }

    // MARK: - Starter config

    public static let starterConfig = #"""
    # apfel-run configuration
    # Full reference: https://github.com/Arthur-Ficial/apfel-run/blob/main/docs/config-reference.md
    #
    # This file defines one or more named profiles. Each profile is a complete,
    # independent set of settings for apfel. Pick a profile at run time with:
    #
    #   apfel-run --profile NAME [apfel-args...]
    #
    # If no --profile is given, the [profile.default] section is used.
    #
    # Precedence (low to high):
    #   1. apfel built-in defaults
    #   2. APFEL_* env vars (apfel reads these itself)
    #   3. values from the active profile below
    #   4. CLI flags you pass at the end  (these always win)
    #
    # Never put raw tokens in this file. Use token_env = "NAME_OF_ENV_VAR"
    # so the secret stays out of source control.

    [profile.default]
    # mode = "single" | "stream" | "chat" | "serve" | "benchmark" | "model-info"
    # system_prompt = "You are a concise assistant."
    # output_format = "plain"    # or "json"
    # quiet = false
    # no_color = false
    # permissive = false

    [profile.default.generation]
    # temperature = 0.7
    # max_tokens = 500
    # retry = 3                 # 0 = disabled

    [profile.default.mcp]
    # timeout_seconds = 30
    # token_env = "APFEL_MCP_TOKEN"

    # One [[profile.default.mcp.server]] block per MCP. Prefix enabled = false
    # to keep the entry but skip it at runtime.
    # [[profile.default.mcp.server]]
    # path = "/Users/me/mcp/calc.py"
    # enabled = true

    # -------------------------------------------------------------------
    # Example research profile using apfel-mcp tools.
    # Install the MCPs first: brew install Arthur-Ficial/tap/apfel-mcp
    # Then pick this profile with:   apfel-run -p research "..."

    # [profile.research]
    # mode = "single"
    # system_prompt = "You are a research assistant. Use search and fetch tools to ground answers in real sources."
    #
    # [[profile.research.mcp.server]]
    # path = "/opt/homebrew/bin/apfel-mcp-ddg-search"
    # enabled = true
    #
    # [[profile.research.mcp.server]]
    # path = "/opt/homebrew/bin/apfel-mcp-url-fetch"
    # enabled = true
    #
    # [[profile.research.mcp.server]]
    # path = "/opt/homebrew/bin/apfel-mcp-search-and-fetch"
    # enabled = true

    # -------------------------------------------------------------------
    # Example server profile:
    #
    # [profile.serve]
    # mode = "serve"
    #
    # [profile.serve.server]
    # port = 11434
    # host = "127.0.0.1"
    # token_auto = true         # fresh UUID token each boot; apfel prints it
    # public_health = false
    # origin_check = true
    # allowed_origins = ["https://app.example.com"]
    """#
}
