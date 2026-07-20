import Foundation
import Testing
@testable import QuotaCore

@Test
func remainingPercentIsClamped() {
    #expect(QuotaWindow(name: "5h", usedPercent: 16, resetAt: nil).remainingPercent == 84)
    #expect(QuotaWindow(name: "5h", usedPercent: 120, resetAt: nil).remainingPercent == 0)
}

@Test
func fiveHourResetStringUsesExactLocalTime() throws {
    let window = QuotaWindow(
        name: "5h",
        usedPercent: 16,
        resetAt: Date(timeIntervalSince1970: 1_719_929_880)
    )
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))

    #expect(
        QuotaFormatter.resetString(
            for: window,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone
        ) == "resets at 2:18 PM"
    )
}

@Test
func weeklyResetStringUsesEnglishCompactUnits() {
    let window = QuotaWindow(
        name: "7d",
        usedPercent: 16,
        resetAt: Date().addingTimeInterval(4 * 60 * 60)
    )

    #expect(QuotaFormatter.resetString(for: window) == "resets in 4h")
}

@Test
func appVersionComparesSemanticTags() throws {
    let newer = try #require(AppVersion("v0.1.6"))
    let current = try #require(AppVersion("0.1.5"))
    let older = try #require(AppVersion("0.1.4"))
    let largerMinor = try #require(AppVersion("0.10.0"))
    let smallerMinor = try #require(AppVersion("0.9.9"))

    #expect(newer > current)
    #expect(current == AppVersion("0.1.5"))
    #expect(older < current)
    #expect(largerMinor > smallerMinor)
    #expect(AppVersion("v") == nil)
}

@Test
func appVersionUsesPrefixedDisplayString() throws {
    let version = try #require(AppVersion("0.2.1"))

    #expect(version.displayString == "v0.2.1")
}

@Test
func updateCheckPolicyUsesDailyCadence() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(UpdateCheckPolicy.checkInterval == 24 * 60 * 60)
    #expect(UpdateCheckPolicy.shouldCheck(now: now, lastCheckedAt: nil))
    #expect(UpdateCheckPolicy.shouldCheck(now: now, lastCheckedAt: now.addingTimeInterval(-UpdateCheckPolicy.checkInterval)))
    #expect(UpdateCheckPolicy.shouldCheck(now: now, lastCheckedAt: now.addingTimeInterval(-60)) == false)
}

@Test
func availableUpdateUsesCurrentAndLatestDisplayString() throws {
    let current = try #require(AppVersion("0.2.1"))
    let latest = try #require(AppVersion("0.2.2"))
    let url = try #require(URL(string: "https://github.com/charliehotel/codex-opero/releases/tag/v0.2.2"))
    let update = AvailableUpdate(
        currentVersion: current,
        latestVersion: latest,
        releaseURL: url
    )

    #expect(update.displayString == "v0.2.1 → v0.2.2")
}

@Test
func updatePolicyRestoresOnlyNewerCachedVersion() throws {
    let current = try #require(AppVersion("0.2.1"))
    let releaseURL = "https://github.com/charliehotel/codex-opero/releases/tag/v0.2.2"

    let restored = UpdateCheckPolicy.restoredUpdate(
        currentVersion: current,
        cachedVersion: "0.2.2",
        cachedReleaseURL: releaseURL
    )
    let stale = UpdateCheckPolicy.restoredUpdate(
        currentVersion: current,
        cachedVersion: "0.2.1",
        cachedReleaseURL: releaseURL
    )

    #expect(restored?.latestVersion == AppVersion("0.2.2"))
    #expect(stale == nil)
}

@Test
func updatePolicyRejectsInvalidCachedUpdate() throws {
    let current = try #require(AppVersion("0.2.1"))

    #expect(UpdateCheckPolicy.restoredUpdate(
        currentVersion: current,
        cachedVersion: "not-a-version",
        cachedReleaseURL: "https://github.com/charliehotel/codex-opero/releases"
    ) == nil)
    #expect(UpdateCheckPolicy.restoredUpdate(
        currentVersion: current,
        cachedVersion: "0.2.2",
        cachedReleaseURL: "not a URL"
    ) == nil)
    #expect(UpdateCheckPolicy.restoredUpdate(
        currentVersion: current,
        cachedVersion: "0.2.2",
        cachedReleaseURL: "file:///tmp/codex-opero"
    ) == nil)
}

@Test
func updateCheckPolicyComputesNextCheckDelay() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(UpdateCheckPolicy.nextCheckDelay(now: now, lastCheckedAt: nil) == 0)
    #expect(UpdateCheckPolicy.nextCheckDelay(now: now, lastCheckedAt: now.addingTimeInterval(-60)) == UpdateCheckPolicy.checkInterval - 60)
    #expect(UpdateCheckPolicy.nextCheckDelay(now: now, lastCheckedAt: now.addingTimeInterval(-UpdateCheckPolicy.checkInterval)) == 0)
}

@Test
func updateCheckRunsImmediatelyAfterMissedDailyWindow() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let lastCheckedAt = now.addingTimeInterval(-(UpdateCheckPolicy.checkInterval + 60 * 60))

    #expect(UpdateCheckPolicy.shouldCheck(now: now, lastCheckedAt: lastCheckedAt))
    #expect(UpdateCheckPolicy.nextCheckDelay(now: now, lastCheckedAt: lastCheckedAt) == 0)
}

@Test
func updateCheckPolicyDetectsNewerStableRelease() throws {
    let current = try #require(AppVersion("0.1.5"))

    #expect(UpdateCheckPolicy.newerVersion(
        latestRelease: ReleaseVersionInfo(tagName: "v0.1.6", prerelease: false, draft: false),
        currentVersion: current
    ) == AppVersion("0.1.6"))
    #expect(UpdateCheckPolicy.newerVersion(
        latestRelease: ReleaseVersionInfo(tagName: "v0.1.5", prerelease: false, draft: false),
        currentVersion: current
    ) == nil)
    #expect(UpdateCheckPolicy.newerVersion(
        latestRelease: ReleaseVersionInfo(tagName: "v0.1.6-beta", prerelease: true, draft: false),
        currentVersion: current
    ) == nil)
    #expect(UpdateCheckPolicy.newerVersion(
        latestRelease: ReleaseVersionInfo(tagName: "v0.1.6", prerelease: false, draft: true),
        currentVersion: current
    ) == nil)
}

@Test
func updatePolicyBuildsAvailableUpdateWithDirectReleaseURL() throws {
    let current = try #require(AppVersion("0.2.1"))
    let direct = try #require(URL(string: "https://github.com/charliehotel/codex-opero/releases/tag/v0.2.2"))
    let fallback = try #require(URL(string: "https://github.com/charliehotel/codex-opero/releases"))
    let release = ReleaseVersionInfo(
        tagName: "v0.2.2",
        prerelease: false,
        draft: false,
        releaseURL: direct
    )

    #expect(UpdateCheckPolicy.availableUpdate(
        latestRelease: release,
        currentVersion: current,
        fallbackURL: fallback
    )?.releaseURL == direct)
}

@Test
func updatePolicyFallsBackWhenDirectReleaseURLIsUnavailable() throws {
    let current = try #require(AppVersion("0.2.1"))
    let fallback = try #require(URL(string: "https://github.com/charliehotel/codex-opero/releases"))

    let missingURL = ReleaseVersionInfo(
        tagName: "v0.2.2",
        prerelease: false,
        draft: false,
        releaseURL: nil
    )
    let invalidURL = ReleaseVersionInfo(
        tagName: "v0.2.2",
        prerelease: false,
        draft: false,
        releaseURL: URL(fileURLWithPath: "/tmp/codex-opero")
    )

    #expect(UpdateCheckPolicy.availableUpdate(
        latestRelease: missingURL,
        currentVersion: current,
        fallbackURL: fallback
    )?.releaseURL == fallback)
    #expect(UpdateCheckPolicy.availableUpdate(
        latestRelease: invalidURL,
        currentVersion: current,
        fallbackURL: fallback
    )?.releaseURL == fallback)
}

@Test
func updatePolicyRejectsUnavailableReleaseKinds() throws {
    let current = try #require(AppVersion("0.2.1"))
    let fallback = try #require(URL(string: "https://github.com/charliehotel/codex-opero/releases"))

    #expect(UpdateCheckPolicy.availableUpdate(
        latestRelease: ReleaseVersionInfo(tagName: "v0.2.1", prerelease: false, draft: false),
        currentVersion: current,
        fallbackURL: fallback
    ) == nil)
    #expect(UpdateCheckPolicy.availableUpdate(
        latestRelease: ReleaseVersionInfo(tagName: "v0.2.2-beta", prerelease: true, draft: false),
        currentVersion: current,
        fallbackURL: fallback
    ) == nil)
    #expect(UpdateCheckPolicy.availableUpdate(
        latestRelease: ReleaseVersionInfo(tagName: "v0.2.2", prerelease: false, draft: true),
        currentVersion: current,
        fallbackURL: fallback
    ) == nil)
}

@Test
func updateReleaseRequestUsesBoundedGitHubContract() throws {
    let url = try #require(URL(string: "https://api.github.com/repos/charliehotel/codex-opero/releases/latest"))
    let request = ReleaseRequestFactory.make(url: url)

    #expect(request.timeoutInterval == 15)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "codex-opero")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
}

@Test
func loadedSnapshotUsesCompactMenuTitle() {
    let quota = ProviderQuota(
        providerID: .codex,
        primary: QuotaWindow(name: "5h", usedPercent: 16, resetAt: nil),
        secondary: QuotaWindow(name: "7d", usedPercent: 6, resetAt: nil),
        fetchedAt: Date()
    )

    let snapshot = ProviderSnapshot(providerID: .codex, status: .loaded(quota))
    #expect(snapshot.menuTitle == "84%/94%")
}

@Test
func loadedSnapshotUsesCompactMenuTitleForSelectedDisplayMode() {
    let quota = ProviderQuota(
        providerID: .codex,
        primary: QuotaWindow(name: "5h", usedPercent: 16, resetAt: nil),
        secondary: QuotaWindow(name: "7d", usedPercent: 6, resetAt: nil),
        fetchedAt: Date()
    )

    let snapshot = ProviderSnapshot(providerID: .codex, status: .loaded(quota))

    #expect(snapshot.compactTitle(displayMode: .remaining) == "84%/94%")
    #expect(snapshot.compactTitle(displayMode: .usage) == "16%/6%")
}

@Test
func loadingSnapshotUsesPreviousQuotaForSelectedDisplayMode() {
    let previousQuota = ProviderQuota(
        providerID: .codex,
        primary: QuotaWindow(name: "5h", usedPercent: 39, resetAt: nil),
        secondary: QuotaWindow(name: "7d", usedPercent: 90, resetAt: nil),
        fetchedAt: Date()
    )

    let snapshot = ProviderSnapshot(providerID: .codex, status: .loading(previousQuota))

    #expect(snapshot.compactTitle(displayMode: .remaining) == "61%/10%")
    #expect(snapshot.compactTitle(displayMode: .usage) == "39%/90%")
}

@MainActor
@Test
func defaultProvidersExcludeRetiredGemini() {
    let suiteName = "QuotaCoreTests.defaultProviders"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = QuotaStore(defaults: defaults)

    #expect(store.snapshots.map(\.providerID) == [.codex, .claude, .antigravity])
}

@MainActor
@Test
func persistedGeminiSelectionMigratesToAntigravity() {
    let suiteName = "QuotaCoreTests.geminiMigration"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("gemini", forKey: QuotaStore.selectedProviderDefaultsKey)

    let store = QuotaStore(defaults: defaults)

    #expect(store.selectedProviderID == .antigravity)
}

@Test
func antigravityProviderUsesSharedModelBuckets() async throws {
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravity.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }

    let cache = """
    {
      "updatedAt": 1779200553561,
      "payload": {
        "models": {
          "gemini-3.1-pro-high": {
            "displayName": "Gemini 3.1 Pro (High)",
            "recommended": true,
            "quotaInfo": {
              "remainingFraction": 0.75,
              "resetTime": "2026-05-26T00:22:19Z"
            }
          },
          "gemini-3-flash": {
            "displayName": "Gemini 3 Flash",
            "recommended": true,
            "quotaInfo": {
              "remainingFraction": 0.80,
              "resetTime": "2026-05-26T14:22:33Z"
            }
          },
          "claude-opus-4-6-thinking": {
            "displayName": "Claude Opus 4.6 (Thinking)",
            "recommended": true,
            "quotaInfo": {
              "remainingFraction": 0.50,
              "resetTime": "2026-05-26T00:15:30Z"
            }
          },
          "gpt-oss-120b-medium": {
            "displayName": "GPT-OSS 120B (Medium)",
            "recommended": true,
            "quotaInfo": {
              "remainingFraction": 0.55,
              "resetTime": "2026-05-26T00:15:30Z"
            }
          }
        }
      }
    }
    """
    try cache.data(using: .utf8)?.write(to: cacheDirectory.appendingPathComponent("quota.json"))

    let quota = try await AntigravityProvider(
        cacheDirectoryURLs: [cacheDirectory],
        historyDirectoryURLs: [],
        currentAccountURL: cacheDirectory.appendingPathComponent("missing_current_account.json"),
        usageExecutableURL: nil,
        ideMainLogURL: nil,
        legacyFallbacksEnabled: true
    ).fetchQuota()

    #expect(quota.primary.name == "Google")
    #expect(quota.primary.remainingPercent == 75)
    #expect(quota.secondary.name == "3rd Party")
    #expect(quota.secondary.remainingPercent == 50)
    #expect(quota.detailGroups.map(\.name) == ["Google", "3rd Party"])
    #expect(quota.detailGroups[0].windows.first?.name == "Google")
    #expect(quota.detailGroups[0].windows.first?.usedPercent == 25)
    #expect(quota.detailGroups[0].modelNames == [
        "Gemini 3.1 Pro (High)",
        "Gemini 3.1 Pro (Low)",
        "Gemini 3.5 Flash (High)",
        "Gemini 3.5 Flash (Medium)",
    ])
    #expect(quota.detailGroups[1].windows.first?.name == "3rd Party")
    #expect(quota.detailGroups[1].windows.first?.usedPercent == 50)
    #expect(quota.detailGroups[1].modelNames == [
        "Claude Opus 4.6 (Thinking)",
        "Claude Sonnet 4.6 (Thinking)",
        "GPT-OSS 120B (Medium)",
    ])
}

@Test
func antigravityProviderUsesCurrentAccountAndHistoryBuckets() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityCurrent.\(UUID().uuidString)")
    let cacheDirectory = root.appendingPathComponent("quota")
    let historyDirectory = root.appendingPathComponent("history")
    let currentAccountURL = root.appendingPathComponent("current_account.json")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fullCache = """
    {
      "email": "other@example.com",
      "payload": {
        "models": {
          "gemini-3.1-pro-high": {"quotaInfo": {"remainingFraction": 1, "resetTime": "2026-05-26T00:22:19Z"}},
          "claude-opus-4-6-thinking": {"quotaInfo": {"remainingFraction": 1, "resetTime": "2026-05-26T00:15:30Z"}}
        }
      }
    }
    """
    let currentCache = """
    {
      "email": "current@example.com",
      "payload": {
        "models": {
          "gemini-3.1-pro-high": {"quotaInfo": {"remainingFraction": 0.9, "resetTime": "2026-05-26T00:22:19Z"}},
          "claude-opus-4-6-thinking": {"quotaInfo": {"remainingFraction": 0.9, "resetTime": "2026-05-26T00:15:30Z"}}
        }
      }
    }
    """
    let history = """
    {
      "email": "current@example.com",
      "models": {
        "g3-pro": {
          "points": [{"timestamp": 1000, "remainingPercentage": 80, "resetTime": 1779754939000}]
        },
        "g3-flash": {
          "points": [{"timestamp": 1000, "remainingPercentage": 90, "resetTime": 1779805353000}]
        },
        "claude-4-5": {
          "points": [{"timestamp": 1000, "remainingPercentage": 0, "resetTime": 1779754530000}]
        }
      }
    }
    """
    try fullCache.data(using: .utf8)?.write(to: cacheDirectory.appendingPathComponent("other.json"))
    try currentCache.data(using: .utf8)?.write(to: cacheDirectory.appendingPathComponent("current.json"))
    try history.data(using: .utf8)?.write(to: historyDirectory.appendingPathComponent("current.json"))
    try #"{"email":"current@example.com"}"#.data(using: .utf8)?.write(to: currentAccountURL)

    let quota = try await AntigravityProvider(
        cacheDirectoryURLs: [cacheDirectory],
        historyDirectoryURLs: [historyDirectory],
        currentAccountURL: currentAccountURL,
        usageExecutableURL: nil,
        ideMainLogURL: nil,
        legacyFallbacksEnabled: true
    ).fetchQuota()

    #expect(quota.primary.usedPercent == 20)
    #expect(quota.secondary.usedPercent == 100)
    #expect(quota.detailGroups[0].windows.first?.usedPercent == 20)
    #expect(quota.detailGroups[1].windows.first?.usedPercent == 100)
}

@Test
func antigravityProviderUsesAntigravityIDELocalQuotaSummary() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityIDE.\(UUID().uuidString)")
    let logURL = root.appendingPathComponent("main.log")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let token = "test-csrf-token"
    let httpsPort = 12345
    let log = """
    [2026-05-22 14:34:06.210] [info]
    Spawning: language_server --https_server_port 0 --csrf_token \(token) --app_data_dir antigravity
    [2026-05-22 14:34:08.049] [info]    Local:       https://127.0.0.1:\(httpsPort)/
    """
    try log.data(using: .utf8)?.write(to: logURL)

    let googleWeeklyReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
    let googleFiveHourReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3_600))
    let thirdPartyWeeklyReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(6 * 86_400 + 21 * 3_600))
    let thirdPartyFiveHourReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3_600 + 57 * 60))
    let responseJSON = """
    {
      "response": {
        "groups": [
          {
            "displayName": "Gemini Models",
            "buckets": [
              {
                "bucketId": "gemini-weekly",
                "displayName": "Weekly Limit",
                "window": "weekly",
                "remainingFraction": 0.97,
                "resetTime": "\(googleWeeklyReset)"
              },
              {
                "bucketId": "gemini-5h",
                "displayName": "Five Hour Limit",
                "window": "5h",
                "remainingFraction": 1,
                "resetTime": "\(googleFiveHourReset)"
              }
            ]
          },
          {
            "displayName": "Claude and GPT models",
            "buckets": [
              {
                "bucketId": "3p-weekly",
                "displayName": "Weekly Limit",
                "window": "weekly",
                "remainingFraction": 0,
                "resetTime": "\(thirdPartyWeeklyReset)"
              },
              {
                "bucketId": "3p-5h",
                "displayName": "Five Hour Limit",
                "window": "5h",
                "remainingFraction": 0.69,
                "resetTime": "\(thirdPartyFiveHourReset)"
              }
            ]
          }
        ]
      }
    }
    """

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AntigravityURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer {
        AntigravityURLProtocolStub.requestHandler = nil
        session.invalidateAndCancel()
    }

    AntigravityURLProtocolStub.requestHandler = { request in
        #expect(request.url?.absoluteString == "http://127.0.0.1:12346/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
        #expect(request.value(forHTTPHeaderField: "x-codeium-csrf-token") == token)
        #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (httpResponse, Data(responseJSON.utf8))
    }

    let quota = try await AntigravityProvider(
        cacheDirectoryURLs: [],
        historyDirectoryURLs: [],
        currentAccountURL: root.appendingPathComponent("missing_current_account.json"),
        usageExecutableURL: nil,
        ideMainLogURL: logURL,
        ideSession: session
    ).fetchQuota()

    #expect(quota.primary.remainingPercent == 100)
    #expect(quota.primary.usedPercent == 0)
    #expect(quota.primary.resetAt != nil)
    #expect(quota.secondary.remainingPercent == 0)
    #expect(quota.secondary.usedPercent == 100)
    #expect(quota.secondary.resetAt != nil)
    #expect(quota.detailGroups.map(\.name) == ["Gemini Models", "Claude and GPT models"])
    #expect(quota.detailGroups[0].windows.map(\.id) == ["gemini-5h", "gemini-weekly"])
    #expect(quota.detailGroups[0].windows.map(\.name) == ["5h", "7d"])
    #expect(quota.detailGroups[0].windows.map(\.remainingPercent) == [100, 97])
    #expect(quota.detailGroups[1].windows.map(\.id) == ["3p-5h", "3p-weekly"])
    #expect(quota.detailGroups[1].windows.map(\.name) == ["5h", "7d"])
    #expect(quota.detailGroups[1].windows.map(\.remainingPercent) == [69, 0])
}

@Test
func antigravityProviderDoesNotAutomaticallyLaunchAgyWithoutIDE() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityNoLaunch.\(UUID().uuidString)")
    let executableURL = root.appendingPathComponent("agy-fixture")
    let markerURL = root.appendingPathComponent("launched")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = """
    #!/bin/sh
    touch "\(markerURL.path)"
    exit 0
    """
    try script.data(using: .utf8)?.write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    do {
        _ = try await AntigravityProvider(
            cacheDirectoryURLs: [],
            historyDirectoryURLs: [],
            currentAccountURL: root.appendingPathComponent("missing_current_account.json"),
            usageExecutableURL: executableURL,
            ideMainLogURL: nil
        ).fetchQuota()
        Issue.record("Expected an Antigravity IDE availability failure")
    } catch {
        #expect((error as? LocalizedError)?.errorDescription == "Open Antigravity app to read current quota")
    }

    #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
}

@Test
func antigravityProviderPrefersLiveUsageOutput() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityLive.\(UUID().uuidString)")
    let cacheDirectory = root.appendingPathComponent("quota")
    let executableURL = root.appendingPathComponent("agy-fixture")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let staleCache = """
    {
      "payload": {
        "models": {
          "gemini-3.1-pro-high": {"quotaInfo": {"remainingFraction": 1, "resetTime": "2026-05-26T00:22:19Z"}},
          "claude-opus-4-6-thinking": {"quotaInfo": {"remainingFraction": 0.4, "resetTime": "2026-05-26T00:15:30Z"}}
        }
      }
    }
    """
    try staleCache.data(using: .utf8)?.write(to: cacheDirectory.appendingPathComponent("quota.json"))

    let script = """
    #!/bin/sh
    printf 'agy ready> '
    read command
    if [ "$command" != "/usage" ]; then
      exit 2
    fi
    cat <<'EOF'
    \u{001B}[2J\rModel Quota
    \u{001B}[35mGemini 3.5 Flash (High)\u{001B}[0m
    80% remaining · Refreshes in 3h 0m
    \u{001B}[35mGemini 3.5 Flash (Medium)\u{001B}[0m
    80% remaining · Refreshes in 3h 0m
    \u{001B}[35mGemini 3.1 Pro (High)\u{001B}[0m
    80% remaining · Refreshes in 3h 1m
    \u{001B}[35mGemini 3.1 Pro (Low)\u{001B}[0m
    80% remaining · Refreshes in 3h 1m
    \u{001B}[35mClaude Sonnet 4.6 (Thinking)\u{001B}[0m
    Quota available
    \u{001B}[35mClaude Opus 4.6 (Thinking)\u{001B}[0m
    Quota available
    \u{001B}[35mGPT-OSS 120B (Medium)\u{001B}[0m
    Quota available
    EOF
    sleep 5
    """
    try script.data(using: .utf8)?.write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let quota = try await AntigravityProvider(
        cacheDirectoryURLs: [cacheDirectory],
        historyDirectoryURLs: [],
        currentAccountURL: cacheDirectory.appendingPathComponent("missing_current_account.json"),
        usageExecutableURL: executableURL,
        usageTimeout: 5,
        ideMainLogURL: nil,
        legacyFallbacksEnabled: true
    ).fetchQuota()

    #expect(quota.primary.remainingPercent == 80)
    #expect(quota.primary.usedPercent == 20)
    #expect(quota.secondary.remainingPercent == 100)
    #expect(quota.secondary.usedPercent == 0)
    #expect(quota.detailGroups[0].windows.first?.usedPercent == 20)
    #expect(quota.detailGroups[1].windows.first?.usedPercent == 0)
}

@Test
func antigravityProviderParsesTerminalRedrawUsageOutput() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityRedraw.\(UUID().uuidString)")
    let cacheDirectory = root.appendingPathComponent("quota")
    let executableURL = root.appendingPathComponent("agy-redraw-fixture")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = """
    #!/bin/sh
    printf 'agy ready> '
    read command
    if [ "$command" != "/usage" ]; then
      exit 2
    fi
    printf '\\033[2J\\033[35mGemini 3.5 Flash (High)\\033[m\\033[K 75%% remaining · Refreshes in 2h 10m \\033[35mClaude Sonnet 4.6 (Thinking)\\033[m\\033[K Quota available '
    sleep 5
    """
    try script.data(using: .utf8)?.write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let quota = try await AntigravityProvider(
        cacheDirectoryURLs: [cacheDirectory],
        historyDirectoryURLs: [],
        currentAccountURL: cacheDirectory.appendingPathComponent("missing_current_account.json"),
        usageExecutableURL: executableURL,
        usageTimeout: 5,
        ideMainLogURL: nil,
        legacyFallbacksEnabled: true
    ).fetchQuota()

    #expect(quota.primary.remainingPercent == 75)
    #expect(quota.primary.usedPercent == 25)
    #expect(quota.secondary.remainingPercent == 100)
    #expect(quota.secondary.usedPercent == 0)
}

@Test
func antigravityProviderParsesExhaustedRefreshOnlyUsageOutput() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityExhausted.\(UUID().uuidString)")
    let cacheDirectory = root.appendingPathComponent("quota")
    let executableURL = root.appendingPathComponent("agy-exhausted-fixture")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = """
    #!/bin/sh
    printf 'agy ready> '
    read command
    if [ "$command" != "/usage" ]; then
      exit 2
    fi
    cat <<'EOF'
    Model Quota
    Claude Opus 4.6 (Thinking) ⚠ Refreshes in 5 days, 21 hours
    GPT-OSS 120B (Medium) ⚠ Refreshes in 5 days, 21 hours
    Gemini 3.5 Flash (High)
    80% remaining · Refreshes in 38 minutes
    Claude Sonnet 4.6 (Thinking) ⚠ Refreshes in 5 days, 21 hours
    EOF
    sleep 5
    """
    try script.data(using: .utf8)?.write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let quota = try await AntigravityProvider(
        cacheDirectoryURLs: [cacheDirectory],
        historyDirectoryURLs: [],
        currentAccountURL: cacheDirectory.appendingPathComponent("missing_current_account.json"),
        usageExecutableURL: executableURL,
        usageTimeout: 5,
        ideMainLogURL: nil,
        legacyFallbacksEnabled: true
    ).fetchQuota()

    #expect(quota.primary.remainingPercent == 80)
    #expect(quota.primary.usedPercent == 20)
    #expect(quota.secondary.remainingPercent == 0)
    #expect(quota.secondary.usedPercent == 100)

    let resetAt = try #require(quota.secondary.resetAt)
    let resetInterval = resetAt.timeIntervalSince(quota.fetchedAt)
    #expect(resetInterval > (5 * 86_400 + 20 * 3_600))
    #expect(resetInterval < (5 * 86_400 + 22 * 3_600))
}

@Test
func antigravityProviderParsesStandaloneZeroPercentUsageOutput() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityZeroPercent.\(UUID().uuidString)")
    let cacheDirectory = root.appendingPathComponent("quota")
    let executableURL = root.appendingPathComponent("agy-zero-percent-fixture")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = """
    #!/bin/sh
    printf 'agy ready> '
    read command
    if [ "$command" != "/usage" ]; then
      exit 2
    fi
    cat <<'EOF'
    Model Quota
    Gemini 3.5 Flash (High)
    Quota available 100%
    Gemini 3.1 Pro (High)
    Quota available 100%
    Claude Sonnet 4.6 (Thinking)
    --------------- 0%
    Refreshes in 82h 57m
    Claude Opus 4.6 (Thinking)
    --------------- 0%
    Refreshes in 82h 57m
    GPT-OSS 120B (Medium)
    --------------- 0%
    Refreshes in 82h 57m
    EOF
    sleep 5
    """
    try script.data(using: .utf8)?.write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let quota = try await AntigravityProvider(
        cacheDirectoryURLs: [cacheDirectory],
        historyDirectoryURLs: [],
        currentAccountURL: cacheDirectory.appendingPathComponent("missing_current_account.json"),
        usageExecutableURL: executableURL,
        usageTimeout: 5,
        ideMainLogURL: nil,
        legacyFallbacksEnabled: true
    ).fetchQuota()

    #expect(quota.primary.remainingPercent == 100)
    #expect(quota.primary.usedPercent == 0)
    #expect(quota.secondary.remainingPercent == 0)
    #expect(quota.secondary.usedPercent == 100)

    let resetAt = try #require(quota.secondary.resetAt)
    let resetInterval = resetAt.timeIntervalSince(quota.fetchedAt)
    #expect(resetInterval > (82 * 3_600 + 56 * 60))
    #expect(resetInterval < (82 * 3_600 + 58 * 60))
}

@Test
func antigravityProviderPreservesResetTimerForAvailableRefreshOnlyGoogleBucket() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityGoogleReset.\(UUID().uuidString)")
    let cacheDirectory = root.appendingPathComponent("quota")
    let executableURL = root.appendingPathComponent("agy-google-reset-fixture")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = """
    #!/bin/sh
    printf 'agy ready> '
    read command
    if [ "$command" != "/usage" ]; then
      exit 2
    fi
    cat <<'EOF'
    Model Quota
    Gemini 3.5 Flash (High)
    Quota available · Refreshes in 38 minutes
    Gemini 3.1 Pro (High)
    Quota available
    Claude Opus 4.6 (Thinking) ⚠ Refreshes in 5 days, 21 hours
    Claude Sonnet 4.6 (Thinking) ⚠ Refreshes in 5 days, 21 hours
    GPT-OSS 120B (Medium) ⚠ Refreshes in 5 days, 21 hours
    EOF
    sleep 5
    """
    try script.data(using: .utf8)?.write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let quota = try await AntigravityProvider(
        cacheDirectoryURLs: [cacheDirectory],
        historyDirectoryURLs: [],
        currentAccountURL: cacheDirectory.appendingPathComponent("missing_current_account.json"),
        usageExecutableURL: executableURL,
        usageTimeout: 5,
        ideMainLogURL: nil,
        legacyFallbacksEnabled: true
    ).fetchQuota()

    #expect(quota.primary.remainingPercent == 100)
    #expect(quota.primary.usedPercent == 0)
    #expect(quota.secondary.remainingPercent == 0)
    #expect(quota.secondary.usedPercent == 100)

    let resetAt = try #require(quota.primary.resetAt)
    let resetInterval = resetAt.timeIntervalSince(quota.fetchedAt)
    #expect(resetInterval > 37 * 60)
    #expect(resetInterval < 39 * 60)
}

@Test
func antigravityProviderReadsResetTimerFromModelRowForAvailableGoogleBucket() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityGoogleRowReset.\(UUID().uuidString)")
    let cacheDirectory = root.appendingPathComponent("quota")
    let executableURL = root.appendingPathComponent("agy-google-row-reset-fixture")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = """
    #!/bin/sh
    printf 'agy ready> '
    read command
    if [ "$command" != "/usage" ]; then
      exit 2
    fi
    cat <<'EOF'
    Model Quota
    Refreshes in 38 minutes     Gemini 3.5 Flash (High)
    Quota available
    Gemini 3.1 Pro (High)
    Quota available
    Claude Opus 4.6 (Thinking) ⚠ Refreshes in 5 days, 21 hours
    Claude Sonnet 4.6 (Thinking) ⚠ Refreshes in 5 days, 21 hours
    GPT-OSS 120B (Medium) ⚠ Refreshes in 5 days, 21 hours
    EOF
    sleep 5
    """
    try script.data(using: .utf8)?.write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let quota = try await AntigravityProvider(
        cacheDirectoryURLs: [cacheDirectory],
        historyDirectoryURLs: [],
        currentAccountURL: cacheDirectory.appendingPathComponent("missing_current_account.json"),
        usageExecutableURL: executableURL,
        usageTimeout: 5,
        ideMainLogURL: nil,
        legacyFallbacksEnabled: true
    ).fetchQuota()

    #expect(quota.primary.remainingPercent == 100)
    #expect(quota.primary.usedPercent == 0)

    let resetAt = try #require(quota.primary.resetAt)
    let resetInterval = resetAt.timeIntervalSince(quota.fetchedAt)
    #expect(resetInterval > 37 * 60)
    #expect(resetInterval < 39 * 60)
}

@Test
func antigravityProviderStopsWhenAgyStartsOAuthFlow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityOAuth.\(UUID().uuidString)")
    let cacheDirectory = root.appendingPathComponent("quota")
    let executableURL = root.appendingPathComponent("agy-oauth-fixture")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = """
    #!/bin/sh
    printf 'agy ready> '
    read command
    if [ "$command" != "/usage" ]; then
      exit 2
    fi
    printf 'I0522 auth_manager.go:105] Starting OAuth authentication flow\\n'
    printf 'I0522 browser.go:55] consumerOAuth: starting OAuth flow\\n'
    sleep 5
    """
    try script.data(using: .utf8)?.write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    do {
        _ = try await AntigravityProvider(
            cacheDirectoryURLs: [cacheDirectory],
            historyDirectoryURLs: [],
            currentAccountURL: cacheDirectory.appendingPathComponent("missing_current_account.json"),
            usageExecutableURL: executableURL,
            usageTimeout: 5,
            ideMainLogURL: nil,
            legacyFallbacksEnabled: true
        ).fetchQuota()
        Issue.record("Expected Antigravity OAuth flow failure")
    } catch {
        #expect((error as? LocalizedError)?.errorDescription == "agy tried to start Google login; skipping live usage lookup")
    }
}

@Test
func antigravityProviderSanitizesTimedOutTerminalOutput() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaCoreTests.antigravityTimeout.\(UUID().uuidString)")
    let cacheDirectory = root.appendingPathComponent("quota")
    let executableURL = root.appendingPathComponent("agy-timeout-fixture")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = """
    #!/bin/sh
    printf 'agy ready> '
    read command
    printf '\\033[K\\033[2A\\033[13D\\033[?25h---------------'
    sleep 5
    """
    try script.data(using: .utf8)?.write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    do {
        _ = try await AntigravityProvider(
            cacheDirectoryURLs: [cacheDirectory],
            historyDirectoryURLs: [],
            currentAccountURL: cacheDirectory.appendingPathComponent("missing_current_account.json"),
            usageExecutableURL: executableURL,
            usageTimeout: 1,
            ideMainLogURL: nil,
            legacyFallbacksEnabled: true
        ).fetchQuota()
        Issue.record("Expected Antigravity timeout")
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? ""
        #expect(message.contains("agy usage command timed out"))
        #expect(message.contains("[K") == false)
        #expect(message.contains("[2A") == false)
        #expect(message.contains("[?25h") == false)
    }
}

@MainActor
@Test
func selectedProviderSkipsUnavailableProvidersWhenRotating() async {
    struct MockProvider: UsageProvider {
        let providerID: ProviderID
        let quota: ProviderQuota?

        func fetchQuota() async throws -> ProviderQuota {
            if let quota {
                return quota
            }
            throw ProviderError.credentialsMissing
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.autoRotate")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.autoRotate")

    let codexQuota = ProviderQuota(
        providerID: .codex,
        primary: QuotaWindow(name: "5h", usedPercent: 10, resetAt: nil),
        secondary: QuotaWindow(name: "7d", usedPercent: 20, resetAt: nil),
        fetchedAt: Date()
    )
    let antigravityQuota = ProviderQuota(
        providerID: .antigravity,
        primary: QuotaWindow(name: "Pro", usedPercent: 30, resetAt: nil),
        secondary: QuotaWindow(name: "Flash", usedPercent: 40, resetAt: nil),
        fetchedAt: Date()
    )

    let store = QuotaStore(
        providers: [
            MockProvider(providerID: .codex, quota: codexQuota),
            MockProvider(providerID: .claude, quota: nil),
            MockProvider(providerID: .antigravity, quota: antigravityQuota),
        ],
        defaults: defaults
    )
    store.autoRotateEnabled = true
    await store.refresh()

    #expect(store.rotatableProviderIDs() == [.codex, .antigravity])

    store.rotateToNextProviderIfNeeded()
    #expect(store.selectedProviderID == .antigravity)

    store.rotateToNextProviderIfNeeded()
    #expect(store.selectedProviderID == .codex)
}

@MainActor
@Test
func refreshPublishesSnapshotsAsProvidersFinishAndSelectsFirstLoadedProvider() async throws {
    struct DelayedMockProvider: UsageProvider {
        let providerID: ProviderID
        let quota: ProviderQuota
        let delay: Duration

        func fetchQuota() async throws -> ProviderQuota {
            try await Task.sleep(for: delay)
            return quota
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.incrementalRefresh")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.incrementalRefresh")

    let codexQuota = ProviderQuota(
        providerID: .codex,
        primary: QuotaWindow(name: "5h", usedPercent: 10, resetAt: nil),
        secondary: QuotaWindow(name: "7d", usedPercent: 20, resetAt: nil),
        fetchedAt: Date()
    )
    let antigravityQuota = ProviderQuota(
        providerID: .antigravity,
        primary: QuotaWindow(name: "Pro", usedPercent: 30, resetAt: nil),
        secondary: QuotaWindow(name: "Flash", usedPercent: 40, resetAt: nil),
        fetchedAt: Date()
    )

    let store = QuotaStore(
        providers: [
            DelayedMockProvider(providerID: .codex, quota: codexQuota, delay: .milliseconds(600)),
            DelayedMockProvider(providerID: .antigravity, quota: antigravityQuota, delay: .milliseconds(50)),
        ],
        defaults: defaults
    )

    let refreshTask = Task { await store.refresh() }
    try await Task.sleep(for: .milliseconds(150))

    #expect(store.snapshot(for: .antigravity).quota == antigravityQuota)
    #expect(store.snapshot(for: .codex).quota == nil)
    #expect(store.selectedProviderID == .antigravity)

    await refreshTask.value

    #expect(store.snapshot(for: .codex).quota == codexQuota)
    #expect(store.snapshot(for: .antigravity).quota == antigravityQuota)
}

@MainActor
@Test
func quotaResetEventFiresOnLaunchWhenShortWindowIsFull() async {
    struct MockProvider: UsageProvider {
        let providerID: ProviderID
        let quota: ProviderQuota

        func fetchQuota() async throws -> ProviderQuota {
            quota
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetLaunch")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetLaunch")

    let quota = ProviderQuota(
        providerID: .codex,
        primary: QuotaWindow(name: "5h", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_700_100_000)),
        secondary: QuotaWindow(name: "7d", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var events: [QuotaResetEvent] = []
    let store = QuotaStore(
        providers: [MockProvider(providerID: .codex, quota: quota)],
        defaults: defaults,
        onQuotaReset: { event in
            events.append(event)
            return true
        }
    )

    await store.refresh()
    await store.refresh()
    await store.refresh()

    #expect(events == [
        QuotaResetEvent(
            providerID: .codex,
            windowID: "5h",
            windowName: "5h",
            remainingPercent: 100,
            resetMarker: "shortWindow:5h:1700100000",
            kind: .shortWindow
        ),
    ])
}

@MainActor
@Test
func quotaResetEventIncludesWeeklyWindowAndDoesNotRepeatForSameResetMarker() async {
    struct MockProvider: UsageProvider {
        let providerID: ProviderID
        let quota: ProviderQuota

        func fetchQuota() async throws -> ProviderQuota {
            quota
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetDedupe")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetDedupe")

    let quota = ProviderQuota(
        providerID: .claude,
        primary: QuotaWindow(name: "5h", usedPercent: 20, resetAt: nil),
        secondary: QuotaWindow(name: "7d", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var events: [QuotaResetEvent] = []
    let store = QuotaStore(
        providers: [MockProvider(providerID: .claude, quota: quota)],
        defaults: defaults,
        onQuotaReset: { event in
            events.append(event)
            return true
        }
    )

    await store.refresh()
    await store.refresh()

    #expect(events.count == 1)
}

@MainActor
@Test
func quotaResetEventRetriesWhenNotificationDeliveryFails() async {
    struct MockProvider: UsageProvider {
        let providerID: ProviderID
        let quota: ProviderQuota

        func fetchQuota() async throws -> ProviderQuota {
            quota
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetRetry")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetRetry")

    let quota = ProviderQuota(
        providerID: .codex,
        primary: QuotaWindow(name: "5h", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_700_100_000)),
        secondary: QuotaWindow(name: "7d", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var deliveryResults = [false, true]
    var events: [QuotaResetEvent] = []
    let store = QuotaStore(
        providers: [MockProvider(providerID: .codex, quota: quota)],
        defaults: defaults,
        onQuotaReset: { event in
            events.append(event)
            return deliveryResults.removeFirst()
        }
    )

    await store.refresh()
    await store.refresh()
    await store.refresh()

    #expect(events.count == 2)
}

@MainActor
@Test
func quotaResetEventUsesAntigravityMenuBuckets() async {
    struct MockProvider: UsageProvider {
        let providerID: ProviderID
        let quota: ProviderQuota

        func fetchQuota() async throws -> ProviderQuota {
            quota
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetAntigravity")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetAntigravity")

    let quota = ProviderQuota(
        providerID: .antigravity,
        primary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_700_100_000)),
        secondary: QuotaWindow(name: "Flash", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        detailGroups: [
            QuotaDetailGroup(
                name: "Pro",
                windows: [
                    QuotaWindow(
                        id: "gemini-2.5-pro:REQUESTS",
                        name: "2.5 Pro",
                        usedPercent: 0,
                        resetAt: Date(timeIntervalSince1970: 1_700_100_000)
                    ),
                ]
            ),
        ]
    )
    var events: [QuotaResetEvent] = []
    let store = QuotaStore(
        providers: [MockProvider(providerID: .antigravity, quota: quota)],
        defaults: defaults,
        onQuotaReset: { event in
            events.append(event)
            return true
        }
    )

    await store.refresh()
    await store.refresh()

    #expect(events == [
        QuotaResetEvent(
            providerID: .antigravity,
            windowID: "Pro",
            windowName: "Pro",
            remainingPercent: 100,
            resetMarker: "modelBucket:Pro:1700100000",
            kind: .modelBucket
        ),
    ])
}

@MainActor
@Test
func quotaResetEventDeduplicatesIdenticalAntigravityMarkers() async {
    struct MockProvider: UsageProvider {
        let providerID: ProviderID
        let quota: ProviderQuota

        func fetchQuota() async throws -> ProviderQuota {
            quota
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetAntigravityDuplicate")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetAntigravityDuplicate")

    let resetAt = Date(timeIntervalSince1970: 1_700_100_000)
    let quota = ProviderQuota(
        providerID: .antigravity,
        primary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: resetAt),
        secondary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: resetAt),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var events: [QuotaResetEvent] = []
    let store = QuotaStore(
        providers: [MockProvider(providerID: .antigravity, quota: quota)],
        defaults: defaults,
        onQuotaReset: { event in
            events.append(event)
            return true
        }
    )

    await store.refresh()

    #expect(events.count == 1)
}

@MainActor
@Test
func quotaResetEventDoesNotRepeatWhileAntigravityStaysFullEvenIfResetTimeChanges() async {
    actor MockProvider: UsageProvider {
        let providerID: ProviderID = .antigravity
        var quotas: [ProviderQuota]

        init(quotas: [ProviderQuota]) {
            self.quotas = quotas
        }

        func fetchQuota() async throws -> ProviderQuota {
            if quotas.count > 1 {
                return quotas.removeFirst()
            }
            return quotas[0]
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetAntigravityStableFull")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetAntigravityStableFull")

    let firstFull = ProviderQuota(
        providerID: .antigravity,
        primary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_700_100_000)),
        secondary: QuotaWindow(name: "Flash", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let stillFullWithDifferentResetTime = ProviderQuota(
        providerID: .antigravity,
        primary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_700_100_060)),
        secondary: QuotaWindow(name: "Flash", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_060)
    )
    var events: [QuotaResetEvent] = []
    let store = QuotaStore(
        providers: [MockProvider(quotas: [firstFull, stillFullWithDifferentResetTime])],
        defaults: defaults,
        onQuotaReset: { event in
            events.append(event)
            return true
        }
    )

    await store.refresh()
    await store.refresh()

    #expect(events.count == 1)
}

@MainActor
@Test
func quotaResetEventCanFireAgainAfterUsageDropsBelowFull() async {
    actor MockProvider: UsageProvider {
        let providerID: ProviderID = .antigravity
        var quotas: [ProviderQuota]

        init(quotas: [ProviderQuota]) {
            self.quotas = quotas
        }

        func fetchQuota() async throws -> ProviderQuota {
            if quotas.count > 1 {
                return quotas.removeFirst()
            }
            return quotas[0]
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetAntigravityRefill")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetAntigravityRefill")

    let full = ProviderQuota(
        providerID: .antigravity,
        primary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_700_100_000)),
        secondary: QuotaWindow(name: "Flash", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let used = ProviderQuota(
        providerID: .antigravity,
        primary: QuotaWindow(name: "Pro", usedPercent: 10, resetAt: Date(timeIntervalSince1970: 1_700_100_060)),
        secondary: QuotaWindow(name: "Flash", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_060)
    )
    let refilled = ProviderQuota(
        providerID: .antigravity,
        primary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_700_200_000)),
        secondary: QuotaWindow(name: "Flash", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_100_000)
    )
    var events: [QuotaResetEvent] = []
    let store = QuotaStore(
        providers: [MockProvider(quotas: [full, used, refilled])],
        defaults: defaults,
        onQuotaReset: { event in
            events.append(event)
            return true
        }
    )

    await store.refresh()
    await store.refresh()
    await store.refresh()

    #expect(events.count == 2)
}

@MainActor
@Test
func selectedProviderPersistsAcrossStoreInstances() {
    let defaults = UserDefaults(suiteName: "QuotaCoreTests.selectedProvider")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.selectedProvider")

    let firstStore = QuotaStore(defaults: defaults)
    firstStore.selectedProviderID = .claude

    let secondStore = QuotaStore(defaults: defaults)
    #expect(secondStore.selectedProviderID == .claude)
}

@MainActor
@Test
func autoRotateSettingPersistsAcrossStoreInstances() {
    let defaults = UserDefaults(suiteName: "QuotaCoreTests.autoRotatePersist")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.autoRotatePersist")

    let firstStore = QuotaStore(defaults: defaults)
    firstStore.autoRotateEnabled = true

    let secondStore = QuotaStore(defaults: defaults)
    #expect(secondStore.autoRotateEnabled)
}

@MainActor
@Test
func expandedProvidersPersistAcrossStoreInstances() {
    let defaults = UserDefaults(suiteName: "QuotaCoreTests.expandedProviders")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.expandedProviders")

    let firstStore = QuotaStore(defaults: defaults)
    #expect(firstStore.isExpanded(.antigravity))
    firstStore.toggleExpanded(.antigravity)

    let secondStore = QuotaStore(defaults: defaults)
    #expect(secondStore.isExpanded(.antigravity) == false)
    #expect(secondStore.isExpanded(.codex))
    #expect(secondStore.isExpanded(.claude))
}

@MainActor
@Test
func refreshIntervalPersistsAcrossStoreInstances() {
    let defaults = UserDefaults(suiteName: "QuotaCoreTests.refreshInterval")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.refreshInterval")

    let firstStore = QuotaStore(defaults: defaults)
    firstStore.refreshIntervalSeconds = 300

    let secondStore = QuotaStore(defaults: defaults)
    #expect(secondStore.refreshIntervalSeconds == 300)
}

@MainActor
@Test
func autoRotateIntervalPersistsAcrossStoreInstances() {
    let defaults = UserDefaults(suiteName: "QuotaCoreTests.autoRotateInterval")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.autoRotateInterval")

    let firstStore = QuotaStore(defaults: defaults)
    firstStore.autoRotateIntervalSeconds = 60

    let secondStore = QuotaStore(defaults: defaults)
    #expect(secondStore.autoRotateIntervalSeconds == 60)
}

@MainActor
@Test
func metricDisplayModePersistsAcrossStoreInstances() {
    let suiteName = "QuotaCoreTests.metricDisplayMode"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let firstStore = QuotaStore(defaults: defaults)
    #expect(firstStore.metricDisplayMode == .remaining)
    firstStore.metricDisplayMode = .usage

    let secondStore = QuotaStore(defaults: defaults)
    #expect(secondStore.metricDisplayMode == .usage)
}

@Suite(.serialized)
struct CodexProviderTests {
    @MainActor
    @Test
    func codexProviderParsesUsageWithNullSecondaryWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaCoreTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let authURL = root.appendingPathComponent("auth.json")
        let authJSON = """
        {
          "tokens": {
            "access_token": "mock-token"
          }
        }
        """
        try authJSON.write(to: authURL, atomically: true, encoding: .utf8)

        let responseJSON = """
        {
          "rate_limit": {
            "allowed": false,
            "limit_reached": true,
            "primary_window": {
              "used_percent": 85,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 12345,
              "reset_at": 1784955439
            },
            "secondary_window": null
          }
        }
        """

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer {
            CodexURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        CodexURLProtocolStub.requestHandler = { request in
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mock-token")

            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (httpResponse, Data(responseJSON.utf8))
        }

        let provider = CodexProvider(session: session, authFileURL: authURL)
        let quota = try await provider.fetchQuota()

        #expect(quota.providerID == .codex)
        #expect(quota.primary.name == "5h")
        #expect(quota.primary.usedPercent == nil)
        #expect(quota.primary.resetAt == nil)
        #expect(quota.primary.remainingPercent == nil)
        
        #expect(quota.secondary.name == "7d")
        #expect(quota.secondary.usedPercent == 85)
        #expect(quota.secondary.resetAt == Date(timeIntervalSince1970: 1784955439))
        #expect(quota.secondary.remainingPercent == 15)
    }

    @MainActor
    @Test
    func codexProviderParsesUsageWithBothWindows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaCoreTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let authURL = root.appendingPathComponent("auth.json")
        let authJSON = """
        {
          "tokens": {
            "access_token": "mock-token-2"
          }
        }
        """
        try authJSON.write(to: authURL, atomically: true, encoding: .utf8)

        let responseJSON = """
        {
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 10,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 1000,
              "reset_at": 1784900000
            },
            "secondary_window": {
              "used_percent": 40,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 5000,
              "reset_at": 1784950000
            }
          }
        }
        """

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer {
            CodexURLProtocolStub.requestHandler = nil
            session.invalidateAndCancel()
        }

        CodexURLProtocolStub.requestHandler = { request in
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")

            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (httpResponse, Data(responseJSON.utf8))
        }

        let provider = CodexProvider(session: session, authFileURL: authURL)
        let quota = try await provider.fetchQuota()

        #expect(quota.providerID == .codex)
        #expect(quota.primary.name == "5h")
        #expect(quota.primary.usedPercent == 10)
        #expect(quota.primary.resetAt == Date(timeIntervalSince1970: 1784900000))
        #expect(quota.primary.remainingPercent == 90)
        
        #expect(quota.secondary.name == "7d")
        #expect(quota.secondary.usedPercent == 40)
        #expect(quota.secondary.resetAt == Date(timeIntervalSince1970: 1784950000))
        #expect(quota.secondary.remainingPercent == 60)
    }
}

private final class CodexURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = CodexURLProtocolStub.requestHandler else {
            client?.urlProtocol(self, didFailWithError: ProviderError.badResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class AntigravityURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = AntigravityURLProtocolStub.requestHandler else {
            client?.urlProtocol(self, didFailWithError: ProviderError.badResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
