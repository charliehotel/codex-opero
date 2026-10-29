import CryptoKit
import Foundation
import Security
import SQLite3

struct AgyOAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?

}

struct AgyCloudCredentials: Codable, Sendable {
    var token: AgyOAuthToken
    var oauthClient: AgyOAuthClient?
    let sourceFingerprint: String

    init(token: AgyOAuthToken) {
        self.token = token
        sourceFingerprint = SHA256.hash(data: Data((token.refreshToken ?? token.accessToken).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func mergingRefreshed(_ cached: Self) -> Self {
        guard cached.sourceFingerprint == sourceFingerprint else { return self }
        var result = cached
        // A newer source access token must not discard a rotated refresh token.
        if (token.expiresAt ?? .distantPast) > (cached.token.expiresAt ?? .distantPast) {
            result.token.accessToken = token.accessToken
            result.token.expiresAt = token.expiresAt
        }
        result.token.refreshToken = cached.token.refreshToken ?? token.refreshToken
        return result
    }
}

enum AgyCredentialStore {
    private static let cacheService = "codex-opero.AntigravityOAuth"

    static func load() throws -> AgyCloudCredentials {
        let source: AgyOAuthToken
        do {
            let data = try KeychainReader.genericPassword(service: "gemini", account: "antigravity")
            source = try decodeKeychain(data)
        } catch ProviderError.credentialsMissing {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            let tokens = ["Antigravity IDE", "Antigravity"].compactMap { name in
                try? readDatabase(root.appendingPathComponent("\(name)/User/globalStorage/state.vscdb"))
            }
            guard let newest = tokens.max(by: {
                ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast)
            }) else { throw ProviderError.credentialsMissing }
            source = newest
        }

        let credentials = AgyCloudCredentials(token: source)
        // Keep refreshed tokens separate; Antigravity owns its SQLite and CLI credentials.
        do {
            let data = try KeychainReader.genericPassword(service: cacheService)
            let cached = try JSONDecoder().decode(AgyCloudCredentials.self, from: data)
            return credentials.mergingRefreshed(cached)
        } catch ProviderError.credentialsMissing {
            return credentials
        }
    }

    static func save(_ credentials: AgyCloudCredentials) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: cacheService,
        ]
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrAccount] = "antigravity"
            item[kSecValueData] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ProviderError.other("Could not save Antigravity token (keychain \(status))")
        }
    }

    static func decodeKeychain(_ data: Data) throws -> AgyOAuthToken {
        var json = data
        let prefix = "go-keyring-base64:"
        if let text = String(data: data, encoding: .utf8), text.hasPrefix(prefix) {
            guard let decoded = Data(base64Encoded: String(text.dropFirst(prefix.count))) else {
                throw ProviderError.unsupportedPayload
            }
            json = decoded
        }
        guard let payload = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ProviderError.unsupportedPayload
        }
        let token = (payload["token"] as? [String: Any]) ?? payload
        guard let access = token["access_token"] as? String, !access.isEmpty else {
            throw ProviderError.unsupportedPayload
        }
        let expiry = (token["expiry"] as? String).flatMap(parseDate)
        return AgyOAuthToken(accessToken: access, refreshToken: token["refresh_token"] as? String, expiresAt: expiry)
    }

    static func readDatabase(_ url: URL) throws -> AgyOAuthToken {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw ProviderError.credentialsMissing
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT key, value FROM ItemTable WHERE key IN ('antigravityUnifiedStateSync.oauthToken', 'jetskiStateSync.agentManagerInitState')"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.credentialsMissing
        }
        defer { sqlite3_finalize(statement) }
        var legacy: AgyOAuthToken?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0),
                  let value = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: key)
            if let token = try? decodeDatabaseValue(String(cString: value), unified: name.hasPrefix("antigravityUnified")) {
                if name.hasPrefix("antigravityUnified") { return token }
                legacy = token
            }
        }
        guard let legacy else { throw ProviderError.credentialsMissing }
        return legacy
    }

    static func decodeDatabaseValue(_ value: String, unified: Bool) throws -> AgyOAuthToken {
        guard let data = Data(base64Encoded: value), data.count <= 65_536 else {
            throw ProviderError.unsupportedPayload
        }
        let outer = try AgyProto.fields(data)
        let tokenData: Data
        if unified {
            let entries = try outer.compactMap { field -> [AgyProto.Field]? in
                guard field.number == 1, let bytes = field.bytes else { return nil }
                return try AgyProto.fields(bytes)
            }
            guard let entry = entries.first(where: {
                $0.contains { $0.number == 1 && $0.bytes == Data("oauthTokenInfoSentinelKey".utf8) }
            }), let envelope = entry.first(where: { $0.number == 2 })?.bytes,
               let encoded = try AgyProto.fields(envelope).first(where: { $0.number == 1 })?.bytes,
               let inner = Data(base64Encoded: encoded) else {
                throw ProviderError.unsupportedPayload
            }
            tokenData = inner
        } else {
            guard let inner = outer.first(where: { $0.number == 6 })?.bytes else {
                throw ProviderError.unsupportedPayload
            }
            tokenData = inner
        }
        let fields = try AgyProto.fields(tokenData)
        guard let access = fields.first(where: { $0.number == 1 })?.bytes,
              let accessToken = String(data: access, encoding: .utf8), !accessToken.isEmpty else {
            throw ProviderError.unsupportedPayload
        }
        let refresh = fields.first(where: { $0.number == 3 })?.bytes.flatMap { String(data: $0, encoding: .utf8) }
        let expiry = try fields.first(where: { $0.number == 4 })?.bytes.flatMap { data in
            try AgyProto.fields(data).first(where: { $0.number == 1 })?.integer
        }
        return AgyOAuthToken(accessToken: accessToken, refreshToken: refresh,
                             expiresAt: expiry.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

// The state database uses a small protobuf envelope; reject truncated or oversized fields.
private enum AgyProto {
    struct Field {
        let number: UInt64
        var bytes: Data?
        var integer: UInt64?
    }

    static func fields(_ data: Data) throws -> [Field] {
        let bytes = Array(data)
        var index = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw ProviderError.unsupportedPayload }
                let byte = bytes[index]
                index += 1
                guard shift < 63 || byte <= 1 else { throw ProviderError.unsupportedPayload }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            throw ProviderError.unsupportedPayload
        }
        var result: [Field] = []
        while index < bytes.count {
            let tag = try varint()
            guard tag >> 3 > 0 else { throw ProviderError.unsupportedPayload }
            switch tag & 7 {
            case 0:
                result.append(Field(number: tag >> 3, integer: try varint()))
            case 1, 2, 5:
                let length = tag & 7 == 2 ? try varint() : (tag & 7 == 1 ? 8 : 4)
                guard length <= bytes.count - index else { throw ProviderError.unsupportedPayload }
                let end = index + Int(length)
                result.append(Field(number: tag >> 3, bytes: Data(bytes[index..<end])))
                index = end
            default:
                throw ProviderError.unsupportedPayload
            }
        }
        return result
    }
}
