import Foundation

public struct AntigravityProvider: UsageProvider {
    public let providerID: ProviderID = .antigravity

    private let cacheDirectoryURLs: [URL]

    public init(
        cacheDirectoryURLs: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".antigravity_cockpit/cache/quota_api_v1_plugin/authorized"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".antigravity_cockpit/cache/quota_api_v1_desktop/authorized"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".antigravity_cockpit/cache/quota_api_v1/authorized")
        ]
    ) {
        self.cacheDirectoryURLs = cacheDirectoryURLs
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let cache = try loadLatestCache()
        let models = visibleModels(from: cache)

        guard !models.isEmpty else {
            throw ProviderError.unsupportedPayload
        }

        let primaryModel = pickPrimary(from: models)
        let secondaryModel = pickSecondary(from: models, excluding: primaryModel?.id)

        guard let primary = primaryModel, let secondary = secondaryModel else {
            throw ProviderError.unsupportedPayload
        }

        return ProviderQuota(
            providerID: providerID,
            primary: QuotaWindow(
                id: primary.id,
                name: primary.displayName,
                usedPercent: usedPercent(from: primary),
                resetAt: primary.raw.quotaInfo?.resetDate
            ),
            secondary: QuotaWindow(
                id: secondary.id,
                name: secondary.displayName,
                usedPercent: usedPercent(from: secondary),
                resetAt: secondary.raw.quotaInfo?.resetDate
            ),
            fetchedAt: Date(),
            detailGroups: detailGroups(from: models)
        )
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

        // Pick the most recently modified file across all directories
        let latest = allFiles.max(by: { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate < bDate
        })!

        let data = try Data(contentsOf: latest)
        let cache = try JSONDecoder.agyDecoder.decode(AgyQuotaCache.self, from: data)

        // Use updatedAt from cache to detect stale data (warn but don't fail)
        return cache
    }

    // MARK: - Model filtering

    private func visibleModels(from cache: AgyQuotaCache) -> [AgyModel] {
        // Flatten payload.models dict (keyed by model slug)
        guard let payload = cache.payload else { return [] }
        return payload.models
            .map { id, model in AgyModel(id: id, raw: model) }
            .filter { model in
                // Exclude internal tab/chat models
                guard model.raw.isInternal != true else { return false }
                // Exclude models without a user-facing displayName
                guard let name = model.raw.displayName, !name.isEmpty else { return false }
                // Exclude models without quota info
                guard model.raw.quotaInfo != nil else { return false }
                return true
            }
            .sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Bucket selection

    /// Primary: highest-tier recommended model (pro/high tier preferred)
    private func pickPrimary(from models: [AgyModel]) -> AgyModel? {
        let preferredIDs = [
            "claude-opus-4-6-thinking",
            "claude-sonnet-4-6",
            "gemini-3.1-pro-high",
            "gemini-3-pro-high",
            "gemini-3-pro-low",
            "gemini-2.5-pro",
            "claude-opus-4-5-thinking",
            "claude-sonnet-4-5-thinking",
        ]
        for id in preferredIDs {
            if let m = models.first(where: { $0.id == id }) { return m }
        }
        // Fallback: first recommended
        return models.first(where: { $0.raw.recommended == true })
            ?? models.first
    }

    /// Secondary: first recommended model that is not the primary
    private func pickSecondary(from models: [AgyModel], excluding primaryID: String?) -> AgyModel? {
        let preferredIDs = [
            "gemini-3-flash",
            "gemini-2.5-flash",
            "claude-sonnet-4-5",
            "gpt-oss-120b-medium",
        ]
        for id in preferredIDs {
            if id != primaryID, let m = models.first(where: { $0.id == id }) { return m }
        }
        return models.first(where: { $0.id != primaryID && $0.raw.recommended == true })
            ?? models.first(where: { $0.id != primaryID })
    }

    private func usedPercent(from model: AgyModel) -> Int {
        guard let fraction = model.raw.quotaInfo?.remainingFraction else { return 0 }
        let used = (1.0 - fraction) * 100
        return max(0, min(100, Int(used.rounded())))
    }

    // MARK: - Detail groups

    private func detailGroups(from models: [AgyModel]) -> [QuotaDetailGroup] {
        let providerOrder = ["Google", "Anthropic", "OpenAI", "Other"]

        let grouped = Dictionary(grouping: models) { model -> String in
            switch model.raw.modelProvider {
            case "MODEL_PROVIDER_GOOGLE":   return "Google"
            case "MODEL_PROVIDER_ANTHROPIC": return "Anthropic"
            case "MODEL_PROVIDER_OPENAI":   return "OpenAI"
            default:                        return "Other"
            }
        }

        return providerOrder.compactMap { groupName in
            guard let groupModels = grouped[groupName], !groupModels.isEmpty else { return nil }
            let windows = groupModels
                .sorted { $0.displayName < $1.displayName }
                .map { model in
                    QuotaWindow(
                        id: model.id,
                        name: model.displayName,
                        usedPercent: usedPercent(from: model),
                        resetAt: model.raw.quotaInfo?.resetDate
                    )
                }
            return QuotaDetailGroup(name: groupName, windows: windows)
        }
    }
}

// MARK: - Internal model wrapper

private struct AgyModel {
    let id: String
    let raw: AgyModelPayload

    var displayName: String {
        raw.displayName ?? id
    }
}

// MARK: - JSON decodable types

private struct AgyQuotaCache: Decodable {
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

private extension JSONDecoder {
    static let agyDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}
