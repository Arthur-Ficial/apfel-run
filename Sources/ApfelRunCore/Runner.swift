import Foundation

public struct RunPlan: Equatable, Sendable {
    public let apfelBinary: String
    public let forwardedArgs: [String]
    public let environment: [String: String]
    public let listOnly: Bool
    public let showHelp: Bool
    public let showVersion: Bool
    public let showConfigPath: Bool
    public let configPath: String

    public init(apfelBinary: String,
                forwardedArgs: [String],
                environment: [String: String],
                listOnly: Bool,
                showHelp: Bool,
                showVersion: Bool,
                showConfigPath: Bool,
                configPath: String) {
        self.apfelBinary = apfelBinary
        self.forwardedArgs = forwardedArgs
        self.environment = environment
        self.listOnly = listOnly
        self.showHelp = showHelp
        self.showVersion = showVersion
        self.showConfigPath = showConfigPath
        self.configPath = configPath
    }
}

public enum Planner {
    /// apfel-run's own flags, recognised only as the FIRST argument.
    ///
    /// Any other position forwards the arg untouched to apfel, so
    /// `apfel-run "translate --help to Spanish"` and
    /// `apfel-run --chat --mcp /x.py` work exactly as the user expects.
    ///
    /// Collision escape: `apfel-run -- --list` forces `--list` to
    /// forward to apfel (useful if apfel ever grows its own `--list`).
    public static func plan(args: [String],
                            config: Config,
                            environment: [String: String],
                            configPath: String,
                            apfelBinary: String = "apfel") -> RunPlan {
        var listOnly = false
        var showHelp = false
        var showVersion = false
        var showConfigPath = false
        var forwarded: [String] = args

        // Positional interception: only first arg, only when it matches.
        if let first = args.first {
            switch first {
            case "--list":
                listOnly = true
                forwarded = []
            case "--help", "-h":
                showHelp = true
                forwarded = []
            case "--version", "-v":
                showVersion = true
                forwarded = []
            case "--config-path":
                showConfigPath = true
                forwarded = []
            case "--":
                // Explicit "forward everything after this" - strip the marker.
                forwarded = Array(args.dropFirst())
            default:
                // Anything else (prompt, --serve, --chat, --stream, --mcp ...)
                // is forwarded verbatim. apfel-run's own flags are unreachable
                // past position 0.
                forwarded = args
            }
        }

        var env = environment
        let mcpValue = config.apfelMCPValue
        if !mcpValue.isEmpty {
            env["APFEL_MCP"] = mergeMCP(existing: env["APFEL_MCP"], additional: mcpValue)
        }

        return RunPlan(apfelBinary: apfelBinary,
                       forwardedArgs: forwarded,
                       environment: env,
                       listOnly: listOnly,
                       showHelp: showHelp,
                       showVersion: showVersion,
                       showConfigPath: showConfigPath,
                       configPath: configPath)
    }

    static func mergeMCP(existing: String?, additional: String) -> String {
        guard let existing, !existing.isEmpty else { return additional }
        return existing + "," + additional
    }
}

public enum Formatter {
    public static func listOutput(config: Config, configPath: String) -> String {
        if config.entries.isEmpty {
            return "apfel-run: no MCPs configured\nconfig: \(configPath)\n"
        }
        var lines = ["apfel-run MCPs (\(configPath)):"]
        for entry in config.entries {
            let marker = entry.enabled ? "[x]" : "[ ]"
            lines.append("  \(marker) \(entry.path)")
        }
        let enabledCount = config.entries.filter(\.enabled).count
        lines.append("")
        lines.append("\(enabledCount) enabled, \(config.entries.count - enabledCount) disabled")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func helpText(version: String) -> String {
        """
        apfel-run \(version) - wrap apfel with an MCP registry

        USAGE:
          apfel-run                               Run apfel with registered MCPs
          apfel-run "prompt" [APFEL_FLAGS...]     Forward prompt + all apfel flags
          apfel-run --serve --port 11434          All apfel modes work: --serve, --chat, --stream
          apfel-run --list                        Print registry with enable/disable state
          apfel-run --config-path                 Print config path and exit
          apfel-run -- --help                     Show apfel's own --help (not ours)
          apfel-run -- --version                  Show apfel's own --version

        apfel-run's OWN FLAGS (only recognised as the FIRST argument):
          --list           Print registered MCPs and their enabled/disabled state
          --config-path    Print the effective config file path and exit
          --version, -v    Print apfel-run's own version
          --help, -h       Print this help

        EVERYTHING ELSE IS FORWARDED to apfel verbatim:
          Modes:     --serve, --chat, --stream
          MCP:       --mcp, --mcp-timeout, --mcp-token
          Network:   --port, --host, --token
          Model:     --model-info, --system, --temperature, --max-tokens
          Output:    --json, --quiet, -q
          Any prompt text, any positional args -> passed through unchanged.

          Past position 0 even --list, --help, --version are forwarded to apfel,
          so "apfel-run 'how do I --list my files?'" does what you expect.

        CONFIG:
          Default location:   ~/.config/apfel/mcps.conf
                              ($XDG_CONFIG_HOME/apfel/mcps.conf if set)
                              (override with $APFEL_RUN_CONFIG=path)

          Format:             one MCP per line. Prefix with '-' to disable.
                              '#' starts a comment (whole line or trailing).

          Example:
            # my apfel MCP registry
            /Users/me/mcp/calc.py
            /Users/me/mcp/web.py
            -/Users/me/mcp/filesystem.py   # disabled for now
            https://tools.example.com/mcp

        BEHAVIOUR:
          apfel-run reads the config, builds APFEL_MCP from enabled entries
          (comma-separated), and execve's 'apfel' with your forwarded arguments.
          No parent process survives, signals and exit codes pass through cleanly.
          Any APFEL_MCP value already in your environment is prepended to the
          one derived from config so ad-hoc shell overrides still work.

        ENV:
          APFEL_RUN_CONFIG          Override config file path
          APFEL_RUN_APFEL_BINARY    Override path to the apfel binary (default: $PATH lookup for 'apfel')
          APFEL_MCP                 Your shell-set MCPs, prepended to the config-derived list

        EDITING:
          Just open ~/.config/apfel/mcps.conf in $EDITOR. Comment out (prepend -) to
          disable, uncomment (remove -) to enable. No sub-command needed.
        """
    }
}
