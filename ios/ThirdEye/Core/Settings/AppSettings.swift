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
        static let stageReuseHours = "settings.stageReuseHours"
        static let weeklyLossLimitR = "settings.weeklyLossLimitR"
        static let maxOpenRiskPercent = "settings.maxOpenRiskPercent"
        static let skippedStages = "settings.skippedStagesByProfile"
        static let autoAIReview = "settings.autoAIReview"
        static let watchNotifications = "settings.watchNotifications"
        static let autoImportUpstox = "settings.autoImportUpstox"
        static let skin = "settings.skin"
        static let skinDim = "settings.skinDim"
        static let skinPhotoVersion = "settings.skinPhotoVersion"
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

    /// Reuse news/events/context stages from an analysis of the same product within this many hours (0 = off).
    var stageReuseHours: Int {
        didSet { defaults.set(stageReuseHours, forKey: Keys.stageReuseHours) }
    }

    /// Risk guard: pause suggestion after losing this many R in 7 days, and the cap on total open risk (% of capital).
    var weeklyLossLimitR: Double {
        didSet { defaults.set(weeklyLossLimitR, forKey: Keys.weeklyLossLimitR) }
    }

    var maxOpenRiskPercent: Double {
        didSet { defaults.set(maxOpenRiskPercent, forKey: Keys.maxOpenRiskPercent) }
    }

    var tierAssignments: [ModelTier: ModelRef] {
        didSet { saveAssignments() }
    }

    /// Stages the user turned off, per holding profile (stage 10 can't be skipped).
    var skippedStagesByProfile: [String: [Int]] {
        didSet { defaults.set(skippedStagesByProfile, forKey: Keys.skippedStages) }
    }

    func skippedStages(for profile: HoldingProfile) -> Set<Int> {
        Set(skippedStagesByProfile[profile.rawValue] ?? []).intersection(1...9)
    }

    func setSkipped(_ skip: Set<Int>, for profile: HoldingProfile) {
        skippedStagesByProfile[profile.rawValue] = skip.intersection(1...9).sorted()
    }

    /// Trade watch: ask the AI to re-check an open trade automatically when its parameters change.
    var autoAIReview: Bool {
        didSet { defaults.set(autoAIReview, forKey: Keys.autoAIReview) }
    }

    /// Upstox: add fills that match a Third Eye trade automatically.
    var autoImportUpstox: Bool {
        didSet { defaults.set(autoImportUpstox, forKey: Keys.autoImportUpstox) }
    }

    /// Wallpaper skin behind every screen (Winamp-style); .none = the theme's own background.
    var skin: Skin {
        didSet { defaults.set(skin.rawValue, forKey: Keys.skin) }
    }

    /// 0 … 0.7 black over the wallpaper.
    var skinDim: Double {
        didSet { defaults.set(skinDim, forKey: Keys.skinDim) }
    }

    /// Bumped when the user picks a new photo, so cached images refresh.
    var skinPhotoVersion: Int {
        didSet { defaults.set(skinPhotoVersion, forKey: Keys.skinPhotoVersion) }
    }

    /// Trade watch: notify on this iPhone when a trade's parameters change.
    var watchNotifications: Bool {
        didSet { defaults.set(watchNotifications, forKey: Keys.watchNotifications) }
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
        stageReuseHours = defaults.object(forKey: Keys.stageReuseHours) as? Int ?? 12
        let lossLimit = defaults.double(forKey: Keys.weeklyLossLimitR)
        weeklyLossLimitR = lossLimit > 0 ? lossLimit : 3
        let openCap = defaults.double(forKey: Keys.maxOpenRiskPercent)
        maxOpenRiskPercent = openCap > 0 ? openCap : 6
        skippedStagesByProfile = defaults.dictionary(forKey: Keys.skippedStages) as? [String: [Int]] ?? [:]
        autoAIReview = defaults.object(forKey: Keys.autoAIReview) as? Bool ?? true
        watchNotifications = defaults.object(forKey: Keys.watchNotifications) as? Bool ?? true
        autoImportUpstox = defaults.object(forKey: Keys.autoImportUpstox) as? Bool ?? true
        skin = Skin(rawValue: defaults.string(forKey: Keys.skin) ?? "") ?? .none
        skinDim = defaults.object(forKey: Keys.skinDim) as? Double ?? 0.25
        skinPhotoVersion = defaults.integer(forKey: Keys.skinPhotoVersion)
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
