import Foundation
import Testing
@testable import ApfelRunCore

@Suite("AuthSubcommands - parse + list/status/logout handlers")
struct AuthSubcommandTests {
    let url = "https://mcp.example.com/mcp"

    // MARK: - parse

    @Test("parse: login with url")
    func parseLogin() {
        #expect(AuthSubcommands.parse(args: ["login", url])
                == .login(url: url, scope: nil, timeoutSeconds: 300, noBrowser: false))
    }

    @Test("parse: login rejects missing url -> usageError")
    func parseLoginMissingURL() {
        guard case .usageError(let message) = AuthSubcommands.parse(args: ["login"]) else {
            Issue.record("expected usageError")
            return
        }
        #expect(message.contains("login"))
    }

    @Test("parse: login --scope --timeout --no-browser")
    func parseLoginFlags() {
        let command = AuthSubcommands.parse(args: ["login", url,
                                                   "--scope", "notes.read",
                                                   "--timeout", "60",
                                                   "--no-browser"])
        #expect(command == .login(url: url, scope: "notes.read", timeoutSeconds: 60, noBrowser: true))
    }

    @Test("parse: unknown subcommand -> usageError")
    func parseUnknown() {
        guard case .usageError(let message) = AuthSubcommands.parse(args: ["frobnicate"]) else {
            Issue.record("expected usageError")
            return
        }
        #expect(message.contains("login|list|status|logout"))
        // bare `auth` is also a usage error
        guard case .usageError = AuthSubcommands.parse(args: []) else {
            Issue.record("expected usageError for empty args")
            return
        }
        // unknown flag on login is a usage error too
        guard case .usageError = AuthSubcommands.parse(args: ["login", url, "--bogus"]) else {
            Issue.record("expected usageError for unknown flag")
            return
        }
    }

    @Test("parse: status/logout require url")
    func parseStatusLogoutRequireURL() {
        #expect(AuthSubcommands.parse(args: ["status", url]) == .status(url: url))
        #expect(AuthSubcommands.parse(args: ["logout", url]) == .logout(url: url))
        guard case .usageError = AuthSubcommands.parse(args: ["status"]) else {
            Issue.record("expected usageError")
            return
        }
        guard case .usageError = AuthSubcommands.parse(args: ["logout"]) else {
            Issue.record("expected usageError")
            return
        }
        #expect(AuthSubcommands.parse(args: ["list"]) == .list)
    }

    // MARK: - list

    @Test("list: empty store prints no-credentials line, exit 0")
    func listEmpty() {
        let result = AuthSubcommands.list(store: InMemoryTokenStore(), clock: FixedClock())
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("no OAuth credentials stored"))
    }

    @Test("list: mixed validity renders valid/expired-refresh/expired-relogin lines sorted by url")
    func listMixed() throws {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let store = InMemoryTokenStore()
        try store.save(makeCredential(expiresAt: now.addingTimeInterval(3600)),
                       server: "https://a.example/mcp")
        try store.save(makeCredential(refreshToken: "rt", expiresAt: now.addingTimeInterval(-10)),
                       server: "https://b.example/mcp")
        try store.save(makeCredential(refreshToken: nil, expiresAt: now.addingTimeInterval(-10)),
                       server: "https://c.example/mcp")
        let result = AuthSubcommands.list(store: store, clock: FixedClock(now: now))
        #expect(result.exitCode == 0)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("https://a.example/mcp"))
        #expect(lines[0].contains("valid until"))
        #expect(lines[1].hasPrefix("https://b.example/mcp"))
        #expect(lines[1].contains("expired (refresh available)"))
        #expect(lines[2].hasPrefix("https://c.example/mcp"))
        #expect(lines[2].contains("expired (no refresh - re-login)"))
    }

    // MARK: - status

    @Test("status: valid -> exit 0 with ISO8601 until")
    func statusValid() throws {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let store = InMemoryTokenStore()
        try store.save(makeCredential(expiresAt: Date(timeIntervalSince1970: 1_755_003_600)),
                       server: url)
        let result = AuthSubcommands.status(url: url, store: store, clock: FixedClock(now: now))
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("valid until"))
        // ISO8601 (UTC)
        #expect(result.stdout.contains("Z"))
    }

    @Test("status: expired with refresh -> exit 1, mentions refresh-on-launch")
    func statusExpiredRefreshable() throws {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let store = InMemoryTokenStore()
        try store.save(makeCredential(refreshToken: "rt", expiresAt: now.addingTimeInterval(-5)),
                       server: url)
        let result = AuthSubcommands.status(url: url, store: store, clock: FixedClock(now: now))
        #expect(result.exitCode == 1)
        #expect(result.stdout.contains("will refresh on next apfel-run launch"))
    }

    @Test("status: expired without refresh -> exit 1 with re-login command")
    func statusExpiredNoRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let store = InMemoryTokenStore()
        try store.save(makeCredential(refreshToken: nil, expiresAt: now.addingTimeInterval(-5)),
                       server: url)
        let result = AuthSubcommands.status(url: url, store: store, clock: FixedClock(now: now))
        #expect(result.exitCode == 1)
        #expect(result.stdout.contains("apfel-run auth login \(url)"))
    }

    @Test("status: nothing stored -> exit 4, stderr only")
    func statusNothingStored() {
        let result = AuthSubcommands.status(url: url, store: InMemoryTokenStore(), clock: FixedClock())
        #expect(result.exitCode == 4)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("no credentials stored for \(url)"))
    }

    // MARK: - logout

    @Test("logout: deletes and prints removed, exit 0")
    func logoutDeletes() throws {
        let store = InMemoryTokenStore()
        try store.save(makeCredential(), server: url)
        let result = AuthSubcommands.logout(url: url, store: store)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("removed credentials for"))
        #expect(try store.load(server: url) == nil)
    }

    @Test("logout: nothing stored -> exit 4")
    func logoutNothingStored() {
        let result = AuthSubcommands.logout(url: url, store: InMemoryTokenStore())
        #expect(result.exitCode == 4)
        #expect(result.stderr.contains("no credentials stored for \(url)"))
    }

    // MARK: - login preflight

    @Test("loginPreflight rejects http:// with exit-2-style usage error")
    func loginPreflightRejectsHTTP() {
        guard case .failure(let error) = AuthSubcommands.loginPreflight(url: "http://mcp.example.com/mcp") else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .notHTTPS(url: "http://mcp.example.com/mcp"))
        // valid https passes
        guard case .success(let parsed) = AuthSubcommands.loginPreflight(url: url) else {
            Issue.record("expected success")
            return
        }
        #expect(parsed.absoluteString == url)
        // loopback http passes (F13)
        guard case .success = AuthSubcommands.loginPreflight(url: "http://127.0.0.1:9/mcp") else {
            Issue.record("expected loopback success")
            return
        }
        // garbage fails
        guard case .failure = AuthSubcommands.loginPreflight(url: "not a url") else {
            Issue.record("expected failure for garbage")
            return
        }
    }

    // MARK: - token hygiene

    @Test("no output line ever contains an access or refresh token")
    func noTokenInOutput() throws {
        let accessSentinel = "SENTINEL-ACCESS-TOKEN-XYZZY"
        let refreshSentinel = "SENTINEL-REFRESH-TOKEN-PLUGH"
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let store = InMemoryTokenStore()
        try store.save(makeCredential(accessToken: accessSentinel,
                                      refreshToken: refreshSentinel,
                                      expiresAt: now.addingTimeInterval(-5)),
                       server: url)
        let clock = FixedClock(now: now)
        for result in [AuthSubcommands.list(store: store, clock: clock),
                       AuthSubcommands.status(url: url, store: store, clock: clock),
                       AuthSubcommands.logout(url: url, store: store)] {
            #expect(!result.stdout.contains(accessSentinel))
            #expect(!result.stdout.contains(refreshSentinel))
            #expect(!result.stderr.contains(accessSentinel))
            #expect(!result.stderr.contains(refreshSentinel))
        }
    }
}
