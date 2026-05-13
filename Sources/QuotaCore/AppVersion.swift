import Foundation

public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let core = withoutPrefix
            .components(separatedBy: "-")[0]
            .components(separatedBy: "+")[0]
        let parts = core.split(separator: ".")
        let parsed = parts.compactMap { Int($0) }

        guard parsed.isEmpty == false,
              parsed.count == parts.count else {
            return nil
        }

        self.components = parsed
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}
