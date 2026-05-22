import Foundation
import Testing
@testable import QuotaCore

@Test
func remainingPercentIsClamped() {
    #expect(QuotaWindow(name: "5h", usedPercent: 16, resetAt: nil).remainingPercent == 84)
    #expect(QuotaWindow(name: "5h", usedPercent: 120, resetAt: nil).remainingPercent == 0)
}

@Test
func resetStringUsesEnglishCompactUnits() {
    let window = QuotaWindow(
        name: "5h",
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
func updateCheckPolicyUsesWeeklyCadence() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(UpdateCheckPolicy.shouldCheck(now: now, lastCheckedAt: nil))
    #expect(UpdateCheckPolicy.shouldCheck(now: now, lastCheckedAt: now.addingTimeInterval(-UpdateCheckPolicy.checkInterval)))
    #expect(UpdateCheckPolicy.shouldCheck(now: now, lastCheckedAt: now.addingTimeInterval(-60)) == false)
}

@Test
func updateCheckPolicyComputesNextCheckDelay() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(UpdateCheckPolicy.nextCheckDelay(now: now, lastCheckedAt: nil) == 0)
    #expect(UpdateCheckPolicy.nextCheckDelay(now: now, lastCheckedAt: now.addingTimeInterval(-60)) == UpdateCheckPolicy.checkInterval - 60)
    #expect(UpdateCheckPolicy.nextCheckDelay(now: now, lastCheckedAt: now.addingTimeInterval(-UpdateCheckPolicy.checkInterval)) == 0)
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
func updateCheckPolicySuppressesRepeatedPromptWithinCadence() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(UpdateCheckPolicy.shouldPrompt(
        version: "0.1.6",
        now: now,
        lastPromptedVersion: nil,
        lastPromptedAt: nil
    ))
    #expect(UpdateCheckPolicy.shouldPrompt(
        version: "0.1.6",
        now: now,
        lastPromptedVersion: "0.1.6",
        lastPromptedAt: now.addingTimeInterval(-60)
    ) == false)
    #expect(UpdateCheckPolicy.shouldPrompt(
        version: "0.1.7",
        now: now,
        lastPromptedVersion: "0.1.6",
        lastPromptedAt: now.addingTimeInterval(-60)
    ))
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
func geminiProviderIDHasDisplayName() {
    #expect(ProviderID.gemini.displayName == "Gemini")
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
        usageExecutableURL: nil
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
        usageExecutableURL: nil
    ).fetchQuota()

    #expect(quota.primary.usedPercent == 20)
    #expect(quota.secondary.usedPercent == 100)
    #expect(quota.detailGroups[0].windows.first?.usedPercent == 20)
    #expect(quota.detailGroups[1].windows.first?.usedPercent == 100)
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
        usageTimeout: 2
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
        usageTimeout: 2
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
        usageTimeout: 2
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
            usageTimeout: 5
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
            usageTimeout: 1
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
    let geminiQuota = ProviderQuota(
        providerID: .gemini,
        primary: QuotaWindow(name: "Pro", usedPercent: 30, resetAt: nil),
        secondary: QuotaWindow(name: "Flash", usedPercent: 40, resetAt: nil),
        fetchedAt: Date()
    )

    let store = QuotaStore(
        providers: [
            MockProvider(providerID: .codex, quota: codexQuota),
            MockProvider(providerID: .claude, quota: nil),
            MockProvider(providerID: .gemini, quota: geminiQuota),
        ],
        defaults: defaults
    )
    store.autoRotateEnabled = true
    await store.refresh()

    #expect(store.rotatableProviderIDs() == [.codex, .gemini])

    store.rotateToNextProviderIfNeeded()
    #expect(store.selectedProviderID == .gemini)

    store.rotateToNextProviderIfNeeded()
    #expect(store.selectedProviderID == .codex)
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
func quotaResetEventUsesGeminiMenuBuckets() async {
    struct MockProvider: UsageProvider {
        let providerID: ProviderID
        let quota: ProviderQuota

        func fetchQuota() async throws -> ProviderQuota {
            quota
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetGemini")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetGemini")

    let quota = ProviderQuota(
        providerID: .gemini,
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
        providers: [MockProvider(providerID: .gemini, quota: quota)],
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
            providerID: .gemini,
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
func quotaResetEventDeduplicatesIdenticalGeminiMarkers() async {
    struct MockProvider: UsageProvider {
        let providerID: ProviderID
        let quota: ProviderQuota

        func fetchQuota() async throws -> ProviderQuota {
            quota
        }
    }

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetGeminiDuplicate")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetGeminiDuplicate")

    let resetAt = Date(timeIntervalSince1970: 1_700_100_000)
    let quota = ProviderQuota(
        providerID: .gemini,
        primary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: resetAt),
        secondary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: resetAt),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var events: [QuotaResetEvent] = []
    let store = QuotaStore(
        providers: [MockProvider(providerID: .gemini, quota: quota)],
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
func quotaResetEventDoesNotRepeatWhileGeminiStaysFullEvenIfResetTimeChanges() async {
    actor MockProvider: UsageProvider {
        let providerID: ProviderID = .gemini
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

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetGeminiStableFull")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetGeminiStableFull")

    let firstFull = ProviderQuota(
        providerID: .gemini,
        primary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_700_100_000)),
        secondary: QuotaWindow(name: "Flash", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let stillFullWithDifferentResetTime = ProviderQuota(
        providerID: .gemini,
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
        let providerID: ProviderID = .gemini
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

    let defaults = UserDefaults(suiteName: "QuotaCoreTests.quotaResetGeminiRefill")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.quotaResetGeminiRefill")

    let full = ProviderQuota(
        providerID: .gemini,
        primary: QuotaWindow(name: "Pro", usedPercent: 0, resetAt: Date(timeIntervalSince1970: 1_700_100_000)),
        secondary: QuotaWindow(name: "Flash", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let used = ProviderQuota(
        providerID: .gemini,
        primary: QuotaWindow(name: "Pro", usedPercent: 10, resetAt: Date(timeIntervalSince1970: 1_700_100_060)),
        secondary: QuotaWindow(name: "Flash", usedPercent: 20, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_060)
    )
    let refilled = ProviderQuota(
        providerID: .gemini,
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
    #expect(firstStore.isExpanded(.gemini))
    firstStore.toggleExpanded(.gemini)
    firstStore.toggleExpanded(.antigravity)

    let secondStore = QuotaStore(defaults: defaults)
    #expect(secondStore.isExpanded(.gemini) == false)
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
