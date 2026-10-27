import Foundation
import Observation
import QuotaCore

@Observable
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let lastCheckedAtKey = "updateCheck.lastCheckedAt"
    private static let availableVersionKey = "updateCheck.availableVersion"
    private static let availableReleaseURLKey = "updateCheck.availableReleaseURL"

    private let defaults: UserDefaults
    private let apiURL = URL(string: "https://api.github.com/repos/charliehotel/codex-opero/releases/latest")!
    private let releasesURL = URL(string: "https://github.com/charliehotel/codex-opero/releases")!
    private var checkTask: Task<Void, Never>?
    let currentVersion: AppVersion?
    private(set) var availableUpdate: AvailableUpdate?

    init(
        defaults: UserDefaults = .standard,
        currentVersion: AppVersion? = CurrentVersionReader.currentVersion()
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        if let currentVersion {
            self.availableUpdate = UpdateCheckPolicy.restoredUpdate(
                currentVersion: currentVersion,
                cachedVersion: defaults.string(forKey: Self.availableVersionKey),
                cachedReleaseURL: defaults.string(forKey: Self.availableReleaseURLKey)
            )
        } else {
            self.availableUpdate = nil
        }

        if availableUpdate == nil {
            clearCachedUpdate()
        }
    }

    func start() {
        guard checkTask == nil else {
            return
        }
        checkTask = Task { @MainActor in
            var delay = await checkForUpdateIfNeeded()
            while Task.isCancelled == false {
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                }
                guard Task.isCancelled == false else { return }
                delay = await checkForUpdateIfNeeded()
            }
        }
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
    }

    @discardableResult
    private func checkForUpdateIfNeeded(now: Date = Date()) async -> TimeInterval {
        let lastCheckedAt = defaults.object(forKey: Self.lastCheckedAtKey) as? Date
        guard UpdateCheckPolicy.shouldCheck(now: now, lastCheckedAt: lastCheckedAt) else {
            return UpdateCheckPolicy.nextCheckDelay(now: now, lastCheckedAt: lastCheckedAt)
        }

        do {
            let release = try await fetchLatestRelease()
            defaults.set(now, forKey: Self.lastCheckedAtKey)

            guard let currentVersion else {
                return UpdateCheckPolicy.checkInterval
            }

            if let update = UpdateCheckPolicy.availableUpdate(
                    latestRelease: release.versionInfo,
                    currentVersion: currentVersion,
                    fallbackURL: releasesURL
            ) {
                availableUpdate = update
                defaults.set(update.latestVersion.description, forKey: Self.availableVersionKey)
                defaults.set(update.releaseURL.absoluteString, forKey: Self.availableReleaseURLKey)
            } else {
                availableUpdate = nil
                clearCachedUpdate()
            }
            return UpdateCheckPolicy.checkInterval
        } catch {
            return UpdateCheckPolicy.retryInterval
        }
    }

    private func clearCachedUpdate() {
        defaults.removeObject(forKey: Self.availableVersionKey)
        defaults.removeObject(forKey: Self.availableReleaseURLKey)
    }

    private func fetchLatestRelease() async throws -> LatestRelease {
        let request = ReleaseRequestFactory.make(url: apiURL)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.badResponse
        }
        return try JSONDecoder().decode(LatestRelease.self, from: data)
    }

}

private struct LatestRelease: Decodable {
    let tagName: String
    let prerelease: Bool
    let draft: Bool
    let htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case draft
        case htmlURL = "html_url"
    }

    var versionInfo: ReleaseVersionInfo {
        ReleaseVersionInfo(
            tagName: tagName,
            prerelease: prerelease,
            draft: draft,
            releaseURL: htmlURL
        )
    }
}

private enum UpdateCheckError: Error {
    case badResponse
}

enum CurrentVersionReader {
    static func currentVersion() -> AppVersion? {
        if let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let version = AppVersion(bundleVersion) {
            return version
        }

        let plistURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let versionString = plist["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(versionString)
    }
}
