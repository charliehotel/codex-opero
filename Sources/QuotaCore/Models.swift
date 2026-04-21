import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }
}

public struct QuotaWindow: Codable, Equatable, Sendable {
    public let name: String
    public let usedPercent: Int
    public let resetAt: Date?

    public init(name: String, usedPercent: Int, resetAt: Date?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }

    public var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }
}

public struct ProviderQuota: Equatable, Sendable {
    public let providerID: ProviderID
    public let primary: QuotaWindow
    public let secondary: QuotaWindow
    public let fetchedAt: Date

    public init(providerID: ProviderID, primary: QuotaWindow, secondary: QuotaWindow, fetchedAt: Date) {
        self.providerID = providerID
        self.primary = primary
        self.secondary = secondary
        self.fetchedAt = fetchedAt
    }
}

public enum ProviderStatus: Equatable, Sendable {
    case idle
    case loading
    case loaded(ProviderQuota)
    case failed(String)
}

public struct ProviderSnapshot: Equatable, Identifiable, Sendable {
    public let providerID: ProviderID
    public var status: ProviderStatus

    public init(providerID: ProviderID, status: ProviderStatus = .idle) {
        self.providerID = providerID
        self.status = status
    }

    public var id: String { providerID.rawValue }

    public var menuTitle: String {
        switch status {
        case .loaded(let quota):
            return "\(quota.primary.remainingPercent)%/\(quota.secondary.remainingPercent)%"
        case .loading:
            return "--/--"
        case .idle:
            return "--/--"
        case .failed:
            return "--/--"
        }
    }

    public var detailLine: String {
        switch status {
        case .loaded(let quota):
            return "\(providerID.displayName)  \(quota.primary.remainingPercent)% / \(quota.secondary.remainingPercent)%"
        case .loading:
            return "\(providerID.displayName)  refreshing..."
        case .idle:
            return "\(providerID.displayName)  waiting"
        case .failed(let message):
            return "\(providerID.displayName)  \(message)"
        }
    }
}
