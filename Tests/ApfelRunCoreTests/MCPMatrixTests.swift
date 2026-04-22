import Foundation
import Testing
@testable import ApfelRunCore

/// End-to-end MCP matrix: apfel-run with real apfel + real MCP servers.
///
/// Gated on `APFEL_RUN_MCP_MATRIX=1` because each test runs a real model
/// inference (1-20s per case on Apple Silicon). To run the full matrix
/// locally: `APFEL_RUN_MCP_MATRIX=1 swift test --filter MCPMatrix`.
///
/// CI (without Apple Intelligence) skips this whole suite. Release preflight
/// runs it. This is the only place in the repo where tests are conditionally
/// skipped, and only because the prerequisite hardware is unavailable.
@Suite("MCP matrix - apfel-run + real apfel + real MCPs",
       .enabled(if: ProcessInfo.processInfo.environment["APFEL_RUN_MCP_MATRIX"] == "1"))
struct MCPMatrixTests {
    static let binary = "/Users/arthurficial/dev/apfel-run/.build/release/apfel-run"
    static let calculatorMCP = "/Users/arthurficial/dev/apfel/mcp/calculator/server.py"

    @Test("Calculator MCP: registered via apfel-run config, tool announced by apfel")
    func calculatorRegistered() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let cfg = """
        [profile.default]
        [[profile.default.mcp.server]]
        path = "\(Self.calculatorMCP)"
        """
        try cfg.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        // --model-info is deterministic: apfel prints the mcp: line on startup,
        // then exits. We check apfel-run correctly routed the registry.
        let r = try runApfelRun(args: ["--model-info"], cwd: tmp)
        #expect(r.stderr.contains(Self.calculatorMCP) || r.stderr.contains("calculator"))
    }

    @Test("Calculator MCP: 42 + 18 end-to-end through apfel-run")
    func calculatorE2E() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try """
        [profile.default]
        [[profile.default.mcp.server]]
        path = "\(Self.calculatorMCP)"
        """.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        let r = try runApfelRun(args: ["-q", "use calculator to add 42 and 18"], cwd: tmp)
        // Model may say "60" or "The answer is 60" - just check number appears
        let combined = r.stdout + r.stderr
        #expect(combined.contains("60"))
    }

    @Test("Disabled MCP: calculator not available when enabled=false")
    func disabledMCP() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try """
        [profile.default]
        [[profile.default.mcp.server]]
        path = "\(Self.calculatorMCP)"
        enabled = false
        """.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        let r = try runApfelRun(args: ["-q", "what is 2+2?"], cwd: tmp)
        // No mcp: line means no MCP got loaded
        #expect(!r.stderr.contains("mcp: \(Self.calculatorMCP)"))
    }

    @Test("Profile flag switches MCP set")
    func profileSwitchesMCPs() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try """
        [profile.default]

        [profile.calc]
        [[profile.calc.mcp.server]]
        path = "\(Self.calculatorMCP)"
        """.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        // Default profile: no MCPs registered
        let noMCP = try runApfelRun(args: ["--model-info"], cwd: tmp)
        #expect(!noMCP.stderr.contains(Self.calculatorMCP))

        // calc profile: calculator registered
        let withMCP = try runApfelRun(args: ["-p", "calc", "--model-info"], cwd: tmp)
        #expect(withMCP.stderr.contains(Self.calculatorMCP))
    }

    @Test("url-fetch MCP: installed and accessible")
    func urlFetchExists() throws {
        // We don't run a full fetch (flaky in CI), just verify apfel-run
        // can register the url-fetch MCP without crashing.
        let fetchMCP = "/opt/homebrew/bin/apfel-mcp-url-fetch"
        guard FileManager.default.isExecutableFile(atPath: fetchMCP) else {
            Issue.record("apfel-mcp not installed - run: brew install Arthur-Ficial/tap/apfel-mcp")
            return
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try """
        [profile.default]
        [[profile.default.mcp.server]]
        path = "\(fetchMCP)"
        """.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        let r = try runApfelRun(args: ["--model-info"], cwd: tmp)
        #expect(r.stderr.contains("fetch") || r.stderr.contains(fetchMCP))
    }

    @Test("ddg-search MCP: installed and registerable")
    func ddgSearchRegisterable() throws {
        let ddgMCP = "/opt/homebrew/bin/apfel-mcp-ddg-search"
        guard FileManager.default.isExecutableFile(atPath: ddgMCP) else {
            Issue.record("apfel-mcp not installed - run: brew install Arthur-Ficial/tap/apfel-mcp")
            return
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try """
        [profile.default]
        [[profile.default.mcp.server]]
        path = "\(ddgMCP)"
        """.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        let r = try runApfelRun(args: ["--model-info"], cwd: tmp)
        #expect(r.stderr.contains("search") || r.stderr.contains(ddgMCP))
    }

    @Test("search-and-fetch compound MCP: registers")
    func searchAndFetchRegisterable() throws {
        let mcp = "/opt/homebrew/bin/apfel-mcp-search-and-fetch"
        guard FileManager.default.isExecutableFile(atPath: mcp) else {
            Issue.record("apfel-mcp not installed - run: brew install Arthur-Ficial/tap/apfel-mcp")
            return
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try """
        [profile.default]
        [[profile.default.mcp.server]]
        path = "\(mcp)"
        """.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        let r = try runApfelRun(args: ["--model-info"], cwd: tmp)
        #expect(r.stderr.contains(mcp) || r.stderr.contains("search"))
    }

    @Test("All three apfel-mcp tools register together under one profile")
    func allThreeRegister() throws {
        let ddg = "/opt/homebrew/bin/apfel-mcp-ddg-search"
        let fetch = "/opt/homebrew/bin/apfel-mcp-url-fetch"
        let both = "/opt/homebrew/bin/apfel-mcp-search-and-fetch"
        guard FileManager.default.isExecutableFile(atPath: ddg),
              FileManager.default.isExecutableFile(atPath: fetch),
              FileManager.default.isExecutableFile(atPath: both) else {
            Issue.record("apfel-mcp not installed")
            return
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try """
        [profile.research]

        [[profile.research.mcp.server]]
        path = "\(ddg)"

        [[profile.research.mcp.server]]
        path = "\(fetch)"

        [[profile.research.mcp.server]]
        path = "\(both)"
        """.write(toFile: tmp + "/apfel.toml", atomically: true, encoding: .utf8)

        let r = try runApfelRun(args: ["-p", "research", "--model-info"], cwd: tmp)
        #expect(r.stderr.contains(ddg))
        #expect(r.stderr.contains(fetch))
        #expect(r.stderr.contains(both))
    }

    // MARK: - Helpers

    func runApfelRun(args: [String], cwd: String) throws -> (stdout: String, stderr: String, exit: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.binary)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["APFEL_RUN_CONFIG"] = nil
        env["APFEL_RUN_PROFILE"] = nil
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        try p.run()
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, p.terminationStatus)
    }

    func makeTempDir() throws -> String {
        let base = NSTemporaryDirectory() + "apfel-run-mcp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }
}
