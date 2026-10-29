import Foundation

public struct ClaudeProvider: UsageProvider {
    public let providerID: ProviderID = .claude

    private let session: URLSession
    private let store: ClaudeCredentialStore
    private let now: @Sendable () -> Date
    private let coordinator: ClaudeRequestCoordinator

    public init(
        session: URLSession = .shared,
        credentialsFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    ) {
        self.init(
            session: session, credentialsFileURL: credentialsFileURL,
            readKeychain: { try KeychainReader.genericPasswordItem(service: "Claude Code-credentials") },
            updateKeychain: { try KeychainReader.updateGenericPassword($0, data: $1) },
            now: { Date() }, coordinator: .shared
        )
    }

    internal init(
        session: URLSession,
        credentialsFileURL: URL,
        readKeychain: @escaping @Sendable () throws -> KeychainReader.Password,
        updateKeychain: @escaping @Sendable (KeychainReader.Password, Data) throws -> Bool,
        now: @escaping @Sendable () -> Date,
        coordinator: ClaudeRequestCoordinator = ClaudeRequestCoordinator()
    ) {
        self.session = session
        self.store = ClaudeCredentialStore(fileURL: credentialsFileURL, readKeychain: readKeychain, updateKeychain: updateKeychain)
        self.now = now
        self.coordinator = coordinator
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let credentials = try store.load()
        return try await coordinator.fetch(key: credentials.key) {
            try await fetchUsage()
        }
    }

    private func fetchUsage() async throws -> ProviderQuota {
        var credentials = try store.load()
        var refreshed = false
        // Bound retries even if the CLI repeatedly changes accounts during a request.
        for _ in 0..<3 {
            if !refreshed, let expiry = credentials.oauth.expiresAt,
               expiry <= now().addingTimeInterval(60).timeIntervalSince1970 * 1000 {
                refreshed = true
                credentials = try await refresh(credentials)
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(credentials.oauth.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, http) = try await send(request)
            let current = try store.load()
            if !current.matches(credentials) {
                credentials = current
                continue
            }
            if http.statusCode == 401 {
                guard !refreshed else { throw Self.loginRequired }
                refreshed = true
                credentials = try await refresh(credentials)
                continue
            }
            if http.statusCode == 403 { throw Self.loginRequired }
            guard http.statusCode == 200 else { throw ProviderError.http(http.statusCode) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let payload = try? decoder.decode(ClaudeUsagePayload.self, from: data),
                  let fiveHour = payload.fiveHour, let sevenDay = payload.sevenDay,
                  let primaryUsed = Int(exactly: fiveHour.utilization.rounded()),
                  let secondaryUsed = Int(exactly: sevenDay.utilization.rounded()) else {
                throw ProviderError.unsupportedPayload
            }
            return ProviderQuota(
                providerID: providerID,
                primary: QuotaWindow(name: "5h", usedPercent: primaryUsed, resetAt: fiveHour.resetsAt),
                secondary: QuotaWindow(name: "7d", usedPercent: secondaryUsed, resetAt: sevenDay.resetsAt),
                fetchedAt: now()
            )
        }
        throw ProviderError.other("Claude 인증정보가 변경되었습니다. 다시 조회해 주세요.")
    }

    private func refresh(_ original: ClaudeCredentialStore.Credentials) async throws -> ClaudeCredentialStore.Credentials {
        let current = try store.load()
        guard current.matches(original) else { return current }
        guard let refreshToken = current.oauth.refreshToken, !refreshToken.isEmpty else { throw Self.loginRequired }
        // Public production client contract extracted from the installed Claude Code 2.1.312 bundle.
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let scopes = current.oauth.scopes.flatMap { $0.isEmpty ? nil : $0 }
            ?? ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload", "user:plugins"]
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "scope": scopes.joined(separator: " "),
        ])
        let (data, http) = try await send(request)
        let latest = try store.load()
        guard latest.matches(current) else { return latest }
        if [400, 401, 403].contains(http.statusCode) { throw Self.loginRequired }
        guard http.statusCode == 200 else { throw ProviderError.http(http.statusCode) }
        guard let token = try? JSONDecoder().decode(ClaudeRefreshPayload.self, from: data),
              !token.accessToken.isEmpty, token.expiresIn.isFinite, token.expiresIn > 0,
              token.refreshToken?.isEmpty != true else { throw ProviderError.unsupportedPayload }
        try store.save(token, replacing: latest, now: now())
        return try store.load()
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await coordinator.checkCooldown(now: now())
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.other("Claude 서버에 연결할 수 없습니다. 다시 시도해 주세요.")
        }
        guard let http = result.1 as? HTTPURLResponse else { throw ProviderError.badResponse }
        try await coordinator.record(http, now: now())
        return (result.0, http)
    }

    fileprivate static let loginRequired = ProviderError.other("Claude 인증이 만료되었거나 유효하지 않습니다. Claude Code에서 다시 로그인해 주세요 (claude auth login).")
}

internal actor ClaudeRequestCoordinator {
    static let shared = ClaudeRequestCoordinator()
    private var inFlight: [String: Task<ProviderQuota, Error>] = [:]
    private var retryAt: Date?
    private var rateLimitCount = 0

    func fetch(key: String, operation: @escaping @Sendable () async throws -> ProviderQuota) async throws -> ProviderQuota {
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    func checkCooldown(now: Date) throws {
        if let retryAt, now < retryAt { throw rateLimitError(retryAt) }
    }

    private func rateLimitError(_ deadline: Date) -> ProviderError {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return .other("Claude rate limited; retry after \(formatter.string(from: deadline))")
    }

    func record(_ response: HTTPURLResponse, now: Date) throws {
        guard response.statusCode == 429 else {
            if response.statusCode == 200 { rateLimitCount = 0 }
            return
        }
        rateLimitCount = min(rateLimitCount + 1, 5)
        let fallback = now.addingTimeInterval(min(300, 30 * pow(2, Double(rateLimitCount - 1))))
        var deadline = fallback
        if let header = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 {
                deadline = now.addingTimeInterval(seconds)
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: header) { deadline = max(now, date) }
            }
        }
        let effectiveDeadline = max(retryAt ?? deadline, deadline, now.addingTimeInterval(1))
        retryAt = effectiveDeadline
        throw rateLimitError(effectiveDeadline)
    }
}

private struct ClaudeCredentialStore: Sendable {
    let fileURL: URL
    let readKeychain: @Sendable () throws -> KeychainReader.Password
    let updateKeychain: @Sendable (KeychainReader.Password, Data) throws -> Bool

    struct OAuth: Decodable, Equatable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double?
        let scopes: [String]?
    }

    struct Credentials: Sendable {
        let data: Data
        let oauth: OAuth
        let keychain: KeychainReader.Password?
        let key: String

        func matches(_ other: Self) -> Bool { key == other.key && oauth == other.oauth }
    }

    func load() throws -> Credentials {
        do {
            let item = try readKeychain()
            if let credentials = try decode(item.data, keychain: item) { return credentials }
        } catch ProviderError.credentialsMissing {
            // Claude Code can use a credentials file when the keychain item does not exist.
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw ClaudeProvider.loginRequired }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw ProviderError.other("Claude 인증정보 파일을 읽을 수 없습니다.")
        }
        guard let credentials = try decode(data, keychain: nil) else { throw ClaudeProvider.loginRequired }
        return credentials
    }

    private func decode(_ data: Data, keychain: KeychainReader.Password?) throws -> Credentials? {
        let json = try Self.json(data)
        guard let value = json["claudeAiOauth"] else { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let oauth = try? JSONDecoder().decode(OAuth.self, from: JSONSerialization.data(withJSONObject: value)) else {
            throw ClaudeProvider.loginRequired
        }
        guard !oauth.accessToken.isEmpty else { return nil }
        return Credentials(data: data, oauth: oauth, keychain: keychain,
                           key: keychain.map { "keychain:" + $0.persistentReference.base64EncodedString() } ?? fileURL.standardizedFileURL.path)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ClaudeProvider.loginRequired }
        return json
    }

    func save(_ token: ClaudeRefreshPayload, replacing expected: Credentials, now: Date) throws {
        let failure = ProviderError.other("갱신한 Claude 인증정보를 저장하지 못했습니다. Claude Code에서 다시 로그인해 주세요.")
        // A metadata-only concurrent edit can be merged once without refreshing the token again.
        for _ in 0..<2 {
            let current = try load()
            guard current.matches(expected) else { return }
            var json = try Self.json(current.data)
            guard var oauth = json["claudeAiOauth"] as? [String: Any] else { throw ClaudeProvider.loginRequired }
            oauth["accessToken"] = token.accessToken
            oauth["expiresAt"] = now.addingTimeInterval(token.expiresIn).timeIntervalSince1970 * 1000
            if let refreshToken = token.refreshToken { oauth["refreshToken"] = refreshToken }
            if let scope = token.scope { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
            json["claudeAiOauth"] = oauth
            do {
                let data = try JSONSerialization.data(withJSONObject: json)
                if let keychain = current.keychain {
                    if try updateKeychain(keychain, data) { return }
                } else {
                    let latest = try load()
                    guard latest.matches(current), latest.data == current.data else { continue }
                    try data.write(to: fileURL, options: .atomic)
                    return
                }
            } catch {
                throw failure
            }
        }
        throw failure
    }
}

private struct ClaudeRefreshPayload: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope
    }
}

private struct ClaudeUsagePayload: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?

    struct Window: Decodable {
        let utilization: Double
        let resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}
