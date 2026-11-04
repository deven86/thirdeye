import SwiftUI

struct TradeDetailView: View {
    @Environment(TradeStore.self) private var store
    @Environment(MarketStore.self) private var market
    @Environment(AnalysisStore.self) private var analyses
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let tradeID: UUID
    let prices: PriceBook

    @State private var sheet: FillSheet.Kind?
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
                LabeledContent("Planned quantity", value: t.plannedQuantity.formatted())
            }

            if !t.fills.isEmpty {
                Section("Fills") {
                    ForEach(t.fills.sorted { $0.date < $1.date }) { f in
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
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

struct FillSheet: View {
    enum Kind: String, Identifiable { case entry, exit; var id: String { rawValue } }
    @Environment(TradeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let kind: Kind
    let trade: Trade
    let price: Double?

    @State private var priceText = ""
    @State private var quantityText = ""
    @State private var feesText = ""
    @State private var date = Date()
    @State private var tpStage: Int?
    @State private var note = ""

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }
    private var openQty: Double { TradeMath.summary(trade, lastPrice: nil).openQuantity }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Price") { TextField("0", text: $priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    LabeledContent("Quantity") { TextField("0", text: $quantityText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
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
            }
            .navigationTitle(kind == .entry ? "Record entry" : "Record exit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!valid)
                }
            }
            .onAppear(perform: prefill)
            .onChange(of: tpStage) { _, stage in
                guard let stage, let tp = trade.takeProfits.first(where: { $0.stage == stage }) else { return }
                if let p = tp.price { priceText = p.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) }
                let q = trade.plannedQuantity * tp.bookPercent / 100
                quantityText = min(q, openQty).formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
            }
        }
    }

    private var valid: Bool {
        guard let p = num(priceText), p > 0, let q = num(quantityText), q > 0 else { return false }
        return kind == .entry || q <= openQty + 1e-9
    }

    private func prefill() {
        let plain = { (v: Double) in v.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) }
        if let price { priceText = plain(price) } else if kind == .entry { priceText = plain(trade.plannedEntryMid) }
        quantityText = plain(kind == .entry ? max(trade.plannedQuantity - TradeMath.summary(trade, lastPrice: nil).entryQuantity, 0) : openQty)
    }

    private func save() {
        guard let p = num(priceText), let q = num(quantityText) else { return }
        let fees = num(feesText) ?? 0
        if kind == .entry {
            store.recordEntry(trade, price: p, quantity: q, fees: fees, date: date)
        } else {
            store.recordExit(trade, price: p, quantity: q, fees: fees, date: date, takeProfitStage: tpStage, note: note.isEmpty ? nil : note)
        }
        dismiss()
    }
}
