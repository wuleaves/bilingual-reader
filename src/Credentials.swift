import Foundation
import Security

enum Credentials {
    static let service = "local.bilingualreader.api"
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func load(_ account: String) throws -> String {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw failure(status) }
        return key
    }
    static func save(_ key: String, account: String) throws {
        let q = query(account)
        if key.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }; return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    static func failure(_ status: OSStatus) -> TranslationError {
        TranslationError(message: "无法访问钥匙串（\(status)）。密钥仍可用于本次运行；请允许钥匙串访问后重新保存。")
    }
}
func sameContent(_ a: String, _ b: String) -> Bool {
    a.filter { !$0.isWhitespace } == b.filter { !$0.isWhitespace }
}
