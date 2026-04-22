import Foundation

public struct ResolvedProfile: Equatable, Sendable {
    public let name: String
    public let profile: Profile

    public init(name: String, profile: Profile) {
        self.name = name
        self.profile = profile
    }
}

public struct ProfileResolverError: Error, CustomStringConvertible {
    public let requestedName: String
    public let knownProfiles: [String]
    public let suggestion: String?

    public var description: String {
        var msg = "unknown profile '\(requestedName)'"
        if !knownProfiles.isEmpty {
            msg += "\nknown profiles: \(knownProfiles.sorted().joined(separator: ", "))"
        } else {
            msg += " (no profiles defined in config)"
        }
        if let s = suggestion {
            msg += "\ndid you mean '\(s)'?"
        }
        return msg
    }
}

public enum ProfileResolver {
    public static func resolve(config: ApfelConfig,
                               requested: String?,
                               environment: [String: String]) throws -> ResolvedProfile {
        let resolvedName = requested ?? environment["APFEL_RUN_PROFILE"]

        // No explicit request: use default if present, otherwise empty resolved profile.
        guard let name = resolvedName, !name.isEmpty else {
            if let def = config.profiles["default"] {
                return ResolvedProfile(name: "default", profile: def)
            }
            return ResolvedProfile(name: "", profile: Profile())
        }

        guard let profile = config.profiles[name] else {
            let known = Array(config.profiles.keys)
            throw ProfileResolverError(requestedName: name,
                                       knownProfiles: known,
                                       suggestion: suggest(for: name, from: known))
        }
        return ResolvedProfile(name: name, profile: profile)
    }

    /// Returns the closest known name by Levenshtein distance, or nil if
    /// nothing is within 2 edits (beyond which suggestions are more annoying
    /// than helpful).
    public static func suggest(for name: String, from known: [String]) -> String? {
        guard !known.isEmpty else { return nil }
        let pairs = known.map { ($0, levenshtein($0, name)) }
        let best = pairs.min { $0.1 < $1.1 }
        if let (candidate, distance) = best, distance <= 2, distance < name.count {
            return candidate
        }
        // If strings are short, a distance of 3 might still be the only match;
        // allow it only when we have a single candidate.
        if known.count == 1, let first = known.first {
            return first
        }
        return nil
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let (m, n) = (aChars.count, bChars.count)
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
