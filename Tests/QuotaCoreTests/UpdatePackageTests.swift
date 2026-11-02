import Foundation
import Testing
@testable import QuotaCore

private let digest = "sha256:811b6b2959f85b64423a1f628d6687c7bf08fe85832ccd75044c5a7b77d950d2"

private func asset(name: String = "codex-opero.dmg", url: String = "https://github.com/charliehotel/codex-opero/releases/download/v0.2.9/codex-opero.dmg",
                   size: Int = 10, digest: String? = digest) -> ReleaseAssetInfo {
    ReleaseAssetInfo(name: name, downloadURL: URL(string: url)!, size: size, digest: digest)
}

@Test
func updateAssetSelectorRequiresGitHubDMGWithDigest() {
    #expect(UpdateAssetSelector.dmgAsset(in: [asset(name: "notes.txt"), asset()]) == asset())
    #expect(UpdateAssetSelector.dmgAsset(in: [asset(digest: nil)]) == nil)
    #expect(UpdateAssetSelector.dmgAsset(in: [asset(digest: "sha1:abc")]) == nil)
    #expect(UpdateAssetSelector.dmgAsset(in: [asset(url: "http://github.com/a/codex-opero.dmg")]) == nil)
    #expect(UpdateAssetSelector.dmgAsset(in: [asset(url: "https://example.com/codex-opero.dmg")]) == nil)
    #expect(UpdateAssetSelector.dmgAsset(in: [asset(size: 0)]) == nil)
    #expect(asset(digest: "sha256:" + digest.dropFirst(7).uppercased()).sha256 == String(digest.dropFirst(7)))
}

@Test
func releaseNotesPickLanguageSectionAndFlattenBlocks() {
    let body = """
    # codex-opero v0.2.9

    ## 한국어

    한국어 요약입니다.

    ### 변경 사항

    - **수정**: `security` 사용

    ## English

    English summary.

    ### Changes

    - **Fix**: use `security`
    """

    #expect(UpdateReleaseNotes.displayText(body, preferKorean: true) == """
    한국어 요약입니다.

    **변경 사항**

    • **수정**: `security` 사용
    """)
    #expect(UpdateReleaseNotes.displayText(body, preferKorean: false) == """
    English summary.

    **Changes**

    • **Fix**: use `security`
    """)
    #expect(UpdateReleaseNotes.displayText("Plain notes.\n- item", preferKorean: true) == "Plain notes.\n• item")
}

@Test
func downloadLocationReusesIdenticalFileAndAvoidsOthers() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let version = try #require(AppVersion("0.3.0"))
    let payload = Data("dmg".utf8)
    let source = directory.appendingPathComponent("source")
    try payload.write(to: source)
    let sha = try UpdateFileDigest.sha256(of: source)

    let first = UpdateDownloadLocation.destination(in: directory, version: version, sha256: sha)
    #expect(first.url.lastPathComponent == "codex-opero-v0.3.0.dmg")
    #expect(first.alreadyPresent == false)

    try Data("other".utf8).write(to: first.url)
    let second = UpdateDownloadLocation.destination(in: directory, version: version, sha256: sha)
    #expect(second.url.lastPathComponent == "codex-opero-v0.3.0 (2).dmg")
    #expect(second.alreadyPresent == false)

    try payload.write(to: second.url)
    let reused = UpdateDownloadLocation.destination(in: directory, version: version, sha256: sha)
    #expect(reused.url == second.url)
    #expect(reused.alreadyPresent)
}

@Test
func fileDigestMatchesKnownSHA256() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try UpdateFileDigest.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

private struct InstallScriptRun {
    let root: URL
    let target: URL
    let staged: URL
    let marker: URL
    let staging: URL
    let opened: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        target = root.appendingPathComponent("Applications/codex-opero.app")
        staging = root.appendingPathComponent("staging")
        staged = staging.appendingPathComponent("codex-opero.app")
        marker = root.appendingPathComponent("support/failed.txt")
        opened = root.appendingPathComponent("opened.txt")
        for (app, version) in [(target, "old"), (staged, "new")] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(version.utf8).write(to: app.appendingPathComponent("Contents/version"))
        }
        // Stub `open` so the test records the relaunch instead of launching anything.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let open = bin.appendingPathComponent("open")
        try "#!/bin/sh\nprintf '%s' \"$1\" > '\(opened.path)'\n".write(to: open, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
    }

    func run(pid: Int32) throws -> Int32 {
        let script = root.appendingPathComponent("install.zsh")
        try UpdateInstallScript.source.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, String(pid), target.path, staged.path, marker.path, staging.path]
        process.environment = ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func installedVersion() throws -> String {
        String(decoding: try Data(contentsOf: target.appendingPathComponent("Contents/version")), as: UTF8.self)
    }
}

@Test
func installScriptSwapsAppAfterProcessExitsAndRelaunches() throws {
    let run = try InstallScriptRun()
    defer { try? FileManager.default.removeItem(at: run.root) }
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["0.5"]
    try sleeper.run()

    #expect(try run.run(pid: sleeper.processIdentifier) == 0)
    #expect(sleeper.isRunning == false)
    #expect(try run.installedVersion() == "new")
    #expect(FileManager.default.fileExists(atPath: run.staging.path) == false)
    #expect(FileManager.default.fileExists(atPath: run.marker.path) == false)
    #expect(FileManager.default.fileExists(atPath: run.target.deletingLastPathComponent().appendingPathComponent(".codex-opero-previous.app").path) == false)
    #expect(try String(contentsOf: run.opened, encoding: .utf8) == run.target.path)
}

@Test
func installScriptRestoresPreviousAppWhenCopyFails() throws {
    let run = try InstallScriptRun()
    defer { try? FileManager.default.removeItem(at: run.root) }
    try FileManager.default.removeItem(at: run.staged)

    #expect(try run.run(pid: 999_999) == 1)
    #expect(try run.installedVersion() == "old")
    #expect(try String(contentsOf: run.marker, encoding: .utf8).contains("기존 앱으로 되돌렸습니다"))
    #expect(try String(contentsOf: run.opened, encoding: .utf8) == run.target.path)
}
