import AppKit
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
            ProviderTrayLabel(
                providerID: store.selectedProviderID,
                title: store.selectedSnapshot.menuTitle
            )
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
                    store.selectProvider(snapshot.providerID)
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

            Toggle("Auto Rotate", isOn: $store.autoRotateEnabled)

            Text("Rotates every 30 seconds and skips unavailable providers.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .onAppear {
            store.setMenuPresented(true)
        }
        .onDisappear {
            store.setMenuPresented(false)
        }
    }
}

private enum ProviderTrayIcon {
    static func image(for providerID: ProviderID) -> NSImage? {
        let baseName: String = switch providerID {
        case .codex:
            "TrayIcon-Codex"
        case .claude:
            "TrayIcon-Claude"
        case .gemini:
            "TrayIcon-Gemini"
        }

        if let bundled = loadFromBundle(named: baseName) {
            return bundled
        }
        return loadFromRepository(named: baseName)
    }

    private static func loadFromBundle(named baseName: String) -> NSImage? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }
        let standardURL = resourceURL.appendingPathComponent("\(baseName).png")
        let retinaURL = resourceURL.appendingPathComponent("\(baseName)@2x.png")
        return loadImage(standardURL: standardURL, retinaURL: retinaURL)
    }

    private static func loadFromRepository(named baseName: String) -> NSImage? {
        let baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
        let standardURL = baseURL.appendingPathComponent("\(baseName).png")
        let retinaURL = baseURL.appendingPathComponent("\(baseName)@2x.png")
        return loadImage(standardURL: standardURL, retinaURL: retinaURL)
    }

    private static func loadImage(standardURL: URL, retinaURL: URL) -> NSImage? {
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.isTemplate = true

        if let standard = NSImage(contentsOf: standardURL) {
            standard.representations.forEach { image.addRepresentation($0) }
        }
        if let retina = NSImage(contentsOf: retinaURL) {
            retina.representations.forEach { image.addRepresentation($0) }
        }

        return image.representations.isEmpty ? nil : image
    }
}

private struct ProviderTrayLabel: View {
    let providerID: ProviderID
    let title: String

    var body: some View {
        Image(
            nsImage: ProviderTrayLabelRenderer.makeImage(
                icon: ProviderTrayIcon.image(for: providerID),
                title: title
            )
        )
    }
}

@MainActor
private enum ProviderTrayLabelRenderer {
    private static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    }
    private static let iconSize = NSSize(width: 14, height: 14)

    static func makeImage(icon: NSImage?, title: String) -> NSImage {
        let titleText = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
            ]
        )

        let titleSize = titleText.size()
        let totalWidth = ceil((icon == nil ? 0 : iconSize.width) + titleSize.width)
        let totalHeight = ceil(max(titleSize.height, iconSize.height))

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        image.lockFocus()

        if let icon {
            let iconY = floor((totalHeight - iconSize.height) / 2)
            icon.draw(
                in: NSRect(origin: NSPoint(x: 0, y: iconY), size: iconSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }

        let titleX = icon == nil ? 0 : iconSize.width
        let titleY = floor((totalHeight - titleSize.height) / 2)
        titleText.draw(at: NSPoint(x: titleX, y: titleY))

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
