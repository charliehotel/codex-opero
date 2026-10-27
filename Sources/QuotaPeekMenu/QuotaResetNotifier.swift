import AppKit
import Foundation
import QuotaCore
import UserNotifications

final class QuotaResetNotifier: NSObject, UNUserNotificationCenterDelegate {
    @MainActor
    static let shared = QuotaResetNotifier()
    private static let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"

    private override init() {
        super.init()
    }

    @MainActor
    func notify(_ event: QuotaResetEvent) async -> Bool {
        await Self.sendNotification(for: event)
    }

    @MainActor
    private static func sendNotification(for event: QuotaResetEvent) async -> Bool {
        guard isAppBundle else {
            return sendUnbundledNotification(for: event)
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    return sendUnbundledNotification(for: event)
                }
            } catch {
                return sendUnbundledNotification(for: event)
            }
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return sendUnbundledNotification(for: event)
        @unknown default:
            return sendUnbundledNotification(for: event)
        }

        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: event)
        content.body = notificationBody(for: event)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "quota-reset-\(event.providerID.rawValue)-\(event.resetMarker)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return sendUnbundledNotification(for: event)
        }
    }

    @MainActor
    private static func sendUnbundledNotification(for event: QuotaResetEvent) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            #"display notification "\#(notificationBody(for: event).escapedForAppleScript)" with title "\#(notificationTitle(for: event).escapedForAppleScript)""#,
        ]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func notificationTitle(for event: QuotaResetEvent) -> String {
        switch event.kind {
        case .shortWindow:
            return "\(event.providerID.displayName) 5h quota reset"
        case .weeklyWindow:
            return "\(event.providerID.displayName) weekly quota reset"
        case .modelBucket:
            return "\(event.providerID.displayName) \(event.windowName) quota reset"
        }
    }

    private static func notificationBody(for event: QuotaResetEvent) -> String {
        switch event.kind {
        case .shortWindow:
            return "You can use \(event.providerID.displayName) again."
        case .weeklyWindow:
            return "Weekly usage is back to 100%."
        case .modelBucket:
            return "\(event.windowName) usage is back to 100%."
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

private extension String {
    var escapedForAppleScript: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
