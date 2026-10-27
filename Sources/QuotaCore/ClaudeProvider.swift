import Foundation

public struct ClaudeProvider: UsageProvider {
    public let providerID: ProviderID = .claude

    private let session: URLSession
    private let credentialsFileURL: URL
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init(
        session: URLSession = .shared,
        credentialsFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    ) {
        self.session = session
        self.credentialsFileURL = credentialsFileURL
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let token = try loadOAuthToken()
        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse
        }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode)
        }

        let payload = try JSONDecoder.claudeDecoder.decode(ClaudeUsagePayload.self, from: data)
        guard let fiveHour = payload.fiveHour, let sevenDay = payload.sevenDay else {
            throw ProviderError.unsupportedPayload
        }

        return ProviderQuota(
            providerID: providerID,
            primary: QuotaWindow(
                name: "5h",
                usedPercent: Int(fiveHour.utilization.rounded()),
                resetAt: fiveHour.resetsAt
            ),
            secondary: QuotaWindow(
                name: "7d",
                usedPercent: Int(sevenDay.utilization.rounded()),
                resetAt: sevenDay.resetsAt
            ),
            fetchedAt: Date()
        )
    }

    private func loadOAuthToken() throws -> String {
        if let token = try loadTokenFromKeychain(), token.isEmpty == false {
            return token
        }
        if let token = try loadTokenFromCredentialsFile(), token.isEmpty == false {
            return token
        }
        throw ProviderError.credentialsMissing
    }

    private func loadTokenFromKeychain() throws -> String? {
        do {
            let data = try KeychainReader.genericPassword(service: "Claude Code-credentials")
            let payload = try JSONDecoder().decode(ClaudeCredentialsPayload.self, from: data)
            return payload.claudeAiOauth.accessToken
        } catch ProviderError.credentialsMissing {
            return nil
        }
    }

    private func loadTokenFromCredentialsFile() throws -> String? {
        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: credentialsFileURL)
        let payload = try JSONDecoder().decode(ClaudeCredentialsPayload.self, from: data)
        return payload.claudeAiOauth.accessToken
    }
}

private struct ClaudeCredentialsPayload: Decodable {
    let claudeAiOauth: OAuth

    struct OAuth: Decodable {
        let accessToken: String
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

private extension JSONDecoder {
    static let claudeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
