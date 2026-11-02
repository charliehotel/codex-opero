import AppKit
import SwiftUI
import QuotaCore

struct UpdateStatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    let currentVersion: AppVersion?
    let availableUpdate: AvailableUpdate?
    let isChecking: Bool
    let checkForUpdates: () -> Void

    var body: some View {
        if isChecking {
            Text("확인 중…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let availableUpdate {
            Button(action: checkForUpdates) {
                Text(availableUpdate.displayString)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .opacity(isDimmed ? 0.45 : 1)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isDimmed
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(availableUpdate.latestVersion.displayString) 업데이트 가능, 릴리즈 노트 보기"
            )
            .help("새 버전 확인")
            .onAppear {
                updateAnimation()
            }
            .onChange(of: reduceMotion) {
                updateAnimation()
            }
        } else if let currentVersion {
            Button(action: checkForUpdates) {
                Text(currentVersion.displayString)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(currentVersion.displayString), 업데이트 확인")
            .help("업데이트 확인")
        }
    }

    private func updateAnimation() {
        isDimmed = reduceMotion == false
    }
}
