import Foundation
import Testing
@testable import ApfelRunCore

@Suite("Subcommands")
struct SubcommandTests {
    // MARK: - config show

    @Test("config show --format toml emits TOML with all profiles")
    func showTOML() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(systemPrompt: "hi")
        ])
        let loader = LoaderResult(config: cfg, source: .projectLocal, path: "/tmp/x.toml")
        let r = Subcommands.configShow(loaderResult: loader, profile: nil,
                                       format: .toml, environment: [:])
        #expect(r.exitCode == 0)
        #expect(r.stdout.contains("[profile.default]"))
        #expect(r.stdout.contains("system_prompt"))
        #expect(r.stdout.contains("hi"))
    }

    @Test("config show --format json emits JSON")
    func showJSON() {
        let cfg = ApfelConfig(profiles: ["default": Profile(systemPrompt: "hi")])
        let loader = LoaderResult(config: cfg, source: .projectLocal, path: "/tmp/x.toml")
        let r = Subcommands.configShow(loaderResult: loader, profile: nil,
                                       format: .json, environment: [:])
        #expect(r.exitCode == 0)
        #expect(r.stdout.contains("\"system_prompt\""))
        #expect(r.stdout.contains("\"hi\""))
    }

    @Test("config show --format flags emits apfel argv preview")
    func showFlags() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mode: .serve, server: ServerSettings(port: 11434))
        ])
        let loader = LoaderResult(config: cfg, source: .projectLocal, path: "/tmp/x.toml")
        let r = Subcommands.configShow(loaderResult: loader, profile: nil,
                                       format: .flags, environment: [:])
        #expect(r.exitCode == 0)
        #expect(r.stdout.contains("--serve"))
        #expect(r.stdout.contains("11434"))
        #expect(r.stdout.contains("# profile: default"))
    }

    @Test("config show --format flags redacts tokens")
    func showFlagsRedacts() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(mode: .serve, server: ServerSettings(tokenEnv: "MY_TOKEN"))
        ])
        let loader = LoaderResult(config: cfg, source: .projectLocal, path: "/tmp/x.toml")
        let r = Subcommands.configShow(loaderResult: loader, profile: nil,
                                       format: .flags, environment: ["MY_TOKEN": "super-secret-xyz"])
        #expect(!r.stdout.contains("super-secret-xyz"))
        #expect(r.stdout.contains("APFEL_TOKEN=<redacted>"))
    }

    @Test("config show --format flags with unknown profile -> error")
    func showFlagsUnknownProfile() {
        let cfg = ApfelConfig(profiles: ["default": Profile()])
        let loader = LoaderResult(config: cfg, source: .projectLocal, path: "/tmp/x.toml")
        let r = Subcommands.configShow(loaderResult: loader, profile: "bogus",
                                       format: .flags, environment: [:])
        #expect(r.exitCode == 2)
        #expect(r.stderr.contains("bogus"))
    }

    // MARK: - config path

    @Test("config path prints loader path")
    func pathWithLoader() {
        let loader = LoaderResult(config: ApfelConfig(), source: .projectLocal, path: "/tmp/apfel.toml")
        let r = Subcommands.configPath(loaderResult: loader)
        #expect(r.stdout == "/tmp/apfel.toml\n")
    }

    @Test("config path with no file prints empty")
    func pathEmpty() {
        let loader = LoaderResult(config: ApfelConfig(), source: .none, path: nil)
        let r = Subcommands.configPath(loaderResult: loader)
        #expect(r.stdout == "")
    }

    // MARK: - config validate

    @Test("config validate on clean config exits 0")
    func validateClean() {
        let loader = LoaderResult(config: ApfelConfig(profiles: ["default": Profile()]),
                                  source: .projectLocal, path: "/tmp/x.toml")
        let r = Subcommands.configValidate(loaderResult: loader)
        #expect(r.exitCode == 0)
        #expect(r.stdout.contains("valid"))
    }

    @Test("config validate on broken config exits 1")
    func validateBroken() {
        let cfg = ApfelConfig(profiles: [
            "bad": Profile(server: ServerSettings(port: -1))
        ])
        let loader = LoaderResult(config: cfg, source: .projectLocal, path: "/tmp/x.toml")
        let r = Subcommands.configValidate(loaderResult: loader)
        #expect(r.exitCode == 1)
        #expect(r.stderr.contains("port"))
    }

    @Test("config validate with only warnings exits 0")
    func validateWarnOnly() {
        let cfg = ApfelConfig(profiles: [
            "default": Profile(server: ServerSettings(originCheck: true, footgun: true))
        ])
        let loader = LoaderResult(config: cfg, source: .projectLocal, path: "/tmp/x.toml")
        let r = Subcommands.configValidate(loaderResult: loader)
        #expect(r.exitCode == 0)
        #expect(r.stdout.contains("warning"))
    }

    // MARK: - config profiles

    @Test("config profiles lists alphabetically, one per line")
    func listProfiles() {
        let cfg = ApfelConfig(profiles: [
            "zzz": Profile(),
            "default": Profile(),
            "dev": Profile(),
        ])
        let loader = LoaderResult(config: cfg, source: .projectLocal, path: nil)
        let r = Subcommands.configProfiles(loaderResult: loader)
        #expect(r.stdout == "default\ndev\nzzz\n")
    }

    @Test("config profiles on empty config")
    func listProfilesEmpty() {
        let loader = LoaderResult(config: ApfelConfig(), source: .none, path: nil)
        let r = Subcommands.configProfiles(loaderResult: loader)
        #expect(r.stderr.contains("no profiles"))
    }

    // MARK: - config init

    @Test("config init writes starter TOML to path")
    func initWrites() throws {
        let tmp = NSTemporaryDirectory() + "apfel-run-init-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let target = tmp + "/apfel/config.toml"

        let r = try Subcommands.configInit(targetPath: target)
        #expect(r.exitCode == 0)
        #expect(r.stdout.contains(target))
        let written = try String(contentsOfFile: target, encoding: .utf8)
        #expect(written.contains("[profile.default]"))
        #expect(written.contains("apfel-mcp"))  // research section example is present
    }

    @Test("config init refuses to overwrite existing")
    func initRefusesOverwrite() throws {
        let tmp = NSTemporaryDirectory() + "apfel-run-init-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let target = tmp + "/existing.toml"
        try "existing".write(toFile: target, atomically: true, encoding: .utf8)

        let r = try Subcommands.configInit(targetPath: target)
        #expect(r.exitCode == 1)
        #expect(r.stderr.contains("refusing"))
    }

    // MARK: - migrate-config

    @Test("migrate-config reads legacy mcps.conf and writes TOML")
    func migrateHappyPath() throws {
        let tmp = NSTemporaryDirectory() + "apfel-run-migrate-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let legacy = tmp + "/mcps.conf"
        let target = tmp + "/config.toml"
        try "/a.py\n-/b.py\n".write(toFile: legacy, atomically: true, encoding: .utf8)

        let r = try Subcommands.migrateConfig(legacyPath: legacy, targetPath: target)
        #expect(r.exitCode == 0)
        #expect(r.stdout.contains("migrated"))

        // TOML was written
        let toml = try String(contentsOfFile: target, encoding: .utf8)
        #expect(toml.contains("[profile.default"))
        #expect(toml.contains("/a.py"))
        #expect(toml.contains("/b.py"))

        // Legacy renamed to .v0.1.bak
        #expect(FileManager.default.fileExists(atPath: legacy + ".v0.1.bak"))
        #expect(!FileManager.default.fileExists(atPath: legacy))
    }

    @Test("migrate-config missing legacy file -> error")
    func migrateMissingLegacy() throws {
        let tmp = NSTemporaryDirectory() + "apfel-run-migrate-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let r = try Subcommands.migrateConfig(legacyPath: tmp + "/none", targetPath: tmp + "/target.toml")
        #expect(r.exitCode == 1)
        #expect(r.stderr.contains("no legacy"))
    }
}
