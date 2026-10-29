import Foundation

actor AgyCloudClient {
    static let shared = AgyCloudClient()
    private let session: URLSession
    private let loadCredentials: @Sendable () throws -> AgyCloudCredentials
    private let saveCredentials: @Sendable (AgyCloudCredentials) throws -> Void
    private let now: @Sendable () -> Date
    private var cachedCredentials: AgyCloudCredentials?
    private var project: (fingerprint: String, id: String)?
    private var retryAt: Date?
    private var inFlight: Task<Data, Error>?

    private let oauthClients: @Sendable () throws -> [AgyOAuthClient]
    private let baseURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:"

    init(
        session: URLSession = .shared,
        loadCredentials: @escaping @Sendable () throws -> AgyCloudCredentials = AgyCredentialStore.load,
        saveCredentials: @escaping @Sendable (AgyCloudCredentials) throws -> Void = AgyCredentialStore.save,
        now: @escaping @Sendable () -> Date = { Date() },
        oauthClients: @escaping @Sendable () throws -> [AgyOAuthClient] = AgyOAuthClient.installedCandidates
    ) {
        self.session = session
        self.loadCredentials = loadCredentials
        self.saveCredentials = saveCredentials
        self.now = now
        self.oauthClients = oauthClients
    }

    func fetchSummary() async throws -> Data {
        if let inFlight { return try await inFlight.value }
        if let retryAt, retryAt > now() { throw rateLimitError(retryAt) }
        let task = Task { try await fetchAuthorizedSummary() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func fetchAuthorizedSummary() async throws -> Data {
        var credentials: AgyCloudCredentials
        do {
            credentials = try loadCredentials()
        } catch ProviderError.credentialsMissing {
            throw ProviderError.other("Sign in to Antigravity or agy once to read quota")
        }
        if let cachedCredentials {
            credentials = credentials.mergingRefreshed(cachedCredentials)
        }
        var refreshed = false
        if credentials.token.expiresAt.map({ $0 <= now().addingTimeInterval(60) }) == true {
            credentials = try await refresh(credentials)
            refreshed = true
        }
        let data: Data
        do {
            data = try await quotaSummary(credentials)
        } catch ProviderError.http(401) {
            guard !refreshed else { throw signInError }
            credentials = try await refresh(credentials)
            do { data = try await quotaSummary(credentials) }
            catch ProviderError.http(401) { throw signInError }
        }
        guard try loadCredentials().sourceFingerprint == credentials.sourceFingerprint else {
            project = nil
            cachedCredentials = nil
            throw ProviderError.other("Antigravity account changed; refresh again")
        }
        return data
    }

    private func refresh(_ credentials: AgyCloudCredentials) async throws -> AgyCloudCredentials {
        guard let refreshToken = credentials.token.refreshToken, !refreshToken.isEmpty else {
            throw signInError
        }
        let clients = try credentials.oauthClient.map { [$0] } ?? oauthClients()
        var result: (Data, AgyOAuthClient)?
        for client in clients {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "client_id", value: client.clientID),
                URLQueryItem(name: "client_secret", value: client.clientSecret),
                URLQueryItem(name: "refresh_token", value: refreshToken),
            ]
            request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            do {
                result = (try await send(request), client)
                break
            } catch ProviderError.http(let code) where code == 400 || code == 401 {
                continue
            }
        }
        guard let (data, client) = result else { throw signInError }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = payload["access_token"] as? String, !access.isEmpty,
              let lifetime = payload["expires_in"] as? Double, lifetime > 0, lifetime.isFinite else {
            throw ProviderError.unsupportedPayload
        }
        var updated = credentials
        updated.oauthClient = client
        updated.token = AgyOAuthToken(
            accessToken: access,
            refreshToken: (payload["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken,
            expiresAt: now().addingTimeInterval(lifetime)
        )
        // Never write refreshed credentials over a concurrent account switch.
        guard try loadCredentials().sourceFingerprint == credentials.sourceFingerprint else {
            cachedCredentials = nil
            project = nil
            throw ProviderError.other("Antigravity account changed; refresh again")
        }
        try saveCredentials(updated)
        cachedCredentials = updated
        return updated
    }

    private func quotaSummary(_ credentials: AgyCloudCredentials) async throws -> Data {
        let projectID: String
        if let project, project.fingerprint == credentials.sourceFingerprint {
            projectID = project.id
        } else {
            let data = try await call("loadCodeAssist", body: ["metadata": ["ideType": "ANTIGRAVITY"]], token: credentials.token.accessToken)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderError.unsupportedPayload
            }
            let project = (payload["cloudaicompanionProject"] as? String)
                ?? (payload["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
            guard let project, !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderError.other("Antigravity account project is unavailable")
            }
            projectID = project
            self.project = (credentials.sourceFingerprint, project)
        }
        // A projectless request can return misleading full quota for the wrong pool.
        return try await call("retrieveUserQuotaSummary", body: ["project": projectID], token: credentials.token.accessToken)
    }

    private func call(_ method: String, body: [String: Any], token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + method)!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Google omits the Gemini quota group for an unversioned user agent.
        request.setValue("antigravity/2.28.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        if http.statusCode == 429 {
            let value = http.value(forHTTPHeaderField: "Retry-After")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let date = value.flatMap { Double($0) }.flatMap { $0.isFinite ? now().addingTimeInterval(max(60, $0)) : nil }
                ?? value.flatMap { formatter.date(from: $0) }
                ?? now().addingTimeInterval(300)
            retryAt = max(date, now().addingTimeInterval(60))
            throw rateLimitError(retryAt!)
        }
        guard http.statusCode == 200 else { throw ProviderError.http(http.statusCode) }
        return data
    }

    private var signInError: ProviderError {
        .other("Antigravity login expired; sign in to Antigravity or agy again")
    }

    private func rateLimitError(_ date: Date) -> ProviderError {
        .other("Antigravity rate limited; retry after \(date.formatted(date: .omitted, time: .shortened))")
    }
}
