import Darwin
import Foundation

public struct AntigravityProvider: UsageProvider {
    public let providerID: ProviderID = .antigravity

    private let cacheDirectoryURLs: [URL]
    private let historyDirectoryURLs: [URL]
    private let currentAccountURL: URL
    private let usageExecutableURL: URL?
    private let usageTimeout: TimeInterval

    public init(
        cacheDirectoryURLs: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".antigravity_cockpit/cache/quota_api_v1_plugin/authorized"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".antigravity_cockpit/cache/quota_api_v1_desktop/authorized"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".antigravity_cockpit/cache/quota_api_v1/authorized")
        ],
        historyDirectoryURLs: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".antigravity_cockpit/cache/quota_history")
        ],
        currentAccountURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".antigravity_cockpit/current_account.json"),
        usageExecutableURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/agy"),
        usageTimeout: TimeInterval = 30
    ) {
        self.cacheDirectoryURLs = cacheDirectoryURLs
        self.historyDirectoryURLs = historyDirectoryURLs
        self.currentAccountURL = currentAccountURL
        self.usageExecutableURL = usageExecutableURL
        self.usageTimeout = usageTimeout
    }

    public func fetchQuota() async throws -> ProviderQuota {
        if let quota = try fetchLiveUsageQuota() {
            return quota
        }

        let cache = try loadLatestCache()
        let models = visibleModels(from: cache)
        let history = try? loadLatestHistory(preferredEmail: cache.email ?? loadCurrentAccountEmail())

        guard !models.isEmpty else {
            throw ProviderError.unsupportedPayload
        }

        let primaryModel = bucketRepresentative(from: models, ids: antigravityGoogleModelIDs)
        let secondaryModel = bucketRepresentative(from: models, ids: antigravityThirdPartyModelIDs)

        guard let primary = primaryModel, let secondary = secondaryModel else {
            throw ProviderError.unsupportedPayload
        }
        let googleBucket = history?.bucket(for: .google)
        let thirdPartyBucket = history?.bucket(for: .thirdParty)
        let primaryWindow = QuotaWindow(
            id: "group:Google",
            name: "Google",
            usedPercent: googleBucket?.usedPercent ?? usedPercent(from: primary),
            resetAt: googleBucket?.resetAt ?? primary.raw.quotaInfo?.resetDate
        )
        let secondaryWindow = QuotaWindow(
            id: "group:3rd Party",
            name: "3rd Party",
            usedPercent: thirdPartyBucket?.usedPercent ?? usedPercent(from: secondary),
            resetAt: thirdPartyBucket?.resetAt ?? secondary.raw.quotaInfo?.resetDate
        )

        return ProviderQuota(
            providerID: providerID,
            primary: primaryWindow,
            secondary: secondaryWindow,
            fetchedAt: Date(),
            detailGroups: detailGroups(from: models, googleBucket: googleBucket, thirdPartyBucket: thirdPartyBucket)
        )
    }

    // MARK: - Live usage loading

    private func fetchLiveUsageQuota() throws -> ProviderQuota? {
        guard
            let usageExecutableURL,
            FileManager.default.isExecutableFile(atPath: usageExecutableURL.path)
        else {
            return nil
        }

        let output = try runUsageCommand(executableURL: usageExecutableURL)
        guard let usage = AgyLiveUsageSnapshot(output: output) else {
            throw ProviderError.other("agy usage output did not contain quota data")
        }

        return ProviderQuota(
            providerID: providerID,
            primary: QuotaWindow(
                id: "group:Google",
                name: "Google",
                usedPercent: usage.google.usedPercent,
                resetAt: usage.google.resetAt
            ),
            secondary: QuotaWindow(
                id: "group:3rd Party",
                name: "3rd Party",
                usedPercent: usage.thirdParty.usedPercent,
                resetAt: usage.thirdParty.resetAt
            ),
            fetchedAt: Date(),
            detailGroups: [
                QuotaDetailGroup(
                    name: "Google",
                    windows: [
                        QuotaWindow(
                            id: "group:Google",
                            name: "Google",
                            usedPercent: usage.google.usedPercent,
                            resetAt: usage.google.resetAt
                        )
                    ],
                    modelNames: antigravityGoogleModelNames
                ),
                QuotaDetailGroup(
                    name: "3rd Party",
                    windows: [
                        QuotaWindow(
                            id: "group:3rd Party",
                            name: "3rd Party",
                            usedPercent: usage.thirdParty.usedPercent,
                            resetAt: usage.thirdParty.resetAt
                        )
                    ],
                    modelNames: antigravityThirdPartyModelNames
                ),
            ]
        )
    }

    private func runUsageCommand(executableURL: URL) throws -> String {
        try runInteractiveUsageCommand(executableURL: executableURL)
    }

    private func runInteractiveUsageCommand(executableURL: URL) throws -> String {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var windowSize = winsize(ws_row: 36, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &windowSize) == 0 else {
            throw ProviderError.other("failed to allocate pty")
        }

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--log-file", "/tmp/codex-opero-agy-usage.log"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "xterm-256color",
            "NO_COLOR": "1",
        ]) { _, new in new }
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        try process.run()
        slaveHandle.closeFile()

        let start = Date()
        let deadline = start.addingTimeInterval(usageTimeout)
        let output = LockedPTYOutput()
        let reader = DispatchQueue(label: "codex-opero.agy-usage-reader")
        reader.async {
            while true {
                let chunk = masterHandle.availableData
                if chunk.isEmpty {
                    break
                }
                output.append(chunk)
            }
            output.finish()
        }

        var lastUsageSend = Date.distantPast
        var parsedOutput: String?
        while Date() < deadline {
            if Date().timeIntervalSince(start) >= min(3, max(0.2, usageTimeout / 10)),
               Date().timeIntervalSince(lastUsageSend) >= 2 {
                try? masterHandle.write(contentsOf: Data([0x15]))
                try? masterHandle.write(contentsOf: Data("/usage\r".utf8))
                lastUsageSend = Date()
            }

            let currentOutput = output.string
            if AgyLiveUsageSnapshot(output: currentOutput) != nil {
                parsedOutput = currentOutput
                break
            }

            if process.isRunning == false {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        try? masterHandle.write(contentsOf: Data([0x03]))

        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            let outputString = output.string
            if AgyLiveUsageSnapshot(output: outputString) != nil {
                process.terminate()
                return outputString
            }
            process.terminate()
            throw ProviderError.other("agy usage command timed out: \(outputString.suffix(500))")
        }

        let waitUntil = Date().addingTimeInterval(1)
        while Date() < waitUntil {
            if output.isFinished { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        masterHandle.closeFile()

        if let parsedOutput {
            return parsedOutput
        }

        guard process.terminationStatus == 0 else {
            let outputString = output.string
            if AgyLiveUsageSnapshot(output: outputString) != nil {
                return outputString
            }
            throw ProviderError.other(outputString)
        }
        return output.string
    }

    // MARK: - Cache loading

    private func loadLatestCache() throws -> AgyQuotaCache {
        var allFiles: [URL] = []
        for dir in cacheDirectoryURLs {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            if let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) {
                allFiles.append(contentsOf: files.filter { $0.pathExtension == "json" })
            }
        }

        guard !allFiles.isEmpty else {
            throw ProviderError.credentialsMissing
        }

        let preferredEmail = loadCurrentAccountEmail()
        let candidates = allFiles.compactMap { file -> (url: URL, cache: AgyQuotaCache)? in
            guard
                let data = try? Data(contentsOf: file),
                let cache = try? JSONDecoder.agyDecoder.decode(AgyQuotaCache.self, from: data)
            else {
                return nil
            }
            return (file, cache)
        }
        let visibleCandidates: [(url: URL, cache: AgyQuotaCache)]
        if let preferredEmail {
            let accountCandidates = candidates.filter { $0.cache.email == preferredEmail }
            visibleCandidates = accountCandidates.isEmpty ? candidates : accountCandidates
        } else {
            visibleCandidates = candidates
        }
        guard !visibleCandidates.isEmpty else {
            throw ProviderError.unsupportedPayload
        }

        return visibleCandidates.max(by: { a, b in
            modificationDate(for: a.url) < modificationDate(for: b.url)
        })!.cache
    }

    private func loadLatestHistory(preferredEmail: String?) throws -> AgyQuotaHistory {
        var allFiles: [URL] = []
        for dir in historyDirectoryURLs {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            if let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) {
                allFiles.append(contentsOf: files.filter { $0.pathExtension == "json" })
            }
        }
        guard !allFiles.isEmpty else {
            throw ProviderError.credentialsMissing
        }
        let candidates = allFiles.compactMap { file -> (url: URL, history: AgyQuotaHistory)? in
            guard
                let data = try? Data(contentsOf: file),
                let history = try? JSONDecoder.agyDecoder.decode(AgyQuotaHistory.self, from: data)
            else {
                return nil
            }
            return (file, history)
        }
        let visibleCandidates: [(url: URL, history: AgyQuotaHistory)]
        if let preferredEmail {
            let accountCandidates = candidates.filter { $0.history.email == preferredEmail }
            visibleCandidates = accountCandidates.isEmpty ? candidates : accountCandidates
        } else {
            visibleCandidates = candidates
        }
        guard !visibleCandidates.isEmpty else {
            throw ProviderError.unsupportedPayload
        }
        return visibleCandidates.max(by: { a, b in
            modificationDate(for: a.url) < modificationDate(for: b.url)
        })!.history
    }

    private func loadCurrentAccountEmail() -> String? {
        guard
            FileManager.default.fileExists(atPath: currentAccountURL.path),
            let data = try? Data(contentsOf: currentAccountURL),
            let account = try? JSONDecoder.agyDecoder.decode(AgyCurrentAccount.self, from: data)
        else {
            return nil
        }
        return account.email
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - Model filtering

    private func visibleModels(from cache: AgyQuotaCache) -> [AgyModel] {
        guard let payload = cache.payload else { return [] }
        let allModels = payload.models
            .map { id, model in AgyModel(id: id, raw: model) }
            .filter { model in
                // Only allow models in our explicit display mapping
                guard modelDisplayNameMapping[model.id] != nil else { return false }
                // Exclude internal tab/chat models
                guard model.raw.isInternal != true else { return false }
                // Exclude models without quota info
                guard model.raw.quotaInfo != nil else { return false }
                return true
            }
            .sorted { $0.displayName < $1.displayName }

        var uniqueModels: [AgyModel] = []
        var seenNames: Set<String> = []
        for model in allModels {
            if !seenNames.contains(model.displayName) {
                seenNames.insert(model.displayName)
                uniqueModels.append(model)
            }
        }
        return uniqueModels
    }

    // MARK: - Bucket selection

    private func bucketRepresentative(from models: [AgyModel], ids: [String]) -> AgyModel? {
        let bucketModels = ids.compactMap { id in models.first(where: { $0.id == id }) }
        return bucketModels.min { lhs, rhs in
            let lhsRemaining = lhs.raw.quotaInfo?.remainingFraction ?? 1
            let rhsRemaining = rhs.raw.quotaInfo?.remainingFraction ?? 1
            return lhsRemaining < rhsRemaining
        }
    }

    private func usedPercent(from model: AgyModel) -> Int {
        guard let fraction = model.raw.quotaInfo?.remainingFraction else { return 0 }
        let used = (1.0 - fraction) * 100
        return max(0, min(100, Int(used.rounded())))
    }

    // MARK: - Detail groups

    private func detailGroups(
        from models: [AgyModel],
        googleBucket: AgyHistoryBucket?,
        thirdPartyBucket: AgyHistoryBucket?
    ) -> [QuotaDetailGroup] {
        let groups: [(name: String, ids: [String], modelNames: [String])] = [
            ("Google", antigravityGoogleModelIDs, antigravityGoogleModelNames),
            ("3rd Party", antigravityThirdPartyModelIDs, antigravityThirdPartyModelNames),
        ]

        return groups.compactMap { group in
            guard let representative = bucketRepresentative(from: models, ids: group.ids) else {
                return nil
            }
            let historyBucket = group.name == "Google" ? googleBucket : thirdPartyBucket
            let window = QuotaWindow(
                id: "group:\(group.name)",
                name: group.name,
                usedPercent: historyBucket?.usedPercent ?? usedPercent(from: representative),
                resetAt: historyBucket?.resetAt ?? representative.raw.quotaInfo?.resetDate
            )
            return QuotaDetailGroup(name: group.name, windows: [window], modelNames: group.modelNames)
        }
    }
}

// MARK: - Model mapping dictionary

private let antigravityGoogleModelIDs = [
    "gemini-3.1-pro-high",
    "gemini-3.1-pro-low",
    "gemini-3-flash-agent",
    "gemini-3-flash",
]

private let antigravityThirdPartyModelIDs = [
    "claude-opus-4-6-thinking",
    "claude-sonnet-4-6",
    "gpt-oss-120b-medium",
]

private let antigravityGoogleModelNames = [
    "Gemini 3.1 Pro (High)",
    "Gemini 3.1 Pro (Low)",
    "Gemini 3.5 Flash (High)",
    "Gemini 3.5 Flash (Medium)",
]

private let antigravityThirdPartyModelNames = [
    "Claude Opus 4.6 (Thinking)",
    "Claude Sonnet 4.6 (Thinking)",
    "GPT-OSS 120B (Medium)",
]

private let modelDisplayNameMapping: [String: String] = [
    "gemini-3-flash-agent": "Gemini 3.5 Flash (High)",
    "gemini-3-flash": "Gemini 3.5 Flash (Medium)",
    "gemini-3.1-pro-high": "Gemini 3.1 Pro (High)",
    "gemini-3.1-pro-low": "Gemini 3.1 Pro (Low)",
    "claude-sonnet-4-6": "Claude Sonnet 4.6 (Thinking)",
    "claude-opus-4-6-thinking": "Claude Opus 4.6 (Thinking)",
    "gpt-oss-120b-medium": "GPT-OSS 120B (Medium)"
]

// MARK: - Internal model wrapper

private struct AgyModel {
    let id: String
    let raw: AgyModelPayload

    var displayName: String {
        modelDisplayNameMapping[id] ?? raw.displayName ?? id
    }
}

// MARK: - JSON decodable types

private struct AgyQuotaCache: Decodable {
    let email: String?
    let updatedAt: Double?
    let payload: AgyPayload?
}

private struct AgyPayload: Decodable {
    let models: [String: AgyModelPayload]
}

private struct AgyModelPayload: Decodable {
    let displayName: String?
    let recommended: Bool?
    let isInternal: Bool?
    let quotaInfo: AgyQuotaInfo?
    let modelProvider: String?
}

private struct AgyQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?

    var resetDate: Date? {
        guard let resetTime else { return nil }
        return ISO8601DateFormatter().date(from: resetTime)
    }
}

private struct AgyCurrentAccount: Decodable {
    let email: String?
}

private enum AgyHistoryGroup {
    case google
    case thirdParty
}

private struct AgyHistoryBucket {
    let usedPercent: Int
    let resetAt: Date?
}

private final class LockedPTYOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

private struct AgyLiveUsageSnapshot {
    let google: AgyHistoryBucket
    let thirdParty: AgyHistoryBucket

    init?(output: String, now: Date = Date()) {
        let lines = output
            .strippingANSIEscapeSequences()
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.removingControlCharacters().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var googleBuckets: [AgyHistoryBucket] = []
        var thirdPartyBuckets: [AgyHistoryBucket] = []

        for (index, line) in lines.enumerated() {
            let group: AgyHistoryGroup?
            if antigravityGoogleModelNames.contains(where: { line.contains($0) }) {
                group = .google
            } else if antigravityThirdPartyModelNames.contains(where: { line.contains($0) }) {
                group = .thirdParty
            } else {
                group = nil
            }

            guard let group else { continue }

            let following = lines.dropFirst(index + 1).prefix(4)
            guard let bucket = AgyLiveUsageSnapshot.bucket(from: following, now: now) else {
                continue
            }
            switch group {
            case .google:
                googleBuckets.append(bucket)
            case .thirdParty:
                thirdPartyBuckets.append(bucket)
            }
        }

        let flatBuckets = AgyLiveUsageSnapshot.bucketsFromFlatText(output, now: now)
        googleBuckets.append(contentsOf: flatBuckets.google)
        thirdPartyBuckets.append(contentsOf: flatBuckets.thirdParty)

        guard
            let google = AgyLiveUsageSnapshot.representativeBucket(from: googleBuckets),
            let thirdParty = AgyLiveUsageSnapshot.representativeBucket(from: thirdPartyBuckets)
        else {
            return nil
        }

        self.google = google
        self.thirdParty = thirdParty
    }

    private static func bucket<S: Sequence>(from lines: S, now: Date) -> AgyHistoryBucket? where S.Element == String {
        for line in lines {
            if let bucket = bucket(from: line, now: now) {
                return bucket
            }
        }
        return nil
    }

    private static func bucketsFromFlatText(_ output: String, now: Date) -> (google: [AgyHistoryBucket], thirdParty: [AgyHistoryBucket]) {
        let flatText = output
            .strippingANSIEscapeSequences()
            .replacingControlCharactersWithSpaces()
            .removingCommonANSIRemnants()
            .collapsingWhitespace()
        let models: [(name: String, group: AgyHistoryGroup)] =
            antigravityGoogleModelNames.map { ($0, .google) } +
            antigravityThirdPartyModelNames.map { ($0, .thirdParty) }

        var googleBuckets: [AgyHistoryBucket] = []
        var thirdPartyBuckets: [AgyHistoryBucket] = []

        for model in models {
            guard let modelRange = flatText.range(of: model.name, options: [.caseInsensitive]) else {
                continue
            }

            var segmentEnd = flatText.endIndex
            for nextModel in models where nextModel.name != model.name {
                guard
                    let nextRange = flatText.range(of: nextModel.name, options: [.caseInsensitive], range: modelRange.upperBound..<flatText.endIndex),
                    nextRange.lowerBound < segmentEnd
                else {
                    continue
                }
                segmentEnd = nextRange.lowerBound
            }

            let segment = String(flatText[modelRange.upperBound..<segmentEnd])
            guard let bucket = bucket(from: segment, now: now) else {
                continue
            }

            switch model.group {
            case .google:
                googleBuckets.append(bucket)
            case .thirdParty:
                thirdPartyBuckets.append(bucket)
            }
        }

        return (googleBuckets, thirdPartyBuckets)
    }

    private static func bucket(from text: String, now: Date) -> AgyHistoryBucket? {
        if text.localizedCaseInsensitiveContains("Quota available") {
            return AgyHistoryBucket(usedPercent: 0, resetAt: nil)
        }

        guard let remaining = remainingPercent(from: text) else {
            return nil
        }
        let used = max(0, min(100, 100 - remaining))
        return AgyHistoryBucket(
            usedPercent: used,
            resetAt: resetDate(from: text, now: now)
        )
    }

    private static func remainingPercent(from text: String) -> Int? {
        if let remaining = text.firstInteger(before: "% remaining") {
            return remaining
        }

        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*%\s*remaining"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[valueRange])
    }

    private static func representativeBucket(from buckets: [AgyHistoryBucket]) -> AgyHistoryBucket? {
        buckets.max { lhs, rhs in
            lhs.usedPercent < rhs.usedPercent
        }
    }

    private static func resetDate(from line: String, now: Date) -> Date? {
        guard let range = line.range(of: "Refreshes in", options: [.caseInsensitive]) else {
            return nil
        }
        let text = String(line[range.upperBound...])
        let seconds = durationSeconds(from: text)
        return seconds > 0 ? now.addingTimeInterval(TimeInterval(seconds)) : now
    }

    private static func durationSeconds(from text: String) -> Int {
        var seconds = 0
        let patterns: [(String, Int)] = [
            (#"(\d+)\s*d(?:ay|ays)?"#, 86_400),
            (#"(\d+)\s*h(?:our|ours)?"#, 3_600),
            (#"(\d+)\s*m(?:inute|inutes)?"#, 60),
            (#"(\d+)\s*s(?:econd|econds)?"#, 1),
        ]

        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard
                    let valueRange = Range(match.range(at: 1), in: text),
                    let value = Int(text[valueRange])
                else {
                    continue
                }
                seconds += value * multiplier
            }
        }

        return seconds
    }
}

private struct AgyQuotaHistory: Decodable {
    let email: String?
    let models: [String: AgyHistoryModel]

    func bucket(for group: AgyHistoryGroup) -> AgyHistoryBucket? {
        let modelIDs: [String]
        switch group {
        case .google:
            modelIDs = ["g3-pro", "g3-flash"]
        case .thirdParty:
            modelIDs = ["claude-4-5"]
        }

        let buckets = modelIDs.compactMap { models[$0]?.latestBucket }
        guard !buckets.isEmpty else {
            return nil
        }
        return buckets.max { lhs, rhs in
            lhs.usedPercent < rhs.usedPercent
        }
    }
}

private struct AgyHistoryModel: Decodable {
    let points: [AgyHistoryPoint]

    var latestBucket: AgyHistoryBucket? {
        guard let point = points.max(by: { $0.timestamp < $1.timestamp }) else {
            return nil
        }
        return point.bucket
    }
}

private struct AgyHistoryPoint: Decodable {
    let timestamp: Double
    let remainingPercentage: Double?
    let resetTime: Double?

    var bucket: AgyHistoryBucket? {
        guard let remainingPercentage else {
            return nil
        }
        let used = 100 - remainingPercentage
        let resetAt = resetTime.map { Date(timeIntervalSince1970: $0 / 1000) }
        return AgyHistoryBucket(
            usedPercent: max(0, min(100, Int(used.rounded()))),
            resetAt: resetAt
        )
    }
}

private extension JSONDecoder {
    static let agyDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}

private extension String {
    func strippingANSIEscapeSequences() -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\u{001B}(?:\[[0-9;?]*[ -/]*[@-~]|\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\)|[PX^_].*?\u{001B}\\|.)"#,
            options: [.dotMatchesLineSeparators]
        ) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: "")
    }

    func removingControlCharacters() -> String {
        String(unicodeScalars.filter { scalar in
            scalar.value >= 0x20 || scalar == "\t"
        })
    }

    func replacingControlCharactersWithSpaces() -> String {
        components(separatedBy: .controlCharacters).joined(separator: " ")
    }

    func removingCommonANSIRemnants() -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[[0-9;?]*[ -/]*[@-~]"#) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: " ")
    }

    func collapsingWhitespace() -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\s+"#) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func firstInteger(before suffix: String) -> Int? {
        guard let suffixRange = range(of: suffix, options: [.caseInsensitive]) else {
            return nil
        }
        let prefixString = String(self[..<suffixRange.lowerBound])
        guard
            let regex = try? NSRegularExpression(pattern: #"(\d+)\s*$"#),
            let match = regex.firstMatch(
                in: prefixString,
                range: NSRange(prefixString.startIndex..<prefixString.endIndex, in: prefixString)
            )
        else {
            return nil
        }
        guard let range = Range(match.range(at: 1), in: prefixString) else {
            return nil
        }
        return Int(prefixString[range])
    }
}
