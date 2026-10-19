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

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            HSplitView {
                manualList.frame(minWidth: 640)
                hiddenList.frame(minWidth: 260, idealWidth: 300)
            }
        }
        .navigationTitle("Symbols")
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                TextField("Add NSE symbols — e.g. TCS, INFY, NSE:M&M (comma or space separated)", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
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
                TableColumn("Symbol") { m in Text(m.symbol).fontWeight(.semibold) }.width(min: 80, ideal: 100)
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
                TextField("Hide symbols…", text: $hideInput).textFieldStyle(.roundedBorder)
                    .onSubmit { hide() }
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
