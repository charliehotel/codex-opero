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
