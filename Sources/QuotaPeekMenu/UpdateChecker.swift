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
    private(set) var isCheckingManually = false

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
            try await apply(fetchLatestRelease(), checkedAt: now)
            return UpdateCheckPolicy.checkInterval
        } catch {
            return UpdateCheckPolicy.retryInterval
        }
    }

    /// Checks GitHub immediately, regardless of the daily schedule.
    func checkNow(now: Date = Date()) async -> ManualUpdateCheckResult {
        guard isCheckingManually == false else {
            return .inProgress
        }
        isCheckingManually = true
        defer { isCheckingManually = false }

        guard let currentVersion else {
            return .failed("현재 앱 버전을 확인할 수 없습니다.")
        }
        do {
            let release = try await fetchLatestRelease()
            guard let update = apply(release, checkedAt: now) else {
                return .upToDate(currentVersion)
            }
            let preferKorean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
            return .available(UpdateOffer(
                update: update,
                notes: UpdateReleaseNotes.displayText(release.body ?? "", preferKorean: preferKorean),
                asset: UpdateAssetSelector.dmgAsset(in: release.assets.map(\.info))
            ))
        } catch {
            return .failed("GitHub에서 최신 버전 정보를 가져오지 못했습니다. 네트워크 연결을 확인한 뒤 다시 시도해 주세요.")
        }
    }

    @discardableResult
    private func apply(_ release: LatestRelease, checkedAt now: Date) -> AvailableUpdate? {
        defaults.set(now, forKey: Self.lastCheckedAtKey)
        guard let currentVersion,
              let update = UpdateCheckPolicy.availableUpdate(
                  latestRelease: release.versionInfo,
                  currentVersion: currentVersion,
                  fallbackURL: releasesURL
              ) else {
            availableUpdate = nil
            clearCachedUpdate()
            return nil
        }
        availableUpdate = update
        defaults.set(update.latestVersion.description, forKey: Self.availableVersionKey)
        defaults.set(update.releaseURL.absoluteString, forKey: Self.availableReleaseURLKey)
        return update
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
    let body: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }

        var info: ReleaseAssetInfo {
            ReleaseAssetInfo(name: name, downloadURL: browserDownloadURL, size: size, digest: digest)
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case draft
        case htmlURL = "html_url"
        case body
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        prerelease = try container.decode(Bool.self, forKey: .prerelease)
        draft = try container.decode(Bool.self, forKey: .draft)
        htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
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

struct UpdateOffer {
    let update: AvailableUpdate
    let notes: String
    let asset: ReleaseAssetInfo?
}

enum ManualUpdateCheckResult {
    case upToDate(AppVersion)
    case available(UpdateOffer)
    case failed(String)
    case inProgress
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
