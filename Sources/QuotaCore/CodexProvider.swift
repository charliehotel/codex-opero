import Foundation

public struct CodexProvider: UsageProvider {
    public let providerID: ProviderID = .codex

    private let session: URLSession
    private let authFileURL: URL
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(
        session: URLSession = .shared,
        authFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    ) {
        self.session = session
        self.authFileURL = authFileURL
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let auth = try loadAuth()
        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse
        }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode)
        }

        let payload = try JSONDecoder.codexDecoder.decode(CodexUsagePayload.self, from: data)
        
        let rateLimit = payload.rateLimit
        var fiveHourWindow = QuotaWindow(name: "5h", usedPercent: nil, resetAt: nil)
        var sevenDayWindow = QuotaWindow(name: "7d", usedPercent: nil, resetAt: nil)
        
        func makeQuotaWindow(from window: CodexUsagePayload.Window, defaultName: String) -> QuotaWindow {
            let name: String
            if let seconds = window.limitWindowSeconds {
                if seconds == 18000 {
                    name = "5h"
                } else if seconds == 604800 {
                    name = "7d"
                } else {
                    let hours = seconds / 3600
                    if hours >= 24 {
                        name = "\(hours / 24)d"
                    } else {
                        name = "\(hours)h"
                    }
                }
            } else {
                name = defaultName
            }
            return QuotaWindow(
                name: name,
                usedPercent: window.usedPercent,
                resetAt: Date(timeIntervalSince1970: TimeInterval(window.resetAt))
            )
        }
        
        if let primary = rateLimit.primaryWindow, let secondary = rateLimit.secondaryWindow {
            fiveHourWindow = makeQuotaWindow(from: primary, defaultName: "5h")
            sevenDayWindow = makeQuotaWindow(from: secondary, defaultName: "7d")
        } else if let primary = rateLimit.primaryWindow {
            let qw = makeQuotaWindow(from: primary, defaultName: "5h")
            if qw.name == "7d" {
                sevenDayWindow = qw
            } else {
                fiveHourWindow = qw
            }
        } else if let secondary = rateLimit.secondaryWindow {
            let qw = makeQuotaWindow(from: secondary, defaultName: "7d")
            if qw.name == "5h" {
                fiveHourWindow = qw
            } else {
                sevenDayWindow = qw
            }
        }
        
        return ProviderQuota(
            providerID: providerID,
            primary: fiveHourWindow,
            secondary: sevenDayWindow,
            fetchedAt: Date()
        )
    }

    private func loadAuth() throws -> CodexAuthPayload {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw ProviderError.credentialsMissing
        }
        let data = try Data(contentsOf: authFileURL)
        return try JSONDecoder().decode(CodexAuthPayload.self, from: data)
    }
}

private struct CodexAuthPayload: Decodable {
    let tokens: Tokens

    struct Tokens: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
}

private struct CodexUsagePayload: Decodable {
    let rateLimit: RateLimit

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Int
        let resetAt: Int
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private extension JSONDecoder {
    static let codexDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}
