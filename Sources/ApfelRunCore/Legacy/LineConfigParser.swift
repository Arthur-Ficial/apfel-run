import Foundation

public struct MCPEntry: Equatable, Sendable {
    public let path: String
    public let enabled: Bool
    public let lineNumber: Int

    public init(path: String, enabled: Bool, lineNumber: Int = 0) {
        self.path = path
        self.enabled = enabled
        self.lineNumber = lineNumber
    }
}

public struct Config: Equatable, Sendable {
    public let entries: [MCPEntry]

    public init(entries: [MCPEntry] = []) {
        self.entries = entries
    }

    public var enabledPaths: [String] {
        entries.filter(\.enabled).map(\.path)
    }

    public var apfelMCPValue: String {
        enabledPaths.joined(separator: ",")
    }
}

public enum ConfigParser {
    public static func parse(_ text: String) -> Config {
        var entries: [MCPEntry] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1

            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }

            let (path, enabled) = splitEnabledFlag(line)
            let cleaned = stripTrailingComment(path).trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty { continue }

            entries.append(MCPEntry(path: cleaned, enabled: enabled, lineNumber: lineNumber))
        }
        return Config(entries: entries)
    }

    private static func splitEnabledFlag(_ line: String) -> (path: String, enabled: Bool) {
        if line.hasPrefix("-") {
            let remainder = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (remainder, false)
        }
        return (line, true)
    }

    private static func stripTrailingComment(_ line: String) -> String {
        guard let hashIndex = line.firstIndex(of: "#") else { return line }
        if hashIndex == line.startIndex { return "" }
        let previous = line.index(before: hashIndex)
        if line[previous] == " " || line[previous] == "\t" {
            return String(line[line.startIndex..<hashIndex])
        }
        return line
    }
}

public enum ConfigPath {
    public static func defaultLocation(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       home: String = NSHomeDirectory()) -> String {
        if let override = environment["APFEL_RUN_CONFIG"], !override.isEmpty {
            return override
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return xdg + "/apfel/mcps.conf"
        }
        return home + "/.config/apfel/mcps.conf"
    }
}
