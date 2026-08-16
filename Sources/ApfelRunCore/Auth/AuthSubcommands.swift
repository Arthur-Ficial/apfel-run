import Foundation

/// Typed `apfel-run auth` subcommand.
public enum AuthCommand: Equatable, Sendable {
    case login(url: String, scope: String?, timeoutSeconds: Int, noBrowser: Bool)
    case list
    case status(url: String)
    case logout(url: String)
    case usageError(String)
}

/// Pure handlers for `apfel-run auth ...`. The interactive part of `login`
/// (browser, loopback listener) lives in the executable glue; everything
/// with branching is here and unit-tested.
public enum AuthSubcommands {
    public static let usage = "usage: apfel-run auth <login|list|status|logout>"

    // MARK: - parse

    public static func parse(args: [String]) -> AuthCommand {
        guard let sub = args.first else {
            return .usageError(usage)
        }
        let tail = Array(args.dropFirst())
        switch sub {
        case "login":
            return parseLogin(tail)
        case "list":
            guard tail.isEmpty else {
                return .usageError("auth list takes no arguments")
            }
            return .list
        case "status":
            guard let url = tail.first, tail.count == 1 else {
                return .usageError("usage: apfel-run auth status <https-mcp-url>")
            }
            return .status(url: url)
        case "logout":
            guard let url = tail.first, tail.count == 1 else {
                return .usageError("usage: apfel-run auth logout <https-mcp-url>")
            }
            return .logout(url: url)
        default:
            return .usageError(usage)
        }
    }

    static func parseLogin(_ tail: [String]) -> AuthCommand {
        var url: String? = nil
        var scope: String? = nil
        var timeoutSeconds = 300
        var noBrowser = false
        var i = 0
        while i < tail.count {
            let arg = tail[i]
            switch arg {
            case "--scope":
                i += 1
                guard i < tail.count else { return .usageError("--scope requires a value") }
                scope = tail[i]
            case "--timeout":
                i += 1
                guard i < tail.count, let seconds = Int(tail[i]), seconds > 0 else {
                    return .usageError("--timeout requires a positive integer (seconds)")
                }
                timeoutSeconds = seconds
            case "--no-browser":
                noBrowser = true
            default:
                if arg.hasPrefix("-") {
                    return .usageError("unknown flag for auth login: \(arg)")
                }
                guard url == nil else {
                    return .usageError("auth login takes exactly one URL (got '\(arg)' too)")
                }
                url = arg
            }
            i += 1
        }
        guard let url else {
            return .usageError("usage: apfel-run auth login <https-mcp-url> [--scope SCOPE] [--timeout SECONDS] [--no-browser]")
        }
        return .login(url: url, scope: scope, timeoutSeconds: timeoutSeconds, noBrowser: noBrowser)
    }

    /// https + URL validity gate for login (loopback http exempt, F13).
    public static func loginPreflight(url: String) -> Result<URL, AuthError> {
        guard let parsed = URL(string: url), parsed.host != nil else {
            return .failure(.notHTTPS(url: url))
        }
        guard isSecureOrLoopback(parsed) else {
            return .failure(.notHTTPS(url: url))
        }
        return .success(parsed)
    }

    // MARK: - list

    public static func list(store: TokenStoring, clock: AuthClock) -> Subcommands.Result {
        do {
            let servers = try store.list()
            guard !servers.isEmpty else {
                return Subcommands.Result(stdout: "no OAuth credentials stored\n")
            }
            var lines: [String] = []
            for server in servers.sorted() {
                let credential = try store.load(server: server)
                lines.append("\(server)  \(describeValidity(validity(of: credential, clock: clock)))")
            }
            return Subcommands.Result(stdout: lines.joined(separator: "\n") + "\n")
        } catch let e as AuthError {
            return Subcommands.Result(stderr: e.message + "\n", exitCode: 1)
        } catch {
            return Subcommands.Result(stderr: "\(error)\n", exitCode: 1)
        }
    }

    // MARK: - status

    public static func status(url: String, store: TokenStoring, clock: AuthClock) -> Subcommands.Result {
        do {
            let credential = try store.load(server: url)
            switch validity(of: credential, clock: clock) {
            case .valid(let until):
                if let until {
                    return Subcommands.Result(stdout: "valid until \(iso8601(until))\n")
                }
                return Subcommands.Result(stdout: "valid (no expiry recorded)\n")
            case .expired(refreshable: true):
                return Subcommands.Result(stdout: "expired (will refresh on next apfel-run launch)\n",
                                          exitCode: 1)
            case .expired(refreshable: false):
                return Subcommands.Result(stdout: "expired - run: apfel-run auth logout \(url) && apfel-run auth login \(url)\n",
                                          exitCode: 1)
            case .none:
                return Subcommands.Result(stderr: "no credentials stored for \(url)\n", exitCode: 4)
            }
        } catch let e as AuthError {
            return Subcommands.Result(stderr: e.message + "\n", exitCode: 1)
        } catch {
            return Subcommands.Result(stderr: "\(error)\n", exitCode: 1)
        }
    }

    // MARK: - logout

    public static func logout(url: String, store: TokenStoring) -> Subcommands.Result {
        do {
            guard try store.delete(server: url) else {
                return Subcommands.Result(stderr: "no credentials stored for \(url)\n", exitCode: 4)
            }
            return Subcommands.Result(stdout: "removed credentials for \(normalizeServerKey(url))\n")
        } catch let e as AuthError {
            return Subcommands.Result(stderr: e.message + "\n", exitCode: 1)
        } catch {
            return Subcommands.Result(stderr: "\(error)\n", exitCode: 1)
        }
    }

    // MARK: - Helpers

    static func describeValidity(_ v: TokenValidity) -> String {
        switch v {
        case .valid(let until):
            if let until { return "valid until \(iso8601(until))" }
            return "valid (no expiry recorded)"
        case .expired(refreshable: true):
            return "expired (refresh available)"
        case .expired(refreshable: false):
            return "expired (no refresh - re-login)"
        case .none:
            return "no credential"
        }
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
