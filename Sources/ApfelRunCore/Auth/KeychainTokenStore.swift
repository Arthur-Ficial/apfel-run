import Foundation
import Security

/// SecItem seam under KeychainTokenStore, so query construction is
/// unit-testable without touching the real keychain.
public protocol KeychainItems: Sendable {
    func add(_ query: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    /// All account strings matching the query (for `list()`).
    func copyAllAccounts(_ query: [String: Any]) -> (OSStatus, [String])
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// Keychain-backed TokenStoring: generic passwords under a fixed service,
/// account = normalized server URL, value = ISO8601-dated JSON credential.
/// `kSecAttrAccessibleWhenUnlocked`, never `kSecAttrSynchronizable`
/// (no iCloud sync of tokens).
public struct KeychainTokenStore: TokenStoring {
    public static let service = "com.arthur-ficial.apfel-run.oauth"

    public let items: KeychainItems

    public init(items: KeychainItems) {
        self.items = items
    }

    // MARK: - TokenStoring

    public func load(server: String) throws -> StoredCredential? {
        var query = baseQuery(server: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne as String
        let (status, data) = items.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data else { throw AuthError.keychainError(status: status) }
            return try Self.decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychainError(status: status)
        }
    }

    public func save(_ credential: StoredCredential, server: String) throws {
        let data = try Self.encode(credential)
        var addQuery = baseQuery(server: server)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked as String
        let status = items.add(addQuery)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = items.update(baseQuery(server: server),
                                            attributes: [kSecValueData as String: data])
            guard updateStatus == errSecSuccess else {
                throw AuthError.keychainError(status: updateStatus)
            }
        default:
            throw AuthError.keychainError(status: status)
        }
    }

    @discardableResult
    public func delete(server: String) throws -> Bool {
        let status = items.delete(baseQuery(server: server))
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw AuthError.keychainError(status: status)
        }
    }

    public func list() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: Self.service,
        ]
        query[kSecMatchLimit as String] = kSecMatchLimitAll as String
        let (status, accounts) = items.copyAllAccounts(query)
        switch status {
        case errSecSuccess:
            return accounts.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw AuthError.keychainError(status: status)
        }
    }

    // MARK: - JSON codec (ISO8601 dates, second precision)

    public static func encode(_ credential: StoredCredential) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(credential)
    }

    public static func decode(_ data: Data) throws -> StoredCredential {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredCredential.self, from: data)
    }

    // MARK: - Internals

    func baseQuery(server: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: normalizeServerKey(server),
        ]
    }
}

/// Thin real SecItem implementation. Not exercised by unit tests
/// (FakeKeychainItems covers the store logic); the smoke script and the
/// subprocess integration tests hit this for the errSecItemNotFound path.
public struct SecItemKeychain: KeychainItems {
    public init() {}

    public func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    public func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func copyAllAccounts(_ query: [String: Any]) -> (OSStatus, [String]) {
        var query = query
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, []) }
        let dicts = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        let accounts = dicts.compactMap { $0[kSecAttrAccount as String] as? String }
        return (status, accounts)
    }

    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
