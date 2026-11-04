import Foundation
import Observation

/// Non-secret preferences. Persisted in UserDefaults for M1; moves to SwiftData + CloudKit in M2.
/// Never store keys or tokens here.
@Observable
final class AppSettings {
    private enum Keys {
        static let theme = "settings.theme"
        static let colorBlindSafe = "settings.colorBlindSafe"
        static let relockSeconds = "settings.relockSeconds"
        static let tierAssignments = "settings.tierAssignments"
        static let paperMode = "settings.paperMode"
        static let hideLockScreenPnL = "settings.hideLockScreenPnL"
    }

    private let defaults: UserDefaults

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// Blue/orange instead of green/red for up/down.
    var colorBlindSafe: Bool {
        didSet { defaults.set(colorBlindSafe, forKey: Keys.colorBlindSafe) }
    }

    var relockSeconds: Int {
        didSet { defaults.set(relockSeconds, forKey: Keys.relockSeconds) }
    }

    /// Paper-trading is the default. Real-money mode requires Face ID to enable (M5).
    var paperMode: Bool {
        didSet { defaults.set(paperMode, forKey: Keys.paperMode) }
    }

    var hideLockScreenPnL: Bool {
        didSet { defaults.set(hideLockScreenPnL, forKey: Keys.hideLockScreenPnL) }
    }

    var tierAssignments: [ModelTier: ModelRef] {
        didSet { saveAssignments() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .liquidGlass
        colorBlindSafe = defaults.bool(forKey: Keys.colorBlindSafe)
        let relock = defaults.integer(forKey: Keys.relockSeconds)
        relockSeconds = relock == 0 ? 30 : relock
        paperMode = defaults.object(forKey: Keys.paperMode) as? Bool ?? true
        hideLockScreenPnL = defaults.object(forKey: Keys.hideLockScreenPnL) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.tierAssignments),
           let decoded = try? JSONDecoder().decode([String: ModelRef].self, from: data) {
            var map: [ModelTier: ModelRef] = [:]
            for (key, value) in decoded {
                if let tier = ModelTier(rawValue: key) { map[tier] = value }
            }
            tierAssignments = map
        } else {
            tierAssignments = [:]
        }
    }

    private func saveAssignments() {
        let encodable = Dictionary(uniqueKeysWithValues: tierAssignments.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: Keys.tierAssignments)
        }
    }

    /// Fills only the tiers the user has not chosen yet.
    func fillMissingTiers(from models: [AIModelInfo]) {
        let suggestions = TierSuggester.defaultAssignments(from: models)
        var updated = tierAssignments
        for (tier, ref) in suggestions where updated[tier] == nil {
            updated[tier] = ref
        }
        if updated != tierAssignments { tierAssignments = updated }
    }
}
