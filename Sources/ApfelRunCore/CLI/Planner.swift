import Foundation

/// apfel-run v0.2 Planner - recognises subcommands + `--profile` and forwards
/// everything else to apfel verbatim.
///
/// Priority at position 0:
///   - `config`, `migrate-config` = our subcommand, rest is subcommand args
///   - `--help`/`-h`, `--version`/`-v` = our own help/version
///   - anything else = forward to apfel (with profile applied)
///
/// `--profile NAME` / `-p NAME` can appear anywhere before `--` marker and is
/// extracted out of the forward stream.
///
/// `--` terminates apfel-run flag scanning; everything after forwards verbatim.
public enum PlannerV2 {
    public enum Action: Equatable, Sendable {
        case runApfel(profile: String?, args: [String])
        case showHelp
        case showVersion
        case configSubcommand(args: [String])
        case migrateConfig(args: [String])
    }

    public static func plan(args: [String]) -> Action {
        guard let first = args.first else {
            return .runApfel(profile: nil, args: [])
        }

        // Position-0 subcommands + own flags
        switch first {
        case "--help", "-h":
            return .showHelp
        case "--version", "-v":
            return .showVersion
        case "config":
            return .configSubcommand(args: Array(args.dropFirst()))
        case "migrate-config":
            return .migrateConfig(args: Array(args.dropFirst()))
        case "--":
            return .runApfel(profile: nil, args: Array(args.dropFirst()))
        default:
            break
        }

        // Extract --profile/-p before `--` marker, leave rest for forwarding.
        var remaining: [String] = []
        var profile: String? = nil
        var i = 0
        var seenDoubleDash = false
        while i < args.count {
            let arg = args[i]
            if seenDoubleDash {
                remaining.append(arg)
                i += 1
                continue
            }
            switch arg {
            case "--":
                seenDoubleDash = true
                // strip the marker itself
                i += 1
            case "--profile", "-p":
                i += 1
                if i < args.count {
                    profile = args[i]
                    i += 1
                }
            default:
                remaining.append(arg)
                i += 1
            }
        }
        return .runApfel(profile: profile, args: remaining)
    }
}
