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
                title: store.selectedSnapshot.menuTitle
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

            Text(store.selectedSnapshot.menuTitle)
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
                            Text(snapshot.menuTitle)
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
                                Text("[\(quota.primary.name)]  \(quota.primary.usedPercent)% used, \(QuotaFormatter.resetString(for: quota.primary))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("[\(quota.secondary.name)]  \(quota.secondary.usedPercent)% used, \(QuotaFormatter.resetString(for: quota.secondary))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(quota.detailGroups, id: \.name) { group in
                                    if group.modelNames.isEmpty {
                                        Text(group.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        ForEach(group.windows, id: \.id) { window in
                                            Text("[\(window.name)]  \(window.usedPercent)% used, \(QuotaFormatter.resetString(for: window))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } else if let window = group.windows.first {
                                        Text("[\(group.name)]  \(window.usedPercent)% used, \(QuotaFormatter.resetString(for: window))")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
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

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Refresh")
                    Spacer()
                    Picker("Refresh", selection: $store.refreshIntervalSeconds) {
                        ForEach(QuotaStore.refreshIntervalOptions, id: \.self) { seconds in
                            Text(QuotaStore.label(forRefreshIntervalSeconds: seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                Toggle("Auto Rotate", isOn: $store.autoRotateEnabled)

                if store.autoRotateEnabled {
                    Picker("Rotate Interval", selection: $store.autoRotateIntervalSeconds) {
                        ForEach(QuotaStore.autoRotateIntervalOptions, id: \.self) { seconds in
                            Text(QuotaStore.label(forAutoRotateIntervalSeconds: seconds)).tag(seconds)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { loginItemManager.isEnabled },
                set: { loginItemManager.setEnabled($0) }
            )) {
                Text("Launch at Login")
            }
            .disabled(loginItemManager.isAvailable == false)

            if let errorMessage = loginItemManager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Refresh Now") {
                    Task { await store.refresh() }
                }
                Spacer()
                if let lastRefresh = store.lastRefresh {
                    Text(QuotaFormatter.timestampString(lastRefresh))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

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
}
