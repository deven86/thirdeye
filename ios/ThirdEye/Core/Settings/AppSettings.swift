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
        static let riskPercent = "settings.riskPercent"
        static let capital = "settings.capitalByCurrency"
        static let hotMarket = "settings.hotMarket"
        static let hotProfile = "settings.hotProfile"
        static let hotCandidates = "settings.hotCandidates"
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

    /// Risk per trade for position sizing (spec default 1 %, max 2 %).
    var riskPercent: Double {
        didSet { defaults.set(riskPercent, forKey: Keys.riskPercent) }
    }

    /// Trading capital per currency (never converted between currencies).
    var capital: [String: Double] {
        didSet { defaults.set(capital, forKey: Keys.capital) }
    }

    /// Market and holding style for Hot trades.
    var hotMarket: HotMarket {
        didSet { defaults.set(hotMarket.rawValue, forKey: Keys.hotMarket) }
    }

    var hotProfile: HoldingProfile {
        didSet { defaults.set(hotProfile.rawValue, forKey: Keys.hotProfile) }
    }

    /// How many shortlisted products get the full 10-stage analysis (3 or 5).
    var hotCandidates: Int {
        didSet { defaults.set(hotCandidates, forKey: Keys.hotCandidates) }
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
        let risk = defaults.double(forKey: Keys.riskPercent)
        riskPercent = risk > 0 ? risk : 1
        capital = defaults.dictionary(forKey: Keys.capital) as? [String: Double] ?? [:]
        hotMarket = HotMarket(rawValue: defaults.string(forKey: Keys.hotMarket) ?? "") ?? .crypto
        hotProfile = HoldingProfile(rawValue: defaults.string(forKey: Keys.hotProfile) ?? "") ?? .swing
        let candidates = defaults.integer(forKey: Keys.hotCandidates)
        hotCandidates = candidates == 5 ? 5 : 3
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
