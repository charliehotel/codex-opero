import Foundation
import QuotaCore

@main
struct QuotaPeekCLI {
    static func main() async {
        let providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider()]

        for provider in providers {
            do {
                let quota = try await provider.fetchQuota()
                print("\(quota.providerID.displayName): \(quota.primary.remainingPercent)%/\(quota.secondary.remainingPercent)%")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("\(provider.providerID.displayName): --/-- (\(message))")
            }
        }
    }
}
