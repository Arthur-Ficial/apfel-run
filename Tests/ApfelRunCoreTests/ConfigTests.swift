import Testing
@testable import ApfelRunCore

@Suite("ConfigParser")
struct ConfigParserTests {
    @Test("empty string yields empty config")
    func emptyString() {
        #expect(ConfigParser.parse("").entries.isEmpty)
    }

    @Test("comment-only file yields empty config")
    func commentsOnly() {
        let text = "# comment\n# another\n"
        #expect(ConfigParser.parse(text).entries.isEmpty)
    }

    @Test("single enabled path")
    func singleEnabled() {
        let config = ConfigParser.parse("/Users/me/mcp/calc.py")
        #expect(config.entries == [MCPEntry(path: "/Users/me/mcp/calc.py", enabled: true, lineNumber: 1)])
    }

    @Test("dash-prefixed path is disabled")
    func dashDisables() {
        let config = ConfigParser.parse("-/Users/me/mcp/filesystem.py")
        #expect(config.entries == [MCPEntry(path: "/Users/me/mcp/filesystem.py", enabled: false, lineNumber: 1)])
    }

    @Test("dash with whitespace is still a disabled entry")
    func dashWithSpace() {
        let config = ConfigParser.parse("-   /Users/me/mcp/a.py")
        #expect(config.entries == [MCPEntry(path: "/Users/me/mcp/a.py", enabled: false, lineNumber: 1)])
    }

    @Test("trailing comment is stripped")
    func trailingComment() {
        let config = ConfigParser.parse("/path/a.py   # my calculator")
        #expect(config.entries == [MCPEntry(path: "/path/a.py", enabled: true, lineNumber: 1)])
    }

    @Test("hash inside URL fragment is preserved (no leading space)")
    func hashInURLPreserved() {
        let config = ConfigParser.parse("https://tools.example.com/mcp#v2")
        #expect(config.entries.count == 1)
        #expect(config.entries[0].path == "https://tools.example.com/mcp#v2")
    }

    @Test("blank lines ignored")
    func blankLinesIgnored() {
        let text = "\n\n/path/a.py\n\n\n"
        #expect(ConfigParser.parse(text).entries.count == 1)
    }

    @Test("multiple entries preserve order and line numbers")
    func multipleEntries() {
        let text = """
        # header
        /one.py
        -/two.py
        /three.py
        """
        let config = ConfigParser.parse(text)
        #expect(config.entries.count == 3)
        #expect(config.entries[0] == MCPEntry(path: "/one.py", enabled: true, lineNumber: 2))
        #expect(config.entries[1] == MCPEntry(path: "/two.py", enabled: false, lineNumber: 3))
        #expect(config.entries[2] == MCPEntry(path: "/three.py", enabled: true, lineNumber: 4))
    }

    @Test("enabledPaths returns only enabled")
    func enabledPathsOnly() {
        let text = "/one.py\n-/two.py\n/three.py\n"
        let config = ConfigParser.parse(text)
        #expect(config.enabledPaths == ["/one.py", "/three.py"])
    }

    @Test("apfelMCPValue joins with comma")
    func apfelMCPValueJoinsComma() {
        let config = ConfigParser.parse("/a.py\n/b.py\n-/c.py\n")
        #expect(config.apfelMCPValue == "/a.py,/b.py")
    }

    @Test("apfelMCPValue empty when all disabled")
    func apfelMCPValueEmptyWhenAllDisabled() {
        let config = ConfigParser.parse("-/a.py\n-/b.py\n")
        #expect(config.apfelMCPValue == "")
    }

    @Test("URLs with commas are supported as single entries (one per line)")
    func urlPerLine() {
        let text = "https://a.example/mcp\nhttps://b.example/mcp\n"
        let config = ConfigParser.parse(text)
        #expect(config.enabledPaths == ["https://a.example/mcp", "https://b.example/mcp"])
    }

    @Test("whitespace-only lines skipped")
    func whitespaceLinesSkipped() {
        let text = "   \n\t\n/a.py\n"
        #expect(ConfigParser.parse(text).entries.count == 1)
    }

    @Test("standalone dash yields no entry")
    func standaloneDash() {
        #expect(ConfigParser.parse("-").entries.isEmpty)
    }
}

@Suite("ConfigPath")
struct ConfigPathTests {
    @Test("APFEL_RUN_CONFIG override wins")
    func overrideWins() {
        let path = ConfigPath.defaultLocation(environment: [
            "APFEL_RUN_CONFIG": "/tmp/custom.conf",
            "XDG_CONFIG_HOME": "/tmp/xdg",
        ], home: "/Users/me")
        #expect(path == "/tmp/custom.conf")
    }

    @Test("XDG_CONFIG_HOME used when override absent")
    func xdgHome() {
        let path = ConfigPath.defaultLocation(environment: [
            "XDG_CONFIG_HOME": "/tmp/xdg",
        ], home: "/Users/me")
        #expect(path == "/tmp/xdg/apfel/mcps.conf")
    }

    @Test("HOME fallback")
    func homeFallback() {
        let path = ConfigPath.defaultLocation(environment: [:], home: "/Users/me")
        #expect(path == "/Users/me/.config/apfel/mcps.conf")
    }

    @Test("empty override falls through")
    func emptyOverrideFallsThrough() {
        let path = ConfigPath.defaultLocation(environment: [
            "APFEL_RUN_CONFIG": "",
            "XDG_CONFIG_HOME": "/tmp/xdg",
        ], home: "/Users/me")
        #expect(path == "/tmp/xdg/apfel/mcps.conf")
    }
}

@Suite("Planner")
struct PlannerTests {
    let config = ConfigParser.parse("/a.py\n-/b.py\n/c.py\n")
    let configPath = "/tmp/mcps.conf"

    @Test("no args forwards none, sets APFEL_MCP")
    func noArgs() {
        let plan = Planner.plan(args: [], config: config, environment: [:], configPath: configPath)
        #expect(plan.forwardedArgs.isEmpty)
        #expect(plan.environment["APFEL_MCP"] == "/a.py,/c.py")
        #expect(!plan.listOnly)
        #expect(!plan.showHelp)
    }

    @Test("--list is detected and does not forward")
    func listFlag() {
        let plan = Planner.plan(args: ["--list"], config: config, environment: [:], configPath: configPath)
        #expect(plan.listOnly)
        #expect(plan.forwardedArgs.isEmpty)
    }

    @Test("--help detected")
    func helpFlag() {
        let plan = Planner.plan(args: ["--help"], config: config, environment: [:], configPath: configPath)
        #expect(plan.showHelp)
    }

    @Test("-h detected")
    func shortHelp() {
        let plan = Planner.plan(args: ["-h"], config: config, environment: [:], configPath: configPath)
        #expect(plan.showHelp)
    }

    @Test("--version detected")
    func versionFlag() {
        let plan = Planner.plan(args: ["--version"], config: config, environment: [:], configPath: configPath)
        #expect(plan.showVersion)
    }

    @Test("--config-path detected")
    func configPathFlag() {
        let plan = Planner.plan(args: ["--config-path"], config: config, environment: [:], configPath: configPath)
        #expect(plan.showConfigPath)
    }

    @Test("-- passes through all subsequent args verbatim")
    func doubleDashPassthrough() {
        let plan = Planner.plan(args: ["--", "--help", "--list"],
                                config: config, environment: [:], configPath: configPath)
        #expect(plan.forwardedArgs == ["--help", "--list"])
        #expect(!plan.showHelp)
        #expect(!plan.listOnly)
    }

    @Test("prompt args forwarded unchanged")
    func promptForwarded() {
        let plan = Planner.plan(args: ["what is 42?", "--stream"],
                                config: config, environment: [:], configPath: configPath)
        #expect(plan.forwardedArgs == ["what is 42?", "--stream"])
    }

    @Test("existing APFEL_MCP is prepended, config appended")
    func existingMCPMerged() {
        let plan = Planner.plan(args: [],
                                config: config,
                                environment: ["APFEL_MCP": "/shell-override.py"],
                                configPath: configPath)
        #expect(plan.environment["APFEL_MCP"] == "/shell-override.py,/a.py,/c.py")
    }

    @Test("empty config does not set APFEL_MCP")
    func emptyConfigNoEnv() {
        let empty = Config(entries: [])
        let plan = Planner.plan(args: [], config: empty, environment: [:], configPath: configPath)
        #expect(plan.environment["APFEL_MCP"] == nil)
    }

    @Test("empty config preserves existing APFEL_MCP")
    func emptyConfigPreservesEnv() {
        let empty = Config(entries: [])
        let plan = Planner.plan(args: [],
                                config: empty,
                                environment: ["APFEL_MCP": "/existing.py"],
                                configPath: configPath)
        #expect(plan.environment["APFEL_MCP"] == "/existing.py")
    }

    @Test("all-disabled config behaves like empty config")
    func allDisabledBehavesLikeEmpty() {
        let cfg = ConfigParser.parse("-/a.py\n-/b.py\n")
        let plan = Planner.plan(args: [],
                                config: cfg,
                                environment: ["APFEL_MCP": "/existing.py"],
                                configPath: configPath)
        #expect(plan.environment["APFEL_MCP"] == "/existing.py")
    }
}

@Suite("Formatter")
struct FormatterTests {
    @Test("list output - empty config")
    func listEmpty() {
        let out = Formatter.listOutput(config: Config(), configPath: "/tmp/x.conf")
        #expect(out.contains("no MCPs configured"))
        #expect(out.contains("/tmp/x.conf"))
    }

    @Test("list output shows enabled/disabled markers")
    func listMarkers() {
        let cfg = ConfigParser.parse("/a.py\n-/b.py\n")
        let out = Formatter.listOutput(config: cfg, configPath: "/tmp/x.conf")
        #expect(out.contains("[x] /a.py"))
        #expect(out.contains("[ ] /b.py"))
        #expect(out.contains("1 enabled, 1 disabled"))
    }

    @Test("help text includes usage")
    func helpMentionsUsage() {
        let help = Formatter.helpText(version: "1.2.3")
        #expect(help.contains("apfel-run 1.2.3"))
        #expect(help.contains("--list"))
        #expect(help.contains("APFEL_MCP"))
        #expect(help.contains("~/.config/apfel/mcps.conf"))
    }
}
