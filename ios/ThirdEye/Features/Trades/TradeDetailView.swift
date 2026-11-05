import SwiftUI

struct TradeDetailView: View {
    @Environment(TradeStore.self) private var store
    @Environment(MarketStore.self) private var market
    @Environment(AnalysisStore.self) private var analyses
    @Environment(AppSettings.self) private var settings
    @Environment(TradeGuardian.self) private var guardian
    @Environment(LiveActivityManager.self) private var live
    @Environment(MonitorStore.self) private var monitor
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var liveTick = 0
    let tradeID: UUID
    let prices: PriceBook

    @State private var sheet: FillSheet.Kind?
    @State private var editingFill: Fill?
    @State private var editPlan = false
    @State private var showMoveStop = false
    @State private var newStop = ""
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    var body: some View {
        if let t = store.trade(id: tradeID) {
            content(t)
        } else {
            ContentUnavailableView("Trade removed", systemImage: "trash")
        }
    }

    private func content(_ t: Trade) -> some View {
        let price = prices.price(t.instrument)
        let s = TradeMath.summary(t, lastPrice: price)
        let cur = t.instrument.currency
        return List {
            Section {
                HStack {
                    Text(t.side.uppercased()).font(.headline).foregroundStyle(t.isLong ? palette.up : palette.down)
                    Chip(text: t.badge.title, color: palette.accent)
                    Chip(text: t.mode.title, color: t.mode == .real ? palette.warning : palette.neutral)
                    if t.againstVerdict { Chip(text: t.analysisID == nil ? "Own idea" : "Against verdict", color: palette.warning) }
                    Spacer()
                    SignalLabel(signal: TradeMath.signal(t, lastPrice: price), trade: t)
                }
                if let price { LabeledContent("Price now", value: plainPrice(price)) }
                if let score = t.analysisScore {
                    LabeledContent("Analysis", value: "\(score) · \(Verdict(rawValue: t.analysisVerdict ?? "")?.title ?? "—")")
                }
                LabeledContent("Complete by", value: t.completeBy.formatted(date: .abbreviated, time: .omitted))
            }

            Section {
                TradeChartView(instrument: t.instrument, levels: TradeChart.levels(t), markers: TradeChart.markers(t),
                               defaultTimeframe: TradeWatch.timeframe(for: t, run: run(t)))
                    .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
            } header: {
                Text("Chart")
            } footer: {
                Text("Dashed blue: entry zone · solid blue: your average entry · red: stop · green: take-profits (✓ booked). Arrows mark when you entered and exited.")
            }

            if t.status == .open || t.status == .closed {
                Section("Profit & loss (\(cur))") {
                    LabeledContent("Invested", value: money(s.invested, cur))
                    LabeledContent("Average entry", value: s.averageEntry.map(plainPrice) ?? "—")
                    LabeledContent("Open quantity", value: s.openQuantity.formatted())
                    LabeledContent("Realised", value: money(s.realized, cur, signed: true))
                    if t.status == .open {
                        LabeledContent("Unrealised", value: s.unrealized.map { money($0, cur, signed: true) } ?? "waiting for price")
                    }
                    if let total = s.total {
                        LabeledContent("Total", value: money(total, cur, signed: true)).bold()
                            .foregroundStyle(total >= 0 ? palette.up : palette.down)
                    }
                    if let pct = s.returnPercent { LabeledContent("Return", value: String(format: "%+.2f%%", pct)) }
                    if let r = s.rMultiple { LabeledContent("R-multiple", value: String(format: "%+.2fR", r)) }
                    if s.fees > 0 { LabeledContent("Fees", value: money(s.fees, cur)) }
                }
            }

            Section("Plan") {
                LabeledContent("Entry zone", value: "\(plainPrice(t.plannedEntryLow)) – \(plainPrice(t.plannedEntryHigh))")
                LabeledContent("Stop-loss", value: plainPrice(t.stopLoss) + (t.stopLoss != t.initialStop ? " (moved from \(plainPrice(t.initialStop)))" : ""))
                let booked = Set(t.fills.compactMap(\.takeProfitStage))
                ForEach(t.takeProfits, id: \.stage) { tp in
                    HStack {
                        Image(systemName: booked.contains(tp.stage) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(booked.contains(tp.stage) ? palette.up : palette.neutral)
                        Text("TP\(tp.stage) · book \(Int(tp.bookPercent))%")
                        Spacer()
                        Text(tp.price.map(plainPrice) ?? "Trailing").monospacedDigit()
                    }
                }
                LabeledContent(t.instrument.contractSize > 1 ? "Planned lots" : "Planned quantity",
                               value: t.plannedQuantity.formatted() + (t.instrument.contractSize > 1 ? " (\((t.plannedQuantity * t.instrument.contractSize).formatted()) units)" : ""))
                Button { editPlan = true } label: { Label("Edit plan", systemImage: "pencil") }
            }

            if t.status == .open {
                watchSection(t, price: price)
            } else if t.status == .upcoming {
                Section("Trade watch") {
                    Text("Starts when you record your entry: Third Eye then re-checks the reasons for this trade and tells you if they change.")
                        .font(.caption).foregroundStyle(palette.textSecondary)
                }
            }

            if !t.fills.isEmpty {
                Section {
                    ForEach(t.fills.sorted { $0.date < $1.date }) { f in
                        Button { editingFill = f } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(f.kind == .entry ? "Entry" : (f.takeProfitStage.map { "Exit · TP\($0)" } ?? "Exit"))
                                    .font(.callout.weight(.semibold))
                                Spacer()
                                Text("\(f.quantity.formatted()) @ \(plainPrice(f.price))").monospacedDigit()
                            }
                            Text(f.date.formatted(date: .abbreviated, time: .shortened) + (f.fees > 0 ? " · fees \(money(f.fees, cur))" : "") + (f.note.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(palette.textSecondary)
                        }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { store.deleteFill(t, id: f.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("Fills")
                } footer: {
                    Text("Tap a fill to correct it; swipe left to delete it.\(t.instrument.contractSize > 1 ? " Quantities are in lots (1 lot = \(Int(t.instrument.contractSize).formatted()) units), like MetaTrader." : "")")
                }
            }

            if t.status == .open || t.status == .upcoming {
                let showing = liveTick >= 0 && live.isShowing(t.id)
                Section {
                    Button {
                        Task {
                            if showing { await live.stop(t.id, monitor: monitor) }
                            else { live.start(t, price: price, monitor: monitor) }
                            liveTick += 1
                        }
                    } label: {
                        Label(showing ? "Remove from Lock Screen" : "Show on Lock Screen", systemImage: showing ? "lock.slash" : "lock.iphone")
                    }
                    if let err = live.lastError { Text(err).font(.caption).foregroundStyle(palette.warning) }
                } header: {
                    Text("Lock Screen & Dynamic Island")
                } footer: {
                    Text(monitor.isPaired
                         ? "Live price, result in R and distance to the stop and next target. Your PC keeps it updated while Third Eye is closed. iOS ends it after about 8 hours — opening Third Eye starts it again."
                         : "Live price and result in R while Third Eye is open. Connect your PC (Settings → Alerts) to keep it updated while the app is closed.")
                }
            }

            if !t.notes.isEmpty { Section("Notes") { Text(t.notes) } }

            Section {
                if t.status == .upcoming || t.status == .open {
                    Button { sheet = .entry } label: { Label(t.status == .upcoming ? "I entered this trade" : "Add to position", systemImage: "arrow.down.to.line") }
                }
                if t.status == .open {
                    Button { sheet = .exit } label: { Label("Record exit / take profit", systemImage: "arrow.up.right") }
                    Button { newStop = plainPrice(t.stopLoss); showMoveStop = true } label: { Label("Move stop-loss", systemImage: "arrow.up.and.down") }
                }
                if let id = t.analysisID, let run = analyses.runs.first(where: { $0.id == id }) {
                    NavigationLink { AnalysisReportView(run: run).navigationTitle(run.instrument.symbol) } label: {
                        Label("Open the analysis", systemImage: "doc.text.magnifyingglass")
                    }
                }
                if t.status == .upcoming {
                    Button(role: .destructive) { confirmCancel = true } label: { Label("Cancel — didn't enter", systemImage: "xmark") }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
            Section {
                Text("Keep a real stop-loss order at your broker. This app does not place orders, and in-app hints only update while the app is open.")
                    .font(.caption).foregroundStyle(palette.textSecondary)
            }
        }
        .navigationTitle(t.instrument.symbol)
        .sheet(item: $sheet) { kind in FillSheet(kind: kind, trade: t, price: price) }
        .sheet(item: $editingFill) { f in FillSheet(kind: f.kind == .entry ? .entry : .exit, trade: t, price: price, editing: f) }
        .sheet(isPresented: $editPlan) { EditPlanSheet(trade: t) }
        .alert("Move stop-loss", isPresented: $showMoveStop) {
            TextField("New stop", text: $newStop).keyboardType(.decimalPad)
            Button("Save") {
                if let v = Double(newStop.replacingOccurrences(of: ",", with: "")) {
                    var u = t; u.stopLoss = v; store.save(u)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only tighten a stop (move it toward profit). Widening it increases your risk.")
        }
        .confirmationDialog("Cancel this upcoming trade?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel trade", role: .destructive) { store.cancel(t) }
        }
        .confirmationDialog("Delete this trade from iPhone and iPad? This also removes it from your journal.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(t); dismiss() }
        }
        .task {
            while !Task.isCancelled && (t.status == .open || t.status == .upcoming) {
                await prices.refresh([t.instrument], market: market)
                if let p = prices.price(t.instrument), let fresh = store.trade(id: t.id) { await live.update(fresh, price: p) }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

extension TradeDetailView {
    private func run(_ t: Trade) -> AnalysisRun? {
        t.analysisID.flatMap { id in analyses.runs.first { $0.id == id } }
    }

    @ViewBuilder
    func watchSection(_ t: Trade, price: Double?) -> some View {
        let check = guardian.current(for: t)
        let busy = guardian.working.contains(t.id)
        let reviewing = guardian.reviewing.contains(t.id)
        let tf = TradeWatch.timeframe(for: t, run: run(t))
        Section {
            if let check {
                HStack {
                    Chip(text: check.status.title, color: color(check.status))
                    Spacer()
                    Text("checked \(check.at.formatted(date: .omitted, time: .shortened)) · \(FeatureEngine.plain(check.price))\(check.r.map { String(format: " · %+.2fR", $0) } ?? "")")
                        .font(.caption.monospacedDigit()).foregroundStyle(palette.textSecondary)
                }
                if check.changes.isEmpty {
                    Text("Nothing important changed since the analysis — trend, swings, momentum, volatility and key levels are as planned.")
                        .font(.callout).foregroundStyle(palette.textSecondary)
                }
                ForEach(check.changes) { c in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: c.effect == .adverse ? "arrow.down.right.circle.fill" : c.effect == .favourable ? "arrow.up.right.circle.fill" : "info.circle.fill")
                            .foregroundStyle(c.effect == .adverse ? palette.down : c.effect == .favourable ? palette.up : palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.callout.weight(.semibold))
                            Text("\(c.before) → \(c.now)").font(.caption.monospacedDigit()).foregroundStyle(palette.textSecondary)
                            Text(c.advice).font(.caption)
                        }
                    }
                }
                if let trail = check.trail {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Trail the stop to \(FeatureEngine.plain(trail.price))", systemImage: "arrow.up.and.down.circle")
                            .font(.callout.weight(.semibold)).foregroundStyle(palette.accent)
                        Text("\(trail.reason). If hit: \(String(format: "%+.2fR", trail.lockedR)).").font(.caption).foregroundStyle(palette.textSecondary)
                        Button("Move my stop to \(FeatureEngine.plain(trail.price))") { guardian.applyStop(trail.price, to: t.id, trades: store) }
                            .font(.callout)
                    }
                }
            } else {
                Text(busy ? "Reading the \(tf.label) chart…" : "Not checked yet.").font(.callout).foregroundStyle(palette.textSecondary)
            }
            if let err = guardian.errors[t.id] { Text(err).font(.caption).foregroundStyle(palette.warning) }
            Button {
                Task { await guardian.check(t.id, trades: store, market: market, analyses: analyses, settings: settings, askAI: false, allowAutoAI: false) }
            } label: {
                Label(busy && !reviewing ? "Checking…" : "Check now", systemImage: "eye")
            }
            .disabled(busy)
        } header: {
            Text("Trade watch")
        } footer: {
            Text("Compares what this trade was based on — trend, swing structure, momentum, volatility and the key \(t.isLong ? "support" : "resistance") — with the \(tf.label) chart now, every \(Int(TradeWatch.interval(tf) / 60)) min while Third Eye is open. You get a notification when something important changes. The PC monitor also alerts 24×7 if the key level breaks.")
        }

        Section {
            if let ai = check?.ai ?? t.lastAIReview {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(ai.actionTitle).font(.headline).foregroundStyle(ai.action == "exit" ? palette.down : ai.action == "hold" ? palette.textPrimary : palette.accent)
                        Spacer()
                        Chip(text: ai.status.title, color: color(ai.status))
                    }
                    if let b = ai.bookPercent, ai.action == "book_partial" { Text("Book about \(Int(b))% of what is open.").font(.callout) }
                    Text(ai.summary).font(.callout)
                    ForEach(ai.points, id: \.self) { Text("• \($0)").font(.caption) }
                    if let ns = ai.newStop {
                        Button("Move my stop to \(FeatureEngine.plain(ns))") { guardian.applyStop(ns, to: t.id, trades: store) }
                            .font(.callout)
                    }
                    ForEach(ai.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(palette.warning) }
                    ForEach(ai.sources, id: \.self) { src in
                        Button { if let u = URL(string: src.url) { openURL(u) } } label: { Text(src.title).font(.caption).lineLimit(1) }
                    }
                    Text("\(ai.model) · $\(String(format: "%.3f", ai.costUSD)) · \(ai.at.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2.monospaced()).foregroundStyle(palette.textSecondary)
                }
            }
            Button {
                Task { await guardian.check(t.id, trades: store, market: market, analyses: analyses, settings: settings, askAI: true) }
            } label: {
                Label(reviewing ? "AI is re-checking…" : "Ask AI to re-check now", systemImage: "sparkles")
            }
            .disabled(busy)
        } header: {
            Text("AI re-check")
        } footer: {
            Text(settings.autoAIReview
                 ? "Runs by itself (at most every \(Int(TradeGuardian.aiCooldown(tf) / 3600)) h) when the watch finds an important change, using your Balanced model — about $0.01–0.05 each. Its advice is checked in code: it can never widen your stop or add to a losing trade."
                 : "Automatic AI re-checks are off (Settings). Tap to run one — about $0.01–0.05 on your Balanced model.")
        }

        if let log = t.watchLog, log.count > 1 {
            Section("Watch history") {
                ForEach(log.dropFirst()) { c in
                    HStack(alignment: .top) {
                        Chip(text: c.status.title, color: color(c.status))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.ai?.actionTitle ?? c.changes.first?.title ?? "No change").font(.caption.weight(.semibold))
                            Text(c.at.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(palette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private func color(_ s: WatchStatus) -> Color {
        switch s {
        case .strengthened: palette.up
        case .intact: palette.neutral
        case .weakened: palette.warning
        case .broken: palette.down
        }
    }
}

struct FillSheet: View {
    enum Kind: String, Identifiable { case entry, exit; var id: String { rawValue } }
    @Environment(TradeStore.self) private var store
    @Environment(LiveActivityManager.self) private var live
    @Environment(MonitorStore.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let kind: Kind
    let trade: Trade
    let price: Double?
    var editing: Fill? = nil

    @State private var priceText = ""
    @State private var quantityText = ""
    @State private var feesText = ""
    @State private var date = Date()
    @State private var tpStage: Int?
    @State private var note = ""

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }
    /// Open quantity, not counting the fill being corrected.
    private var openQty: Double {
        let base = TradeMath.summary(trade, lastPrice: nil).openQuantity
        guard let editing else { return base }
        return editing.kind == .exit ? base + editing.quantity : base - editing.quantity
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Price") { TextField("0", text: $priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    LabeledContent(trade.instrument.contractSize > 1 ? "Lots" : "Quantity") { TextField("0", text: $quantityText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    LabeledContent("Fees & taxes") { TextField("0", text: $feesText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    DatePicker("When", selection: $date)
                }
                if kind == .exit {
                    Section {
                        Picker("Reason", selection: $tpStage) {
                            Text("Stop-loss / manual").tag(Int?.none)
                            ForEach(trade.takeProfits, id: \.stage) { tp in Text("TP\(tp.stage)").tag(Optional(tp.stage)) }
                        }
                        TextField("Note (optional)", text: $note)
                    } footer: {
                        Text("Open quantity: \(openQty.formatted()). Recording TP1 moves your stop to breakeven automatically.")
                    }
                }
                if let q = num(quantityText), kind == .exit, q > openQty + 1e-9 {
                    Section { Text("You can't exit more than the open quantity.").foregroundStyle(palette.warning) }
                }
                if let editing {
                    Section {
                        Button("Delete this fill", role: .destructive) { store.deleteFill(trade, id: editing.id); dismiss() }
                    }
                }
            }
            .navigationTitle(editing != nil ? "Correct fill" : kind == .entry ? "Record entry" : "Record exit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!valid)
                }
            }
            .onAppear(perform: prefill)
            .onChange(of: tpStage) { _, stage in
                guard let stage, stage != editing?.takeProfitStage,
                      let tp = trade.takeProfits.first(where: { $0.stage == stage }) else { return }
                if let p = tp.price { priceText = p.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) }
                let q = trade.plannedQuantity * tp.bookPercent / 100
                quantityText = min(q, openQty).formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
            }
        }
    }

    private var valid: Bool {
        guard let p = num(priceText), p > 0, let q = num(quantityText), q > 0 else { return false }
        if kind == .entry, editing != nil { return openQty + q >= -1e-9 }   // can't shrink an entry below what was exited
        return kind == .entry || q <= openQty + 1e-9
    }

    private func prefill() {
        let plain = { (v: Double) in v.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) }
        if let editing {
            priceText = plain(editing.price)
            quantityText = plain(editing.quantity)
            feesText = editing.fees > 0 ? plain(editing.fees) : ""
            date = editing.date
            tpStage = editing.takeProfitStage
            note = editing.note ?? ""
            return
        }
        if let price { priceText = plain(price) } else if kind == .entry { priceText = plain(trade.plannedEntryMid) }
        quantityText = plain(kind == .entry ? max(trade.plannedQuantity - TradeMath.summary(trade, lastPrice: nil).entryQuantity, 0) : openQty)
    }

    private func save() {
        guard let p = num(priceText), let q = num(quantityText) else { return }
        let fees = num(feesText) ?? 0
        if var f = editing {
            f.price = p; f.quantity = q; f.fees = fees; f.date = date
            f.takeProfitStage = kind == .exit ? tpStage : nil
            f.note = kind == .exit && !note.isEmpty ? note : f.note
            store.replaceFill(trade, with: f)
            dismiss()
            return
        }
        if kind == .entry {
            store.recordEntry(trade, price: p, quantity: q, fees: fees, date: date)
            // First entry: put the trade on the Lock Screen (the user can remove it on the trade screen).
            if trade.status == .upcoming, let opened = store.trade(id: trade.id) {
                live.start(opened, price: p, monitor: monitor)
            }
        } else {
            store.recordExit(trade, price: p, quantity: q, fees: fees, date: date, takeProfitStage: tpStage, note: note.isEmpty ? nil : note)
        }
        dismiss()
    }
}

/// Correct the plan after saving: entry zone, stop, targets, planned size, deadline, notes.
struct EditPlanSheet: View {
    @Environment(TradeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let trade: Trade

    @State private var entryLow = ""
    @State private var entryHigh = ""
    @State private var stop = ""
    @State private var initialStop = ""
    @State private var targets: [String] = []
    @State private var quantity = ""
    @State private var completeBy = Date()
    @State private var notes = ""

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }
    private func plain(_ v: Double) -> String { v.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) }

    private var problems: [String] {
        var out: [String] = []
        guard let lo = num(entryLow), let hi = num(entryHigh), let st = num(stop), let ist = num(initialStop),
              let q = num(quantity) else { return ["Fill in every number."] }
        if lo > hi { out.append("Entry low is above entry high.") }
        if trade.isLong ? st >= lo && !hasEntries : st <= hi && !hasEntries { out.append("The stop must be \(trade.isLong ? "below" : "above") the entry zone.") }
        if trade.isLong ? ist >= lo : ist <= hi { out.append("The first stop must be \(trade.isLong ? "below" : "above") the entry zone (it defines 1R).") }
        if q <= 0 { out.append("Planned quantity must be above 0.") }
        for (i, t) in targets.enumerated() where !t.isEmpty {
            guard let v = num(t) else { out.append("TP\(i + 1) is not a number."); continue }
            if trade.isLong ? v <= hi : v >= lo { out.append("TP\(i + 1) is on the wrong side of the entry zone.") }
        }
        return out
    }

    private var hasEntries: Bool { trade.fills.contains { $0.kind == .entry } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry zone") {
                    row("Low", $entryLow)
                    row("High", $entryHigh)
                }
                Section {
                    row("Stop-loss now", $stop)
                    row("First stop (defines 1R)", $initialStop)
                } header: {
                    Text("Stop")
                } footer: {
                    Text("Moving the stop further away raises your risk — only do it to correct a typo.")
                }
                Section("Take-profits") {
                    ForEach(Array(trade.takeProfits.enumerated()), id: \.offset) { i, tp in
                        if tp.price != nil, i < targets.count {
                            row("TP\(tp.stage) · book \(Int(tp.bookPercent))%", $targets[i])
                        }
                    }
                }
                Section {
                    row(trade.instrument.contractSize > 1 ? "Planned lots" : "Planned quantity", $quantity)
                    DatePicker("Complete by", selection: $completeBy, displayedComponents: .date)
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                if !problems.isEmpty {
                    Section { ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(palette.warning) } }
                }
            }
            .navigationTitle("Edit plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!problems.isEmpty) }
            }
            .onAppear {
                entryLow = plain(trade.plannedEntryLow)
                entryHigh = plain(trade.plannedEntryHigh)
                stop = plain(trade.stopLoss)
                initialStop = plain(trade.initialStop)
                targets = trade.takeProfits.map { $0.price.map(plain) ?? "" }
                quantity = plain(trade.plannedQuantity)
                completeBy = trade.completeBy
                notes = trade.notes
            }
        }
    }

    private func row(_ title: String, _ text: Binding<String>) -> some View {
        LabeledContent(title) { TextField("0", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
    }

    private func save() {
        guard problems.isEmpty, var t = store.trade(id: trade.id) else { return }
        t.plannedEntryLow = num(entryLow) ?? t.plannedEntryLow
        t.plannedEntryHigh = num(entryHigh) ?? t.plannedEntryHigh
        t.stopLoss = num(stop) ?? t.stopLoss
        t.initialStop = num(initialStop) ?? t.initialStop
        for i in t.takeProfits.indices where i < targets.count && t.takeProfits[i].price != nil {
            if let v = num(targets[i]) { t.takeProfits[i].price = v }
        }
        t.plannedQuantity = num(quantity) ?? t.plannedQuantity
        t.completeBy = completeBy
        t.notes = notes
        store.save(t)
        dismiss()
    }
}
