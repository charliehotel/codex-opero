import Foundation

public protocol UsageProvider: Sendable {
    var providerID: ProviderID { get }
    func fetchQuota() async throws -> ProviderQuota
}

public enum ProviderError: LocalizedError, Equatable, Sendable {
    case credentialsMissing
    case badResponse
    case unsupportedPayload
    case http(Int)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "credentials missing"
        case .badResponse:
            return "bad response"
        case .unsupportedPayload:
            return "unsupported payload"
        case .http(let code):
            return "http \(code)"
        case .other(let message):
            return message
        }
    }
}
