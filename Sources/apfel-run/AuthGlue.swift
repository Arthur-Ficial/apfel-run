import ApfelRunCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The impure OAuth glue: URLSession transport, browser open, loopback POSIX
// listener, refresh flock, and the `apfel-run auth ...` dispatcher. Every
// branchy decision lives in ApfelRunCore and is unit-tested there; this file
// only wires syscalls and I/O together (covered by
// scripts/auth-loopback-smoke.sh + two subprocess integration tests).

// MARK: - HTTP transport

/// Ephemeral URLSession (no shared cookie jar, no cache), 30 s timeout,
/// redirects never followed (token/registration endpoints must not bounce).
struct URLSessionTransport: HTTPTransport {
    func send(_ request: HTTPRequestData) async throws -> HTTPResponseData {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration,
                                 delegate: NoRedirectDelegate(),
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.discoveryFailed(rung: "transport",
                                            detail: "non-HTTP response from \(request.url.absoluteString)")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k] = v
            }
        }
        return HTTPResponseData(status: http.statusCode, headers: headers, body: data)
    }
}

/// Stateless delegate that refuses every HTTP redirect.
/// @unchecked Sendable is safe: the class holds no state at all.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Browser

protocol BrowserOpening {
    func open(_ url: URL) throws
}

struct SystemBrowser: BrowserOpening {
    func open(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AuthError.callbackError(oauthError: "could not open browser")
        }
    }
}

// MARK: - Loopback listener (RFC 8252 loopback redirect)

/// POSIX socket bound to 127.0.0.1:0 (ephemeral port, never 0.0.0.0).
/// F3: accept LOOP until the deadline with a ~2 s per-connection read timeout
/// so browser speculative preconnects and favicon fetches cannot hang login.
/// The FIRST valid /callback wins and the listening socket closes immediately
/// (no second, attacker-supplied code can ever arrive).
///
/// @unchecked Sendable proof: access is strictly sequential - `bind()` runs
/// before the callback thread is spawned, `awaitCallback` then owns the
/// instance exclusively on that one thread, and the error-path `close()` in
/// performLogin only runs after the continuation has resumed (i.e. after
/// `awaitCallback` returned). No two threads ever touch `fd` concurrently.
final class LoopbackListener: @unchecked Sendable {
    private var fd: Int32 = -1
    private(set) var port: UInt16 = 0

    func bind() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AuthError.callbackError(oauthError: "socket() failed: \(String(cString: strerror(errno)))")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback ONLY
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close()
            throw AuthError.callbackError(oauthError: "could not bind loopback port: \(message)")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)
    }

    /// Blocking accept loop; run it off the cooperative pool (see performLogin).
    func awaitCallback(expectedState: String, deadline: Date) -> Result<String, AuthError> {
        while Date() < deadline {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainingMS = Int32(min(1000, max(0, deadline.timeIntervalSinceNow * 1000)))
            let ready = poll(&pollFD, 1, remainingMS)
            guard ready > 0 else { continue }

            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            // F3: 2 s per-connection read timeout - preconnects that never
            // send a request line are drained and dropped.
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))

            guard let requestLine = readRequestLine(client) else {
                Darwin.close(client)
                continue
            }
            switch CallbackParser.parse(requestLine: requestLine, expectedState: expectedState) {
            case .success(let code):
                respond(client, status: "200 OK", html: CallbackParser.successHTML())
                Darwin.close(client)
                close()  // no second code can ever arrive
                return .success(code)
            case .failure(.notCallback):
                respond(client, status: "404 Not Found", html: "")
                Darwin.close(client)
                continue
            case .failure(let error):
                // A parseable callback that is bad (state mismatch, AS error,
                // missing code) FAILS the login.
                respond(client, status: "400 Bad Request",
                        html: CallbackParser.failureHTML(error.message))
                Darwin.close(client)
                close()
                return .failure(error)
            }
        }
        close()
        return .failure(.callbackTimeout)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Read up to the first CRLF, capped at 8 KB (request-line length cap).
    private func readRequestLine(_ client: Int32) -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while buffer.count < 8192 {
            let n = recv(client, &byte, 1, 0)
            guard n == 1 else { return nil }
            if byte == 0x0A {  // \n
                break
            }
            if byte != 0x0D {  // skip \r
                buffer.append(byte)
            }
        }
        return String(bytes: buffer, encoding: .utf8)
    }

    private func respond(_ client: Int32, status: String, html: String) {
        let response = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + html
        _ = response.withCString { pointer in
            Darwin.send(client, pointer, strlen(pointer), 0)
        }
    }
}

// MARK: - Refresh lock (F4)

/// Serializes load->refresh->save across concurrent apfel-run invocations via
/// flock, so a rotated refresh token is never replayed (reuse-detecting ASs
/// revoke the whole grant on replay). The lock loser re-loads the winner's
/// rotated credential inside `LaunchTokenResolver.resolve`.
struct RefreshLock {
    let path: String

    func withLock<T>(_ body: () async throws -> T) async throws -> T {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory,
                                                 withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            // Lock file unavailable (exotic $HOME setups): proceed unlocked
            // rather than break every launch; the race window is unchanged
            // from the pre-lock world.
            return try await body()
        }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        return try await body()
    }
}

// MARK: - auth dispatcher

func handleAuth(subArgs: [String]) async {
    let command = AuthSubcommands.parse(args: subArgs)
    let store = KeychainTokenStore(items: SecItemKeychain())
    let clock = SystemClock()
    switch command {
    case .usageError(let message):
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    case .list:
        let result = AuthSubcommands.list(store: store, clock: clock)
        write(result)
        exit(result.exitCode)
    case .status(let url):
        let result = AuthSubcommands.status(url: url, store: store, clock: clock)
        write(result)
        exit(result.exitCode)
    case .logout(let url):
        let result = AuthSubcommands.logout(url: url, store: store)
        write(result)
        exit(result.exitCode)
    case .login(let url, let scope, let timeoutSeconds, let noBrowser):
        await performLogin(url: url, scope: scope,
                           timeoutSeconds: timeoutSeconds, noBrowser: noBrowser)
    }
}

// MARK: - Interactive login orchestration

func performLogin(url: String, scope: String?, timeoutSeconds: Int, noBrowser: Bool) async {
    guard case .success(let mcpURL) = AuthSubcommands.loginPreflight(url: url) else {
        FileHandle.standardError.write(Data("auth login requires an https:// MCP URL (got '\(url)')\n".utf8))
        exit(2)
    }

    let transport = URLSessionTransport()
    let clock = SystemClock()
    let random = SystemRandomBytes()
    let flow = OAuthFlow(transport: transport, clock: clock, random: random)
    let store = KeychainTokenStore(items: SecItemKeychain())
    let listener = LoopbackListener()

    func progress(_ line: String) {
        // Progress goes to stderr so stdout stays pipeable.
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    do {
        // Bind the port FIRST so the concrete redirect URI is known before
        // DCR (avoids RFC 8252 port-mismatch roulette with strict ASs).
        try listener.bind()
        let redirectURI = "http://127.0.0.1:\(listener.port)/callback"

        progress("discovering OAuth metadata for \(mcpURL.absoluteString)...")
        let discovery = try await Discovery.discover(mcpURL: mcpURL, transport: transport)
        try OAuthFlow.checkPKCESupport(discovery.authServer)

        progress("registering client (RFC 7591)...")
        let registration = try await flow.register(metadata: discovery.authServer,
                                                   redirectURI: redirectURI)

        let pkce = PKCE.generate(random: random)
        let state = PKCE.state(random: random)
        let resource = normalizeServerKey(mcpURL.absoluteString)
        let effectiveScope = scope
            ?? discovery.resourceMetadata?.scopesSupported?.joined(separator: " ")
        let authorizationURL = flow.authorizationURL(metadata: discovery.authServer,
                                                     clientID: registration.clientID,
                                                     redirectURI: redirectURI,
                                                     pkce: pkce,
                                                     state: state,
                                                     resource: resource,
                                                     scope: effectiveScope)

        if noBrowser {
            progress("open this URL to authorize:")
            progress(authorizationURL.absoluteString)
        } else {
            do {
                try SystemBrowser().open(authorizationURL)
                progress("opening browser...")
            } catch {
                progress("could not open browser - open this URL manually:")
                progress(authorizationURL.absoluteString)
            }
        }
        progress("waiting for callback on 127.0.0.1:\(listener.port)... (timeout \(timeoutSeconds)s)")

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        // Blocking accept loop on its own thread - never block the
        // cooperative pool.
        let callback: Result<String, AuthError> = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: listener.awaitCallback(expectedState: state,
                                                                      deadline: deadline))
            }
        }
        let code: String
        switch callback {
        case .success(let value): code = value
        case .failure(let error): throw error
        }

        progress("exchanging authorization code...")
        let tokenResponse = try await flow.exchangeCode(code,
                                                        metadata: discovery.authServer,
                                                        clientID: registration.clientID,
                                                        clientSecret: registration.clientSecret,
                                                        redirectURI: redirectURI,
                                                        pkce: pkce,
                                                        resource: resource)
        guard let tokenEndpointURL = URL(string: discovery.authServer.tokenEndpoint) else {
            throw AuthError.discoveryFailed(rung: "token endpoint",
                                            detail: "invalid URL: \(discovery.authServer.tokenEndpoint)")
        }
        let credential = flow.credential(from: tokenResponse,
                                         tokenEndpoint: tokenEndpointURL,
                                         clientID: registration.clientID,
                                         clientSecret: registration.clientSecret,
                                         resource: resource,
                                         previous: nil)
        try store.save(credential, server: mcpURL.absoluteString)

        print("✔ authenticated \(resource)")
        if let expiresAt = credential.expiresAt {
            print("  access token valid until \(ISO8601DateFormatter().string(from: expiresAt))"
                  + (credential.refreshToken != nil ? " (auto-refreshes on launch)" : ""))
        } else {
            print("  access token has no recorded expiry")
        }
        print("  stored in Keychain")
        exit(0)
    } catch let error as AuthError {
        listener.close()
        FileHandle.standardError.write(Data("apfel-run: \(error.message)\n".utf8))
        exit(1)
    } catch {
        listener.close()
        FileHandle.standardError.write(Data("apfel-run: \(error)\n".utf8))
        exit(1)
    }
}
