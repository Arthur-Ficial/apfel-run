import Foundation
import Testing
@testable import ApfelRunCore

@Suite("ProfileResolver")
struct ProfileResolverTests {
    let cfg = ApfelConfig(profiles: [
        "default": Profile(systemPrompt: "default"),
        "dev": Profile(systemPrompt: "dev"),
        "prod": Profile(systemPrompt: "prod"),
    ])

    @Test("No request, no env -> default profile")
    func defaultProfile() throws {
        let r = try ProfileResolver.resolve(config: cfg, requested: nil, environment: [:])
        #expect(r.name == "default")
        #expect(r.profile.systemPrompt == "default")
    }

    @Test("Requested name wins over env")
    func requestedWinsOverEnv() throws {
        let r = try ProfileResolver.resolve(config: cfg, requested: "dev",
                                            environment: ["APFEL_RUN_PROFILE": "prod"])
        #expect(r.name == "dev")
        #expect(r.profile.systemPrompt == "dev")
    }

    @Test("APFEL_RUN_PROFILE env used when no CLI request")
    func envHonoured() throws {
        let r = try ProfileResolver.resolve(config: cfg, requested: nil,
                                            environment: ["APFEL_RUN_PROFILE": "prod"])
        #expect(r.name == "prod")
    }

    @Test("Unknown profile throws with known list + suggestion")
    func unknownProfileThrows() {
        do {
            _ = try ProfileResolver.resolve(config: cfg, requested: "dve", environment: [:])
            Issue.record("expected throw")
        } catch let err as ProfileResolverError {
            #expect(err.requestedName == "dve")
            #expect(err.knownProfiles.sorted() == ["default", "dev", "prod"])
            #expect(err.suggestion == "dev")  // closest match
        } catch {
            Issue.record("expected ProfileResolverError, got \(error)")
        }
    }

    @Test("Empty config + no request -> empty resolved profile")
    func emptyConfigReturnsEmpty() throws {
        let r = try ProfileResolver.resolve(config: ApfelConfig(), requested: nil, environment: [:])
        #expect(r.name == "")
        #expect(r.profile == Profile())
    }

    @Test("Empty config + explicit request -> throws")
    func emptyConfigExplicitRequestThrows() {
        do {
            _ = try ProfileResolver.resolve(config: ApfelConfig(), requested: "dev", environment: [:])
            Issue.record("expected throw")
        } catch let err as ProfileResolverError {
            #expect(err.knownProfiles.isEmpty)
        } catch {
            Issue.record("wrong error")
        }
    }

    @Test("No 'default' profile in config + no request -> empty profile")
    func missingDefaultOK() throws {
        let cfg2 = ApfelConfig(profiles: ["dev": Profile()])
        let r = try ProfileResolver.resolve(config: cfg2, requested: nil, environment: [:])
        // With no default profile defined and no request, we pick no profile
        #expect(r.name == "")
    }

    @Test("Levenshtein suggestion picks closest by edit distance")
    func levenshteinClosest() {
        let known = ["default", "dev", "develop", "production", "prod"]
        #expect(ProfileResolver.suggest(for: "deev", from: known) == "dev")
        #expect(ProfileResolver.suggest(for: "produciton", from: known) == "production")
        #expect(ProfileResolver.suggest(for: "completely-random", from: known) == nil) // far
    }
}
