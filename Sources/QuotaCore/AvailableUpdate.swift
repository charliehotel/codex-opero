import Foundation

public struct AvailableUpdate: Equatable, Sendable {
    public let currentVersion: AppVersion
    public let latestVersion: AppVersion
    public let releaseURL: URL

    public init(
        currentVersion: AppVersion,
        latestVersion: AppVersion,
        releaseURL: URL
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.releaseURL = releaseURL
    }

    public var displayString: String {
        "\(currentVersion.displayString) → \(latestVersion.displayString)"
    }
}
