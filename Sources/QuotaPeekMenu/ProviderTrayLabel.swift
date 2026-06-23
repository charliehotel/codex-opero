import AppKit
import SwiftUI
import QuotaCore

struct ProviderTrayLabel: View {
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

private enum ProviderTrayIcon {
    static func image(for providerID: ProviderID) -> NSImage? {
        let baseName: String = switch providerID {
        case .codex:
            "TrayIcon-Codex"
        case .claude:
            "TrayIcon-Claude"
        case .antigravity:
            "TrayIcon-Antigravity"
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
