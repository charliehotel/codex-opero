import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LoginItemManager {
    var isEnabled = false
    var errorMessage: String?

    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        guard isAvailable else {
            isEnabled = false
            errorMessage = "Packaged .app에서만 사용할 수 있습니다."
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            errorMessage = nil
        case .requiresApproval:
            isEnabled = false
            errorMessage = "시스템 설정에서 로그인 항목 승인이 필요할 수 있습니다."
        case .notRegistered, .notFound:
            isEnabled = false
            errorMessage = nil
        @unknown default:
            isEnabled = false
            errorMessage = "로그인 항목 상태를 확인할 수 없습니다."
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStatus()
        } catch {
            refreshStatus()
            errorMessage = error.localizedDescription
        }
    }
}
