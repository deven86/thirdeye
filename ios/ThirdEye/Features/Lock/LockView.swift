import SwiftUI

struct LockView: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @State private var didAutoPrompt = false

    var body: some View {
        ZStack {
            SkinBackdrop()
            VStack(spacing: 28) {
                Spacer()
                ScoreGauge(score: 900)
                    .frame(maxWidth: 260)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Third Eye")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                    Text("Private market analysis")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer()
                if case .failed(let message) = lock.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(palette.warning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                AdaptiveButton(title: "Unlock with \(lock.biometryName)",
                               systemImage: lock.biometryName == "Face ID" ? "faceid" : "lock.open") {
                    Task { await lock.unlock() }
                }
                .disabled(lock.state == .authenticating)
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                Text("Personal analytical tool · not investment advice")
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.bottom, 8)
            }
        }
        .task(id: scenePhase) {
            // Prompt automatically once per lock, when the app is in front.
            guard scenePhase == .active, !didAutoPrompt, lock.state == .locked else { return }
            didAutoPrompt = true
            await lock.unlock()
        }
        .onChange(of: lock.state) { _, state in
            if state == .locked { didAutoPrompt = false }
        }
    }
}
