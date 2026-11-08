import Foundation
import Security

/// Where the access and refresh tokens live. The protocol lets tests use memory instead of the Keychain.
protocol TokenStore: AnyObject {
    var tokens: AuthTokens? { get }
    func save(_ tokens: AuthTokens)
    func clear()
}

final class KeychainTokenStore: TokenStore {
    private let service = "tech.rmillerqa.expensetracker.tokens"
    private let account = "session"
    private var cached: AuthTokens?
    private var loaded = false

    var tokens: AuthTokens? {
        if !loaded {
            cached = read()
            loaded = true
        }
        return cached
    }

    func save(_ tokens: AuthTokens) {
        cached = tokens
        loaded = true
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query = baseQuery()
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func clear() {
        cached = nil
        loaded = true
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func read() -> AuthTokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class InMemoryTokenStore: TokenStore {
    var tokens: AuthTokens?
    init(_ tokens: AuthTokens? = nil) { self.tokens = tokens }
    func save(_ tokens: AuthTokens) { self.tokens = tokens }
    func clear() { tokens = nil }
}
