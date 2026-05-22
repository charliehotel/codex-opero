import Darwin
import Foundation

public struct AntigravityProvider: UsageProvider {
    public let providerID: ProviderID = .antigravity

    private let cacheDirectoryURLs: [URL]
    private let historyDirectoryURLs: [URL]
    private let currentAccountURL: URL
    private let usageExecutableURL: URL?
    private let usageTimeout: TimeInterval
    private let ideMainLogURL: URL?
    private let ideSession: URLSession
    private let ideRequestTimeout: TimeInterval

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
        usageTimeout: TimeInterval = 30,
        ideMainLogURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Antigravity/main.log"),
        ideSession: URLSession = .shared,
        ideRequestTimeout: TimeInterval = 5
    ) {
        self.cacheDirectoryURLs = cacheDirectoryURLs
        self.historyDirectoryURLs = historyDirectoryURLs
        self.currentAccountURL = currentAccountURL
        self.usageExecutableURL = usageExecutableURL
        self.usageTimeout = usageTimeout
        self.ideMainLogURL = ideMainLogURL
        self.ideSession = ideSession
        self.ideRequestTimeout = ideRequestTimeout
    }

    public func fetchQuota() async throws -> ProviderQuota {
        if let quota = try? await fetchIDEUsageQuota() {
            return quota
        }

        var liveError: Error?
        do {
            if let quota = try fetchLiveUsageQuota() {
                return quota
            }
        } catch {
            liveError = error
        }

        do {
            return try fetchCachedQuota()
        } catch {
            if let liveError {
                throw liveError
            }
            throw error
        }
    }

    private func fetchCachedQuota() throws -> ProviderQuota {
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

    // MARK: - Antigravity 2.0 IDE loading

    private func fetchIDEUsageQuota() async throws -> ProviderQuota? {
        guard let connection = latestIDEConnectionInfo() else {
            return nil
        }

        let httpPort = connection.httpsPort + 1
        guard let url = URL(
            string: "http://127.0.0.1:\(httpPort)/exa.language_server_pb.LanguageServerService/GetAvailableModels"
        ) else {
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: ideRequestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(connection.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await ideSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse
        }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode)
        }
        guard let snapshot = AgyIDEAvailableModelsSnapshot(data: data) else {
            throw ProviderError.unsupportedPayload
        }

        return quotaFromBuckets(google: snapshot.google, thirdParty: snapshot.thirdParty)
    }

    private func latestIDEConnectionInfo() -> AgyIDEConnectionInfo? {
        guard
            let ideMainLogURL,
            FileManager.default.fileExists(atPath: ideMainLogURL.path),
            let log = try? String(contentsOf: ideMainLogURL, encoding: .utf8),
            let csrfToken = lastCapture(in: log, pattern: #"--csrf_token\s+([0-9A-Za-z-]+)"#),
            let portText = lastCapture(in: log, pattern: #"Local:\s+https://127\.0\.0\.1:(\d+)/"#),
            let httpsPort = Int(portText)
        else {
            return nil
        }
        return AgyIDEConnectionInfo(httpsPort: httpsPort, csrfToken: csrfToken)
    }

    private func lastCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).last.flatMap { match in
            guard
                match.numberOfRanges > 1,
                let valueRange = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return String(text[valueRange])
        }
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

        return quotaFromBuckets(google: usage.google, thirdParty: usage.thirdParty)
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
            if let failureMessage = AgyLiveUsageFailure.message(from: currentOutput) {
                process.terminate()
                throw ProviderError.other(failureMessage)
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
            throw ProviderError.other(AgyLiveUsageFailure.timeoutMessage(from: outputString))
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
            throw ProviderError.other(AgyLiveUsageFailure.message(from: outputString) ?? AgyLiveUsageFailure.commandFailedMessage(from: outputString))
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
        let now = Date()
        let bucketModels = ids.compactMap { id in models.first(where: { $0.id == id }) }
        return bucketModels.min { lhs, rhs in
            let lhsRemaining = remainingFraction(from: lhs.raw.quotaInfo, now: now)
            let rhsRemaining = remainingFraction(from: rhs.raw.quotaInfo, now: now)
            return lhsRemaining < rhsRemaining
        }
    }

    private func usedPercent(from model: AgyModel) -> Int {
        let fraction = remainingFraction(from: model.raw.quotaInfo)
        let used = (1.0 - fraction) * 100
        return max(0, min(100, Int(used.rounded())))
    }

    private func quotaFromBuckets(google: AgyHistoryBucket, thirdParty: AgyHistoryBucket) -> ProviderQuota {
        let googleWindow = QuotaWindow(
            id: "group:Google",
            name: "Google",
            usedPercent: google.usedPercent,
            resetAt: google.resetAt
        )
        let thirdPartyWindow = QuotaWindow(
            id: "group:3rd Party",
            name: "3rd Party",
            usedPercent: thirdParty.usedPercent,
            resetAt: thirdParty.resetAt
        )

        return ProviderQuota(
            providerID: providerID,
            primary: googleWindow,
            secondary: thirdPartyWindow,
            fetchedAt: Date(),
            detailGroups: [
                QuotaDetailGroup(
                    name: "Google",
                    windows: [googleWindow],
                    modelNames: antigravityGoogleModelNames
                ),
                QuotaDetailGroup(
                    name: "3rd Party",
                    windows: [thirdPartyWindow],
                    modelNames: antigravityThirdPartyModelNames
                ),
            ]
        )
    }

    private func remainingFraction(from quotaInfo: AgyQuotaInfo?, now: Date = Date()) -> Double {
        guard let quotaInfo else { return 1 }
        if let remainingFraction = quotaInfo.remainingFraction {
            return max(0, min(1, remainingFraction))
        }
        if let resetAt = quotaInfo.resetDate, resetAt > now {
            return 0
        }
        return 1
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
    "gemini-3.5-flash-low",
    "gemini-3-flash",
    "gemini-pro-agent",
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
    "gemini-3.5-flash-low": "Gemini 3.5 Flash (Medium)",
    "gemini-3-flash": "Gemini 3.5 Flash (Medium)",
    "gemini-3.1-pro-high": "Gemini 3.1 Pro (High)",
    "gemini-3.1-pro-low": "Gemini 3.1 Pro (Low)",
    "gemini-pro-agent": "Gemini 3.1 Pro (High)",
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

private struct AgyIDEAvailableModelsSnapshot {
    let google: AgyHistoryBucket
    let thirdParty: AgyHistoryBucket

    init?(data: Data, now: Date = Date()) {
        guard
            let payload = try? JSONDecoder.agyDecoder.decode(AgyIDEAvailableModelsResponse.self, from: data),
            let models = payload.response?.models
        else {
            return nil
        }

        var googleBuckets: [AgyHistoryBucket] = []
        var thirdPartyBuckets: [AgyHistoryBucket] = []

        for (id, model) in models {
            guard model.isInternal != true else {
                continue
            }

            let displayName = modelDisplayNameMapping[id] ?? model.displayName ?? id
            let group: AgyHistoryGroup?
            if antigravityGoogleModelNames.contains(displayName) {
                group = .google
            } else if antigravityThirdPartyModelNames.contains(displayName) {
                group = .thirdParty
            } else {
                group = nil
            }

            guard
                let group,
                let bucket = AgyIDEAvailableModelsSnapshot.bucket(from: model.quotaInfo, now: now)
            else {
                continue
            }

            switch group {
            case .google:
                googleBuckets.append(bucket)
            case .thirdParty:
                thirdPartyBuckets.append(bucket)
            }
        }

        guard
            let google = AgyIDEAvailableModelsSnapshot.representativeBucket(from: googleBuckets),
            let thirdParty = AgyIDEAvailableModelsSnapshot.representativeBucket(from: thirdPartyBuckets)
        else {
            return nil
        }

        self.google = google
        self.thirdParty = thirdParty
    }

    private static func bucket(from quotaInfo: AgyQuotaInfo?, now: Date) -> AgyHistoryBucket? {
        guard let quotaInfo else {
            return nil
        }

        let usedPercent: Int
        if let remainingFraction = quotaInfo.remainingFraction {
            let remaining = max(0, min(1, remainingFraction))
            usedPercent = max(0, min(100, Int(((1 - remaining) * 100).rounded())))
        } else if let resetAt = quotaInfo.resetDate, resetAt > now {
            usedPercent = 100
        } else {
            usedPercent = 0
        }

        return AgyHistoryBucket(usedPercent: usedPercent, resetAt: quotaInfo.resetDate)
    }

    private static func representativeBucket(from buckets: [AgyHistoryBucket]) -> AgyHistoryBucket? {
        buckets.max { lhs, rhs in
            if lhs.usedPercent == rhs.usedPercent {
                switch (lhs.resetAt, rhs.resetAt) {
                case (nil, .some):
                    return true
                case (.some, nil):
                    return false
                case (.some(let lhsReset), .some(let rhsReset)):
                    return lhsReset < rhsReset
                case (nil, nil):
                    return false
                }
            }
            return lhs.usedPercent < rhs.usedPercent
        }
    }
}

private struct AgyIDEAvailableModelsResponse: Decodable {
    let response: AgyPayload?
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

private struct AgyIDEConnectionInfo {
    let httpsPort: Int
    let csrfToken: String
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

            var candidateLines = [line]
            for followingLine in lines.dropFirst(index + 1) {
                if AgyLiveUsageSnapshot.group(for: followingLine) != nil {
                    break
                }
                candidateLines.append(followingLine)
                if candidateLines.count >= 5 {
                    break
                }
            }
            guard let bucket = AgyLiveUsageSnapshot.bucket(from: candidateLines, now: now) else {
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

    private static func group(for line: String) -> AgyHistoryGroup? {
        if antigravityGoogleModelNames.contains(where: { line.contains($0) }) {
            return .google
        }
        if antigravityThirdPartyModelNames.contains(where: { line.contains($0) }) {
            return .thirdParty
        }
        return nil
    }

    private static func bucket<S: Sequence>(from lines: S, now: Date) -> AgyHistoryBucket? where S.Element == String {
        let candidates = Array(lines)
        if let bucket = bucket(from: candidates.joined(separator: " "), now: now) {
            return bucket
        }
        for line in candidates {
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
            return AgyHistoryBucket(usedPercent: 0, resetAt: resetDate(from: text, now: now))
        }

        guard let remaining = remainingPercent(from: text) else {
            if text.range(of: "Refreshes in", options: [.caseInsensitive]) != nil,
               containsExhaustedCue(text) {
                return AgyHistoryBucket(
                    usedPercent: 100,
                    resetAt: resetDate(from: text, now: now)
                )
            }
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

    private static func containsExhaustedCue(_ text: String) -> Bool {
        text.contains("⚠") ||
            text.localizedCaseInsensitiveContains("warning") ||
            text.localizedCaseInsensitiveContains("exhausted") ||
            text.localizedCaseInsensitiveContains("quota exceeded")
    }

    private static func representativeBucket(from buckets: [AgyHistoryBucket]) -> AgyHistoryBucket? {
        buckets.max { lhs, rhs in
            if lhs.usedPercent == rhs.usedPercent {
                switch (lhs.resetAt, rhs.resetAt) {
                case (nil, .some):
                    return true
                case (.some, nil):
                    return false
                case (.some(let lhsReset), .some(let rhsReset)):
                    return lhsReset < rhsReset
                case (nil, nil):
                    return false
                }
            }
            return lhs.usedPercent < rhs.usedPercent
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

private enum AgyLiveUsageFailure {
    static func message(from output: String) -> String? {
        let text = sanitizedOutput(output)
        if text.localizedCaseInsensitiveContains("consumerOAuth: starting OAuth flow") ||
            text.localizedCaseInsensitiveContains("Starting OAuth authentication flow") {
            return "agy tried to start Google login; skipping live usage lookup"
        }
        if text.localizedCaseInsensitiveContains("no such host") ||
            text.localizedCaseInsensitiveContains("network is unreachable") ||
            text.localizedCaseInsensitiveContains("could not resolve host") {
            return "network unavailable"
        }
        if text.localizedCaseInsensitiveContains("You are not logged into Antigravity") {
            return "not logged into Antigravity"
        }
        return nil
    }

    static func timeoutMessage(from output: String) -> String {
        let text = sanitizedOutput(output)
        guard text.isEmpty == false else {
            return "agy usage command timed out"
        }
        return "agy usage command timed out: \(String(text.suffix(160)))"
    }

    static func commandFailedMessage(from output: String) -> String {
        let text = sanitizedOutput(output)
        guard text.isEmpty == false else {
            return "agy usage command failed"
        }
        return text
    }

    private static func sanitizedOutput(_ output: String) -> String {
        output
            .strippingANSIEscapeSequences()
            .replacingControlCharactersWithSpaces()
            .removingCommonANSIRemnants()
            .collapsingWhitespace()
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
