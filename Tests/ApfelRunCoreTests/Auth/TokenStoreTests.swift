import Foundation
import Security
import Testing
@testable import ApfelRunCore

// MARK: - Fixtures

/// Pure in-memory TokenStoring - proves the protocol contract the fakes rely on.
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    // Test-only fixture: mutated from a single test thread.
    var storage: [String: StoredCredential] = [:]
    private(set) var loadCount = 0
    private(set) var saveCount = 0

    func load(server: String) throws -> StoredCredential? {
        loadCount += 1
        return storage[normalizeServerKey(server)]
    }

    func save(_ credential: StoredCredential, server: String) throws {
        saveCount += 1
        storage[normalizeServerKey(server)] = credential
    }

    func delete(server: String) throws -> Bool {
        storage.removeValue(forKey: normalizeServerKey(server)) != nil
    }

    func list() throws -> [String] {
        storage.keys.sorted()
    }
}

/// Records SecItem query dictionaries; replays scripted statuses.
final class FakeKeychainItems: KeychainItems, @unchecked Sendable {
    // Test-only fixture: mutated from a single test thread.
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var copyResult: (OSStatus, Data?) = (errSecItemNotFound, nil)
    var accountsResult: (OSStatus, [String]) = (errSecItemNotFound, [])

    private(set) var addQueries: [[String: Any]] = []
    private(set) var updateQueries: [([String: Any], [String: Any])] = []
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    func add(_ query: [String: Any]) -> OSStatus {
        addQueries.append(query)
        return addStatus
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        copyQueries.append(query)
        return copyResult
    }

    func copyAllAccounts(_ query: [String: Any]) -> (OSStatus, [String]) {
        accountsResult
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateQueries.append((query, attributes))
        return updateStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deleteQueries.append(query)
        return deleteStatus
    }
}

func makeCredential(accessToken: String = "at1",
                    refreshToken: String? = "rt1",
                    expiresAt: Date? = nil) -> StoredCredential {
    StoredCredential(accessToken: accessToken,
                     refreshToken: refreshToken,
                     expiresAt: expiresAt,
                     tokenEndpoint: URL(string: "https://as.example.com/token")!,
                     clientID: "c1",
                     resource: "https://mcp.example.com/mcp",
                     obtainedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

// MARK: - Tests

@Suite("TokenStore - normalization, validity, keychain mapping")
struct TokenStoreTests {
    @Test("normalizeServerKey lowercases scheme+host, strips default port and trailing slash, keeps path")
    func normalizeKey() {
        #expect(normalizeServerKey("HTTPS://MCP.Evernote.com:443/mcp/") == "https://mcp.evernote.com/mcp")
        #expect(normalizeServerKey("https://mcp.example.com/mcp") == "https://mcp.example.com/mcp")
        #expect(normalizeServerKey("http://Localhost:80/x") == "http://localhost/x")
        #expect(normalizeServerKey("https://h.example:8443/mcp") == "https://h.example:8443/mcp")
        #expect(normalizeServerKey("https://h.example") == "https://h.example")
        #expect(normalizeServerKey("https://h.example/") == "https://h.example")
    }

    @Test("validity: valid when now < expiresAt - 60s skew")
    func validityValid() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = FixedClock(now: now)
        let credential = makeCredential(expiresAt: now.addingTimeInterval(120))
        #expect(validity(of: credential, clock: clock) == .valid(until: now.addingTimeInterval(120)))
    }

    @Test("validity: expired inside skew window")
    func validityExpiredInsideSkew() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = FixedClock(now: now)
        // 30s left < 60s skew -> treated as expired
        let credential = makeCredential(expiresAt: now.addingTimeInterval(30))
        #expect(validity(of: credential, clock: clock) == .expired(refreshable: true))
    }

    @Test("validity: expired(refreshable:) reflects refreshToken presence")
    func validityRefreshable() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = FixedClock(now: now)
        let past = now.addingTimeInterval(-10)
        #expect(validity(of: makeCredential(refreshToken: "rt1", expiresAt: past), clock: clock)
                == .expired(refreshable: true))
        #expect(validity(of: makeCredential(refreshToken: nil, expiresAt: past), clock: clock)
                == .expired(refreshable: false))
    }

    @Test("validity: nil expiresAt -> valid(until: nil)")
    func validityNoExpiry() {
        #expect(validity(of: makeCredential(expiresAt: nil), clock: FixedClock()) == .valid(until: nil))
    }

    @Test("validity: nil credential -> none")
    func validityNone() {
        #expect(validity(of: nil, clock: FixedClock()) == .none)
    }

    @Test("InMemoryTokenStore round-trips save/load/delete/list")
    func inMemoryRoundTrip() throws {
        let store = InMemoryTokenStore()
        let credential = makeCredential()
        try store.save(credential, server: "https://mcp.example.com/mcp")
        #expect(try store.load(server: "https://mcp.example.com/mcp") == credential)
        #expect(try store.list() == ["https://mcp.example.com/mcp"])
        #expect(try store.delete(server: "https://mcp.example.com/mcp") == true)
        #expect(try store.load(server: "https://mcp.example.com/mcp") == nil)
        #expect(try store.delete(server: "https://mcp.example.com/mcp") == false)
    }

    @Test("KeychainTokenStore.save builds generic-password add query with service/account/data")
    func keychainSaveQuery() throws {
        let items = FakeKeychainItems()
        let store = KeychainTokenStore(items: items)
        try store.save(makeCredential(), server: "HTTPS://MCP.Example.com:443/mcp/")
        #expect(items.addQueries.count == 1)
        let q = items.addQueries[0]
        #expect(q[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(q[kSecAttrService as String] as? String == "com.arthur-ficial.apfel-run.oauth")
        #expect(q[kSecAttrAccount as String] as? String == "https://mcp.example.com/mcp")
        #expect(q[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
        // Tokens must never sync to iCloud
        #expect(q[kSecAttrSynchronizable as String] == nil)
        let data = q[kSecValueData as String] as? Data
        #expect(data != nil)
        let decoded = try KeychainTokenStore.decode(data ?? Data())
        #expect(decoded.accessToken == "at1")
    }

    @Test("save on errSecDuplicateItem falls through to update")
    func saveDuplicateUpdates() throws {
        let items = FakeKeychainItems()
        items.addStatus = errSecDuplicateItem
        let store = KeychainTokenStore(items: items)
        try store.save(makeCredential(), server: "https://mcp.example.com/mcp")
        #expect(items.updateQueries.count == 1)
        let (query, attributes) = items.updateQueries[0]
        #expect(query[kSecAttrAccount as String] as? String == "https://mcp.example.com/mcp")
        #expect(attributes[kSecValueData as String] is Data)
    }

    @Test("load maps errSecItemNotFound to nil, other status to thrown error")
    func loadStatusMapping() throws {
        let items = FakeKeychainItems()
        items.copyResult = (errSecItemNotFound, nil)
        let store = KeychainTokenStore(items: items)
        #expect(try store.load(server: "https://mcp.example.com/mcp") == nil)

        items.copyResult = (errSecAuthFailed, nil)
        #expect(throws: AuthError.keychainError(status: errSecAuthFailed)) {
            _ = try store.load(server: "https://mcp.example.com/mcp")
        }

        let credential = makeCredential()
        items.copyResult = (errSecSuccess, try KeychainTokenStore.encode(credential))
        #expect(try store.load(server: "https://mcp.example.com/mcp") == credential)
    }

    @Test("delete returns false on errSecItemNotFound")
    func deleteNotFound() throws {
        let items = FakeKeychainItems()
        items.deleteStatus = errSecItemNotFound
        let store = KeychainTokenStore(items: items)
        #expect(try store.delete(server: "https://mcp.example.com/mcp") == false)
        items.deleteStatus = errSecSuccess
        #expect(try store.delete(server: "https://mcp.example.com/mcp") == true)
    }

    @Test("StoredCredential JSON round-trip preserves dates to the second")
    func jsonRoundTrip() throws {
        let credential = makeCredential(expiresAt: Date(timeIntervalSince1970: 1_755_432_100))
        let data = try KeychainTokenStore.encode(credential)
        let decoded = try KeychainTokenStore.decode(data)
        #expect(decoded == credential)
        #expect(decoded.expiresAt == credential.expiresAt)
        #expect(decoded.obtainedAt == credential.obtainedAt)
    }
}
