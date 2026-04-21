import Foundation

public enum QuotaFormatter {
    public static func resetString(for window: QuotaWindow) -> String {
        guard let resetAt = window.resetAt else {
            return "unknown reset"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "resets \(formatter.localizedString(for: resetAt, relativeTo: Date()))"
    }

    public static func timestampString(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
