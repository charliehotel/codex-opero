import AppKit
import QuotaCore

enum UpdateError: Error {
    case cancelled
    case badResponse(Int)
    case sizeMismatch
    case checksumMismatch
    case mountFailed
    case appMissing
    case invalidApp(String)
    case launchFailed

    static func message(for error: Error) -> String {
        switch error {
        case UpdateError.badResponse(let status):
            return "다운로드 서버가 오류를 반환했습니다 (HTTP \(status))."
        case UpdateError.sizeMismatch, UpdateError.checksumMismatch:
            return "받은 파일이 GitHub 릴리즈의 파일과 일치하지 않아 삭제했습니다."
        case UpdateError.mountFailed:
            return "DMG를 열 수 없습니다."
        case UpdateError.appMissing:
            return "DMG에서 codex-opero.app을 찾을 수 없습니다."
        case UpdateError.invalidApp(let reason):
            return "새 앱을 확인하지 못했습니다: \(reason)"
        case UpdateError.launchFailed:
            return "설치 도우미를 실행하지 못했습니다."
        default:
            return "파일을 받거나 저장하지 못했습니다. 네트워크 연결과 데스크탑 폴더 접근 권한을 확인해 주세요."
        }
    }
}

// MARK: - Download

final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: (@Sendable (Double) -> Void)?
    private var cancelled = false

    /// Downloads the asset, verifies its size and SHA-256, and stores it on the Desktop.
    func download(
        _ asset: ReleaseAssetInfo,
        version: AppVersion,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let sha256 = asset.sha256 else {
            throw UpdateError.checksumMismatch
        }
        let temporaryURL = try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: ReleaseRequestFactory.make(url: asset.downloadURL))
            lock.withLock {
                self.continuation = continuation
                self.onProgress = onProgress
                self.task = task
            }
            if lock.withLock({ cancelled }) {
                task.cancel()
            }
            task.resume()
            session.finishTasksAndInvalidate()
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let size = (try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? Int) ?? -1
        guard size == asset.size else {
            throw UpdateError.sizeMismatch
        }
        guard try UpdateFileDigest.sha256(of: temporaryURL) == sha256 else {
            throw UpdateError.checksumMismatch
        }

        let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let destination = UpdateDownloadLocation.destination(in: desktop, version: version, sha256: sha256)
        if destination.alreadyPresent == false {
            try FileManager.default.moveItem(at: temporaryURL, to: destination.url)
        }
        return destination.url
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = lock.withLock { onProgress }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            finish(.failure(UpdateError.badResponse(status)))
            return
        }
        // The system deletes `location` when this method returns, so keep a copy.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("codex-opero-update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let wasCancelled = lock.withLock { cancelled } || (error as? URLError)?.code == .cancelled
        finish(.failure(wasCancelled ? UpdateError.cancelled : error))
    }
}

// MARK: - Install

enum UpdateInstaller {
    static var failureMarkerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codex-opero/update-install-failed.txt")
    }

    /// The running app bundle when it can be replaced in place, otherwise nil (for example under `swift run`).
    static func installTarget() -> URL? {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: bundle.path) else {
            return nil
        }
        return bundle
    }

    /// Stages the new app from the DMG, validates it, and starts a helper that swaps bundles after this app quits.
    static func install(dmgURL: URL, expectedVersion: AppVersion, target: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-opero-update-\(UUID().uuidString)", isDirectory: true)
        let mountPoint = staging.appendingPathComponent("mount", isDirectory: true)
        let stagedApp = staging.appendingPathComponent(target.lastPathComponent)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            try stageApp(from: dmgURL, mountPoint: mountPoint, to: stagedApp)
            try validate(stagedApp, expectedVersion: expectedVersion)

            let script = staging.appendingPathComponent("install.zsh")
            try UpdateInstallScript.source.write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: failureMarkerURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                script.path, String(ProcessInfo.processInfo.processIdentifier),
                target.path, stagedApp.path, failureMarkerURL.path, staging.path,
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw UpdateError.launchFailed
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func stageApp(from dmgURL: URL, mountPoint: URL, to stagedApp: URL) throws {
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                       "-mountpoint", mountPoint.path, dmgURL.path]) == 0 else {
            throw UpdateError.mountFailed
        }
        defer {
            if run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) != 0 {
                run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
            }
        }
        let mountedApp = mountPoint.appendingPathComponent("codex-opero.app")
        guard FileManager.default.fileExists(atPath: mountedApp.path) else {
            throw UpdateError.appMissing
        }
        guard run("/usr/bin/ditto", [mountedApp.path, stagedApp.path]) == 0 else {
            throw UpdateError.invalidApp("앱을 복사할 수 없습니다.")
        }
    }

    private static func validate(_ app: URL, expectedVersion: AppVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.invalidApp("Info.plist를 읽을 수 없습니다.")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidApp("번들 식별자가 다릅니다.")
        }
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              version == expectedVersion else {
            throw UpdateError.invalidApp("버전이 예상한 버전(\(expectedVersion.displayString))과 다릅니다.")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError.invalidApp("코드 서명이 유효하지 않습니다.")
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
