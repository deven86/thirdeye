import SwiftUI

/// Turns an analysis plan into an "Upcoming trade", with position sizing.
struct NewTradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(AppSettings.self) private var settings
    @Environment(TradeStore.self) private var store
    let run: AnalysisRun
    let plan: TradePlan

    @State private var entryLow = ""
    @State private var entryHigh = ""
    @State private var stop = ""
    @State private var capital = ""
    @State private var riskPercent = ""
    @State private var quantity = ""
    @State private var stages = 5
    @State private var notes = ""

    private var verdict: Verdict { Verdict(rawValue: run.verdict ?? "") ?? .noTrade }
    private var currency: String { run.instrument.currency }

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }

    private var preview: TradePlan? {
        guard let lo = num(entryLow), let hi = num(entryHigh), let sl = num(stop), let price = run.lastPrice else { return nil }
        return TradePlanner.build(.init(side: plan.side, entryLow: lo, entryHigh: hi, stopLoss: sl, holdingDays: plan.holdingDays,
                                        invalidation: plan.invalidation, rationale: plan.rationale),
                                  lastPrice: price, atr: nil, tick: run.instrument.tickSize, stages: stages)
    }

    private var suggestedQuantity: Double {
        guard let p = preview, let c = num(capital), let r = num(riskPercent) else { return 0 }
        return TradeMath.positionSize(capital: c, riskPercent: r, entry: p.entryMid, stop: p.stopLoss, lotSize: run.instrument.lotSize)
    }

    var body: some View {
        NavigationStack {
            Form {
                if verdict == .noTrade {
                    Section {
                        Label("The analysis verdict was No trade. You can still track this idea; it will be marked “against verdict” in your journal.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(palette.warning)
                    }
                }
                Section("Levels (\(plan.side.uppercased()) · \(currency))") {
                    field("Entry from", $entryLow)
                    field("Entry to", $entryHigh)
                    field("Stop-loss", $stop)
                    Picker("Take-profit stages", selection: $stages) {
                        Text("3").tag(3); Text("5").tag(5)
                    }
                    .pickerStyle(.segmented)
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
                    LabeledContent("Suggested quantity", value: suggestedQuantity.formatted())
                    field("Quantity you plan", $quantity)
                    if let p = preview, let q = num(quantity), q > 0 {
                        LabeledContent("Money at risk", value: fmt(abs(p.entryMid - p.stopLoss) * q))
                        LabeledContent("Position value", value: fmt(p.entryMid * q))
                    }
                } header: {
                    Text("Position size")
                } footer: {
                    Text("Suggested quantity loses \(riskPercent.isEmpty ? "—" : riskPercent)% of capital if the stop is hit\(run.instrument.lotSize.map { $0 > 1 ? ", rounded down to lots of \(Int($0))" : "" } ?? "").")
                }
                Section("Notes") {
                    TextField("Why you are taking it", text: $notes, axis: .vertical)
                }
                Section {
                    LabeledContent("Mode", value: settings.paperMode ? "Paper" : "Real money")
                    LabeledContent("Complete by", value: plan.completeBy.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .navigationTitle("New upcoming trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(preview == nil || !(preview?.issues.isEmpty ?? false) || (num(quantity) ?? 0) <= 0)
                }
            }
            .onAppear(perform: prefill)
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
        entryLow = plain(plan.entryLow)
        entryHigh = plain(plan.entryHigh)
        stop = plain(plan.stopLoss)
        stages = plan.takeProfits.count == 3 ? 3 : 5
        riskPercent = plain(settings.riskPercent)
        if let c = settings.capital[currency], c > 0 { capital = plain(c) }
    }

    private func save() {
        guard let p = preview, let q = num(quantity), q > 0 else { return }
        if let c = num(capital), c > 0 { settings.capital[currency] = c }
        if let r = num(riskPercent), r > 0 { settings.riskPercent = r }
        let trade = Trade(instrument: run.instrument, analysisID: run.id, analysisScore: run.composite, analysisVerdict: run.verdict,
                          mode: settings.paperMode ? .paper : .real, side: p.side, status: .upcoming,
                          plannedEntryLow: p.entryLow, plannedEntryHigh: p.entryHigh, stopLoss: p.stopLoss, initialStop: p.stopLoss,
                          takeProfits: p.takeProfits, plannedQuantity: q, badge: plan.badge, completeBy: plan.completeBy,
                          notes: notes, againstVerdict: verdict == .noTrade)
        store.save(trade)
        dismiss()
    }
}
