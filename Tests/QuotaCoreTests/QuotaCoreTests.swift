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
func selectedProviderPersistsAcrossStoreInstances() {
    let defaults = UserDefaults(suiteName: "QuotaCoreTests.selectedProvider")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.selectedProvider")

    let firstStore = QuotaStore(defaults: defaults)
    firstStore.selectedProviderID = .claude

    let secondStore = QuotaStore(defaults: defaults)
    #expect(secondStore.selectedProviderID == .claude)
}
