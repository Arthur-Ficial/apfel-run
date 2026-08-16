import Foundation
import Testing
@testable import ApfelRunCore

@Suite("PlannerV2")
struct PlannerV2Tests {
    @Test("No args -> runApfel with no profile")
    func noArgs() {
        let action = PlannerV2.plan(args: [])
        #expect(action == .runApfel(profile: nil, args: []))
    }

    @Test("First arg --help -> showHelp")
    func helpFirstArg() {
        #expect(PlannerV2.plan(args: ["--help"]) == .showHelp)
        #expect(PlannerV2.plan(args: ["-h"]) == .showHelp)
    }

    @Test("First arg --version -> showVersion")
    func versionFirstArg() {
        #expect(PlannerV2.plan(args: ["--version"]) == .showVersion)
        #expect(PlannerV2.plan(args: ["-v"]) == .showVersion)
    }

    @Test("config subcommand captured")
    func configSubcommand() {
        #expect(PlannerV2.plan(args: ["config", "show"]) == .configSubcommand(args: ["show"]))
        #expect(PlannerV2.plan(args: ["config"]) == .configSubcommand(args: []))
    }

    @Test("migrate-config captured")
    func migrateConfig() {
        #expect(PlannerV2.plan(args: ["migrate-config"]) == .migrateConfig(args: []))
        #expect(PlannerV2.plan(args: ["migrate-config", "--dry-run"]) == .migrateConfig(args: ["--dry-run"]))
    }

    @Test("--profile at first position consumed")
    func profileFirst() {
        let action = PlannerV2.plan(args: ["--profile", "dev"])
        #expect(action == .runApfel(profile: "dev", args: []))
    }

    @Test("-p shorthand consumed")
    func profileShort() {
        #expect(PlannerV2.plan(args: ["-p", "dev"]) == .runApfel(profile: "dev", args: []))
    }

    @Test("--profile + apfel flags")
    func profileWithApfelFlags() {
        let action = PlannerV2.plan(args: ["--profile", "dev", "--serve", "--port", "11500"])
        #expect(action == .runApfel(profile: "dev", args: ["--serve", "--port", "11500"]))
    }

    @Test("--profile in middle also extracted")
    func profileMiddle() {
        let action = PlannerV2.plan(args: ["--serve", "--profile", "dev", "--port", "11500"])
        #expect(action == .runApfel(profile: "dev", args: ["--serve", "--port", "11500"]))
    }

    @Test("-- marker stops scanning - --profile after is forwarded")
    func doubleDashStopsProfileScan() {
        let action = PlannerV2.plan(args: ["--", "--profile", "dev"])
        #expect(action == .runApfel(profile: nil, args: ["--profile", "dev"]))
    }

    @Test("--help inside -- region forwarded to apfel")
    func helpAfterDoubleDash() {
        let action = PlannerV2.plan(args: ["--", "--help"])
        #expect(action == .runApfel(profile: nil, args: ["--help"]))
    }

    @Test("Prompt as first arg with profile later")
    func promptWithProfile() {
        let action = PlannerV2.plan(args: ["what is 2+2?", "--profile", "dev"])
        #expect(action == .runApfel(profile: "dev", args: ["what is 2+2?"]))
    }

    @Test("--profile with no value - value not consumed, profile stays nil")
    func profileNoValue() {
        let action = PlannerV2.plan(args: ["--profile"])
        // Current behaviour: no value after --profile means profile stays nil.
        // Alternative would be to error, but runApfel with nil profile is correct.
        #expect(action == .runApfel(profile: nil, args: []))
    }

    @Test("Subcommand 'config' at pos 0 wins over everything else")
    func configBeatsAll() {
        #expect(PlannerV2.plan(args: ["config", "--help"]) == .configSubcommand(args: ["--help"]))
    }

    @Test("Everything verbatim when first arg is a prompt")
    func promptForwarded() {
        let args = ["what is 2+2?", "--stream"]
        let action = PlannerV2.plan(args: args)
        #expect(action == .runApfel(profile: nil, args: args))
    }

    @Test("Apfel flags at position 0 forward verbatim (no profile)")
    func apfelFlagPos0() {
        let action = PlannerV2.plan(args: ["--serve", "--port", "11500"])
        #expect(action == .runApfel(profile: nil, args: ["--serve", "--port", "11500"]))
    }

    // MARK: - auth subcommand (OAuth 2.1, apfel-run#1)

    @Test("auth subcommand captured at position 0")
    func authSubcommand() {
        #expect(PlannerV2.plan(args: ["auth", "login", "https://x/mcp"])
                == .authSubcommand(args: ["login", "https://x/mcp"]))
        #expect(PlannerV2.plan(args: ["auth"]) == .authSubcommand(args: []))
    }

    @Test("auth past position 0 forwards to apfel")
    func authPastPositionZeroForwards() {
        // PIN test: a prompt mentioning "auth" must never be intercepted.
        #expect(PlannerV2.plan(args: ["explain", "auth"])
                == .runApfel(profile: nil, args: ["explain", "auth"]))
    }

    @Test("-- auth forwards verbatim")
    func doubleDashAuthForwards() {
        // PIN test: the `--` escape hatch beats subcommand interception.
        #expect(PlannerV2.plan(args: ["--", "auth", "list"])
                == .runApfel(profile: nil, args: ["auth", "list"]))
    }
}
