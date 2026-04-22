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

    private let providers: [any UsageProvider]
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: Duration
    private let defaults: UserDefaults

    static let selectedProviderDefaultsKey = "selectedProviderID"

    public init(
        providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider(), GeminiProvider()],
        selectedProviderID: ProviderID = .codex,
        refreshInterval: Duration = .seconds(60),
        defaults: UserDefaults = .standard
    ) {
        self.providers = providers
        self.defaults = defaults
        self.refreshInterval = refreshInterval
        if let persisted = defaults.string(forKey: Self.selectedProviderDefaultsKey),
           let providerID = ProviderID(rawValue: persisted) {
            self.selectedProviderID = providerID
        } else {
            self.selectedProviderID = selectedProviderID
        }
        self.snapshots = providers.map { ProviderSnapshot(providerID: $0.providerID) }
    }

    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            await refresh()
            while Task.isCancelled == false {
                try? await Task.sleep(for: refreshInterval)
                await refresh()
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refresh() async {
        await withTaskGroup(of: ProviderSnapshot.self) { group in
            for provider in providers {
                let providerID = provider.providerID
                updateSnapshot(for: providerID, status: .loading)
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
