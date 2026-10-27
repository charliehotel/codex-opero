import AppKit
import SwiftUI
import QuotaCore

@main
struct QuotaPeekMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: QuotaStore
    @State private var loginItemManager = LoginItemManager()
    @State private var updateChecker: UpdateChecker

    @MainActor
    init() {
        let notifier = QuotaResetNotifier.shared
        let quotaStore = QuotaStore(onQuotaReset: { event in
            await notifier.notify(event)
        })
        quotaStore.start()
        _store = State(initialValue: quotaStore)
        _updateChecker = State(initialValue: .shared)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                store: store,
                loginItemManager: loginItemManager,
                updateChecker: updateChecker
            )
        } label: {
            ProviderTrayLabel(
                providerID: store.selectedProviderID,
                title: store.selectedSnapshot.compactTitle(displayMode: store.metricDisplayMode)
            )
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        OnboardingWindowController.shared.showIfNeeded()
        UpdateChecker.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        UpdateChecker.shared.stop()
    }
}

private struct ContentView: View {
    @Bindable var store: QuotaStore
    @Bindable var loginItemManager: LoginItemManager
    @Bindable var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.selectedProviderID.displayName)
                .font(.headline)

            Text(store.selectedSnapshot.compactTitle(displayMode: store.metricDisplayMode))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()

            Divider()

            ForEach(store.snapshots) { snapshot in
                HStack(spacing: 8) {
                    Button {
                        store.toggleExpanded(snapshot.providerID)
                    } label: {
                        Image(systemName: store.isExpanded(snapshot.providerID) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.selectProvider(snapshot.providerID)
                    } label: {
                        HStack {
                            Text(snapshot.providerID.displayName)
                                .foregroundStyle(snapshot.providerID == store.selectedProviderID ? Color.blue : Color.primary)
                            Spacer()
                            Text(snapshot.compactTitle(displayMode: store.metricDisplayMode))
                                .monospacedDigit()
                                .foregroundStyle(snapshot.providerID == store.selectedProviderID ? Color.blue : Color.primary)
                        }
                        .fontWeight(snapshot.providerID == store.selectedProviderID ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                }

                if store.isExpanded(snapshot.providerID) {
                    VStack(alignment: .leading, spacing: 4) {
                        if case .loaded(let quota) = snapshot.status {
                            if quota.detailGroups.isEmpty {
                                if let primaryUsed = quota.primary.usedPercent {
                                    Text("[\(quota.primary.name)]  \(primaryUsed)% used, \(QuotaFormatter.resetString(for: quota.primary))")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("[\(quota.primary.name)]  --")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                if let secondaryUsed = quota.secondary.usedPercent {
                                    Text("[\(quota.secondary.name)]  \(secondaryUsed)% used, \(QuotaFormatter.resetString(for: quota.secondary))")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("[\(quota.secondary.name)]  --")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                ForEach(quota.detailGroups, id: \.name) { group in
                                    if group.modelNames.isEmpty {
                                        Text(group.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        ForEach(group.windows, id: \.id) { window in
                                            if let used = window.usedPercent {
                                                Text("[\(window.name)]  \(used)% used, \(QuotaFormatter.resetString(for: window))")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                Text("[\(window.name)]  --")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    } else if let window = group.windows.first {
                                        if let used = window.usedPercent {
                                            Text("[\(group.name)]  \(used)% used, \(QuotaFormatter.resetString(for: window))")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("[\(group.name)]  --")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        ForEach(group.modelNames, id: \.self) { modelName in
                                            Text("  - \(modelName)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        } else if case .failed(let message) = snapshot.status {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 22)
                }
            }

            Divider()

            MenuSettingsView(
                store: store,
                loginItemManager: loginItemManager
            )

            Divider()

            footerGroup
        }
        .padding(14)
        .frame(width: 320)
        .task {
            loginItemManager.refreshStatus()
        }
        .onAppear {
            store.setMenuPresented(true)
        }
        .onDisappear {
            store.setMenuPresented(false)
        }
    }

    private var footerGroup: some View {
        HStack {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            Spacer()
            UpdateStatusView(
                currentVersion: updateChecker.currentVersion,
                availableUpdate: updateChecker.availableUpdate
            )
        }
    }
}
