import Foundation

public enum QuotaFormatter {
    public static func resetString(for window: QuotaWindow) -> String {
        guard let resetAt = window.resetAt else {
            return "reset unknown"
        }

        let seconds = max(0, Int(resetAt.timeIntervalSinceNow.rounded()))
        return "resets in \(shortIntervalString(seconds: seconds))"
    }

    public static func timestampString(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func shortIntervalString(seconds: Int) -> String {
        let day = 86_400
        let hour = 3_600
        let minute = 60

        if seconds >= day {
            return "\(seconds / day)d"
        }
        if seconds >= hour {
            return "\(seconds / hour)h"
        }
        if seconds >= minute {
            return "\(seconds / minute)m"
        }
        return "<1m"
    }
}
