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
    public static func plan(args: [String],
                            config: Config,
                            environment: [String: String],
                            configPath: String,
                            apfelBinary: String = "apfel") -> RunPlan {
        var forwarded: [String] = []
        var listOnly = false
        var showHelp = false
        var showVersion = false
        var showConfigPath = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--list":
                listOnly = true
            case "--help", "-h":
                showHelp = true
            case "--version", "-v":
                showVersion = true
            case "--config-path":
                showConfigPath = true
            case "--":
                forwarded.append(contentsOf: args[(i + 1)...])
                i = args.count
                continue
            default:
                forwarded.append(arg)
            }
            i += 1
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
          apfel-run [--list | --config-path] [APFEL_ARGS...]
          apfel-run -- [APFEL_ARGS...]            # pass flags that conflict with apfel-run

        FLAGS:
          --list           Print registered MCPs and their enabled/disabled state
          --config-path    Print the effective config file path and exit
          --version, -v    Print version and exit
          --help, -h       Print this help and exit

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
          (comma-separated), and execs 'apfel' with your forwarded arguments.
          Any APFEL_MCP value already in your environment is prepended to the
          one derived from config so ad-hoc shell overrides still work.

        EDITING:
          Just open ~/.config/apfel/mcps.conf in $EDITOR. Comment out (-) to
          disable, uncomment (remove -) to enable. No sub-command needed.
        """
    }
}
