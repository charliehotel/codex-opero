import AppKit

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private let defaults = UserDefaults.standard
    private let suppressionKey = "suppressMenuBarOnboarding"
    private var hasShownThisLaunch = false
    private var panel: NSPanel?
    private var suppressionCheckbox: NSButton?

    func showIfNeeded() {
        guard defaults.bool(forKey: suppressionKey) == false else {
            return
        }
        guard hasShownThisLaunch == false else {
            return
        }
        hasShownThisLaunch = true

        DispatchQueue.main.async {
            self.presentPanel()
        }
    }

    private func presentPanel() {
        if panel != nil {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 279),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "codex-opero"
        panel.center()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = makeContentView()

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeContentView() -> NSView {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 279))

        let imageView = NSImageView(frame: .zero)
        imageView.image = OnboardingImageLoader.image()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let checkbox = NSButton(checkboxWithTitle: "Don't show again", target: nil, action: nil)
        checkbox.setButtonType(.switch)
        checkbox.font = .systemFont(ofSize: 13)
        checkbox.alignment = .left
        self.suppressionCheckbox = checkbox

        let okButton = NSButton(title: "OK", target: self, action: #selector(handleOK))
        okButton.bezelStyle = .rounded
        okButton.controlSize = .small
        okButton.keyEquivalent = "\r"
        okButton.translatesAutoresizingMaskIntoConstraints = false
        okButton.widthAnchor.constraint(equalToConstant: 88).isActive = true

        let buttonRow = NSStackView(views: [checkbox, NSView(), okButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [imageView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            imageView.widthAnchor.constraint(equalToConstant: 396),
            imageView.heightAnchor.constraint(equalToConstant: 223),

            buttonRow.widthAnchor.constraint(equalTo: imageView.widthAnchor),
        ])

        return contentView
    }

    @objc
    private func handleOK() {
        if suppressionCheckbox?.state == .on {
            defaults.set(true, forKey: suppressionKey)
        }
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        if suppressionCheckbox?.state == .on {
            defaults.set(true, forKey: suppressionKey)
        }
        panel = nil
    }
}

private enum OnboardingImageLoader {
    static func image() -> NSImage? {
        if let bundleImage = loadFromBundle() {
            return bundleImage
        }
        return loadFromRepository()
    }

    private static func loadFromBundle() -> NSImage? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }
        return NSImage(contentsOf: resourceURL.appendingPathComponent("popup.png"))
    }

    private static func loadFromRepository() -> NSImage? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/popup.png")
        return NSImage(contentsOf: url)
    }
}
