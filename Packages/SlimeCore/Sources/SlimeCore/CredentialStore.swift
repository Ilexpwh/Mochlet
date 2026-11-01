import Foundation
import Security

public actor CredentialStore {
    private let service = "com.ilexpwh.Mochlet"
    public init() {}
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func read(_ account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MochletError.message("Keychain could not read this credential (\(status)).") }
        return result as? Data
    }
    public func save(_ data: Data, account: String) throws {
        let q = query(account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insert = SecItemAdd(item as CFDictionary, nil)
            guard insert == errSecSuccess else { throw MochletError.message("Keychain could not save this credential (\(insert)).") }
        } else if status != errSecSuccess { throw MochletError.message("Keychain could not update this credential (\(status)).") }
    }
    public func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MochletError.message("Keychain could not remove this credential (\(status)).") }
    }
}
