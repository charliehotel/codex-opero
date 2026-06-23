import AppKit
import SwiftUI
import QuotaCore

struct UpdateStatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    let currentVersion: AppVersion?
    let availableUpdate: AvailableUpdate?

    var body: some View {
        if let availableUpdate {
            Button {
                NSWorkspace.shared.open(availableUpdate.releaseURL)
            } label: {
                Text(availableUpdate.displayString)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .opacity(reduceMotion ? 1 : (isDimmed ? 0.45 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(availableUpdate.latestVersion.displayString) 업데이트 가능, GitHub Releases 열기"
            )
            .accessibilityAddTraits(.isLink)
            .onAppear {
                updateAnimation()
            }
            .onChange(of: reduceMotion) {
                updateAnimation()
            }
        } else if let currentVersion {
            Text(currentVersion.displayString)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private func updateAnimation() {
        if reduceMotion {
            withAnimation(nil) {
                isDimmed = false
            }
        } else {
            isDimmed = false
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isDimmed = true
            }
        }
    }
}
