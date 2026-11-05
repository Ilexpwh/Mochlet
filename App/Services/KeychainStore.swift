import Foundation
import Security

/// API keys in the login keychain under one service name. Values are cached in memory so the
/// keychain is asked once per launch; a denied keychain falls back to a 0600 file so the app
/// still works with an ad-hoc signed debug build.
enum KeychainStore {
    static let service = "com.ilexpwh.Mochlet"
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    private static var fallbackURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mochlet/secrets.json")
    }

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[account] { return cached }
        var value: String?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { value = String(data: data, encoding: .utf8) }
        if value == nil, status != errSecItemNotFound { value = fallback()[account] }
        if value == nil { value = fallback()[account] }
        cache[account] = value
        return value
    }

    static func set(_ value: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        cache[account] = value
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Mochlet \(account)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("keychain set failed (\(status)); using the secrets file")
            var f = fallback()
            f[account] = value
            writeFallback(f)
        } else {
            var f = fallback()
            if f[account] != nil { f[account] = nil; writeFallback(f) }
        }
    }

    static func delete(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        cache[account] = .some(nil)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var f = fallback()
        if f[account] != nil { f[account] = nil; writeFallback(f) }
    }

    static func has(_ account: String) -> Bool { !(get(account) ?? "").isEmpty }

    /// Whether an item exists, without reading it: attributes only, so no access prompt even for an
    /// item another build of the app created.
    static func exists(_ account: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    private static func fallback() -> [String: String] {
        guard let data = try? Data(contentsOf: fallbackURL), let d = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return d
    }

    private static func writeFallback(_ d: [String: String]) {
        let dir = fallbackURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if d.isEmpty { try? FileManager.default.removeItem(at: fallbackURL); return }
        if let data = try? JSONEncoder().encode(d) {
            try? data.write(to: fallbackURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackURL.path)
        }
    }
}
