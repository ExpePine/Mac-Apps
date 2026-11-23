import SwiftUI

/// Your TradingView layout codes (the part after /chart/ in a link), each with a name and the account it belongs to.
/// Pick one for Chart 1 / Chart 2 and every stock opens in that layout — swap codes in one click.
struct LayoutCode: Codable, Identifiable, Equatable {
    var id = UUID()
    var code: String
    var name: String
    var account: String = ""          // which TradingView account it's saved in (e.g. its e-mail)
}

@MainActor final class LayoutCodeStore: ObservableObject {
    static let shared = LayoutCodeStore()
    @Published var codes: [LayoutCode] = [] { didSet { save() } }
    private static let key = "tv.layoutCodes"

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let c = try? JSONDecoder().decode([LayoutCode].self, from: d) { codes = c }
    }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(codes), forKey: Self.key) }

    /// "hs5BavxG" or a whole TradingView link → the layout code.
    static func code(from text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("/chart/") { return ChartLinkBook.layoutID(t) }
        return String(t.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    }

    func name(of code: String) -> String? { codes.first { $0.code == code }?.name }

    /// One-time: the codes you gave (Chart 1 → hs5BavxG instead of I7dkKisW).
    func seed(_ vm: ScreenerViewModel) {
        guard !UserDefaults.standard.bool(forKey: "tv.layoutCodes.seeded1") else { return }
        UserDefaults.standard.set(true, forKey: "tv.layoutCodes.seeded1")
        if !codes.contains(where: { $0.code == "hs5BavxG" }) { codes.append(LayoutCode(code: "hs5BavxG", name: "Chart 1")) }
        if !codes.contains(where: { $0.code == "I7dkKisW" }) { codes.append(LayoutCode(code: "I7dkKisW", name: "Chart 1 (old)")) }
        vm.settings.chartLayoutOverride[vm.chartName(0)] = "hs5BavxG"
    }
}

/// The layout menu next to Chart 1 / Chart 2: which code the chart you're on uses, and your saved codes.
struct LayoutCodeMenu: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var store = LayoutCodeStore.shared
    @State private var manage = false

    var body: some View {
        let c = min(vm.settings.chartLinkColumn, vm.chartCount - 1)
        let col = vm.chartName(c)
        let isSheet = c < max(1, vm.chartBook.columns.count)
        let current = vm.settings.chartLayoutOverride[col] ?? ""
        Menu {
            if isSheet {
                Text("Chart \(c + 1) opens every stock in:")
                Button { vm.settings.chartLayoutOverride[col] = nil } label: {
                    Text((current.isEmpty ? "✓ " : "") + "Each stock's own link from the sheet")
                }
                Divider()
                ForEach(store.codes) { l in
                    Button { vm.settings.chartLayoutOverride[col] = l.code } label: {
                        Text((current == l.code ? "✓ " : "") + l.name + " · " + l.code + (l.account.isEmpty ? "" : " · " + l.account))
                    }
                }
            } else {
                Text("Extra layouts are set in Chart settings")
            }
            Divider()
            Button("Manage layout codes…") { manage = true }
        } label: {
            Text(current.isEmpty ? "Layout: sheet" : "Layout: \(store.name(of: current) ?? current)").font(.caption)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Which TradingView layout Chart \(c + 1) uses for every stock — pick one of your saved codes")
        .sheet(isPresented: $manage) { LayoutCodesView().environmentObject(vm) }
        .onAppear { store.seed(vm) }
    }
}

/// Add, name and swap your layout codes.
struct LayoutCodesView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var store = LayoutCodeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newCode = ""
    @State private var newName = ""
    @State private var newAccount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TradingView layout codes").font(.headline)
            Text("The code is the part after /chart/ in a TradingView link (…/chart/hs5BavxG/?symbol=…). Paste a code or a whole link. Then pick which code Chart 1 and Chart 2 use — every stock opens in that layout.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Code or link", text: $newCode).frame(width: 220)
                TextField("Name", text: $newName).frame(width: 150)
                TextField("Account (e.g. e-mail)", text: $newAccount).frame(width: 180)
                Button("Add") { add() }.disabled(LayoutCodeStore.code(from: newCode).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            List {
                ForEach($store.codes) { $l in
                    HStack(spacing: 8) {
                        TextField("Code", text: $l.code).font(.body.monospaced()).frame(width: 110)
                        TextField("Name", text: $l.name).frame(width: 140)
                        TextField("Account", text: $l.account).frame(width: 170)
                        ForEach(0..<min(2, max(1, vm.chartBook.columns.count)), id: \.self) { c in
                            let col = vm.chartName(c)
                            let on = vm.settings.chartLayoutOverride[col] == l.code
                            Button(on ? "✓ Chart \(c + 1)" : "Use for Chart \(c + 1)") {
                                vm.settings.chartLayoutOverride[col] = on ? nil : l.code
                            }
                            .buttonStyle(.bordered).tint(on ? .accentColor : nil)
                        }
                        Spacer()
                        Button(role: .destructive) { store.codes.removeAll { $0.id == l.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            .frame(minHeight: 200)
            HStack {
                ForEach(0..<min(2, max(1, vm.chartBook.columns.count)), id: \.self) { c in
                    let col = vm.chartName(c)
                    if let o = vm.settings.chartLayoutOverride[col], !o.isEmpty {
                        Button("Chart \(c + 1): back to the sheet's own links") { vm.settings.chartLayoutOverride[col] = nil }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 820, height: 460)
    }

    private func add() {
        let code = LayoutCodeStore.code(from: newCode)
        guard !code.isEmpty else { return }
        store.codes.append(LayoutCode(code: code, name: newName.isEmpty ? code : newName, account: newAccount))
        newCode = ""; newName = ""; newAccount = ""
    }
}
