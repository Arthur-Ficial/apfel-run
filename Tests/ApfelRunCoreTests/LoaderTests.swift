import Foundation
import Testing
@testable import ApfelRunCore

@Suite("ConfigLoader")
struct LoaderTests {
    @Test("APFEL_RUN_CONFIG env override wins")
    func envOverrideWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/custom.toml"
        try "[profile.default]\nsystem_prompt = \"from override\"".write(toFile: path, atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: ["APFEL_RUN_CONFIG": path],
                                       cwd: "/tmp/unrelated",
                                       home: "/tmp/unrelated-home")
        #expect(result.source == .envOverride)
        #expect(result.config.profiles["default"]?.systemPrompt == "from override")
    }

    @Test("Project-local apfel.toml wins over global")
    func projectLocalWins() throws {
        let proj = try makeTempDir()
        let home = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(atPath: proj)
            try? FileManager.default.removeItem(atPath: home)
        }
        try "[profile.default]\nsystem_prompt = \"project\"".write(toFile: proj + "/apfel.toml", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: home + "/.config/apfel", withIntermediateDirectories: true)
        try "[profile.default]\nsystem_prompt = \"home\"".write(toFile: home + "/.config/apfel/config.toml", atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: [:], cwd: proj, home: home)
        #expect(result.source == .projectLocal)
        #expect(result.config.profiles["default"]?.systemPrompt == "project")
    }

    @Test("XDG_CONFIG_HOME honoured over HOME")
    func xdgHome() throws {
        let xdg = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: xdg) }
        try FileManager.default.createDirectory(atPath: xdg + "/apfel", withIntermediateDirectories: true)
        try "[profile.default]\nsystem_prompt = \"xdg\"".write(toFile: xdg + "/apfel/config.toml", atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: ["XDG_CONFIG_HOME": xdg],
                                       cwd: "/tmp/unrelated-\(UUID().uuidString)",
                                       home: "/tmp/unrelated-home-\(UUID().uuidString)")
        #expect(result.source == .globalXDG)
        #expect(result.config.profiles["default"]?.systemPrompt == "xdg")
    }

    @Test("TOML wins over JSON when both exist in same dir")
    func tomlBeatsJSON() throws {
        let proj = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: proj) }
        try "[profile.default]\nsystem_prompt = \"toml\"".write(toFile: proj + "/apfel.toml", atomically: true, encoding: .utf8)
        try #"{"profile":{"default":{"system_prompt":"json"}}}"#.write(toFile: proj + "/apfel.json", atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: [:], cwd: proj, home: "/tmp/does-not-exist")
        #expect(result.config.profiles["default"]?.systemPrompt == "toml")
    }

    @Test("JSON file loads when only JSON exists")
    func jsonAlone() throws {
        let proj = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: proj) }
        try #"{"profile":{"default":{"system_prompt":"json-only"}}}"#.write(toFile: proj + "/apfel.json", atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: [:], cwd: proj, home: "/tmp/does-not-exist")
        #expect(result.config.profiles["default"]?.systemPrompt == "json-only")
    }

    @Test("No file anywhere = empty config, source .none")
    func noFileEmpty() {
        let result = ConfigLoader.load(environment: [:],
                                       cwd: "/tmp/does-not-exist-\(UUID().uuidString)",
                                       home: "/tmp/does-not-exist-\(UUID().uuidString)")
        #expect(result.config.profiles.isEmpty)
        #expect(result.source == .none)
        #expect(result.path == nil)
    }

    @Test("Malformed TOML throws loader error with path")
    func malformedThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/broken.toml"
        try "this is [not valid".write(toFile: path, atomically: true, encoding: .utf8)

        do {
            _ = try ConfigLoader.loadThrowing(environment: ["APFEL_RUN_CONFIG": path],
                                              cwd: "/tmp",
                                              home: "/tmp")
            Issue.record("expected throw")
        } catch let err as ConfigLoaderError {
            #expect(err.path == path)
        } catch {
            Issue.record("expected ConfigLoaderError, got \(error)")
        }
    }

    @Test("Empty file loads as empty config")
    func emptyFileIsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/empty.toml"
        try "".write(toFile: path, atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: ["APFEL_RUN_CONFIG": path],
                                       cwd: "/tmp", home: "/tmp")
        #expect(result.config.profiles.isEmpty)
    }

    @Test("Legacy mcps.conf fallback reads into default profile")
    func legacyFallback() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.config/apfel", withIntermediateDirectories: true)
        try "/a.py\n-/b.py\n".write(toFile: home + "/.config/apfel/mcps.conf", atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(environment: [:], cwd: "/tmp/none", home: home)
        #expect(result.source == .legacyMCPConf)
        let servers = result.config.profiles["default"]?.mcp?.servers ?? []
        #expect(servers.contains(where: { $0.path == "/a.py" && $0.enabled }))
        #expect(servers.contains(where: { $0.path == "/b.py" && !$0.enabled }))
    }

    private func makeTempDir() throws -> String {
        let base = NSTemporaryDirectory() + "apfel-run-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }
}
