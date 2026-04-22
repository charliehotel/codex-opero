import Foundation

public struct GeminiProvider: UsageProvider {
    public let providerID: ProviderID = .gemini

    private let session: URLSession
    private let credentialsFileURL: URL
    private let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private let codeAssistBaseURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal")!

    public init(
        session: URLSession = .shared,
        credentialsFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
    ) {
        self.session = session
        self.credentialsFileURL = credentialsFileURL
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let credentials = try loadCredentials()
        let accessToken = try await validAccessToken(from: credentials)
        let projectID = try await loadProjectID(accessToken: accessToken)
        let quota = try await loadQuota(accessToken: accessToken, projectID: projectID)

        let primaryBucket = pickBucket(
            from: quota.buckets,
            preferredModelIDs: [
                "gemini-2.5-pro",
                "gemini-3.1-pro-preview",
                "gemini-3-pro-preview",
            ],
            fallbackTokenType: "REQUESTS"
        )
        let secondaryBucket = pickBucket(
            from: quota.buckets,
            preferredModelIDs: [
                "gemini-2.5-flash",
                "gemini-2.5-flash-lite",
                "gemini-3-flash-preview",
                "gemini-3.1-flash-lite-preview",
            ],
            fallbackTokenType: "REQUESTS"
        )

        guard let primaryBucket, let secondaryBucket else {
            throw ProviderError.unsupportedPayload
        }

        return ProviderQuota(
            providerID: providerID,
            primary: QuotaWindow(
                name: "Pro",
                usedPercent: usedPercent(from: primaryBucket),
                resetAt: primaryBucket.resetAt
            ),
            secondary: QuotaWindow(
                name: "Flash",
                usedPercent: usedPercent(from: secondaryBucket),
                resetAt: secondaryBucket.resetAt
            ),
            fetchedAt: Date()
        )
    }

    private func loadCredentials() throws -> GeminiCredentials {
        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else {
            throw ProviderError.credentialsMissing
        }
        let data = try Data(contentsOf: credentialsFileURL)
        return try JSONDecoder.geminiDecoder.decode(GeminiCredentials.self, from: data)
    }

    private func validAccessToken(from credentials: GeminiCredentials) async throws -> String {
        let now = Date()
        if credentials.expiryDate.timeIntervalSince(now) > 60 {
            return credentials.accessToken
        }
        return try await refreshAccessToken(using: credentials.refreshToken)
    }

    private func refreshAccessToken(using refreshToken: String) async throws -> String {
        let oauthConfig = try GeminiOAuthConfig.load()
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = URLQueryItemEncoder.encode([
            "client_id": oauthConfig.clientID,
            "client_secret": oauthConfig.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse
        }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode)
        }

        let token = try JSONDecoder().decode(GeminiRefreshResponse.self, from: data)
        return token.accessToken
    }

    private func loadProjectID(accessToken: String) async throws -> String {
        let requestURL = URL(string: "\(codeAssistBaseURL.absoluteString):loadCodeAssist")!
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(GeminiLoadRequest())

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse
        }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode)
        }

        let payload = try JSONDecoder().decode(GeminiLoadResponse.self, from: data)
        guard let projectID = payload.cloudAICompanionProject, projectID.isEmpty == false else {
            throw ProviderError.unsupportedPayload
        }
        return projectID
    }

    private func loadQuota(accessToken: String, projectID: String) async throws -> GeminiQuotaResponse {
        let requestURL = URL(string: "\(codeAssistBaseURL.absoluteString):retrieveUserQuota")!
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(GeminiQuotaRequest(project: projectID))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse
        }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode)
        }

        return try JSONDecoder.geminiDecoder.decode(GeminiQuotaResponse.self, from: data)
    }

    private func pickBucket(
        from buckets: [GeminiQuotaBucket],
        preferredModelIDs: [String],
        fallbackTokenType: String
    ) -> GeminiQuotaBucket? {
        for modelID in preferredModelIDs {
            if let bucket = buckets.first(where: { $0.modelID == modelID && $0.remainingFraction != nil }) {
                return bucket
            }
        }
        return buckets.first(where: { $0.tokenType == fallbackTokenType && $0.remainingFraction != nil })
    }

    private func usedPercent(from bucket: GeminiQuotaBucket) -> Int {
        guard let remainingFraction = bucket.remainingFraction else {
            return 0
        }
        let used = (1 - remainingFraction) * 100
        return max(0, min(100, Int(used.rounded())))
    }
}

private struct GeminiOAuthConfig {
    let clientID: String
    let clientSecret: String

    static func load() throws -> GeminiOAuthConfig {
        for candidate in candidateSourceURLs() {
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                continue
            }
            let source = try String(contentsOf: candidate, encoding: .utf8)
            if let config = parse(from: source) {
                return config
            }
        }
        throw ProviderError.credentialsMissing
    }

    private static func parse(from source: String) -> GeminiOAuthConfig? {
        guard
            let clientID = firstMatch(in: source, pattern: #"const OAUTH_CLIENT_ID = '([^']+)';"#),
            let clientSecret = firstMatch(in: source, pattern: #"const OAUTH_CLIENT_SECRET = '([^']+)';"#)
        else {
            return nil
        }
        return GeminiOAuthConfig(clientID: clientID, clientSecret: clientSecret)
    }

    private static func firstMatch(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard
            let match = regex.firstMatch(in: source, options: [], range: range),
            let valueRange = Range(match.range(at: 1), in: source)
        else {
            return nil
        }
        return String(source[valueRange])
    }

    private static func candidateSourceURLs() -> [URL] {
        var urls: [URL] = []

        if let geminiURL = geminiExecutableURL() {
            let root = geminiURL.deletingLastPathComponent().deletingLastPathComponent()
            urls.append(
                root
                    .appendingPathComponent("node_modules")
                    .appendingPathComponent("@google")
                    .appendingPathComponent("gemini-cli-core")
                    .appendingPathComponent("dist/src/code_assist/oauth2.js")
            )
        }

        urls.append(
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")
        )
        urls.append(
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")
        )

        return urls
    }

    private static func geminiExecutableURL() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "gemini"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                path.isEmpty == false
            else {
                return nil
            }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        } catch {
            return nil
        }
    }
}

private struct GeminiCredentials: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiryDateMilliseconds: Int64

    var expiryDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiryDateMilliseconds) / 1000)
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiryDateMilliseconds = "expiry_date"
    }
}

private struct GeminiRefreshResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct GeminiLoadRequest: Encodable {
    let metadata = Metadata()

    struct Metadata: Encodable {
        let ideType = "IDE_UNSPECIFIED"
        let platform = "PLATFORM_UNSPECIFIED"
        let pluginType = "GEMINI"
    }
}

private struct GeminiLoadResponse: Decodable {
    let cloudAICompanionProject: String?

    enum CodingKeys: String, CodingKey {
        case cloudAICompanionProject = "cloudaicompanionProject"
    }
}

private struct GeminiQuotaRequest: Encodable {
    let project: String
}

private struct GeminiQuotaResponse: Decodable {
    let buckets: [GeminiQuotaBucket]
}

private struct GeminiQuotaBucket: Decodable {
    let remainingFraction: Double?
    let resetAt: Date?
    let tokenType: String?
    let modelID: String?

    enum CodingKeys: String, CodingKey {
        case remainingFraction
        case resetAt = "resetTime"
        case tokenType
        case modelID = "modelId"
    }
}

private extension JSONDecoder {
    static let geminiDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private enum URLQueryItemEncoder {
    static func encode(_ values: [String: String]) -> String {
        values
            .map { key, value in
                let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .sorted()
            .joined(separator: "&")
    }
}
