import ApfelRunCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

let version = "0.1.0"

let env = ProcessInfo.processInfo.environment
let configPath = ConfigPath.defaultLocation(environment: env)

let configText: String = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
let config = ConfigParser.parse(configText)

let args = Array(CommandLine.arguments.dropFirst())
let apfelBinary = env["APFEL_RUN_APFEL_BINARY"].flatMap { $0.isEmpty ? nil : $0 } ?? "apfel"

let plan = Planner.plan(args: args,
                        config: config,
                        environment: env,
                        configPath: configPath,
                        apfelBinary: apfelBinary)

if plan.showHelp {
    print(Formatter.helpText(version: version))
    exit(0)
}
if plan.showVersion {
    print("apfel-run \(version)")
    exit(0)
}
if plan.showConfigPath {
    print(configPath)
    exit(0)
}
if plan.listOnly {
    print(Formatter.listOutput(config: config, configPath: configPath), terminator: "")
    exit(0)
}

// Exec apfel with built environment. Use execvp-style replacement so signals
// and exit codes pass through cleanly (apfel-run leaves no parent in ps).
let resolved = resolveBinary(plan.apfelBinary)
guard let resolved else {
    FileHandle.standardError.write(Data("apfel-run: could not find 'apfel' on $PATH\n".utf8))
    FileHandle.standardError.write(Data("install: brew install Arthur-Ficial/tap/apfel\n".utf8))
    exit(127)
}

let argv: [String] = [resolved] + plan.forwardedArgs
let envv: [String] = plan.environment.map { "\($0.key)=\($0.value)" }.sorted()

execReplace(path: resolved, argv: argv, envv: envv)
exit(126)  // unreachable unless execve itself failed

// MARK: - Helpers (kept in main.swift to stay dependency-free for exec path)

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
