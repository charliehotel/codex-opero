import Foundation

public enum QuotaResetKind: String, Equatable, Sendable {
    case shortWindow
    case weeklyWindow
    case modelBucket
}

public struct QuotaResetEvent: Equatable, Sendable {
    public let providerID: ProviderID
    public let windowID: String
    public let windowName: String
    public let remainingPercent: Int
    public let resetMarker: String
    public let kind: QuotaResetKind

    public init(
        providerID: ProviderID,
        windowID: String,
        windowName: String,
        remainingPercent: Int,
        resetMarker: String,
        kind: QuotaResetKind
    ) {
        self.providerID = providerID
        self.windowID = windowID
        self.windowName = windowName
        self.remainingPercent = remainingPercent
        self.resetMarker = resetMarker
        self.kind = kind
    }
}

struct QuotaResetDetector {
    private static let fullNotifiedPrefix = "quotaResetNotification.fullNotified"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func eventsIfNeeded(for quota: ProviderQuota) -> [QuotaResetEvent] {
        var seenKeys: Set<String> = []
        return quota.notifiableResetWindows.compactMap { candidate in
            let window = candidate.window
            let stateKey = Self.fullNotifiedKey(for: quota.providerID, window: window, kind: candidate.kind)
            guard seenKeys.insert(stateKey).inserted else {
                return nil
            }

            guard window.remainingPercent == 100 else {
                defaults.removeObject(forKey: stateKey)
                return nil
            }

            guard defaults.bool(forKey: stateKey) == false else {
                return nil
            }

            return QuotaResetEvent(
                providerID: quota.providerID,
                windowID: window.id,
                windowName: window.name,
                remainingPercent: window.remainingPercent ?? 100,
                resetMarker: resetMarker(for: quota, window: window, kind: candidate.kind),
                kind: candidate.kind
            )
        }
    }

    func markNotified(_ event: QuotaResetEvent) {
        defaults.set(true, forKey: Self.fullNotifiedKey(for: event.providerID, windowID: event.windowID, kind: event.kind))
    }

    private func resetMarker(for quota: ProviderQuota, window: QuotaWindow, kind: QuotaResetKind) -> String {
        if let resetAt = window.resetAt {
            return "\(kind.rawValue):\(window.id):\(Int(resetAt.timeIntervalSince1970))"
        }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: quota.fetchedAt)
        let year = components.yearForWeekOfYear ?? 0
        let week = components.weekOfYear ?? 0
        return "\(kind.rawValue):\(window.id):\(year)-\(week)"
    }

    private static func fullNotifiedKey(
        for providerID: ProviderID,
        window: QuotaWindow,
        kind: QuotaResetKind
    ) -> String {
        fullNotifiedKey(for: providerID, windowID: window.id, kind: kind)
    }

    private static func fullNotifiedKey(
        for providerID: ProviderID,
        windowID: String,
        kind: QuotaResetKind
    ) -> String {
        "\(fullNotifiedPrefix).\(providerID.rawValue).\(kind.rawValue).\(windowID)"
    }
}

private struct NotifiableResetWindow {
    let window: QuotaWindow
    let kind: QuotaResetKind
}

private extension ProviderQuota {
    var notifiableResetWindows: [NotifiableResetWindow] {
        switch providerID {
        case .codex, .claude:
            return [
                notifiableWindow(primary, expectedName: "5h", kind: .shortWindow),
                notifiableWindow(secondary, expectedName: "7d", kind: .weeklyWindow),
            ].compactMap { $0 }
        case .antigravity:
            return [
                NotifiableResetWindow(window: primary, kind: .modelBucket),
                NotifiableResetWindow(window: secondary, kind: .modelBucket),
            ]
        }
    }

    func notifiableWindow(
        _ window: QuotaWindow,
        expectedName: String,
        kind: QuotaResetKind
    ) -> NotifiableResetWindow? {
        guard window.name.lowercased() == expectedName else {
            return nil
        }
        return NotifiableResetWindow(window: window, kind: kind)
    }
}
