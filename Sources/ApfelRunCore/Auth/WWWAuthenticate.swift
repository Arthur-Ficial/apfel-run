import Foundation

/// RFC 9728 WWW-Authenticate parsing: extract `resource_metadata="<url>"`
/// from a Bearer challenge.
public enum WWWAuthenticate {
    /// Returns the resource_metadata URL, or nil when the header is not a
    /// Bearer challenge, lacks the parameter, or points at an insecure URL
    /// (https required; loopback http exempt per F13).
    public static func resourceMetadataURL(fromHeader header: String) -> URL? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        // Scheme is case-insensitive (RFC 9110 section 11.1).
        guard trimmed.lowercased().hasPrefix("bearer") else { return nil }
        let params = String(trimmed.dropFirst("bearer".count))

        guard let range = params.range(of: #"resource_metadata\s*=\s*"((?:[^"\\]|\\.)*)""#,
                                       options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let match = String(params[range])
        // Extract the quoted value and unescape quoted-pair sequences.
        guard let openQuote = match.firstIndex(of: "\""),
              let closeQuote = match.lastIndex(of: "\""),
              openQuote < closeQuote else { return nil }
        let raw = String(match[match.index(after: openQuote)..<closeQuote])
        let unescaped = unescapeQuotedString(raw)

        guard let url = URL(string: unescaped),
              url.host != nil,
              isSecureOrLoopback(url) else { return nil }
        return url
    }

    /// RFC 9110 quoted-string unescaping: `\X` -> `X`.
    static func unescapeQuotedString(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
