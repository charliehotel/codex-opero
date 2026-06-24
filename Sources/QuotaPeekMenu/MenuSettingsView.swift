import AppKit
import SwiftUI
import QuotaCore

struct MenuSettingsView: View {
    @Bindable var store: QuotaStore
    @Bindable var loginItemManager: LoginItemManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            refreshRow
            rotateRow

            HStack {
                settingsLabel("Launch at Login")
                Spacer()
                Toggle(isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { loginItemManager.setEnabled($0) }
                )) {
                    Text("Launch at Login")
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(loginItemManager.isAvailable == false)
            }

            if let errorMessage = loginItemManager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var refreshRow: some View {
        HStack(spacing: 8) {
            symbolButton(systemName: "arrow.clockwise", label: "Refresh now") {
                Task { await store.refresh() }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                settingsLabel("Refresh")
                statusText(lastRefreshLabel, color: .secondaryLabelColor)
            }

            Spacer(minLength: 8)

            intervalLabel
            refreshIntervalPicker
        }
    }

    private var rotateRow: some View {
        HStack(spacing: 8) {
            symbolButton(systemName: "arrow.triangle.2.circlepath", label: "Toggle auto rotate") {
                store.autoRotateEnabled.toggle()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                settingsLabel("Rotate")
                statusText(rotateStatusLabel, color: rotateStatusColor)
            }

            Spacer(minLength: 8)

            intervalLabel
            autoRotateIntervalPicker
                .disabled(store.autoRotateEnabled == false)
                .opacity(store.autoRotateEnabled ? 1 : 0.45)
        }
    }

    private var intervalLabel: some View {
        Text("Interval")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var lastRefreshLabel: String {
        guard let lastRefresh = store.lastRefresh else {
            return "--:--"
        }
        return QuotaFormatter.timestampString(lastRefresh)
    }

    private var rotateStatusLabel: String {
        store.autoRotateEnabled ? "On" : "Off"
    }

    private var rotateStatusColor: NSColor {
        store.autoRotateEnabled ? .systemGreen : .secondaryLabelColor
    }

    private var refreshIntervalPicker: some View {
        Picker("Refresh Interval", selection: $store.refreshIntervalSeconds) {
            ForEach(QuotaStore.refreshIntervalOptions, id: \.self) { seconds in
                Text(QuotaStore.label(forRefreshIntervalSeconds: seconds)).tag(seconds)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 76)
    }

    private var autoRotateIntervalPicker: some View {
        Picker("Rotate Interval", selection: $store.autoRotateIntervalSeconds) {
            ForEach(QuotaStore.autoRotateIntervalOptions, id: \.self) { seconds in
                Text(QuotaStore.label(forAutoRotateIntervalSeconds: seconds)).tag(seconds)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 76)
    }

    private func settingsLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.primary)
    }

    private func statusText(_ title: String, color: NSColor) -> some View {
        Text(title)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: color))
    }

    private func symbolButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(label)
        .accessibilityLabel(label)
    }
}
