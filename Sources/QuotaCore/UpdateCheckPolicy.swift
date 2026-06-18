import Foundation

public struct ReleaseVersionInfo: Equatable, Sendable {
    public let tagName: String
    public let prerelease: Bool
    public let draft: Bool

    public init(tagName: String, prerelease: Bool, draft: Bool) {
        self.tagName = tagName
        self.prerelease = prerelease
        self.draft = draft
    }
}

public enum ReleaseRequestFactory {
    public static func make(url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("codex-opero", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
}

public enum UpdateCheckPolicy {
    public static let checkInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let retryInterval: TimeInterval = 60 * 60

    public static func shouldCheck(now: Date, lastCheckedAt: Date?) -> Bool {
        guard let lastCheckedAt else {
            return true
        }
        return now.timeIntervalSince(lastCheckedAt) >= checkInterval
    }

    public static func shouldPrompt(
        version: String,
        now: Date,
        lastPromptedVersion: String?,
        lastPromptedAt: Date?
    ) -> Bool {
        guard lastPromptedVersion == version,
              let lastPromptedAt else {
            return true
        }
        return now.timeIntervalSince(lastPromptedAt) >= checkInterval
    }

    public static func nextCheckDelay(now: Date, lastCheckedAt: Date?) -> TimeInterval {
        guard let lastCheckedAt else {
            return 0
        }
        let nextCheckAt = lastCheckedAt.addingTimeInterval(checkInterval)
        return max(0, nextCheckAt.timeIntervalSince(now))
    }

    public static func newerVersion(
        latestRelease: ReleaseVersionInfo,
        currentVersion: AppVersion
    ) -> AppVersion? {
        guard latestRelease.draft == false,
              latestRelease.prerelease == false,
              let latestVersion = AppVersion(latestRelease.tagName),
              latestVersion > currentVersion else {
            return nil
        }
        return latestVersion
    }
}
