import Foundation

public enum ConfigSource: Equatable, Sendable {
    case none
    case envOverride
    case projectLocal
    case globalXDG
    case globalHome
    case legacyMCPConf
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
        let projTOML = cwd + "/apfel.toml"
        let projJSON = cwd + "/apfel.json"
        if FileManager.default.fileExists(atPath: projTOML),
           let cfg = try readFormatted(path: projTOML) {
            return LoaderResult(config: cfg, source: .projectLocal, path: projTOML)
        }
        if FileManager.default.fileExists(atPath: projJSON),
           let cfg = try readFormatted(path: projJSON) {
            return LoaderResult(config: cfg, source: .projectLocal, path: projJSON)
        }

        // 3. Global XDG or home
        let xdgBase: String
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            xdgBase = xdg
        } else {
            xdgBase = home + "/.config"
        }
        let globalTOML = xdgBase + "/apfel/config.toml"
        let globalJSON = xdgBase + "/apfel/config.json"
        let globalSource: ConfigSource =
            (environment["XDG_CONFIG_HOME"]?.isEmpty == false) ? .globalXDG : .globalHome

        if FileManager.default.fileExists(atPath: globalTOML),
           let cfg = try readFormatted(path: globalTOML) {
            return LoaderResult(config: cfg, source: globalSource, path: globalTOML)
        }
        if FileManager.default.fileExists(atPath: globalJSON),
           let cfg = try readFormatted(path: globalJSON) {
            return LoaderResult(config: cfg, source: globalSource, path: globalJSON)
        }

        // 4. Legacy mcps.conf fallback (v0.2 grace; v0.3 removes)
        let legacy = home + "/.config/apfel/mcps.conf"
        if FileManager.default.fileExists(atPath: legacy),
           let cfg = try readLegacy(path: legacy) {
            return LoaderResult(config: cfg, source: .legacyMCPConf, path: legacy)
        }

        return LoaderResult(config: ApfelConfig(), source: .none, path: nil)
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
