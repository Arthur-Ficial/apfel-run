import CryptoKit
import Foundation

/// RFC 7636 PKCE, S256 only. `plain` is never offered (OAuth 2.1 stance).
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    /// 32 random bytes -> base64url (no padding) verifier (43 chars)
    /// -> SHA-256 -> base64url challenge.
    public static func generate(random: RandomBytesProviding) -> PKCE {
        let verifier = base64URL(Data(random.randomBytes(32)))
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// base64url(SHA256(ascii(verifier))) - RFC 7636 section 4.2.
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// CSRF `state`: an independent 32-byte draw, base64url encoded.
    public static func state(random: RandomBytesProviding) -> String {
        base64URL(Data(random.randomBytes(32)))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
