import SwiftUI
import AppKit

/// "Changes": one screen of cards, each showing the stocks that changed in a way you chose,
/// comparing the live data with the previous stored day (or any earlier day).
struct ChangesView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showEditor = false
    @State private var expanded: ChangeCard?

    private var cards: [ChangeCard] {
        vm.settings.changeCards.filter(\.isEnabled).filter { card in
            !vm.settings.changeHideEmpty || !(vm.changeResults[card.id]?.items.isEmpty ?? true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let status = vm.changeStatus {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(status).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 14)], spacing: 14) {
                        ForEach(cards) { card in
                            ChangeCardView(card: card, result: vm.changeResults[card.id],
                                           onExpand: { expanded = card },
                                           onEdit: { showEditor = true },
                                           openWindow: openWindow)
                        }
                    }
                    .padding(14)
                    if cards.isEmpty {
                        Text(vm.settings.changeCards.isEmpty ? "No cards yet — click Edit cards to add some."
                                                             : "No changes match your cards.")
                            .foregroundStyle(.secondary).padding(30)
                    }
                }
            }
        }
        .navigationTitle("Changes")
        .onAppear { vm.computeChanges() }
        .onChange(of: vm.filterVersion) { _ in if vm.timelineIndex == nil { vm.computeChanges() } }
        .onChange(of: vm.settings.changeCards) { _ in vm.computeChanges() }
        .onChange(of: vm.changeCompareDay) { _ in vm.computeChanges() }
        .sheet(isPresented: $showEditor) { ChangeCardsEditor().environmentObject(vm) }
        .sheet(item: $expanded) { card in
            ChangeListSheet(card: card, result: vm.changeResults[card.id] ?? ChangeResult(), openWindow: openWindow)
                .environmentObject(vm)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What changed").font(.title2.bold())
                Text("Live data (\(dayText(HistoryStore.dayKey(vm.dataDay(of: vm.table))))) compared with \(vm.changeComparedDay.map(dayText) ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Compare with", selection: $vm.changeCompareDay) {
                Text("Previous day").tag(String?.none)
                ForEach(vm.changeDayOptions.prefix(60), id: \.self) { d in Text(dayText(d)).tag(String?.some(d)) }
            }
            .frame(width: 230)
            Toggle("Hide empty", isOn: $vm.settings.changeHideEmpty).toggleStyle(.checkbox)
            if vm.isComputingChanges { ProgressView().controlSize(.small) }
            Button { vm.computeChanges() } label: { Image(systemName: "arrow.clockwise") }.help("Recompute")
            Button { showEditor = true } label: { Label("Edit cards", systemImage: "slider.horizontal.3") }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    private func dayText(_ key: String) -> String {
        HistoryStore.date(fromKey: key)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? key
    }
}

/// One card: name, count, condition, and the biggest changes.
struct ChangeCardView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let card: ChangeCard
    let result: ChangeResult?
    let onExpand: () -> Void
    let onEdit: () -> Void
    let openWindow: OpenWindowAction
    private let shown = 8

    var body: some View {
        let accent = Color(hex: card.color)
        let items = result?.items ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(accent).frame(width: 9, height: 9)
                Text(card.name.isEmpty ? card.kind.title : card.name).font(.headline).lineLimit(1)
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(items.isEmpty ? Color.secondary : accent)
                Menu {
                    Button("Show all \(items.count)") { onExpand() }.disabled(items.isEmpty)
                    ForEach(vm.watchlists) { list in
                        Button("Add all to “\(list.name)”") { vm.addSymbols(items.map(\.symbol), listID: list.id) }
                    }
                    .disabled(items.isEmpty)
                    Button("Copy symbols") { copy(items.map(\.symbol).joined(separator: "\n")) }.disabled(items.isEmpty)
                    Divider()
                    Button("Edit cards…") { onEdit() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Text(card.describe + (card.scope == .all ? "" : " · " + card.scope.title.lowercased()))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let p = result?.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            if items.isEmpty && result?.problem == nil {
                Text("No stocks").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 40)
            } else {
                VStack(spacing: 3) {
                    ForEach(items.prefix(shown)) { item in ChangeRow(item: item, card: card, openWindow: openWindow) }
                }
                if items.count > shown {
                    Button("+ \(items.count - shown) more") { onExpand() }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(alignment: .top) {
            UnevenTop(color: accent)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .animation(.easeOut(duration: 0.3), value: items.count)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Thin colour strip on top of a card.
private struct UnevenTop: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 12).fill(color).frame(height: 4).padding(.horizontal, 8)
    }
}

/// One stock in a card: symbol, old → new, and the change.
struct ChangeRow: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let item: ChangeItem
    let card: ChangeCard
    let openWindow: OpenWindowAction

    var body: some View {
        HStack(spacing: 6) {
            Text(item.symbol).fontWeight(.semibold).lineLimit(1).frame(minWidth: 90, alignment: .leading)
            Spacer(minLength: 4)
            if !item.old.isEmpty || !item.new.isEmpty {
                Text(item.old.isEmpty ? "—" : item.old).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text(item.new.isEmpty ? "—" : item.new).lineLimit(1)
            }
            if let d = item.delta, d != 0 {
                Text(change(d, item.percent))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(d > 0 ? Color.green : Color.red)
                    .frame(minWidth: 62, alignment: .trailing)
            }
        }
        .font(.callout.monospacedDigit())
        .contentShape(Rectangle())
        .contextMenu {
            ForEach(vm.watchlists) { list in
                Button("Add \(item.symbol) to “\(list.name)”") { vm.addSymbols([item.symbol], listID: list.id) }
            }
            Button("Open chart of \(item.symbol)") { vm.openChart(item.symbol, openWindow: openWindow) }
            Button("Screenshots of \(item.symbol)…") { vm.shotSymbol = item.symbol; openWindow(id: "shots") }
            Button("Copy \(item.symbol)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.symbol, forType: .string)
            }
        }
    }

    private func change(_ d: Double, _ p: Double?) -> String {
        if card.unit == .percent, let p { return String(format: "%+.1f%%", p) }
        let abs = d.formatted(.number.precision(.fractionLength(0...2)))
        return d > 0 ? "+" + abs : abs
    }
}

/// All stocks of one card.
struct ChangeListSheet: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    let card: ChangeCard
    let result: ChangeResult
    let openWindow: OpenWindowAction
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(hex: card.color)).frame(width: 10, height: 10)
                Text(card.name.isEmpty ? card.kind.title : card.name).font(.title3.bold())
                Text("\(result.items.count)").foregroundStyle(.secondary)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            Text(card.describe).font(.caption).foregroundStyle(.secondary)
            List(filtered) { item in ChangeRow(item: item, card: card, openWindow: openWindow) }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Menu("Add all to watchlist") {
                    ForEach(vm.watchlists) { list in
                        Button(list.name) { vm.addSymbols(filtered.map(\.symbol), listID: list.id) }
                    }
                }
                .fixedSize()
                Button("Copy symbols") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(filtered.map(\.symbol).joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 560)
    }

    private var filtered: [ChangeItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? result.items : result.items.filter { $0.symbol.localizedCaseInsensitiveContains(q) }
    }
}

/// Settings for the cards: what changes to show.
struct ChangeCardsEditor: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Change cards").font(.title3.bold())
                Spacer()
                Menu("Add card") {
                    ForEach(ChangeCard.Kind.allCases, id: \.self) { kind in
                        Button(kind.title) { add(kind) }
                    }
                }
                .fixedSize()
            }
            Text("Each card lists the stocks that changed in the way you set, between the live data and the earlier day chosen on the Changes screen. Drag to reorder.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($vm.settings.changeCards) { $card in
                    CardEditorRow(card: $card, columns: vm.headers) {
                        vm.settings.changeCards.removeAll { $0.id == card.id }
                    }
                }
                .onMove { vm.settings.changeCards.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button("Restore default cards") {
                    vm.settings.changeCards = ChangeCard.defaults(trigger: vm.settings.triggerColumn)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 820, height: 600)
    }

    private func add(_ kind: ChangeCard.Kind) {
        let colors = ScreenshotsView.palette.dropLast(2)
        let color = colors[vm.settings.changeCards.count % colors.count]
        var card = ChangeCard(name: kind.title, kind: kind,
                              column: vm.settings.triggerColumn, color: color)
        if kind == .crossedAbove || kind == .crossedBelow { card.amount = 50 }
        vm.settings.changeCards.append(card)
    }
}

private struct CardEditorRow: View {
    @Binding var card: ChangeCard
    let columns: [String]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: $card.isEnabled).labelsHidden().toggleStyle(.checkbox)
                TextField("Card name", text: $card.name).textFieldStyle(.roundedBorder).frame(width: 190)
                Picker("", selection: $card.kind) {
                    ForEach(ChangeCard.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 200)
                if card.kind.needsColumn || [.enteredFilter, .leftFilter, .newStock, .droppedStock].contains(card.kind) {
                    Picker("", selection: $card.column) {
                        if !columns.contains(card.column) { Text(card.column.isEmpty ? "Column…" : card.column).tag(card.column) }
                        ForEach(columns, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                    .help(card.kind.needsColumn ? "Column to compare" : "Column whose old → new value is shown")
                }
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                if card.kind.needsAmount {
                    Text(card.kind == .crossedAbove || card.kind == .crossedBelow ? "Level" : "By at least")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("0", value: $card.amount, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                    if card.kind.usesUnit {
                        Picker("", selection: $card.unit) {
                            Text("points").tag(ChangeCard.Unit.absolute)
                            Text("%").tag(ChangeCard.Unit.percent)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 110)
                    }
                }
                Picker("", selection: $card.scope) {
                    ForEach(ChangeCard.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 230)
                ForEach(ScreenshotsView.palette.dropLast(2), id: \.self) { hex in
                    Circle().fill(Color(hex: hex))
                        .overlay(Circle().stroke(Color.primary.opacity(hex == card.color ? 0.9 : 0.15), lineWidth: hex == card.color ? 2 : 1))
                        .frame(width: 14, height: 14)
                        .onTapGesture { card.color = hex }
                }
                Spacer()
                Text(card.describe).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 4)
        .opacity(card.isEnabled ? 1 : 0.5)
    }
}
