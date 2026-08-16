import Foundation
import Testing
@testable import ApfelRunCore

@Suite("PKCE - RFC 7636 S256")
struct PKCETests {
    @Test("verifier is 43-char base64url from 32 bytes")
    func verifierShape() {
        let random = FixedRandom(bytes: [UInt8](repeating: 0x00, count: 32))
        let pkce = PKCE.generate(random: random)
        // base64url of 32 zero bytes = 43 'A' characters, no padding
        #expect(pkce.verifier == String(repeating: "A", count: 43))
        #expect(pkce.verifier.count == 43)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(pkce.verifier.allSatisfy { allowed.contains($0) })
        #expect(!pkce.verifier.contains("="))
    }

    @Test("challenge is base64url(SHA256(verifier)) - RFC 7636 appendix B vector")
    func rfcVector() {
        let challenge = PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("state is a 43-char base64url from an independent 32-byte draw")
    func stateIndependentDraw() {
        let verifierBytes = [UInt8](repeating: 0x01, count: 32)
        let stateBytes = [UInt8](repeating: 0x02, count: 32)
        let random = FixedRandom(draws: [verifierBytes, stateBytes])
        let pkce = PKCE.generate(random: random)
        let state = PKCE.state(random: random)
        #expect(random.callCount == 2)
        #expect(state.count == 43)
        #expect(state != pkce.verifier)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(state.allSatisfy { allowed.contains($0) })
    }

    @Test("two generates with system random differ")
    func systemRandomDiffers() {
        let a = PKCE.generate(random: SystemRandomBytes())
        let b = PKCE.generate(random: SystemRandomBytes())
        #expect(a.verifier != b.verifier)
        #expect(a.challenge != b.challenge)
    }
}
