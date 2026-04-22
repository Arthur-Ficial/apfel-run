import ApfelRunCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

let version = "0.2.0"

let env = ProcessInfo.processInfo.environment
let cwd = FileManager.default.currentDirectoryPath
// Read HOME directly from env so subprocess tests that set HOME work.
// NSHomeDirectory() may cache or read from getpwuid which ignores env HOME.
let home = env["HOME"] ?? NSHomeDirectory()
let args = Array(CommandLine.arguments.dropFirst())

let action = PlannerV2.plan(args: args)

switch action {
case .showHelp:
    print(helpText())
    exit(0)

case .showVersion:
    print("apfel-run \(version)")
    exit(0)

case .configSubcommand(let subArgs):
    handleConfigSubcommand(subArgs: subArgs)
    exit(0)

case .migrateConfig(let subArgs):
    handleMigrateConfig(subArgs: subArgs)
    exit(0)

case .runApfel(let profile, let userArgs):
    handleRunApfel(profile: profile, userArgs: userArgs)
    exit(126)  // only reached if execve itself failed
}

// MARK: - Handlers

func handleConfigSubcommand(subArgs: [String]) {
    let loader = ConfigLoader.load(environment: env, cwd: cwd, home: home)
    guard let sub = subArgs.first else {
        FileHandle.standardError.write(Data("usage: apfel-run config <show|path|validate|profiles|init|edit>\n".utf8))
        exit(2)
    }
    var tail = Array(subArgs.dropFirst())
    switch sub {
    case "show":
        var format: Subcommands.ShowFormat = .toml
        var profile: String? = nil
        var i = 0
        while i < tail.count {
            switch tail[i] {
            case "--format":
                i += 1
                if i < tail.count, let f = Subcommands.ShowFormat(rawValue: tail[i]) {
                    format = f
                }
            case "--profile", "-p":
                i += 1
                if i < tail.count { profile = tail[i] }
            default:
                break
            }
            i += 1
        }
        let r = Subcommands.configShow(loaderResult: loader,
                                       profile: profile,
                                       format: format,
                                       environment: env)
        write(r)

    case "path":
        if tail.contains("--all") {
            write(Subcommands.configPathAll(loaderResult: loader,
                                            environment: env,
                                            cwd: cwd,
                                            home: home))
        } else {
            write(Subcommands.configPath(loaderResult: loader))
        }

    case "validate":
        write(Subcommands.configValidate(loaderResult: loader))

    case "profiles":
        write(Subcommands.configProfiles(loaderResult: loader))

    case "init":
        let target = tail.first ?? (home + "/.config/apfel/config.toml")
        do {
            write(try Subcommands.configInit(targetPath: target))
        } catch {
            FileHandle.standardError.write(Data("init failed: \(error)\n".utf8))
            exit(1)
        }

    case "edit":
        let editor = env["EDITOR"] ?? "vi"
        let target = loader.path ?? (home + "/.config/apfel/config.toml")
        if !FileManager.default.fileExists(atPath: target) {
            // Create an empty file so the editor has something to open
            try? FileManager.default.createDirectory(
                atPath: (target as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? "".write(toFile: target, atomically: true, encoding: .utf8)
        }
        let editorArgs = [editor, target]
        var envArray: [String] = env.map { "\($0.key)=\($0.value)" }
        _ = envArray  // used via execve below
        if let editorPath = resolveBinary(editor) {
            let argvC = editorArgs.map { strdup($0) } + [nil]
            let envvC = envArray.map { strdup($0) } + [nil]
            _ = execve(editorPath, argvC, envvC)
            FileHandle.standardError.write(Data("exec editor failed\n".utf8))
            exit(127)
        }
        FileHandle.standardError.write(Data("editor not found: \(editor)\n".utf8))
        exit(127)

    default:
        FileHandle.standardError.write(Data("unknown subcommand: config \(sub)\n".utf8))
        exit(2)
    }
}

func handleMigrateConfig(subArgs: [String]) {
    let legacy = home + "/.config/apfel/mcps.conf"
    let target = home + "/.config/apfel/config.toml"
    do {
        write(try Subcommands.migrateConfig(legacyPath: legacy, targetPath: target))
    } catch {
        FileHandle.standardError.write(Data("migrate failed: \(error)\n".utf8))
        exit(1)
    }
}

func handleRunApfel(profile: String?, userArgs: [String]) {
    let loader = ConfigLoader.load(environment: env, cwd: cwd, home: home)
    let resolved: ResolvedProfile
    do {
        resolved = try ProfileResolver.resolve(config: loader.config,
                                               requested: profile,
                                               environment: env)
    } catch let err as ProfileResolverError {
        FileHandle.standardError.write(Data("\(err)\n".utf8))
        exit(2)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(2)
    }

    let built = FlagBuilder.build(profile: resolved.profile,
                                  userArgs: userArgs,
                                  environment: env)
    for w in built.warnings {
        FileHandle.standardError.write(Data("apfel-run: warning: \(w)\n".utf8))
    }

    let apfelBinary = env["APFEL_RUN_APFEL_BINARY"].flatMap { $0.isEmpty ? nil : $0 } ?? "apfel"
    guard let resolvedBinary = resolveBinary(apfelBinary) else {
        FileHandle.standardError.write(Data("apfel-run: could not find 'apfel' on $PATH\n".utf8))
        FileHandle.standardError.write(Data("install: brew install Arthur-Ficial/tap/apfel\n".utf8))
        exit(127)
    }

    let argv: [String] = [resolvedBinary] + built.argv
    let envv: [String] = built.env.map { "\($0.key)=\($0.value)" }.sorted()
    execReplace(path: resolvedBinary, argv: argv, envv: envv)
}

// MARK: - Helpers

func write(_ result: Subcommands.Result) {
    if !result.stdout.isEmpty {
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
    }
    if !result.stderr.isEmpty {
        FileHandle.standardError.write(Data(result.stderr.utf8))
    }
    if result.exitCode != 0 { exit(result.exitCode) }
}

func resolveBinary(_ name: String) -> String? {
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    for dir in path.split(separator: ":") {
        let candidate = String(dir) + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

func execReplace(path: String, argv: [String], envv: [String]) {
    let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let cEnvv: [UnsafeMutablePointer<CChar>?] = envv.map { strdup($0) } + [nil]
    _ = execve(path, cArgv, cEnvv)
    let err = String(cString: strerror(errno))
    FileHandle.standardError.write(Data("apfel-run: execve failed: \(err)\n".utf8))
}

func helpText() -> String {
    """
    apfel-run \(version) - configuration wrapper for apfel

    USAGE:
      apfel-run                               Run apfel using the default profile
      apfel-run "prompt" [apfel-flags...]     Forward prompt + all apfel flags
      apfel-run -p NAME                       Use profile NAME
      apfel-run -p NAME "prompt"              Combine: profile + prompt
      apfel-run --                            Terminate apfel-run flag scanning
      apfel-run -- --help                     Show apfel's own --help

    SUBCOMMANDS:
      config show [--format toml|json|flags] [--profile NAME]
                    Print the current config (default: TOML canonical form)
      config path [--all]
                    Print the discovered config file path, or with --all
                    the full search cascade with [x]/[-]/[ ] markers
      config validate
                    Validate the config; exit 1 with line-level errors if bad
      config profiles
                    List profile names, one per line
      config init [PATH]
                    Write a starter config to ~/.config/apfel/config.toml
                    (or the given PATH)
      config edit   Open the config in $EDITOR (vi by default)
      migrate-config
                    Read legacy ~/.config/apfel/mcps.conf (v0.1), write
                    equivalent config.toml, rename legacy to .v0.1.bak

    PROFILE FLAG:
      -p, --profile NAME   Use profile NAME from the config (default: "default")
                           Can appear anywhere before --; overrides APFEL_RUN_PROFILE.

    SELF FLAGS (only at position 0):
      --help, -h           Print this help
      --version, -v        Print apfel-run's own version

    CONFIG DISCOVERY (first hit wins) - follows XDG Base Directory Spec:
      1. $APFEL_RUN_CONFIG                   explicit file override (any path)
      2. ./apfel.toml or ./apfel.json        project-local (committable, team-shareable)
      3. $XDG_CONFIG_HOME/apfel/config.{toml,json}
                                             user config (default: ~/.config)
      4. $XDG_CONFIG_DIRS/apfel/config.{toml,json}
                                             system config, colon-separated list
                                             (default: /etc/xdg, per XDG spec)
      5. ~/.config/apfel/mcps.conf           legacy v0.1 (will be removed in v0.3)

      To see exactly which paths will be tried on your machine right now:
        apfel-run config path --all

    ENVIRONMENT:
      APFEL_RUN_CONFIG          Path to config file (bypasses discovery cascade)
      APFEL_RUN_PROFILE         Profile name (overridden by --profile flag)
      APFEL_RUN_APFEL_BINARY    Custom path to the apfel binary
      XDG_CONFIG_HOME           User config root (default: ~/.config) - XDG Base Dir Spec
      XDG_CONFIG_DIRS           System config search path, colon-separated
                                (default: /etc/xdg)
      APFEL_MCP                 Your shell-set MCPs; prepended to config's list

    Full reference:  https://github.com/Arthur-Ficial/apfel-run/blob/main/docs/config-reference.md
    Design notes:    https://github.com/Arthur-Ficial/apfel-run/blob/main/docs/DESIGN.md
    """
}
