import Foundation
import Testing
@testable import ApfelRunCore

@Suite("CallbackParser - loopback GET /callback")
struct CallbackParserTests {
    @Test("parses code and state from GET request line")
    func parsesCodeAndState() {
        let result = CallbackParser.parse(requestLine: "GET /callback?code=abc&state=S1 HTTP/1.1",
                                          expectedState: "S1")
        #expect(result == .success("abc"))
    }

    @Test("state mismatch -> AuthError.stateMismatch")
    func stateMismatch() {
        let result = CallbackParser.parse(requestLine: "GET /callback?code=abc&state=WRONG HTTP/1.1",
                                          expectedState: "S1")
        #expect(result == .failure(.stateMismatch))
    }

    @Test("error=access_denied -> typed failure")
    func accessDenied() {
        let result = CallbackParser.parse(requestLine: "GET /callback?error=access_denied&state=S1 HTTP/1.1",
                                          expectedState: "S1")
        #expect(result == .failure(.callbackError(oauthError: "access_denied")))
    }

    @Test("percent-decoded code")
    func percentDecodedCode() {
        let result = CallbackParser.parse(requestLine: "GET /callback?code=a%2Fb&state=S1 HTTP/1.1",
                                          expectedState: "S1")
        #expect(result == .success("a/b"))
    }

    @Test("wrong path -> failure")
    func wrongPath() {
        let result = CallbackParser.parse(requestLine: "GET /favicon.ico HTTP/1.1",
                                          expectedState: "S1")
        #expect(result == .failure(.notCallback))
    }

    @Test("missing code -> failure")
    func missingCode() {
        let result = CallbackParser.parse(requestLine: "GET /callback?state=S1 HTTP/1.1",
                                          expectedState: "S1")
        #expect(result == .failure(.callbackError(oauthError: "missing code parameter")))
    }

    @Test("successHTML says close this tab and check the terminal, and contains no token material")
    func successHTMLCopy() {
        let html = CallbackParser.successHTML()
        // F14: the page must NOT claim success - the code exchange runs after
        // the page renders and can still fail.
        #expect(html.lowercased().contains("close this tab"))
        #expect(html.lowercased().contains("check the terminal"))
        #expect(!html.lowercased().contains("success"))
        #expect(!html.contains("code="))
        #expect(!html.contains("token"))
    }

    @Test("constantTimeEquals compares correctly")
    func constantTimeCompare() {
        #expect(CallbackParser.constantTimeEquals("abc", "abc"))
        #expect(!CallbackParser.constantTimeEquals("abc", "abd"))
        #expect(!CallbackParser.constantTimeEquals("abc", "ab"))
        #expect(!CallbackParser.constantTimeEquals("", "a"))
        #expect(CallbackParser.constantTimeEquals("", ""))
    }
}
