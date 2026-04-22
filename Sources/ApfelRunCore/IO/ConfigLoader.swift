import Foundation

public enum ConfigSource: Equatable, Sendable {
    case none
    case envOverride     // $APFEL_RUN_CONFIG
    case projectLocal    // ./apfel.toml or ./apfel.json
    case globalXDG       // $XDG_CONFIG_HOME/apfel/config.{toml,json}
    case globalHome      // ~/.config/apfel/config.{toml,json} (XDG default)
    case systemXDG       // $XDG_CONFIG_DIRS/apfel/config.{toml,json} (default /etc/xdg)
    case legacyMCPConf   // ~/.config/apfel/mcps.conf (v0.1 fallback)
}

public struct LoaderResult: Equatable, Sendable {
    public let config: ApfelConfig
    public let source: ConfigSource
    public let path: String?

    public init(config: ApfelConfig, source: ConfigSource, path: String?) {
        self.config = config
        self.source = source
        self.path = path
    }
}

public struct ConfigLoaderError: Error, CustomStringConvertible {
    public let path: String
    public let underlying: Error

    public var description: String {
        "failed to load \(path): \(underlying)"
    }
}

public enum ConfigLoader {
    /// Non-throwing variant: unreadable or malformed files fall through to .none.
    /// Useful in the exec path where we prefer "behave like pure apfel" over hard-error.
    public static func load(environment: [String: String],
                            cwd: String,
                            home: String) -> LoaderResult {
        do {
            return try loadThrowing(environment: environment, cwd: cwd, home: home)
        } catch {
            return LoaderResult(config: ApfelConfig(), source: .none, path: nil)
        }
    }

    /// Throwing variant: used by `config validate`. Reports the offending file.
    public static func loadThrowing(environment: [String: String],
                                    cwd: String,
                                    home: String) throws -> LoaderResult {
        // 1. Explicit override via env
        if let override = environment["APFEL_RUN_CONFIG"], !override.isEmpty {
            if let cfg = try readFormatted(path: override) {
                return LoaderResult(config: cfg, source: .envOverride, path: override)
            }
            return LoaderResult(config: ApfelConfig(), source: .none, path: nil)
        }

        // 2. Project-local
        for ext in ["toml", "json"] {
            let path = cwd + "/apfel." + ext
            if FileManager.default.fileExists(atPath: path),
               let cfg = try readFormatted(path: path) {
                return LoaderResult(config: cfg, source: .projectLocal, path: path)
            }
        }

        // 3. User config: $XDG_CONFIG_HOME or ~/.config (XDG default)
        let xdgHomeExplicit = !(environment["XDG_CONFIG_HOME"]?.isEmpty ?? true)
        let userBase: String
        if xdgHomeExplicit, let xdg = environment["XDG_CONFIG_HOME"] {
            userBase = xdg
        } else {
            userBase = home + "/.config"
        }
        let userSource: ConfigSource = xdgHomeExplicit ? .globalXDG : .globalHome
        for ext in ["toml", "json"] {
            let path = userBase + "/apfel/config." + ext
            if FileManager.default.fileExists(atPath: path),
               let cfg = try readFormatted(path: path) {
                return LoaderResult(config: cfg, source: userSource, path: path)
            }
        }

        // 4. System config: $XDG_CONFIG_DIRS (colon-separated, first-hit-wins)
        //    Default is /etc/xdg per the XDG Base Directory Spec.
        for dir in systemConfigDirs(environment: environment) {
            for ext in ["toml", "json"] {
                let path = dir + "/apfel/config." + ext
                if FileManager.default.fileExists(atPath: path),
                   let cfg = try readFormatted(path: path) {
                    return LoaderResult(config: cfg, source: .systemXDG, path: path)
                }
            }
        }

        // 5. Legacy mcps.conf fallback (v0.2 grace; v0.3 removes)
        let legacy = home + "/.config/apfel/mcps.conf"
        if FileManager.default.fileExists(atPath: legacy),
           let cfg = try readLegacy(path: legacy) {
            return LoaderResult(config: cfg, source: .legacyMCPConf, path: legacy)
        }

        return LoaderResult(config: ApfelConfig(), source: .none, path: nil)
    }

    /// Returns every path the loader would inspect for the given environment,
    /// in priority order. Primary use: `apfel-run config path --all` and docs.
    public static func searchPaths(environment: [String: String],
                                   cwd: String,
                                   home: String) -> [String] {
        var paths: [String] = []

        if let override = environment["APFEL_RUN_CONFIG"], !override.isEmpty {
            paths.append(override)
        }

        // Project-local
        for ext in ["toml", "json"] {
            paths.append(cwd + "/apfel." + ext)
        }

        // User config
        let userBase: String
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            userBase = xdg
        } else {
            userBase = home + "/.config"
        }
        for ext in ["toml", "json"] {
            paths.append(userBase + "/apfel/config." + ext)
        }

        // System config (XDG_CONFIG_DIRS, default /etc/xdg)
        for dir in systemConfigDirs(environment: environment) {
            for ext in ["toml", "json"] {
                paths.append(dir + "/apfel/config." + ext)
            }
        }

        // Legacy
        paths.append(home + "/.config/apfel/mcps.conf")

        return paths
    }

    /// $XDG_CONFIG_DIRS split on colon, empty entries removed. Defaults to
    /// ["/etc/xdg"] per the XDG Base Directory Spec.
    static func systemConfigDirs(environment: [String: String]) -> [String] {
        if let raw = environment["XDG_CONFIG_DIRS"], !raw.isEmpty {
            return raw.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
        return ["/etc/xdg"]
    }

    // MARK: - Helpers

    private static func readFormatted(path: String) throws -> ApfelConfig? {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigLoaderError(path: path, underlying: error)
        }

        let lower = path.lowercased()
        if lower.hasSuffix(".toml") {
            do {
                return try TOMLCoder.decode(ApfelConfig.self, from: text)
            } catch {
                throw ConfigLoaderError(path: path, underlying: error)
            }
        }
        if lower.hasSuffix(".json") {
            do {
                return try JSONCoder.decode(ApfelConfig.self, from: Data(text.utf8))
            } catch {
                throw ConfigLoaderError(path: path, underlying: error)
            }
        }
        // Unknown extension - treat as TOML
        do {
            return try TOMLCoder.decode(ApfelConfig.self, from: text)
        } catch {
            throw ConfigLoaderError(path: path, underlying: error)
        }
    }

    private static func readLegacy(path: String) throws -> ApfelConfig? {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigLoaderError(path: path, underlying: error)
        }
        let parsed = ConfigParser.parse(text)
        let servers = parsed.entries.map {
            MCPServer(path: $0.path, enabled: $0.enabled)
        }
        let profile = Profile(mcp: MCPSettings(servers: servers))
        return ApfelConfig(profiles: ["default": profile])
    }
}
