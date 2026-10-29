import Foundation
import Security

enum KeychainReader {
    struct Password: Sendable {
        let data: Data
        let persistentReference: Data
    }

    static func genericPassword(service: String, account: String? = nil) throws -> Data {
        try genericPasswordItem(service: service, account: account).data
    }

    static func genericPasswordItem(service: String, account: String? = nil) throws -> Password {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw ProviderError.credentialsMissing }
        guard status == errSecSuccess, let result = item as? [CFString: Any],
              let data = result[kSecValueData] as? Data,
              let reference = result[kSecValuePersistentRef] as? Data else {
            throw ProviderError.other("keychain error \(status)")
        }
        return Password(data: data, persistentReference: reference)
    }

    static func updateGenericPassword(_ expected: Password, data: Data) throws -> Bool {
        let query: [CFString: Any] = [kSecValuePersistentRef: expected.persistentReference]
        var readQuery = query
        readQuery[kSecReturnData] = true
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &item)
        if readStatus == errSecItemNotFound { return false }
        guard readStatus == errSecSuccess, let current = item as? Data else {
            throw ProviderError.other("keychain error \(readStatus)")
        }
        guard current == expected.data else { return false }
        // Update only the data on the exact existing item to retain its ACL and Always Allow grants.
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw ProviderError.other("keychain error \(status)") }
        return true
    }
}
