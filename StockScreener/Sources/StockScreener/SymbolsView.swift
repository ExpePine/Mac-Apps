import SwiftUI

/// Add NSE symbols by hand (checked on Yahoo, name / industry / chart links filled in) and hide sheet symbols.
struct SymbolsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var input = ""
    @State private var selection = Set<String>()
    @State private var hiddenSelection = Set<String>()
    @State private var hideInput = ""
    @State private var search = ""
    @State private var renameFrom = ""
    @State private var renameTo = ""
    @State private var renameSelection = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            HSplitView {
                manualList.frame(minWidth: 640)
                VSplitView {
                    hiddenList.frame(minHeight: 220)
                    renameList.frame(minHeight: 220)
                }
                .frame(minWidth: 280, idealWidth: 320)
            }
        }
        .navigationTitle("Symbols")
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                SymbolField(vm: vm, placeholder: "Add NSE symbols — e.g. TCS, INFY, NSE:M&M (comma or space separated)", text: $input, multi: true) { add() }
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                if vm.isCheckingSymbols { ProgressView().controlSize(.small); Text("Checking on Yahoo…").font(.caption) }
            }
            Text(vm.symbolStatus ?? "Each added symbol is checked on Yahoo; a year of prices, the company name and the industry are filled in, and chart links follow your chart sheet's pattern. Added symbols appear in Data, Filter, Gainers, Sectors, Performance and Charts like sheet rows (their sheet columns stay blank).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    // MARK: Manual symbols

    private var manualList: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let rows = vm.symbolBook.manual.filter { q.isEmpty || $0.symbol.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) || $0.industry.localizedCaseInsensitiveContains(q) }
        let industries = vm.knownIndustries
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("My added symbols (\(vm.symbolBook.manual.count))").font(.headline)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                Button("Re-check on Yahoo") { vm.checkManualSymbols(vm.symbolBook.manual.map(\.symbol)) }
                    .disabled(vm.symbolBook.manual.isEmpty || vm.isCheckingSymbols)
                Button(role: .destructive) { vm.removeManual(selection); selection = [] } label: { Label("Remove", systemImage: "trash") }
                    .disabled(selection.isEmpty)
            }
            Table(rows, selection: $selection) {
                TableColumn("") { m in
                    Image(systemName: m.foundOnYahoo == true ? "checkmark.circle.fill" : (m.foundOnYahoo == false ? "exclamationmark.triangle.fill" : "clock"))
                        .foregroundStyle(m.foundOnYahoo == true ? Color.green : (m.foundOnYahoo == false ? Color.orange : Color.secondary))
                        .help(m.foundOnYahoo == true ? "Found on Yahoo (NSE)" : (m.foundOnYahoo == false ? "Not found on Yahoo — check the symbol" : "Not checked yet"))
                }
                .width(22)
                TableColumn("Symbol") { m in SymbolWithDots(symbol: m.symbol, bold: false) }.width(min: 110, ideal: 130)
                TableColumn("Company") { m in
                    TextField("Company name", text: binding(m.symbol, \.name)).textFieldStyle(.plain)
                }
                .width(min: 120, ideal: 180)
                TableColumn("Industry") { m in
                    HStack(spacing: 4) {
                        TextField("Industry", text: binding(m.symbol, \.industry)).textFieldStyle(.plain)
                        Menu {
                            ForEach(industries, id: \.self) { ind in Button(ind) { vm.updateManual(m.symbol) { $0.industry = ind } } }
                        } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Pick one of your sheet's industries so Sectors groups it correctly" + (m.yahooIndustry.isEmpty ? "" : " · Yahoo says: \(m.yahooIndustry)"))
                    }
                }
                .width(min: 150, ideal: 220)
                TableColumn("Price") { m in
                    Text(m.lastPrice.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Chart 1 link") { m in
                    TextField(vm.chartURL(m.symbol, column: 0)?.absoluteString ?? "pattern", text: linkBinding(m.symbol, 0))
                        .textFieldStyle(.plain).font(.caption.monospaced())
                        .help("Blank = your chart sheet's pattern. Paste a link to override for this symbol.")
                }
                .width(min: 160, ideal: 240)
                TableColumn("Chart 2 link") { m in
                    TextField(vm.chartCount > 1 ? (vm.chartURL(m.symbol, column: 1)?.absoluteString ?? "") : "optional", text: linkBinding(m.symbol, 1))
                        .textFieldStyle(.plain).font(.caption.monospaced())
                }
                .width(min: 120, ideal: 200)
                TableColumn("Note") { m in TextField("", text: binding(m.symbol, \.note)).textFieldStyle(.plain) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Open chart") { if let s = ids.first { vm.openChart(s, queue: rows.map(\.symbol), openWindow: openWindow) } }
                    .disabled(ids.count != 1)
                Button("Re-check on Yahoo") { vm.checkManualSymbols(Array(ids)) }
                Divider()
                Button("Remove \(ids.count)", role: .destructive) { vm.removeManual(ids); selection.subtract(ids) }
            }
            .onDeleteCommand { vm.removeManual(selection); selection = [] }
            if !industries.isEmpty && vm.symbolBook.manual.contains(where: { !industries.contains($0.industry) && !$0.industry.isEmpty }) {
                Label("Some industries don't match your sheet's names — pick from the ▾ list so the Sectors screen groups them with the right sector.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    // MARK: Hidden sheet symbols

    private var hiddenList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hidden from the sheet (\(vm.symbolBook.hidden.count))").font(.headline)
            Text("These sheet symbols are removed everywhere in the app. Your Google Sheet isn't changed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                SymbolField(vm: vm, placeholder: "Hide symbols…", text: $hideInput, multi: true) { hide() }
                Button("Hide") { hide() }.disabled(hideInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List(vm.symbolBook.hidden, id: \.self, selection: $hiddenSelection) { s in
                Text(s)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Restore \(ids.count)") { vm.unhideSymbols(ids); hiddenSelection.subtract(ids) }
            }
            HStack {
                Button("Restore selected") { vm.unhideSymbols(hiddenSelection); hiddenSelection = [] }.disabled(hiddenSelection.isEmpty)
                Spacer()
                Text("\(vm.sheetSymbols.count) symbols in the sheet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: NSE renames

    private var renameList: some View {
        let list = vm.symbolBook.renames ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Text("Renamed on NSE (\(list.count))").font(.headline)
            Text("When NSE changes a stock's symbol: its old days join the new symbol's delivery history, deals and Yahoo prices, and both names (sheet or NSE) find the same data.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                SymbolField(vm: vm, placeholder: "Old NSE symbol", text: $renameFrom, multi: false) { addRename() }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                SymbolField(vm: vm, placeholder: "New NSE symbol", text: $renameTo, multi: false) { addRename() }
                Button("Add") { addRename() }
                    .disabled(renameFrom.trimmingCharacters(in: .whitespaces).isEmpty || renameTo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List(list, selection: $renameSelection) { r in
                HStack {
                    Text(r.from).font(.body.monospaced())
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(r.to).font(.body.monospaced().bold())
                    Spacer()
                    Text(r.addedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                }
                .tag(r.from)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button("Remove selected") { vm.removeRenames(renameSelection); renameSelection = [] }.disabled(renameSelection.isEmpty)
                Spacer()
            }
        }
        .padding(12)
    }

    private func addRename() {
        vm.addRename(from: renameFrom, to: renameTo)
        renameFrom = ""; renameTo = ""
    }

    // MARK: Helpers

    private func add() {
        vm.addManualSymbols(input)
        input = ""
    }

    private func hide() {
        let list = hideInput.components(separatedBy: CharacterSet(charactersIn: ",; \n\t")).filter { !$0.isEmpty }
        vm.hideSymbols(list)
        hideInput = ""
    }

    private func binding(_ sym: String, _ key: WritableKeyPath<ManualSymbol, String>) -> Binding<String> {
        Binding(get: { vm.symbolBook.manual.first { $0.symbol == sym }?[keyPath: key] ?? "" },
                set: { v in vm.updateManual(sym) { $0[keyPath: key] = v } })
    }

    private func linkBinding(_ sym: String, _ i: Int) -> Binding<String> {
        Binding(get: {
                    let l = vm.symbolBook.manual.first { $0.symbol == sym }?.links ?? []
                    return i < l.count ? l[i] : ""
                },
                set: { v in vm.updateManual(sym) { m in
                    while m.links.count <= i { m.links.append("") }
                    m.links[i] = v.trimmingCharacters(in: .whitespaces)
                } })
    }
}
