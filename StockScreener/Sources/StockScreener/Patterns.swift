import SwiftUI
import AppKit

// Pattern pad: study multibaggers one by one. A shared checklist of things you see before a move ("elements"); tick
// the ones present for the stock on the chart, add new ones as you spot them, and see at once which usual elements this
// stock is missing. The Patterns board puts every reviewed stock against every element, groups them into kinds and
// shows what each kind has in common.

struct PatternElement: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var created = Date()
}

struct PatternReview: Codable, Identifiable, Equatable {
    var id: String              // MBEvent.id = "SYMBOL|yyyy-MM"
    var symbol: String
    var month: String
    var gain: Double
    var checked: Set<UUID> = []
    var kind = ""
    var note = ""
    var updated = Date()
}

@MainActor final class PatternStore: ObservableObject {
    static let shared = PatternStore()
    @Published var elements: [PatternElement] = [] { didSet { save() } }
    @Published var reviews: [String: PatternReview] = [:] { didSet { save() } }
    @Published var kinds: [String] = [] { didSet { save() } }

    private struct Book: Codable { var elements: [PatternElement]; var reviews: [String: PatternReview]; var kinds: [String] }
    private static var url: URL { AppFolders.base.appendingPathComponent("patterns.json") }
    private var loading = true

    private init() {
        if let d = try? Data(contentsOf: Self.url), let b = try? JSONDecoder().decode(Book.self, from: d) {
            elements = b.elements; reviews = b.reviews; kinds = b.kinds
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let b = Book(elements: elements, reviews: reviews, kinds: kinds), url = Self.url
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(b) { try? d.write(to: url, options: .atomic) }
        }
    }

    // MARK: editing

    func review(_ e: MBEvent) -> PatternReview {
        reviews[e.id] ?? PatternReview(id: e.id, symbol: e.symbol, month: e.month, gain: e.gain)
    }

    func toggle(_ el: UUID, for e: MBEvent) {
        var r = review(e)
        if r.checked.contains(el) { r.checked.remove(el) } else { r.checked.insert(el) }
        r.updated = Date()
        reviews[e.id] = r
    }

    func setNote(_ text: String, for e: MBEvent) {
        var r = review(e); guard r.note != text else { return }
        r.note = text; r.updated = Date(); reviews[e.id] = r
    }

    func setKind(_ k: String, for id: String) {
        guard var r = reviews[id] else { return }
        r.kind = k; reviews[id] = r
        if !k.isEmpty && !kinds.contains(k) { kinds.append(k) }
    }

    func setKind(_ k: String, for e: MBEvent) {
        var r = review(e); r.kind = k; r.updated = Date(); reviews[e.id] = r
        if !k.isEmpty && !kinds.contains(k) { kinds.append(k) }
    }

    @discardableResult
    func addElement(_ text: String, checkFor e: MBEvent?) -> UUID? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let el = PatternElement(text: t)
        elements.append(el)
        if let e { toggle(el.id, for: e) }
        return el.id
    }

    func rename(_ id: UUID, _ text: String) {
        guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[i].text = text
    }

    func deleteElement(_ id: UUID) {
        elements.removeAll { $0.id == id }
        for (k, var r) in reviews where r.checked.contains(id) { r.checked.remove(id); reviews[k] = r }
    }

    func move(_ id: UUID, by d: Int) {
        guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard j >= 0, j < elements.count else { return }
        elements.swapAt(i, j)
    }

    // MARK: reading

    /// Stocks reviewed (at least one tick or a note).
    var reviewed: [PatternReview] {
        reviews.values.filter { !$0.checked.isEmpty || !$0.note.isEmpty }.sorted { ($0.kind, $0.symbol) < ($1.kind, $1.symbol) }
    }

    /// How many reviewed stocks (other than `except`) had this element.
    func hits(_ el: UUID, except: String? = nil) -> (count: Int, of: Int) {
        let rs = reviewed.filter { $0.id != except }
        return (rs.filter { $0.checked.contains(el) }.count, rs.count)
    }

    /// Kinds suggested from the ticks: stocks whose ticks overlap a lot (Jaccard ≥ `minSim`) end up together.
    func suggestKinds(minSim: Double = 0.5) -> [[PatternReview]] {
        let rs = reviewed.filter { !$0.checked.isEmpty }
        var groups: [[PatternReview]] = []
        var used = Set<String>()
        func sim(_ a: Set<UUID>, _ b: Set<UUID>) -> Double {
            let u = a.union(b).count
            return u == 0 ? 0 : Double(a.intersection(b).count) / Double(u)
        }
        for r in rs.sorted(by: { $0.checked.count > $1.checked.count }) where !used.contains(r.id) {
            var g = [r]; used.insert(r.id)
            for o in rs where !used.contains(o.id) && sim(r.checked, o.checked) >= minSim { g.append(o); used.insert(o.id) }
            groups.append(g)
        }
        return groups.sorted { $0.count > $1.count }
    }

    /// Elements present in at least `share` of a group's stocks.
    func common(_ group: [PatternReview], share: Double = 0.8) -> [PatternElement] {
        guard !group.isEmpty else { return [] }
        return elements.filter { el in Double(group.filter { $0.checked.contains(el.id) }.count) / Double(group.count) >= share }
    }
}

// MARK: - The tiny floating pad

@MainActor final class PatternPad {
    static let shared = PatternPad()
    private var panel: NSPanel?

    func show(_ vm: ScreenerViewModel, symbol: String) {
        if !symbol.isEmpty, MBNoteFocus.shared.event?.symbol != symbol.uppercased() { MBNoteFocus.shared.setChart(symbol, day: nil) }
        FloatingNotes.shared.symbol = symbol.uppercased()
        if panel == nil {
            let host = NSHostingController(rootView: PatternPadView().environmentObject(vm))
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 460),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = "Patterns"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isReleasedWhenClosed = false
            p.contentViewController = host
            p.setContentSize(NSSize(width: 280, height: 460))
            p.setFrameAutosaveName("PatternPadPanel")
            if !p.setFrameUsingName("PatternPadPanel"), let s = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: s.maxX - 300, y: s.maxY - 120))
            }
            panel = p
        }
        panel?.orderFront(nil)
        FloatingNotes.shared.padOpen = true
    }

    func close() { panel?.orderOut(nil); FloatingNotes.shared.padOpen = false }
}

struct PatternPadView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var store = PatternStore.shared
    @ObservedObject private var focus = MBNoteFocus.shared
    @ObservedObject private var fn = FloatingNotes.shared
    @Environment(\.openWindow) private var openWindow
    @State private var newElement = ""
    @State private var note = ""
    @State private var editing: UUID?
    @State private var editText = ""
    @State private var dated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = focus.event {
                header(e)
                list(e)
                addRow(e)
                noteBox(e)
            } else {
                Text("Open a stock on Chart 1 (chart viewer, Chart Reel or Multibaggers)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            footer
        }
        .padding(8)
        .frame(minWidth: 240, minHeight: 300)
        .onChange(of: focus.event?.id) { _ in note = focus.event.map { store.review($0).note } ?? "" }
        .onAppear { note = focus.event.map { store.review($0).note } ?? "" }
    }

    private func header(_ e: MBEvent) -> some View {
        let r = store.review(e)
        return HStack(spacing: 6) {
            Text(e.symbol).font(.headline)
            if e.gain != 0 { Text(String(format: "+%.0f%%", e.gain)).font(.caption.bold()).foregroundStyle(.green) }
            Text(e.month).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(store.kinds, id: \.self) { k in Button(k) { store.setKind(k, for: e) } }
                Divider()
                Button("New kind…") { promptKind(e) }
                if !r.kind.isEmpty { Button("No kind") { store.setKind("", for: e) } }
            } label: { Text(r.kind.isEmpty ? "kind" : r.kind).font(.caption2.bold()) }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Which kind of multibagger this is (your own groups — see the Patterns board)")
        }
    }

    private func list(_ e: MBEvent) -> some View {
        let r = store.review(e)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(store.elements.enumerated()), id: \.element.id) { k, el in
                    row(k, el, r, e)
                }
                if store.elements.isEmpty {
                    Text("Add what you see before the move ↓ — each becomes a tick box for every stock")
                        .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 6)
                }
            }
        }
    }

    private func row(_ k: Int, _ el: PatternElement, _ r: PatternReview, _ e: MBEvent) -> some View {
        let on = r.checked.contains(el.id)
        let h = store.hits(el.id, except: e.id)
        let share = h.of > 0 ? Double(h.count) / Double(h.of) : 0
        let missing = !on && h.of >= 2 && share >= 0.6         // usually there, not here: a deviation
        return HStack(spacing: 5) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .foregroundStyle(on ? Color.green : (missing ? Color.orange : Color.secondary))
            if editing == el.id {
                TextField("", text: $editText, onCommit: { store.rename(el.id, editText); editing = nil })
                    .textFieldStyle(.roundedBorder).font(.caption)
            } else {
                Text(el.text).font(.caption).lineLimit(2)
                    .foregroundStyle(missing ? Color.orange : Color.primary)
            }
            Spacer(minLength: 2)
            if h.of > 0 {
                Text("\(h.count)/\(h.of)").font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(share >= 0.6 ? Color.green : Color.secondary)
                    .help("\(h.count) of the \(h.of) other stocks you reviewed had this")
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.green.opacity(0.10) : (missing ? Color.orange.opacity(0.10) : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(el.id, for: e) }
        .contextMenu {
            Button("Rename") { editing = el.id; editText = el.text }
            Button("Move up") { store.move(el.id, by: -1) }
            Button("Move down") { store.move(el.id, by: 1) }
            Divider()
            Button("Delete for all stocks", role: .destructive) { store.deleteElement(el.id) }
        }
        .help(missing ? "Most stocks you reviewed had this — this one doesn't (deviation)" : el.text)
    }

    private func addRow(_ e: MBEvent) -> some View {
        TextField("+ what you see before the move…", text: $newElement, onCommit: {
            store.addElement(newElement, checkFor: e); newElement = ""
        })
        .textFieldStyle(.roundedBorder).font(.caption)
        .help("Type and press Return: a new tick box, ticked for this stock — test it on the next stocks")
    }

    private func noteBox(_ e: MBEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("Observations…", text: $note, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).font(.caption)
                .onChange(of: note) { v in store.setNote(v, for: e) }
            HStack(spacing: 6) {
                if fn.capturing {
                    Image(systemName: "scope").foregroundStyle(.orange)
                    Text(fn.crossDay.map { DayNoteStore.short($0) } ?? "move over Chart 1…").font(.caption.bold()).foregroundStyle(.orange)
                    Text("click the candle").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("✕") { fn.capturing = false }.buttonStyle(.borderless)
                } else {
                    Button { fn.text = note; fn.symbol = e.symbol; fn.capturing = true } label: { Label("Pin to a date", systemImage: "scope") }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Saves the observation as a dated ✎ note: put Chart 1's crosshair on the day and click the candle")
                    Spacer()
                    if !fn.lastSaved.isEmpty { Text(fn.lastSaved).font(.caption2).foregroundStyle(.green) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(store.reviewed.count) reviewed · \(store.elements.count) elements").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Board") { openWindow(id: "patterns") }.font(.caption).buttonStyle(.borderless)
                .help("Every reviewed stock against every element; kinds and what each kind has in common")
        }
    }

    private func promptKind(_ e: MBEvent) {
        let a = NSAlert()
        a.messageText = "New kind"
        a.informativeText = "A name for this kind of multibagger (e.g. \"Delivery build-up\", \"Deal-led\")"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Add"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            let k = f.stringValue.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { store.setKind(k, for: e) }
        }
    }
}

/// The chart toolbars' button.
struct PatternPadButton: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let symbol: String
    var body: some View {
        Button { PatternPad.shared.show(vm, symbol: symbol) } label: { Label("Notes", systemImage: "checklist") }
            .help("Patterns pad: tick what you see before this multibagger, add new elements, note observations — floats over the chart")
    }
}

// MARK: - The board

struct PatternBoardView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var store = PatternStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var sim = 0.5
    @State private var showSuggest = false

    var body: some View {
        let rs = store.reviewed
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Patterns board").font(.headline)
                Text("\(rs.count) stocks · \(store.elements.count) elements").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Suggest kinds") { showSuggest.toggle() }
                    .help("Groups stocks whose ticks overlap a lot, and shows what each group has in common")
            }
            if showSuggest { suggestions }
            ScrollView([.horizontal, .vertical]) { matrix(rs) }
            kindSummary(rs)
        }
        .padding(12)
    }

    private let colW: CGFloat = 34
    static func letter(_ k: Int) -> String {
        let a = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String(a[min(max(0, k), a.count - 1)])
    }

    private func matrix(_ rs: [PatternReview]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .bottom, spacing: 1) {
                Text("Stock").font(.caption.bold()).frame(width: 150, alignment: .leading)
                Text("Kind").font(.caption.bold()).frame(width: 90, alignment: .leading)
                ForEach(Array(store.elements.enumerated()), id: \.element.id) { k, el in
                    Text("\(k + 1)").font(.caption2.bold()).frame(width: colW).help(el.text)
                }
                Text("Observations").font(.caption.bold()).frame(width: 260, alignment: .leading)
            }
            ForEach(rs) { r in
                HStack(spacing: 1) {
                    Button { open(r) } label: {
                        HStack(spacing: 4) {
                            Text(r.symbol).font(.caption.bold())
                            Text(String(format: "+%.0f%%", r.gain)).font(.caption2).foregroundStyle(.green)
                            Text(r.month).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain).frame(width: 150, alignment: .leading)
                    .help("Open \(r.symbol) on the chart")
                    Menu {
                        ForEach(store.kinds, id: \.self) { k in Button(k) { store.setKind(k, for: r.id) } }
                        Button("No kind") { store.setKind("", for: r.id) }
                    } label: { Text(r.kind.isEmpty ? "—" : r.kind).font(.caption2) }
                    .menuStyle(.borderlessButton).frame(width: 90, alignment: .leading)
                    ForEach(store.elements) { el in
                        Image(systemName: r.checked.contains(el.id) ? "checkmark.square.fill" : "square")
                            .font(.caption)
                            .foregroundStyle(r.checked.contains(el.id) ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: colW)
                    }
                    Text(r.note).font(.caption2).lineLimit(2).frame(width: 260, alignment: .leading)
                }
                .padding(.vertical, 1)
            }
            // share of stocks with each element
            HStack(spacing: 1) {
                Text("Share of stocks").font(.caption2.bold()).frame(width: 240, alignment: .leading)
                ForEach(store.elements) { el in
                    let h = store.hits(el.id)
                    let p = h.of > 0 ? Int(Double(h.count) / Double(h.of) * 100) : 0
                    Text("\(p)%").font(.caption2.monospacedDigit()).foregroundStyle(p >= 60 ? Color.green : Color.secondary).frame(width: colW)
                }
            }
            .padding(.top, 4)
            // element legend
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(store.elements.enumerated()), id: \.element.id) { k, el in
                    Text("\(k + 1). \(el.text)").font(.caption2)
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder private var suggestions: some View {
        let groups = store.suggestKinds(minSim: sim)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Similar when ≥ \(Int(sim * 100))% of their ticks match").font(.caption)
                Slider(value: $sim, in: 0.3...0.9, step: 0.05).frame(width: 160)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { k, g in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Group \(k + 1) · \(g.count) stock\(g.count == 1 ? "" : "s")").font(.caption.bold())
                        Text(g.map(\.symbol).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        Text("Common: " + store.common(g).map(\.text).joined(separator: " · ")).font(.caption2).lineLimit(3)
                    }
                    Spacer()
                    Menu("Name this kind") {
                        ForEach(store.kinds, id: \.self) { kn in Button(kn) { for r in g { store.setKind(kn, for: r.id) } } }
                        Button("Kind " + Self.letter(k)) {
                            let kn = "Kind " + Self.letter(k)
                            for r in g { store.setKind(kn, for: r.id) }
                        }
                    }
                    .fixedSize()
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    private func kindSummary(_ rs: [PatternReview]) -> some View {
        let byKind = Dictionary(grouping: rs.filter { !$0.kind.isEmpty }, by: \.kind)
        return VStack(alignment: .leading, spacing: 4) {
            if !byKind.isEmpty { Text("Kinds").font(.caption.bold()) }
            ForEach(byKind.keys.sorted(), id: \.self) { k in
                let g = byKind[k] ?? []
                HStack(alignment: .top) {
                    Text("\(k) (\(g.count))").font(.caption.bold()).frame(width: 160, alignment: .leading)
                    Text(store.common(g).map(\.text).joined(separator: " · ")).font(.caption2)
                }
            }
        }
    }

    private func open(_ r: PatternReview) {
        let day = MultibaggerCenter.shared.events.first { $0.id == r.id }?.crossDay
        vm.openChart(r.symbol, queue: store.reviewed.map(\.symbol), context: .gainers, openWindow: openWindow)
        if let day { vm.chartGoTo = day }
    }
}
