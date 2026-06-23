import Foundation

public struct ReleaseVersionInfo: Equatable, Sendable {
    public let tagName: String
    public let prerelease: Bool
    public let draft: Bool
    public let releaseURL: URL?

    public init(
        tagName: String,
        prerelease: Bool,
        draft: Bool,
        releaseURL: URL? = nil
    ) {
        self.tagName = tagName
        self.prerelease = prerelease
        self.draft = draft
        self.releaseURL = releaseURL
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
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    public static let retryInterval: TimeInterval = 60 * 60

    public static func shouldCheck(now: Date, lastCheckedAt: Date?) -> Bool {
        guard let lastCheckedAt else {
            return true
        }
        return now.timeIntervalSince(lastCheckedAt) >= checkInterval
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

    public static func restoredUpdate(
        currentVersion: AppVersion,
        cachedVersion: String?,
        cachedReleaseURL: String?
    ) -> AvailableUpdate? {
        guard let cachedVersion,
              let latestVersion = AppVersion(cachedVersion),
              latestVersion > currentVersion,
              let cachedReleaseURL,
              let releaseURL = URL(string: cachedReleaseURL),
              isWebURL(releaseURL) else {
            return nil
        }
        return AvailableUpdate(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseURL: releaseURL
        )
    }

    public static func availableUpdate(
        latestRelease: ReleaseVersionInfo,
        currentVersion: AppVersion,
        fallbackURL: URL
    ) -> AvailableUpdate? {
        guard let latestVersion = newerVersion(
            latestRelease: latestRelease,
            currentVersion: currentVersion
        ) else {
            return nil
        }
        let releaseURL = latestRelease.releaseURL.flatMap { isWebURL($0) ? $0 : nil }
            ?? fallbackURL
        return AvailableUpdate(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseURL: releaseURL
        )
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}
