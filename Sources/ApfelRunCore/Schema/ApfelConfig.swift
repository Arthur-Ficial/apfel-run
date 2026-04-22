import Foundation

// MARK: - Enums

public enum ProfileMode: String, Codable, Equatable, Sendable, CaseIterable {
    case single
    case stream
    case chat
    case serve
    case benchmark
    case modelInfo = "model-info"
}

public enum OutputFormat: String, Codable, Equatable, Sendable, CaseIterable {
    case plain
    case json
}

public enum ContextStrategy: String, Codable, Equatable, Sendable, CaseIterable {
    case newestFirst = "newest-first"
    case oldestFirst = "oldest-first"
    case slidingWindow = "sliding-window"
    case summarize
    case strict
}

// MARK: - Sub-settings

public struct GenerationSettings: Codable, Equatable, Sendable {
    public var temperature: Double?
    public var seed: UInt64?
    public var maxTokens: Int?
    public var retry: Int?

    public init(temperature: Double? = nil,
                seed: UInt64? = nil,
                maxTokens: Int? = nil,
                retry: Int? = nil) {
        self.temperature = temperature
        self.seed = seed
        self.maxTokens = maxTokens
        self.retry = retry
    }

    enum CodingKeys: String, CodingKey {
        case temperature, seed, retry
        case maxTokens = "max_tokens"
    }
}

public struct ContextSettings: Codable, Equatable, Sendable {
    public var strategy: ContextStrategy?
    public var maxTurns: Int?
    public var outputReserve: Int?

    public init(strategy: ContextStrategy? = nil,
                maxTurns: Int? = nil,
                outputReserve: Int? = nil) {
        self.strategy = strategy
        self.maxTurns = maxTurns
        self.outputReserve = outputReserve
    }

    enum CodingKeys: String, CodingKey {
        case strategy
        case maxTurns = "max_turns"
        case outputReserve = "output_reserve"
    }
}

public struct ServerSettings: Codable, Equatable, Sendable {
    public var port: Int?
    public var host: String?
    public var cors: Bool
    public var maxConcurrent: Int?
    public var allowedOrigins: [String]
    public var tokenAuto: Bool
    public var tokenEnv: String?
    public var publicHealth: Bool
    public var originCheck: Bool
    public var footgun: Bool

    public init(port: Int? = nil,
                host: String? = nil,
                cors: Bool = false,
                maxConcurrent: Int? = nil,
                allowedOrigins: [String] = [],
                tokenAuto: Bool = false,
                tokenEnv: String? = nil,
                publicHealth: Bool = false,
                originCheck: Bool = true,
                footgun: Bool = false) {
        self.port = port
        self.host = host
        self.cors = cors
        self.maxConcurrent = maxConcurrent
        self.allowedOrigins = allowedOrigins
        self.tokenAuto = tokenAuto
        self.tokenEnv = tokenEnv
        self.publicHealth = publicHealth
        self.originCheck = originCheck
        self.footgun = footgun
    }

    enum CodingKeys: String, CodingKey {
        case port, host, cors
        case maxConcurrent = "max_concurrent"
        case allowedOrigins = "allowed_origins"
        case tokenAuto = "token_auto"
        case tokenEnv = "token_env"
        case publicHealth = "public_health"
        case originCheck = "origin_check"
        case footgun
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.host = try c.decodeIfPresent(String.self, forKey: .host)
        self.cors = try c.decodeIfPresent(Bool.self, forKey: .cors) ?? false
        self.maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent)
        self.allowedOrigins = try c.decodeIfPresent([String].self, forKey: .allowedOrigins) ?? []
        self.tokenAuto = try c.decodeIfPresent(Bool.self, forKey: .tokenAuto) ?? false
        self.tokenEnv = try c.decodeIfPresent(String.self, forKey: .tokenEnv)
        self.publicHealth = try c.decodeIfPresent(Bool.self, forKey: .publicHealth) ?? false
        self.originCheck = try c.decodeIfPresent(Bool.self, forKey: .originCheck) ?? true
        self.footgun = try c.decodeIfPresent(Bool.self, forKey: .footgun) ?? false
    }
}

public struct MCPServer: Codable, Equatable, Sendable {
    public var path: String
    public var enabled: Bool
    public var tokenEnv: String?

    public init(path: String, enabled: Bool = true, tokenEnv: String? = nil) {
        self.path = path
        self.enabled = enabled
        self.tokenEnv = tokenEnv
    }

    enum CodingKeys: String, CodingKey {
        case path, enabled
        case tokenEnv = "token_env"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.tokenEnv = try c.decodeIfPresent(String.self, forKey: .tokenEnv)
    }
}

public struct MCPSettings: Codable, Equatable, Sendable {
    public var timeoutSeconds: Int?
    public var tokenEnv: String?
    public var servers: [MCPServer]

    public init(timeoutSeconds: Int? = nil,
                tokenEnv: String? = nil,
                servers: [MCPServer] = []) {
        self.timeoutSeconds = timeoutSeconds
        self.tokenEnv = tokenEnv
        self.servers = servers
    }

    enum CodingKeys: String, CodingKey {
        case timeoutSeconds = "timeout_seconds"
        case tokenEnv = "token_env"
        case servers = "server"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        self.tokenEnv = try c.decodeIfPresent(String.self, forKey: .tokenEnv)
        self.servers = try c.decodeIfPresent([MCPServer].self, forKey: .servers) ?? []
    }
}

// MARK: - Profile

public struct Profile: Codable, Equatable, Sendable {
    public var mode: ProfileMode?
    public var systemPrompt: String?
    public var systemPromptFile: String?
    public var files: [String]
    public var outputFormat: OutputFormat?
    public var quiet: Bool
    public var noColor: Bool
    public var debug: Bool
    public var permissive: Bool
    public var generation: GenerationSettings?
    public var context: ContextSettings?
    public var server: ServerSettings?
    public var mcp: MCPSettings?

    public init(mode: ProfileMode? = nil,
                systemPrompt: String? = nil,
                systemPromptFile: String? = nil,
                files: [String] = [],
                outputFormat: OutputFormat? = nil,
                quiet: Bool = false,
                noColor: Bool = false,
                debug: Bool = false,
                permissive: Bool = false,
                generation: GenerationSettings? = nil,
                context: ContextSettings? = nil,
                server: ServerSettings? = nil,
                mcp: MCPSettings? = nil) {
        self.mode = mode
        self.systemPrompt = systemPrompt
        self.systemPromptFile = systemPromptFile
        self.files = files
        self.outputFormat = outputFormat
        self.quiet = quiet
        self.noColor = noColor
        self.debug = debug
        self.permissive = permissive
        self.generation = generation
        self.context = context
        self.server = server
        self.mcp = mcp
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case systemPrompt = "system_prompt"
        case systemPromptFile = "system_prompt_file"
        case files
        case outputFormat = "output_format"
        case quiet
        case noColor = "no_color"
        case debug, permissive
        case generation, context, server, mcp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(ProfileMode.self, forKey: .mode)
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.systemPromptFile = try c.decodeIfPresent(String.self, forKey: .systemPromptFile)
        self.files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        self.outputFormat = try c.decodeIfPresent(OutputFormat.self, forKey: .outputFormat)
        self.quiet = try c.decodeIfPresent(Bool.self, forKey: .quiet) ?? false
        self.noColor = try c.decodeIfPresent(Bool.self, forKey: .noColor) ?? false
        self.debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        self.permissive = try c.decodeIfPresent(Bool.self, forKey: .permissive) ?? false
        self.generation = try c.decodeIfPresent(GenerationSettings.self, forKey: .generation)
        self.context = try c.decodeIfPresent(ContextSettings.self, forKey: .context)
        self.server = try c.decodeIfPresent(ServerSettings.self, forKey: .server)
        self.mcp = try c.decodeIfPresent(MCPSettings.self, forKey: .mcp)
    }
}

// MARK: - Top-level config

public struct ApfelConfig: Codable, Equatable, Sendable {
    /// Map from profile name ("default", "dev", ...) to Profile.
    /// Stored as a dictionary so TOML `[profile.NAME]` and JSON
    /// `{"profiles": {"NAME": ...}}` both decode naturally.
    public var profiles: [String: Profile]

    public init(profiles: [String: Profile] = [:]) {
        self.profiles = profiles
    }

    enum CodingKeys: String, CodingKey {
        case profiles = "profile"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.profiles = try c.decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !profiles.isEmpty {
            try c.encode(profiles, forKey: .profiles)
        }
    }
}
