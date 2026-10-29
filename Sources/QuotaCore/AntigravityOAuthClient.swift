import Foundation

struct AgyOAuthClient: Codable, Sendable {
    let clientID: String
    let clientSecret: String

    private static let maximumBytes = 300_000_000
    private static var unavailable: ProviderError {
        .other("Install Antigravity or agy to refresh its login")
    }

    static func installedCandidates() throws -> [Self] {
        let paths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/agy").path,
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
            "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw unavailable
        }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            guard try handle.seekToEnd() <= UInt64(maximumBytes) else { throw unavailable }
            try handle.seek(toOffset: 0)
            var data = Data()
            while let chunk = try handle.read(upToCount: min(1_048_576, maximumBytes - data.count + 1)),
                  !chunk.isEmpty {
                guard chunk.count <= maximumBytes - data.count else { throw unavailable }
                data.append(chunk)
            }
            return try candidates(in: data)
        } catch {
            throw unavailable
        }
    }

    static func candidates(in data: Data) throws -> [Self] {
        guard data.count <= maximumBytes else { throw unavailable }
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        func matches(_ pattern: String) throws -> [String] {
            let expression = try NSRegularExpression(pattern: pattern)
            var values: [String] = []
            expression.enumerateMatches(in: text, range: range) { match, _, stop in
                guard let match, let matchRange = Range(match.range, in: text) else { return }
                let value = String(text[matchRange])
                if !values.contains(value) { values.append(value) }
                if values.count == 4 { stop.pointee = true }
            }
            return values
        }

        do {
            let clientIDs = try matches(#"[0-9]{10,14}-[a-z0-9]{25,40}\.apps\.googleusercontent\.com"#)
            let secrets = try matches(#"GOCSPX-[A-Za-z0-9_-]{28}"#)
            guard !clientIDs.isEmpty, !secrets.isEmpty else { throw unavailable }
            return clientIDs.flatMap { clientID in
                secrets.map { Self(clientID: clientID, clientSecret: $0) }
            }
        } catch {
            throw unavailable
        }
    }
}
