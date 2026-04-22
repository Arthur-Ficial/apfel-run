import Foundation
import Testing
@testable import ApfelRunCore

// Full XDG Base Directory Spec compliance:
//   https://specifications.freedesktop.org/basedir-spec/latest/
//
// Cascade (first hit wins):
//   1. $APFEL_RUN_CONFIG              explicit file override
//   2. ./apfel.toml | ./apfel.json    project-local
//   3. $XDG_CONFIG_HOME/apfel/config  user config (defaults to ~/.config)
//   4. $XDG_CONFIG_DIRS/apfel/config  system config (colon-separated,
//                                     default /etc/xdg, plus /etc/apfel)
//   5. ~/.config/apfel/mcps.conf      legacy v0.1 fallback

@Suite("XDG Base Directory Spec compliance")
struct XDGLoaderTests {

    @Test("XDG_CONFIG_DIRS is scanned after XDG_CONFIG_HOME")
    func xdgConfigDirsScanned() throws {
        let dirA = try tempDir()
        let dirB = try tempDir()
        let home = try tempDir()
        defer {
            try? FileManager.default.removeItem(atPath: dirA)
            try? FileManager.default.removeItem(atPath: dirB)
            try? FileManager.default.removeItem(atPath: home)
        }
        try FileManager.default.createDirectory(atPath: dirB + "/apfel", withIntermediateDirectories: true)
        try """
        [profile.default]
        system_prompt = "from XDG_CONFIG_DIRS dirB"
        """.write(toFile: dirB + "/apfel/config.toml", atomically: true, encoding: .utf8)

        // No file in XDG_CONFIG_HOME, no project file, but dirB has one
        let result = ConfigLoader.load(environment: [
            "XDG_CONFIG_HOME": dirA,      // empty
            "XDG_CONFIG_DIRS": "/tmp/nonexistent-\(UUID().uuidString):\(dirB)",
        ], cwd: "/tmp/none-\(UUID().uuidString)", home: home)

        #expect(result.source == .systemXDG)
        #expect(result.config.profiles["default"]?.systemPrompt == "from XDG_CONFIG_DIRS dirB")
    }

    @Test("XDG_CONFIG_DIRS first entry wins over second entry")
    func xdgConfigDirsFirstWins() throws {
        let dirA = try tempDir()
        let dirB = try tempDir()
        defer {
            try? FileManager.default.removeItem(atPath: dirA)
            try? FileManager.default.removeItem(atPath: dirB)
        }
        try FileManager.default.createDirectory(atPath: dirA + "/apfel", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dirB + "/apfel", withIntermediateDirectories: true)
        try "[profile.default]\nsystem_prompt = \"from dirA\""
            .write(toFile: dirA + "/apfel/config.toml", atomically: true, encoding: .utf8)
        try "[profile.default]\nsystem_prompt = \"from dirB\""
            .write(toFile: dirB + "/apfel/config.toml", atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: [
            "XDG_CONFIG_DIRS": "\(dirA):\(dirB)",
        ], cwd: "/tmp/none-\(UUID().uuidString)", home: "/tmp/none-\(UUID().uuidString)")

        #expect(result.config.profiles["default"]?.systemPrompt == "from dirA")
    }

    @Test("XDG_CONFIG_HOME still wins over XDG_CONFIG_DIRS")
    func xdgHomeBeatsDirs() throws {
        let userDir = try tempDir()
        let sysDir = try tempDir()
        defer {
            try? FileManager.default.removeItem(atPath: userDir)
            try? FileManager.default.removeItem(atPath: sysDir)
        }
        try FileManager.default.createDirectory(atPath: userDir + "/apfel", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sysDir + "/apfel", withIntermediateDirectories: true)
        try "[profile.default]\nsystem_prompt = \"user\""
            .write(toFile: userDir + "/apfel/config.toml", atomically: true, encoding: .utf8)
        try "[profile.default]\nsystem_prompt = \"sys\""
            .write(toFile: sysDir + "/apfel/config.toml", atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: [
            "XDG_CONFIG_HOME": userDir,
            "XDG_CONFIG_DIRS": sysDir,
        ], cwd: "/tmp/none-\(UUID().uuidString)", home: "/tmp/none-\(UUID().uuidString)")

        #expect(result.config.profiles["default"]?.systemPrompt == "user")
        #expect(result.source == .globalXDG)
    }

    @Test("Default XDG_CONFIG_DIRS is /etc/xdg when env unset")
    func defaultXDGConfigDirsIsEtc() {
        // Just check the computed cascade - we don't need /etc/xdg to actually exist.
        let paths = ConfigLoader.searchPaths(environment: [:],
                                             cwd: "/tmp",
                                             home: "/home/me")
        // Must include /etc/xdg/apfel/config.toml somewhere
        #expect(paths.contains(where: { $0.hasPrefix("/etc/xdg/apfel/config") }))
    }

    @Test("Default when XDG_CONFIG_HOME unset is ~/.config/apfel/config.toml")
    func defaultUserHomeConfig() {
        let paths = ConfigLoader.searchPaths(environment: [:],
                                             cwd: "/tmp",
                                             home: "/home/me")
        #expect(paths.contains("/home/me/.config/apfel/config.toml"))
    }

    @Test("searchPaths returns cascade in priority order")
    func searchPathsOrdering() {
        let paths = ConfigLoader.searchPaths(
            environment: ["APFEL_RUN_CONFIG": "/explicit.toml"],
            cwd: "/proj",
            home: "/home/me")
        #expect(paths.first == "/explicit.toml")
    }

    @Test("Project-local still beats XDG_CONFIG_HOME beats XDG_CONFIG_DIRS")
    func fullCascadePriority() throws {
        let proj = try tempDir()
        let user = try tempDir()
        let sys = try tempDir()
        defer {
            try? FileManager.default.removeItem(atPath: proj)
            try? FileManager.default.removeItem(atPath: user)
            try? FileManager.default.removeItem(atPath: sys)
        }
        try FileManager.default.createDirectory(atPath: user + "/apfel", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sys + "/apfel", withIntermediateDirectories: true)
        try "[profile.default]\nsystem_prompt = \"proj\""
            .write(toFile: proj + "/apfel.toml", atomically: true, encoding: .utf8)
        try "[profile.default]\nsystem_prompt = \"user\""
            .write(toFile: user + "/apfel/config.toml", atomically: true, encoding: .utf8)
        try "[profile.default]\nsystem_prompt = \"sys\""
            .write(toFile: sys + "/apfel/config.toml", atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: [
            "XDG_CONFIG_HOME": user,
            "XDG_CONFIG_DIRS": sys,
        ], cwd: proj, home: "/tmp/doesnt-matter")

        #expect(result.config.profiles["default"]?.systemPrompt == "proj")
        #expect(result.source == .projectLocal)
    }

    @Test("Empty XDG_CONFIG_DIRS entry is skipped")
    func emptyDirsEntrySkipped() {
        let paths = ConfigLoader.searchPaths(
            environment: ["XDG_CONFIG_DIRS": "::/tmp/a::/tmp/b:"],
            cwd: "/tmp",
            home: "/home/me")
        // No empty entries in the resolved path list
        let etcPaths = paths.filter { $0.hasPrefix("//") }
        #expect(etcPaths.isEmpty)
    }

    @Test("Both TOML and JSON variants are in the search list for every dir")
    func tomlAndJSONEverywhere() {
        let paths = ConfigLoader.searchPaths(environment: [:],
                                             cwd: "/proj",
                                             home: "/home/me")
        #expect(paths.contains("/proj/apfel.toml"))
        #expect(paths.contains("/proj/apfel.json"))
        #expect(paths.contains("/home/me/.config/apfel/config.toml"))
        #expect(paths.contains("/home/me/.config/apfel/config.json"))
        #expect(paths.contains("/etc/xdg/apfel/config.toml"))
        #expect(paths.contains("/etc/xdg/apfel/config.json"))
    }

    private func tempDir() throws -> String {
        let d = NSTemporaryDirectory() + "apfel-run-xdg-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
}
