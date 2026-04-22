import Foundation
import Testing
@testable import QuotaCore

@Test
func remainingPercentIsClamped() {
    #expect(QuotaWindow(name: "5h", usedPercent: 16, resetAt: nil).remainingPercent == 84)
    #expect(QuotaWindow(name: "5h", usedPercent: 120, resetAt: nil).remainingPercent == 0)
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
