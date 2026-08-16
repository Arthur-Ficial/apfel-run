import Foundation
import Testing
@testable import ApfelRunCore

/// Integration tests that invoke the built apfel-run binary as a subprocess.
///
/// These tests run against the release binary at `.build/release/apfel-run`.
/// Run `swift build -c release` first. Without the binary, the whole suite
/// fails (not skipped) - per golden rule: skipped tests are a critical error.
@Suite("apfel-run binary integration")
struct IntegrationTests {
    static let binaryPath: String = {
        let fm = FileManager.default
        let candidates = [
            ".build/release/apfel-run",
            "../.build/release/apfel-run",
            "/Users/arthurficial/dev/apfel-run/.build/release/apfel-run",
        ]
        for c in candidates where fm.fileExists(atPath: c) {
            return (c as NSString).standardizingPath
        }
        return "/Users/arthurficial/dev/apfel-run/.build/release/apfel-run"
    }()

    @Test("Binary exists (prereq for integration suite)")
    func binaryExists() {
        #expect(FileManager.default.isExecutableFile(atPath: Self.binaryPath))
    }

    @Test("--version prints apfel-run and the .version string")
    func versionOutput() throws {
        let result = try runBinary(args: ["--version"])
        #expect(result.stdout.hasPrefix("apfel-run"))
        // Assert against the .version file so a version bump never breaks this test.
        let versionCandidates = [".version", "/Users/arthurficial/dev/apfel-run/.version"]
        let expected = versionCandidates
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let expected, !expected.isEmpty {
            #expect(result.stdout.contains(expected))
        }
        #expect(result.exit == 0)
    }

    @Test("--help prints usage")
    func helpOutput() throws {
        let result = try runBinary(args: ["--help"])
        #expect(result.stdout.contains("USAGE"))
        #expect(result.stdout.contains("config show"))
        #expect(result.stdout.contains("--profile"))
        #expect(result.exit == 0)
    }

    @Test("config path with no config returns empty")
    func configPathEmpty() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let result = try runBinary(args: ["config", "path"],
                                   cwd: tmp,
                                   extraEnv: ["APFEL_RUN_CONFIG": "/tmp/does-not-exist-\(UUID().uuidString)"])
        #expect(result.stdout.isEmpty || result.stdout == "\n")
        #expect(result.exit == 0)
    }

    @Test("config init writes a starter file")
    func configInitWrites() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let target = tmp + "/config.toml"
        let result = try runBinary(args: ["config", "init", target])
        #expect(result.exit == 0)
        #expect(FileManager.default.fileExists(atPath: target))
        let written = try String(contentsOfFile: target, encoding: .utf8)
        #expect(written.contains("[profile.default]"))
    }

    @Test("config validate on init'd starter is valid")
    func configValidateOnStarter() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let target = tmp + "/config.toml"
        _ = try runBinary(args: ["config", "init", target])
        let result = try runBinary(args: ["config", "validate"],
                                   extraEnv: ["APFEL_RUN_CONFIG": target])
        #expect(result.exit == 0)
        #expect(result.stdout.contains("valid"))
    }

    @Test("config profiles lists profile names")
    func configProfilesLists() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let target = tmp + "/apfel.toml"
        try """
        [profile.default]

        [profile.dev]

        [profile.prod]
        """.write(toFile: target, atomically: true, encoding: .utf8)

        let result = try runBinary(args: ["config", "profiles"],
                                   cwd: tmp)
        #expect(result.stdout == "default\ndev\nprod\n")
    }

    @Test("config show --format toml round-trips")
    func configShowTOML() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let target = tmp + "/apfel.toml"
        try """
        [profile.default]
        system_prompt = "be terse"
        """.write(toFile: target, atomically: true, encoding: .utf8)

        let result = try runBinary(args: ["config", "show"], cwd: tmp)
        #expect(result.stdout.contains("[profile.default]"))
        #expect(result.stdout.contains("be terse"))
    }

    @Test("config show --format json produces valid JSON")
    func configShowJSON() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let target = tmp + "/apfel.toml"
        try """
        [profile.default]
        system_prompt = "be terse"
        """.write(toFile: target, atomically: true, encoding: .utf8)

        let result = try runBinary(args: ["config", "show", "--format", "json"], cwd: tmp)
        let data = Data(result.stdout.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed != nil)
    }

    @Test("config show --format flags emits apfel argv")
    func configShowFlags() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let target = tmp + "/apfel.toml"
        try """
        [profile.default]
        system_prompt = "be terse"
        quiet = true

        [profile.default.generation]
        temperature = 0.3
        max_tokens = 100

        [[profile.default.mcp.server]]
        path = "/some/mcp.py"
        """.write(toFile: target, atomically: true, encoding: .utf8)

        let result = try runBinary(args: ["config", "show", "--format", "flags"], cwd: tmp)
        #expect(result.stdout.contains("-s"))
        #expect(result.stdout.contains("be terse"))
        #expect(result.stdout.contains("-q"))
        #expect(result.stdout.contains("--temperature"))
        #expect(result.stdout.contains("0.3"))
        #expect(result.stdout.contains("--max-tokens"))
        #expect(result.stdout.contains("100"))
        #expect(result.stdout.contains("APFEL_MCP=/some/mcp.py"))
    }

    @Test("config validate on broken TOML exits non-zero")
    func validateBroken() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let target = tmp + "/apfel.toml"
        try """
        [profile.bad.server]
        port = -1
        """.write(toFile: target, atomically: true, encoding: .utf8)

        let result = try runBinary(args: ["config", "validate"], cwd: tmp)
        #expect(result.exit == 1)
        #expect(result.stderr.contains("port"))
    }

    @Test("--profile unknown -> exit 2 with suggestion")
    func unknownProfileError() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let target = tmp + "/apfel.toml"
        try """
        [profile.default]
        [profile.dev]
        """.write(toFile: target, atomically: true, encoding: .utf8)

        let result = try runBinary(args: ["--profile", "dve", "--version"],
                                   cwd: tmp)
        #expect(result.exit == 2)
        #expect(result.stderr.contains("dve"))
        #expect(result.stderr.contains("dev"))
    }

    @Test("migrate-config: legacy mcps.conf -> config.toml")
    func migrateLegacy() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: tmp + "/.config/apfel", withIntermediateDirectories: true)
        try "/a.py\n-/b.py\n".write(toFile: tmp + "/.config/apfel/mcps.conf",
                                     atomically: true, encoding: .utf8)

        let result = try runBinary(args: ["migrate-config"],
                                   extraEnv: ["HOME": tmp])
        #expect(result.exit == 0)
        #expect(result.stdout.contains("migrated"))
        #expect(FileManager.default.fileExists(atPath: tmp + "/.config/apfel/config.toml"))
        #expect(FileManager.default.fileExists(atPath: tmp + "/.config/apfel/mcps.conf.v0.1.bak"))
        let tomlText = try String(contentsOfFile: tmp + "/.config/apfel/config.toml", encoding: .utf8)
        #expect(tomlText.contains("/a.py"))
        #expect(tomlText.contains("/b.py"))
    }

    @Test("apfel passthrough: -- --version shows apfel's own version")
    func apfelPassthroughVersion() throws {
        let result = try runBinary(args: ["--", "--version"])
        // apfel itself prints "apfel v1.x.x"
        #expect(result.stdout.contains("apfel v"))
        #expect(!result.stdout.contains("apfel-run"))
    }

    @Test("apfel --model-info passthrough works")
    func apfelModelInfo() throws {
        let result = try runBinary(args: ["--model-info"])
        // apfel prints "model info" + 2 lines
        #expect(result.stdout.contains("apfel"))
        #expect(result.stdout.contains("model"))
    }

    @Test("Project-local apfel.toml is discovered")
    func projectLocalDiscovery() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try """
        [profile.default]
        system_prompt = "project-local"
        """.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        let result = try runBinary(args: ["config", "path"], cwd: tmp)
        #expect(result.stdout.contains("apfel.toml"))
        #expect(result.stdout.contains(tmp))
    }

    // MARK: - auth subcommand (apfel-run#1)

    @Test("subprocess: auth status for a never-stored URL exits 4")
    func authStatusNeverStored() throws {
        // Unique random host: the keychain read is a guaranteed
        // errSecItemNotFound, which returns without prompting.
        let url = "https://never-logged-in-\(UUID().uuidString.lowercased()).example/mcp"
        let result = try runBinary(args: ["auth", "status", url])
        #expect(result.exit == 4)
        #expect(result.stderr.contains("no credentials stored"))
    }

    @Test("subprocess: oauth profile with no stored credential exits 1 with 'apfel-run auth login' hint")
    func oauthProfileNoCredentialFailsLoudly() throws {
        // F5 guard: the launch wiring must never regress to try?-swallowing
        // noCredential (which would execve into a silent 401).
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let url = "https://never-logged-in-\(UUID().uuidString.lowercased()).example/mcp"
        try """
        [[profile.default.mcp.server]]
        path = "\(url)"
        enabled = true
        auth = "oauth"
        """.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        let result = try runBinary(args: ["--", "--version"], cwd: tmp)
        #expect(result.exit == 1)
        #expect(result.stderr.contains("apfel-run auth login"))
        #expect(result.stderr.contains(url))
        // apfel must NOT have been exec'd
        #expect(!result.stdout.contains("apfel v"))
    }

    // MARK: - Helpers

    struct RunResult {
        let stdout: String
        let stderr: String
        let exit: Int32
    }

    func runBinary(args: [String],
                   cwd: String? = nil,
                   extraEnv: [String: String] = [:],
                   stdin: String? = nil) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binaryPath)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        // Purge caller-level APFEL_RUN_* overrides, then merge test-supplied ones
        env["APFEL_RUN_CONFIG"] = nil
        env["APFEL_RUN_PROFILE"] = nil
        for (k, v) in extraEnv {
            env[k] = v
        }
        process.environment = env

        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try inPipe.fileHandleForWriting.close()
        }

        try process.run()
        process.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return RunResult(stdout: out, stderr: err, exit: process.terminationStatus)
    }

    func makeTempDir() throws -> String {
        let base = NSTemporaryDirectory() + "apfel-run-int-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }
}
