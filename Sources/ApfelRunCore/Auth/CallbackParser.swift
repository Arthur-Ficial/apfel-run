import Foundation

/// Parses the loopback redirect request (`GET /callback?code=..&state=.. HTTP/1.1`).
/// Pure - the socket glue feeds request lines in, HTML bodies come back out.
public enum CallbackParser {
    /// Parse one HTTP request line against the expected CSRF state.
    ///
    /// - `.success(code)`: valid callback, state verified (constant-time).
    /// - `.failure(.notCallback)`: not a `/callback` request (favicon,
    ///   speculative preconnect, garbage) - the accept loop keeps going (F3).
    /// - any other `.failure`: a parseable callback that must FAIL the login
    ///   (state mismatch, AS error response, missing code).
    public static func parse(requestLine: String, expectedState: String) -> Result<String, AuthError> {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return .failure(.notCallback)
        }
        let target = String(parts[1])
        guard let components = URLComponents(string: target),
              components.path == "/callback" else {
            return .failure(.notCallback)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        if let error = query["error"], !error.isEmpty {
            return .failure(.callbackError(oauthError: error))
        }
        guard let state = query["state"], constantTimeEquals(state, expectedState) else {
            return .failure(.stateMismatch)
        }
        guard let code = query["code"], !code.isEmpty else {
            return .failure(.callbackError(oauthError: "missing code parameter"))
        }
        return .success(code)
    }

    /// Constant-time string comparison (CSRF state check must not leak
    /// prefix-match timing).
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    /// F14: must NOT claim the login succeeded - the code exchange runs after
    /// this page renders and can still fail.
    public static func successHTML() -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>apfel-run</title></head>
        <body style="font-family: -apple-system, sans-serif; margin: 3em;">
        <h1>apfel-run</h1>
        <p>Authorization received. You can close this tab - check the terminal for the result.</p>
        </body></html>
        """
    }

    public static func failureHTML(_ reason: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>apfel-run</title></head>
        <body style="font-family: -apple-system, sans-serif; margin: 3em;">
        <h1>apfel-run</h1>
        <p>Login failed: \(reason). Check the terminal.</p>
        </body></html>
        """
    }
}
