import Foundation
import Testing
@testable import ApfelRunCore

@Suite("config path --all")
struct ConfigPathAllTests {
    @Test("Lists every search path in priority order")
    func listsAll() {
        let loader = LoaderResult(config: ApfelConfig(), source: .none, path: nil)
        let r = Subcommands.configPathAll(
            loaderResult: loader,
            environment: ["APFEL_RUN_CONFIG": "/explicit.toml"],
            cwd: "/proj",
            home: "/home/me"
        )
        let out = r.stdout
        #expect(out.contains("/explicit.toml"))
        #expect(out.contains("/proj/apfel.toml"))
        #expect(out.contains("/proj/apfel.json"))
        #expect(out.contains("/home/me/.config/apfel/config.toml"))
        #expect(out.contains("/home/me/.config/apfel/config.json"))
        #expect(out.contains("/etc/xdg/apfel/config.toml"))
        #expect(out.contains("/home/me/.config/apfel/mcps.conf"))
    }

    @Test("Marks active path with [x]")
    func marksActive() throws {
        let tmp = NSTemporaryDirectory() + "apfel-pathall-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let path = tmp + "/apfel.toml"
        try "[profile.default]".write(toFile: path, atomically: true, encoding: .utf8)
        let loader = LoaderResult(config: ApfelConfig(), source: .projectLocal, path: path)
        let r = Subcommands.configPathAll(
            loaderResult: loader,
            environment: [:],
            cwd: tmp,
            home: "/home/me"
        )
        #expect(r.stdout.contains("[x] \(path)"))
    }

    @Test("Output includes a legend")
    func includesLegend() {
        let loader = LoaderResult(config: ApfelConfig(), source: .none, path: nil)
        let r = Subcommands.configPathAll(loaderResult: loader,
                                          environment: [:],
                                          cwd: "/proj", home: "/home/me")
        #expect(r.stdout.contains("Legend:"))
        #expect(r.stdout.contains("[x] loaded"))
        #expect(r.stdout.contains("[-] exists but not loaded"))
    }

    @Test("When no config loaded, shows '(none - running with apfel defaults)'")
    func showsActiveNone() {
        let loader = LoaderResult(config: ApfelConfig(), source: .none, path: nil)
        let r = Subcommands.configPathAll(loaderResult: loader,
                                          environment: [:],
                                          cwd: "/proj", home: "/home/me")
        #expect(r.stdout.contains("Active: (none"))
    }
}
