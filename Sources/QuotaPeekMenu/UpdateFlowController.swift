import AppKit
import QuotaCore

/// Drives the manual update flow: check, release notes, download to the Desktop, and install.
@MainActor
final class UpdateFlowController {
    static let shared = UpdateFlowController()

    private let checker = UpdateChecker.shared
    private var isRunning = false
    private var progressPanel: UpdateProgressPanel?
    private var downloader: UpdateDownloader?

    func checkForUpdates() {
        guard isRunning == false else {
            progressPanel?.show()
            return
        }
        isRunning = true
        Task { @MainActor in
            defer { isRunning = false }
            switch await checker.checkNow() {
            case .upToDate(let version):
                showAlert(
                    title: "최신 버전을 사용하고 있습니다",
                    message: "현재 사용 중인 버전은 \(version.displayString)입니다."
                )
            case .failed(let message):
                showAlert(title: "업데이트를 확인할 수 없습니다", message: message, style: .warning)
            case .available(let offer):
                await offerUpdate(offer)
            case .inProgress:
                break
            }
        }
    }

    /// Reports a failure recorded by the install script during the previous update attempt.
    func reportPreviousInstallFailureIfNeeded() {
        let marker = UpdateInstaller.failureMarkerURL
        guard let message = try? String(contentsOf: marker, encoding: .utf8) else {
            return
        }
        try? FileManager.default.removeItem(at: marker)
        showAlert(
            title: "업데이트를 설치하지 못했습니다",
            message: message.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n데스크탑에 받은 DMG를 열어 직접 설치해 주세요.",
            style: .warning
        )
    }

    // MARK: - Steps

    private func offerUpdate(_ offer: UpdateOffer) async {
        let alert = NSAlert()
        alert.messageText = "새 버전을 발견했습니다: \(offer.update.latestVersion.displayString)"
        alert.informativeText = "현재 버전은 \(offer.update.currentVersion.displayString)입니다. 업데이트하시겠습니까?"
        alert.accessoryView = Self.releaseNotesView(offer.notes)
        alert.addButton(withTitle: offer.asset == nil ? "릴리즈 페이지 열기" : "업데이트")
        alert.addButton(withTitle: "나중에")
        guard run(alert) == .alertFirstButtonReturn else {
            return
        }
        guard let asset = offer.asset else {
            NSWorkspace.shared.open(offer.update.releaseURL)
            return
        }
        await download(asset, offer: offer)
    }

    private func download(_ asset: ReleaseAssetInfo, offer: UpdateOffer) async {
        let version = offer.update.latestVersion
        let panel = UpdateProgressPanel(title: "\(version.displayString) 다운로드 중…") { [weak self] in
            self?.downloader?.cancel()
        }
        progressPanel = panel
        panel.show()

        let downloader = UpdateDownloader()
        self.downloader = downloader
        let result: Result<URL, Error>
        do {
            result = .success(try await downloader.download(asset, version: version) { fraction in
                Task { @MainActor in panel.update(fraction: fraction) }
            })
        } catch {
            result = .failure(error)
        }
        self.downloader = nil
        panel.close()
        progressPanel = nil

        switch result {
        case .success(let dmgURL):
            offerInstall(dmgURL: dmgURL, version: version)
        case .failure(UpdateError.cancelled):
            break
        case .failure(let error):
            showAlert(title: "업데이트를 다운로드하지 못했습니다", message: UpdateError.message(for: error), style: .warning)
        }
    }

    private func offerInstall(dmgURL: URL, version: AppVersion) {
        guard let installTarget = UpdateInstaller.installTarget() else {
            showAlert(
                title: "다운로드가 완료되었습니다",
                message: "데스크탑에 저장했습니다: \(dmgURL.lastPathComponent)\n현재 위치의 앱은 자동으로 교체할 수 없어 DMG를 엽니다."
            )
            NSWorkspace.shared.open(dmgURL)
            return
        }

        let alert = NSAlert()
        alert.messageText = "다운로드가 완료되었습니다"
        alert.informativeText = "데스크탑에 저장했습니다: \(dmgURL.lastPathComponent)\n지금 설치하고 앱을 다시 시작할까요?"
        alert.addButton(withTitle: "설치 후 재시작")
        alert.addButton(withTitle: "나중에")
        guard run(alert) == .alertFirstButtonReturn else {
            NSWorkspace.shared.activateFileViewerSelecting([dmgURL])
            return
        }

        do {
            try UpdateInstaller.install(dmgURL: dmgURL, expectedVersion: version, target: installTarget)
            NSApp.terminate(nil)
        } catch {
            showAlert(
                title: "업데이트를 설치하지 못했습니다",
                message: UpdateError.message(for: error) + "\n데스크탑에 받은 DMG를 열어 직접 설치해 주세요.",
                style: .warning
            )
            NSWorkspace.shared.activateFileViewerSelecting([dmgURL])
        }
    }

    // MARK: - Alerts

    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        run(alert)
    }

    @discardableResult
    private func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        return alert.runModal()
    }

    private static func releaseNotesView(_ notes: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributedNotes(notes.isEmpty ? "릴리즈 노트가 없습니다." : notes))
        scrollView.documentView = textView
        return scrollView
    }

    private static func attributedNotes(_ notes: String) -> NSAttributedString {
        let size = NSFont.smallSystemFontSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: notes, options: options) else {
            return NSAttributedString(string: notes, attributes: base)
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            } else if intent.contains(.stronglyEmphasized) {
                attributes[.font] = NSFont.boldSystemFont(ofSize: size)
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

// MARK: - Progress panel

@MainActor
private final class UpdateProgressPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let indicator = NSProgressIndicator()
    private let onCancel: () -> Void

    init(title: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "codex-opero 업데이트"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let label = NSTextField(labelWithString: title)
        indicator.isIndeterminate = true
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.startAnimation(nil)
        let cancelButton = NSButton(title: "취소", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), cancelButton])
        let stack = NSStackView(views: [label, indicator, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttonRow.widthAnchor.constraint(equalTo: indicator.widthAnchor),
        ])
        panel.contentView = content
        panel.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func update(fraction: Double) {
        if indicator.isIndeterminate {
            indicator.stopAnimation(nil)
            indicator.isIndeterminate = false
        }
        indicator.doubleValue = fraction
    }

    func close() {
        panel.delegate = nil
        panel.close()
    }

    @objc private func cancel() {
        onCancel()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCancel()
        return false
    }
}
