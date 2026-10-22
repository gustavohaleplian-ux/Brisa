import Foundation
import Security

/// Stores the ThinQ Personal Access Token in the macOS Keychain, only on this Mac
/// and only while it is unlocked. The token never goes to UserDefaults or disk.
enum TokenVault {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        // Follows the app's identifier, e.g. "com.surtocriativo.Brisa.thinq".
        kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Brisa") + ".thinq",
        kSecAttrAccount as String: "personal-access-token"
    ]
    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary,
                                  [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw BrisaError(message: "Não foi possível salvar a chave no Chaves do macOS (\(status)).")
        }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BrisaError(message: "Não foi possível remover a chave (\(status)).")
        }
    }
}
