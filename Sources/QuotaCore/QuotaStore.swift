import Foundation
import Observation

@MainActor
@Observable
public final class QuotaStore {
    public private(set) var snapshots: [ProviderSnapshot]
    public private(set) var lastRefresh: Date?
    public var selectedProviderID: ProviderID {
        didSet {
            defaults.set(selectedProviderID.rawValue, forKey: Self.selectedProviderDefaultsKey)
        }
    }
    public var autoRotateEnabled: Bool {
        didSet {
            defaults.set(autoRotateEnabled, forKey: Self.autoRotateEnabledDefaultsKey)
        }
    }

    private let providers: [any UsageProvider]
    private var refreshTask: Task<Void, Never>?
    private var rotateTask: Task<Void, Never>?
    private let refreshInterval: Duration
    private let rotateInterval: Duration
    private let defaults: UserDefaults
    private var isMenuPresented = false

    static let selectedProviderDefaultsKey = "selectedProviderID"
    static let autoRotateEnabledDefaultsKey = "autoRotateEnabled"

    public init(
        providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider(), GeminiProvider()],
        selectedProviderID: ProviderID = .codex,
        refreshInterval: Duration = .seconds(60),
        rotateInterval: Duration = .seconds(30),
        defaults: UserDefaults = .standard
    ) {
        self.providers = providers
        self.defaults = defaults
        self.refreshInterval = refreshInterval
        self.rotateInterval = rotateInterval
        if let persisted = defaults.string(forKey: Self.selectedProviderDefaultsKey),
           let providerID = ProviderID(rawValue: persisted) {
            self.selectedProviderID = providerID
        } else {
            self.selectedProviderID = selectedProviderID
        }
        self.autoRotateEnabled = defaults.bool(forKey: Self.autoRotateEnabledDefaultsKey)
        self.snapshots = providers.map { ProviderSnapshot(providerID: $0.providerID) }
    }

    public func start() {
        guard refreshTask == nil, rotateTask == nil else { return }
        refreshTask = Task {
            await refresh()
            while Task.isCancelled == false {
                try? await Task.sleep(for: refreshInterval)
                await refresh()
            }
        }
        rotateTask = Task {
            while Task.isCancelled == false {
                try? await Task.sleep(for: rotateInterval)
                rotateToNextProviderIfNeeded()
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        rotateTask?.cancel()
        rotateTask = nil
    }

    public func refresh() async {
        await withTaskGroup(of: ProviderSnapshot.self) { group in
            for provider in providers {
                let providerID = provider.providerID
                let previousQuota = snapshot(for: providerID).quota
                updateSnapshot(for: providerID, status: .loading(previousQuota))
                group.addTask {
                    do {
                        let quota = try await provider.fetchQuota()
                        return ProviderSnapshot(providerID: providerID, status: .loaded(quota))
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? "failed"
                        return ProviderSnapshot(providerID: providerID, status: .failed(message))
                    }
                }
            }

            var updated: [ProviderSnapshot] = []
            for await snapshot in group {
                updated.append(snapshot)
            }

            updated.sort { $0.providerID.rawValue < $1.providerID.rawValue }
            for snapshot in updated {
                replaceSnapshot(snapshot)
            }
            lastRefresh = Date()
        }
    }

    public func snapshot(for providerID: ProviderID) -> ProviderSnapshot {
        snapshots.first(where: { $0.providerID == providerID }) ?? ProviderSnapshot(providerID: providerID)
    }

    public var selectedSnapshot: ProviderSnapshot {
        snapshot(for: selectedProviderID)
    }

    public func selectProvider(_ providerID: ProviderID) {
        selectedProviderID = providerID
    }

    public func setMenuPresented(_ presented: Bool) {
        isMenuPresented = presented
    }

    func rotateToNextProviderIfNeeded() {
        guard autoRotateEnabled, isMenuPresented == false else {
            return
        }
        let candidates = rotatableProviderIDs()
        guard candidates.count > 1 else {
            return
        }
        guard let currentIndex = candidates.firstIndex(of: selectedProviderID) else {
            selectedProviderID = candidates[0]
            return
        }
        let nextIndex = candidates.index(after: currentIndex)
        selectedProviderID = nextIndex < candidates.endIndex
            ? candidates[nextIndex]
            : candidates[0]
    }

    func rotatableProviderIDs() -> [ProviderID] {
        ProviderID.allCases.filter { providerID in
            if case .loaded = snapshot(for: providerID).status {
                return true
            }
            return false
        }
    }

    private func updateSnapshot(for providerID: ProviderID, status: ProviderStatus) {
        replaceSnapshot(ProviderSnapshot(providerID: providerID, status: status))
    }

    private func replaceSnapshot(_ snapshot: ProviderSnapshot) {
        if let index = snapshots.firstIndex(where: { $0.providerID == snapshot.providerID }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
        }
    }
}
