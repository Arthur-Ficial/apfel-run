import Foundation

/// Package-root-relative paths for the integration tests. Resolved from this
/// file's location, so they work on any checkout (CI, other machines).
enum TestPaths {
    /// The package root: three levels above this file (Tests/ApfelRunCoreTests/TestPaths.swift).
    static let packageRoot: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }()

    /// The release binary. Build it first with `swift build -c release`;
    /// the integration tests fail (not skip) when it is missing.
    static let releaseBinary = packageRoot + "/.build/release/apfel-run"

    static let versionFile = packageRoot + "/.version"

    /// apfel's bundled calculator MCP. Only used by suites gated on
    /// APFEL_RUN_MCP_MATRIX=1. Override with APFEL_CALCULATOR_MCP.
    static let calculatorMCP: String =
        ProcessInfo.processInfo.environment["APFEL_CALCULATOR_MCP"]
        ?? (packageRoot as NSString).deletingLastPathComponent + "/apfel/mcp/calculator/server.py"

    /// True when a real `apfel` executable is on PATH. The passthrough tests
    /// that exec the real apfel are gated on this, so a machine without apfel
    /// (CI) skips them visibly instead of failing on a missing prerequisite.
    static let apfelOnPath: Bool = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/apfel")
        }
    }()
}
