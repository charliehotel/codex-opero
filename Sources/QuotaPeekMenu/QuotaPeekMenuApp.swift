import SwiftUI
import QuotaCore

@main
struct QuotaPeekMenuApp: App {
    @State private var store = QuotaStore()
    @State private var loginItemManager = LoginItemManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store, loginItemManager: loginItemManager)
        } label: {
            Text(store.selectedSnapshot.menuTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct ContentView: View {
    @Bindable var store: QuotaStore
    @Bindable var loginItemManager: LoginItemManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.selectedProviderID.displayName)
                .font(.headline)

            Text(store.selectedSnapshot.menuTitle)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()

            Divider()

            ForEach(store.snapshots) { snapshot in
                Button {
                    store.selectedProviderID = snapshot.providerID
                } label: {
                    HStack {
                        Text(snapshot.providerID.displayName)
                            .foregroundStyle(snapshot.providerID == store.selectedProviderID ? Color.blue : Color.black)
                        Spacer()
                        Text(snapshot.menuTitle)
                            .monospacedDigit()
                            .foregroundStyle(snapshot.providerID == store.selectedProviderID ? Color.blue : Color.black)
                    }
                    .fontWeight(snapshot.providerID == store.selectedProviderID ? .semibold : .regular)
                }
                .buttonStyle(.plain)

                if case .loaded(let quota) = snapshot.status {
                    Text("\(quota.primary.name): \(quota.primary.usedPercent)% used, \(QuotaFormatter.resetString(for: quota.primary))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(quota.secondary.name): \(quota.secondary.usedPercent)% used, \(QuotaFormatter.resetString(for: quota.secondary))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .failed(let message) = snapshot.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 320)
        .task {
            store.start()
            loginItemManager.refreshStatus()
        }
    }
}
