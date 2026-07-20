import Foundation
import QuotaCore

@main
struct QuotaPeekCLI {
    static func main() async {
        let providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider(), AntigravityProvider()]

        for provider in providers {
            do {
                let quota = try await provider.fetchQuota()
                let pStr = quota.primary.remainingPercent.map { "\($0)%" } ?? "--"
                let sStr = quota.secondary.remainingPercent.map { "\($0)%" } ?? "--"
                print("\(quota.providerID.displayName): \(pStr)/\(sStr)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("\(provider.providerID.displayName): --/-- (\(message))")
            }
        }
    }
}
