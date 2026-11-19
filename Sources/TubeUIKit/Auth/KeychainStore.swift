import Foundation
import Security

enum KeychainStore {
    static let service = "app.tubeui.mac"

    static func set(_ data: Data, account: String) throws {
        let query = base(account: account)
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    static func get(account: String) -> Data? {
        var query = base(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    static func get<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = get(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func delete(account: String) {
        SecItemDelete(base(account: account) as CFDictionary)
    }

    private static func base(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        "The Keychain returned \(status)."
    }
}
