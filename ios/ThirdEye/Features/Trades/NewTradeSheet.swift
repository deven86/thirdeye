import SwiftUI

/// Creates an "Upcoming trade" from an analysis plan or the user's own plan, with position sizing.
struct NewTradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(AppSettings.self) private var settings
    @Environment(TradeStore.self) private var store
    @Environment(MarketStore.self) private var market
    let instrument: Instrument
    /// The analysis this came from (nil = the user's own idea).
    let run: AnalysisRun?
    /// The AI's plan, if it gave one; otherwise the user fills the levels in.
    let plan: TradePlan?
    /// Price to start from (and to sanity-check levels against).
    let referencePrice: Double?

    init(run: AnalysisRun, plan: TradePlan?) {
        instrument = run.instrument
        self.run = run
        self.plan = plan
        referencePrice = run.lastPrice
    }

    init(instrument: Instrument, referencePrice: Double?) {
        self.instrument = instrument
        run = nil
        plan = nil
        self.referencePrice = referencePrice
    }

    @State private var side = "long"
    @State private var holdingDays = "30"

    @State private var entryLow = ""
    @State private var entryHigh = ""
    @State private var stop = ""
    @State private var capital = ""
    @State private var riskPercent = ""
    @State private var quantity = ""
    @State private var stages = 5
    @State private var notes = ""
    @State private var correlations: [String: Double] = [:]
    @State private var overrideGuard = false

    private var verdict: Verdict? { run.flatMap { Verdict(rawValue: $0.verdict ?? "") } }
    private var currency: String { instrument.currency }
    /// Tracked without (or against) an AI recommendation.
    private var againstVerdict: Bool { plan == nil || verdict == .noTrade }

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }

    private var preview: TradePlan? {
        guard let lo = num(entryLow), let hi = num(entryHigh), let sl = num(stop) else { return nil }
        let days = Int(num(holdingDays) ?? 30)
        return TradePlanner.build(.init(side: plan?.side ?? side, entryLow: lo, entryHigh: hi, stopLoss: sl,
                                        holdingDays: plan?.holdingDays ?? days,
                                        invalidation: plan?.invalidation ?? "", rationale: plan?.rationale ?? "Own plan"),
                                  lastPrice: referencePrice ?? (lo + hi) / 2, atr: nil, tick: instrument.tickSize, stages: stages)
    }

    private var mode: TradeMode { settings.paperMode ? .paper : .real }

    private var guardChecks: [RiskGuard.Check] {
        var out = [RiskGuard.weeklyCheck(store.trades, mode: mode, limitR: settings.weeklyLossLimitR, now: Date())]
        if let p = preview, let q = num(quantity), q > 0,
           let open = RiskGuard.openRiskCheck(store.trades, mode: mode, currency: currency, newRisk: abs(p.entryMid - p.stopLoss) * q * instrument.contractSize,
                                              capital: num(capital), capPercent: settings.maxOpenRiskPercent) {
            out.append(open)
        }
        if let same = RiskGuard.sameBetCheck(newInstrument: instrument, side: plan?.side ?? side, trades: store.trades,
                                             mode: mode, correlations: correlations) {
            out.append(same)
        }
        return out
    }

    private var guardSaysStop: Bool { guardChecks.contains { $0.level == .stop } }

    private var suggestedQuantity: Double {
        guard let p = preview, let c = num(capital), let r = num(riskPercent) else { return 0 }
        return TradeMath.positionSize(capital: c, riskPercent: r, entry: p.entryMid, stop: p.stopLoss, lotSize: instrument.lotSize,
                                       contractSize: instrument.contractSize)
    }

    var body: some View {
        NavigationStack {
            Form {
                if againstVerdict {
                    Section {
                        Label(run == nil ? "Your own plan, not an AI recommendation. It will be marked “own idea” in your journal."
                                         : "The analysis did not recommend this trade. It will be marked “against verdict” in your journal.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(palette.warning)
                    }
                }
                if plan == nil {
                    Section {
                        Picker("Direction", selection: $side) {
                            Text("Long (buy)").tag("long")
                            Text("Short (sell)").tag("short")
                        }
                        .pickerStyle(.segmented)
                        field("Holding days", $holdingDays)
                        if let referencePrice { LabeledContent("Price now", value: plainPrice(referencePrice)) }
                    }
                }
                Section("Levels (\((plan?.side ?? side).uppercased()) · \(currency))") {
                    field("Entry from", $entryLow)
                    field("Entry to", $entryHigh)
                    field("Stop-loss", $stop)
                    Picker("Take-profit stages", selection: $stages) {
                        Text("3 stages").tag(3); Text("5 stages").tag(5)
                    }
                    .pickerStyle(.menu)
                    if let p = preview {
                        ForEach(p.takeProfits, id: \.stage) { tp in
                            LabeledContent("TP\(tp.stage) · book \(Int(tp.bookPercent))%", value: tp.price.map { fmt($0) } ?? "Trailing")
                        }
                        ForEach(p.issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(palette.warning) }
                    }
                }
                Section {
                    field("Capital for this market", $capital)
                    field("Risk per trade (%)", $riskPercent)
                    LabeledContent(instrument.contractSize > 1 ? "Suggested lots" : "Suggested quantity", value: suggestedQuantity.formatted())
                    field(instrument.contractSize > 1 ? "Lots you plan" : "Quantity you plan", $quantity)
                    if let p = preview, let q = num(quantity), q > 0 {
                        LabeledContent("Money at risk", value: fmt(abs(p.entryMid - p.stopLoss) * q * instrument.contractSize))
                        LabeledContent("Position value", value: fmt(p.entryMid * q * instrument.contractSize))
                    }
                } header: {
                    Text("Position size")
                } footer: {
                    Text("Suggested quantity loses \(riskPercent.isEmpty ? "—" : riskPercent)% of capital if the stop is hit\(instrument.lotSize.map { $0 > 1 ? ", rounded down to lots of \(Int($0))" : "" } ?? "").\(instrument.contractSize > 1 ? " Counted in lots like MetaTrader: 1 lot = \(Int(instrument.contractSize).formatted()) units, 0.01 = micro lot." : "")")
                }
                Section {
                    ForEach(guardChecks) { c in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.callout.weight(.semibold))
                                Text(c.detail).font(.caption).foregroundStyle(palette.textSecondary)
                            }
                        } icon: {
                            Image(systemName: c.level == .ok ? "checkmark.shield" : c.level == .caution ? "exclamationmark.triangle" : "hand.raised.fill")
                                .foregroundStyle(c.level == .ok ? palette.up : c.level == .caution ? palette.warning : palette.down)
                        }
                    }
                    if guardSaysStop {
                        Toggle("I understand — save anyway", isOn: $overrideGuard)
                    }
                } header: {
                    Text("Risk guard")
                }
                Section("Notes") {
                    TextField("Why you are taking it", text: $notes, axis: .vertical)
                }
                Section {
                    LabeledContent("Mode", value: settings.paperMode ? "Paper" : "Real money")
                    if let p = preview { LabeledContent("Complete by", value: p.completeBy.formatted(date: .abbreviated, time: .omitted)) }
                }
            }
            .navigationTitle(plan == nil ? "Track a trade" : "New upcoming trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(preview == nil || !(preview?.issues.isEmpty ?? false) || (num(quantity) ?? 0) <= 0
                                  || (guardSaysStop && !overrideGuard))
                }
            }
            .onAppear(perform: prefill)
            .task { await measureCorrelations() }
            .onChange(of: side) { _, _ in if plan == nil { prefill() } }
            .onChange(of: suggestedQuantity) { _, q in if quantity.isEmpty || num(quantity) == 0 { quantity = q > 0 ? q.formatted(.number.grouping(.never)) : "" } }
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }

    private func fmt(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 10 ? 4 : 2)).locale(Locale(identifier: currency == "INR" ? "en_IN" : "en_US")))
    }

    private func prefill() {
        let plain = { (v: Double) in v.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) }
        if let plan {
            entryLow = plain(plan.entryLow)
            entryHigh = plain(plan.entryHigh)
            stop = plain(plan.stopLoss)
            stages = plan.takeProfits.count == 3 ? 3 : 5
        } else if let p = referencePrice {
            // Starting point only: a narrow zone around the price and a 3 % stop. Adjust to your own levels.
            entryLow = plain(roundTo(p * 0.998))
            entryHigh = plain(roundTo(p * 1.002))
            stop = plain(roundTo(side == "long" ? p * 0.97 : p * 1.03))
        }
        riskPercent = plain(settings.riskPercent)
        if let c = settings.capital[currency], c > 0 { capital = plain(c) }
    }

    /// 60-day daily-return correlation with each product you already hold or plan (max 5, so data limits hold).
    private func measureCorrelations() async {
        var seen = Set<String>()
        let others = store.trades
            .filter { $0.mode == mode && ($0.status == .open || $0.status == .upcoming) && $0.instrument.id != instrument.id }
            .map(\.instrument)
            .filter { seen.insert($0.id).inserted }
        guard !others.isEmpty, let mine = try? await market.candles(for: instrument, timeframe: .d1) else { return }
        for other in others.prefix(5) {
            if let theirs = try? await market.candles(for: other, timeframe: .d1),
               let rho = RiskGuard.returnCorrelation(mine, theirs) {
                correlations[other.id] = rho
            }
        }
    }

    private func roundTo(_ v: Double) -> Double {
        let m = pow(10, Double(v < 10 ? 4 : 2))
        return (v * m).rounded() / m
    }

    private func save() {
        guard let p = preview, let q = num(quantity), q > 0 else { return }
        if let c = num(capital), c > 0 { settings.capital[currency] = c }
        if let r = num(riskPercent), r > 0 { settings.riskPercent = r }
        let trade = Trade(instrument: instrument, analysisID: run?.id, analysisScore: run?.composite, analysisVerdict: run?.verdict,
                          mode: settings.paperMode ? .paper : .real, side: p.side, status: .upcoming,
                          plannedEntryLow: p.entryLow, plannedEntryHigh: p.entryHigh, stopLoss: p.stopLoss, initialStop: p.stopLoss,
                          takeProfits: p.takeProfits, plannedQuantity: q, badge: p.badge, completeBy: p.completeBy,
                          notes: notes, againstVerdict: againstVerdict, watchBaseline: run?.watchBaseline)
        store.save(trade)
        dismiss()
    }
}
