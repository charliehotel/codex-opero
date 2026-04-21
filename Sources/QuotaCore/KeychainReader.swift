import Foundation
import Security

enum KeychainReader {
    static func genericPassword(service: String, account: String? = nil) throws -> Data {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw ProviderError.credentialsMissing
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ProviderError.other("keychain error \(status)")
        }
        return data
    }
}
