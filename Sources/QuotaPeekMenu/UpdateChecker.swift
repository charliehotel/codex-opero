import AppKit
import Foundation
import QuotaCore

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let lastCheckedAtKey = "updateCheck.lastCheckedAt"
    private static let lastPromptedVersionKey = "updateCheck.lastPromptedVersion"
    private static let lastPromptedAtKey = "updateCheck.lastPromptedAt"

    private let defaults: UserDefaults
    private let apiURL = URL(string: "https://api.github.com/repos/charliehotel/codex-opero/releases/latest")!
    private let releasesURL = URL(string: "https://github.com/charliehotel/codex-opero/releases")!
    private var checkTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

            guard let currentVersion = CurrentVersionReader.currentVersion(),
                  let latestVersion = UpdateCheckPolicy.newerVersion(
                    latestRelease: release.versionInfo,
                    currentVersion: currentVersion
                  ) else {
                return UpdateCheckPolicy.checkInterval
            }

            guard shouldPrompt(version: latestVersion.description, now: now) else {
                return UpdateCheckPolicy.checkInterval
            }

            showUpdatePrompt(version: latestVersion.description, now: now)
            return UpdateCheckPolicy.checkInterval
        } catch {
            return UpdateCheckPolicy.retryInterval
        }
    }

    private func shouldPrompt(version: String, now: Date) -> Bool {
        UpdateCheckPolicy.shouldPrompt(
            version: version,
            now: now,
            lastPromptedVersion: defaults.string(forKey: Self.lastPromptedVersionKey),
            lastPromptedAt: defaults.object(forKey: Self.lastPromptedAtKey) as? Date
        )
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

    @MainActor
    private func showUpdatePrompt(version: String, now: Date) {
        defaults.set(version, forKey: Self.lastPromptedVersionKey)
        defaults.set(now, forKey: Self.lastPromptedAtKey)

        let alert = NSAlert()
        alert.messageText = "codex-opero \(version) is available"
        alert.informativeText = "Open GitHub Releases to download the latest version?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasesURL)
        }
    }
}

private struct LatestRelease: Decodable {
    let tagName: String
    let prerelease: Bool
    let draft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case draft
    }

    var versionInfo: ReleaseVersionInfo {
        ReleaseVersionInfo(tagName: tagName, prerelease: prerelease, draft: draft)
    }
}

private enum UpdateCheckError: Error {
    case badResponse
}

private enum CurrentVersionReader {
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
