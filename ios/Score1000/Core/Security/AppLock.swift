import Foundation
import LocalAuthentication
import Observation
import SwiftUI

/// App-level lock. The unlocked state lives only in memory and is never persisted.
@Observable
final class AppLock {
    enum State: Equatable {
        case locked
        case authenticating
        case unlocked
        case failed(String)
    }

    private(set) var state: State = .locked
    /// Seconds the app may stay in the background before it re-locks.
    var relockAfter: TimeInterval = 30
    private var backgroundedAt: Date?

    var isUnlocked: Bool { state == .unlocked }

    /// Name of the available biometry, for button labels.
    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    func unlock() async {
        guard state != .authenticating else { return }
        state = .authenticating
        let result = await Self.authenticate(reason: "Unlock SCORE1000")
        switch result {
        case .success:
            state = .unlocked
        case .failure(let message):
            state = .failed(message)
        }
    }

    func lock() {
        state = .locked
    }

    /// Call from `.onChange(of: scenePhase)`.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
        case .active:
            if let since = backgroundedAt, Date().timeIntervalSince(since) > relockAfter {
                lock()
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    nonisolated enum AuthResult: Equatable, Sendable {
        case success
        case failure(String)
    }

    /// One-off confirmation, e.g. before revealing an API key or switching to real-money mode.
    static func authenticate(reason: String) async -> AuthResult {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        // `.deviceOwnerAuthentication` = biometrics with device-passcode fallback.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .failure(error?.localizedDescription ?? "Set a device passcode to use SCORE1000.")
        }
        // Completion-handler API + explicit @Sendable closure: LocalAuthentication calls back on a
        // private queue, so the closure must not inherit MainActor isolation.
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { @Sendable ok, error in
                continuation.resume(returning: AppLock.mapResult(ok: ok, error: error))
            }
        }
    }

    nonisolated private static func mapResult(ok: Bool, error: Error?) -> AuthResult {
        if ok { return .success }
        guard let laError = error as? LAError else {
            return .failure(error?.localizedDescription ?? "Authentication failed.")
        }
        switch laError.code {
        case .userCancel, .systemCancel, .appCancel:
            return .failure("Cancelled.")
        case .biometryLockout:
            return .failure("Too many attempts. Use your passcode.")
        default:
            return .failure(laError.localizedDescription)
        }
    }
}
