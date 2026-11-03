import SwiftUI

/// "Add to watchlist" button used across the app (Daily Gainers, Filter, Chart viewer, Chart Reel, Gainer Charts,
/// Multibaggers). One stock: tick / untick it per list. Several: add them to a list (or a new one).
/// `day` = the day whose close is the starting price (e.g. the gainer day); nil = the data day.
struct AddToWatchlistButton: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    /// Named groups of symbols, e.g. [("Selected", [...]), ("All shown", [...])]; a single group of one = one stock.
    let groups: [(title: String, symbols: [String])]
    var day: String? = nil
    let source: String
    var compact = false

    @State private var naming = false
    @State private var newName = ""
    @State private var pending: [String] = []
    @State private var flash: String?

    init(symbol: String, day: String? = nil, source: String, compact: Bool = true) {
        groups = [(symbol, [symbol])]; self.day = day; self.source = source; self.compact = compact
    }
    init(groups: [(title: String, symbols: [String])], day: String? = nil, source: String, compact: Bool = false) {
        self.groups = groups; self.day = day; self.source = source; self.compact = compact
    }

    private var single: String? {
        let g = groups.filter { !$0.symbols.isEmpty }
        return g.count == 1 && g[0].symbols.count == 1 ? g[0].symbols[0].uppercased() : nil
    }
    private var heldIn: [Watchlist] { single.map { vm.watchlistsHolding($0) } ?? [] }

    var body: some View {
        Menu {
            if let s = single {
                Text(heldIn.isEmpty ? "Add \(s) to…" : "\(s) is in \(heldIn.map(\.name).joined(separator: ", "))")
                ForEach(vm.watchlists) { list in
                    let inIt = heldIn.contains { $0.id == list.id }
                    Button {
                        if inIt { vm.removeFromWatchlist(s, listID: list.id); flash = "Removed from \(list.name)" }
                        else { add([s], to: list.id, name: list.name) }
                    } label: { if inIt { Label(list.name, systemImage: "checkmark") } else { Text(list.name) } }
                }
                Divider()
                Button("New watchlist with \(s)…") { pending = [s]; newName = ""; naming = true }
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    Section("\(g.title) (\(g.symbols.count))") {
                        ForEach(vm.watchlists) { list in
                            Button("Add to \(list.name)") { add(g.symbols, to: list.id, name: list.name) }.disabled(g.symbols.isEmpty)
                        }
                        Button("New watchlist with these…") { pending = g.symbols; newName = ""; naming = true }.disabled(g.symbols.isEmpty)
                    }
                }
            }
            Divider()
            Button("Open Watchlists  ⇧⌘5") { openWindow(id: "watch") }
        } label: {
            if compact {
                Image(systemName: heldIn.isEmpty ? "star" : "star.fill").foregroundStyle(heldIn.isEmpty ? Color.secondary : Color.yellow)
            } else {
                Label(flash ?? "Watchlist", systemImage: heldIn.isEmpty ? "star" : "star.fill")
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(flash ?? (single.map { s in heldIn.isEmpty ? "Add \(s) to a watchlist" : "\(s) is in \(heldIn.map(\.name).joined(separator: ", ")) — click to change" }
                        ?? "Add these stocks to a watchlist"))
        .sheet(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New watchlist").font(.headline)
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit { createAndAdd() }
                Text("\(pending.count) stock\(pending.count == 1 ? "" : "s") will be added, priced at the close of \(day ?? "the data day").")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { naming = false }.keyboardShortcut(.cancelAction)
                    Button("Create") { createAndAdd() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }

    private func add(_ syms: [String], to id: UUID, name: String) {
        let n = vm.addToWatchlist(symbols: syms, listID: id, day: day, source: source)
        flash = n == 0 ? "Already in \(name)" : "Added \(n) to \(name)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { flash = nil }
    }

    private func createAndAdd() {
        let id = vm.newWatchlist(named: newName.trimmingCharacters(in: .whitespaces))
        add(pending, to: id, name: vm.watchlists.first { $0.id == id }?.name ?? "the new list")
        naming = false
    }
}

/// "Add to watchlist ▸" for right-click menus.
struct WatchlistSubmenu: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let symbols: [String]
    var day: String? = nil
    let source: String
    var body: some View {
        Menu(symbols.count == 1 ? "Add \(symbols[0]) to watchlist" : "Add \(symbols.count) to watchlist") {
            ForEach(vm.watchlists) { list in
                Button(list.name) { vm.addToWatchlist(symbols: symbols, listID: list.id, day: day, source: source) }
            }
            Divider()
            Button("New watchlist") { let id = vm.newWatchlist(named: ""); vm.addToWatchlist(symbols: symbols, listID: id, day: day, source: source) }
        }
    }
}
