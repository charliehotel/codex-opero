import CryptoKit
import Foundation

public struct ReleaseAssetInfo: Equatable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let size: Int
    public let digest: String?

    public init(name: String, downloadURL: URL, size: Int, digest: String?) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.digest = digest
    }

    /// The lowercase SHA-256 hex from GitHub's `sha256:<hex>` asset digest.
    public var sha256: String? {
        guard let digest, digest.hasPrefix("sha256:") else {
            return nil
        }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return hex
    }
}

public enum UpdateAssetSelector {
    public static let dmgName = "codex-opero.dmg"

    public static func dmgAsset(in assets: [ReleaseAssetInfo]) -> ReleaseAssetInfo? {
        assets.first { asset in
            asset.name == dmgName
                && asset.downloadURL.scheme?.lowercased() == "https"
                && asset.downloadURL.host?.lowercased() == "github.com"
                && asset.sha256 != nil
                && asset.size > 0
        }
    }
}

public enum UpdateReleaseNotes {
    /// Picks the Korean or English half of a bilingual release body and converts block
    /// markdown that inline-only rendering keeps literally (headings, bullets) into text.
    public static func displayText(_ body: String, preferKorean: Bool) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let marker = preferKorean ? "## 한국어" : "## English"
        var section = lines
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) {
            let rest = lines[(start + 1)...]
            let end = rest.firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
            section = Array(lines[(start + 1)..<end])
        }

        let converted = section.compactMap { line -> String? in
            if line.hasPrefix("# ") {
                return nil
            }
            if let heading = ["### ", "## "].first(where: line.hasPrefix) {
                return "**\(line.dropFirst(heading.count))**"
            }
            if line.hasPrefix("- ") {
                return "• " + line.dropFirst(2)
            }
            return line
        }
        return converted.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum UpdateFileDigest {
    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), chunk.isEmpty == false {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum UpdateDownloadLocation {
    /// Returns the destination for a downloaded DMG, reusing an identical earlier download.
    public static func destination(
        in directory: URL,
        version: AppVersion,
        sha256: String,
        fileManager: FileManager = .default
    ) -> (url: URL, alreadyPresent: Bool) {
        let base = "codex-opero-\(version.displayString)"
        for index in 1...100 {
            let name = index == 1 ? "\(base).dmg" : "\(base) (\(index)).dmg"
            let url = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else {
                return (url, false)
            }
            if (try? UpdateFileDigest.sha256(of: url)) == sha256 {
                return (url, true)
            }
        }
        return (directory.appendingPathComponent("\(base)-\(UUID().uuidString).dmg"), false)
    }
}

public enum UpdateInstallScript {
    /// Arguments: app PID, installed app path, staged new app path, failure marker path, staging directory.
    /// Waits for the app to quit, swaps the bundle, restores the previous one on failure, and relaunches.
    public static let source = #"""
    #!/bin/zsh
    set -u
    pid="$1" target="$2" staged="$3" marker="$4" staging="$5"
    backup="${target:h}/.${target:t:r}-previous.app"

    fail() {
        mkdir -p "${marker:h}"
        print -r -- "$1" > "$marker"
        open "$target"
        exit 1
    }

    for _ in {1..300}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && fail "기존 앱이 종료되지 않아 업데이트를 설치하지 못했습니다."

    rm -rf "$backup"
    mv "$target" "$backup" || fail "기존 앱을 교체할 수 없어 업데이트를 설치하지 못했습니다."
    if ditto "$staged" "$target"; then
        rm -rf "$backup" "$staging"
        open "$target"
        exit 0
    fi
    rm -rf "$target"
    mv "$backup" "$target"
    fail "새 버전을 복사하지 못해 기존 앱으로 되돌렸습니다."
    """#
}
