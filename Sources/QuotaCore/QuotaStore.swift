import Foundation
import Observation

@MainActor
@Observable
public final class QuotaStore {
    public static let refreshIntervalOptions: [Int] = [60, 180, 300, 900]
    public static let autoRotateIntervalOptions: [Int] = [10, 30, 60]

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
    public var refreshIntervalSeconds: Int {
        didSet {
            guard oldValue != refreshIntervalSeconds else { return }
            defaults.set(refreshIntervalSeconds, forKey: Self.refreshIntervalDefaultsKey)
            restartRefreshTaskIfNeeded()
        }
    }
    public var autoRotateIntervalSeconds: Int {
        didSet {
            guard oldValue != autoRotateIntervalSeconds else { return }
            defaults.set(autoRotateIntervalSeconds, forKey: Self.autoRotateIntervalDefaultsKey)
            restartRotateTaskIfNeeded()
        }
    }

    private let providers: [any UsageProvider]
    private var refreshTask: Task<Void, Never>?
    private var rotateTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var isMenuPresented = false

    static let selectedProviderDefaultsKey = "selectedProviderID"
    static let autoRotateEnabledDefaultsKey = "autoRotateEnabled"
    static let refreshIntervalDefaultsKey = "refreshIntervalSeconds"
    static let autoRotateIntervalDefaultsKey = "autoRotateIntervalSeconds"

    public init(
        providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider(), GeminiProvider()],
        selectedProviderID: ProviderID = .codex,
        refreshIntervalSeconds: Int = 60,
        autoRotateIntervalSeconds: Int = 30,
        defaults: UserDefaults = .standard
    ) {
        self.providers = providers
        self.defaults = defaults
        if let persisted = defaults.string(forKey: Self.selectedProviderDefaultsKey),
           let providerID = ProviderID(rawValue: persisted) {
            self.selectedProviderID = providerID
        } else {
            self.selectedProviderID = selectedProviderID
        }
        self.autoRotateEnabled = defaults.bool(forKey: Self.autoRotateEnabledDefaultsKey)
        let persistedRefresh = defaults.integer(forKey: Self.refreshIntervalDefaultsKey)
        if Self.refreshIntervalOptions.contains(persistedRefresh) {
            self.refreshIntervalSeconds = persistedRefresh
        } else {
            self.refreshIntervalSeconds = refreshIntervalSeconds
        }
        let persistedRotate = defaults.integer(forKey: Self.autoRotateIntervalDefaultsKey)
        if Self.autoRotateIntervalOptions.contains(persistedRotate) {
            self.autoRotateIntervalSeconds = persistedRotate
        } else {
            self.autoRotateIntervalSeconds = autoRotateIntervalSeconds
        }
        self.snapshots = providers.map { ProviderSnapshot(providerID: $0.providerID) }
    }

    public func start() {
        guard refreshTask == nil, rotateTask == nil else { return }
        startRefreshTask()
        startRotateTask()
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        rotateTask?.cancel()
        rotateTask = nil
    }

    private func startRefreshTask() {
        refreshTask = Task {
            await refresh()
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(refreshIntervalSeconds))
                await refresh()
            }
        }
    }

    private func startRotateTask() {
        rotateTask = Task {
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(autoRotateIntervalSeconds))
                rotateToNextProviderIfNeeded()
            }
        }
    }

    private func restartRefreshTaskIfNeeded() {
        guard refreshTask != nil else { return }
        refreshTask?.cancel()
        startRefreshTask()
    }

    private func restartRotateTaskIfNeeded() {
        guard rotateTask != nil else { return }
        rotateTask?.cancel()
        startRotateTask()
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

    public var refreshIntervalLabel: String {
        Self.label(forRefreshIntervalSeconds: refreshIntervalSeconds)
    }

    public var autoRotateIntervalLabel: String {
        Self.label(forAutoRotateIntervalSeconds: autoRotateIntervalSeconds)
    }

    public static func label(forRefreshIntervalSeconds seconds: Int) -> String {
        switch seconds {
        case 60:
            return "1 min"
        case 180:
            return "3 min"
        case 300:
            return "5 min"
        case 900:
            return "15 min"
        default:
            return "\(seconds) sec"
        }
    }

    public static func label(forAutoRotateIntervalSeconds seconds: Int) -> String {
        switch seconds {
        case 10:
            return "10 sec"
        case 30:
            return "30 sec"
        case 60:
            return "60 sec"
        default:
            return "\(seconds) sec"
        }
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
