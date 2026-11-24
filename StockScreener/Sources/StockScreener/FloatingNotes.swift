import SwiftUI
import AppKit
import WebKit

// A floating note pad over TradingView Chart 1: write a note, then put Chart 1's crosshair on the day it belongs to and
// click the candle (or press ⌘↩) — the note is saved for that date, shown as ✎ on the delivery chart, and added to the
// stock's multibagger note for that month (F Notes).

struct DayNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var symbol: String
    var day: String
    var text: String
    var created = Date()
}

@MainActor final class DayNoteStore: ObservableObject {
    static let shared = DayNoteStore()
    @Published private(set) var notes: [DayNote] = []
    private static var url: URL { AppFolders.base.appendingPathComponent("day_notes.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.url), let a = try? JSONDecoder().decode([DayNote].self, from: d) { notes = a }
    }
    private func save() {
        let snap = notes, url = Self.url
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
        }
    }

    func notes(for symbol: String) -> [DayNote] {
        let s = symbol.uppercased()
        return notes.filter { $0.symbol == s }.sorted { $0.day > $1.day }
    }

    func add(_ text: String, symbol: String, day: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !symbol.isEmpty else { return }
        notes.append(DayNote(symbol: symbol.uppercased(), day: day, text: t))
        save()
        // also into the stock's multibagger note for that month (F Notes, patterns)
        MBNoteFocus.shared.setChart(symbol, day: day)
        if let e = MBNoteFocus.shared.event {
            let old = MBNoteStore.shared.text(for: e)
            let line = "\(Self.short(day)): \(t)"
            MBNoteStore.shared.set(old.isEmpty ? line : old + "\n" + line, for: e)
        }
        DeliveryCenter.shared.refreshColumns()       // charts redraw with the ✎ mark
    }

    func remove(_ id: UUID) { notes.removeAll { $0.id == id }; save(); DeliveryCenter.shared.refreshColumns() }

    func update(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].text = text; save()
    }

    static func short(_ day: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        let o = DateFormatter(); o.dateFormat = "d MMM yy"
        return o.string(from: d)
    }

    /// ✎ marks for the delivery chart.
    func markers(_ symbol: String) -> [LWChartData.Marker] {
        notes(for: symbol).map {
            LWChartData.Marker(time: $0.day, text: "✎", position: "aboveBar", color: "#B39DDB", shape: "circle", info: "Note: " + $0.text)
        }
    }
}

/// The floating pad and its crosshair date capture.
@MainActor final class FloatingNotes: ObservableObject {
    static let shared = FloatingNotes()
    @Published var symbol = ""
    @Published var text = ""
    @Published var capturing = false          // waiting for you to put Chart 1's crosshair on the day
    @Published var crossDay: String?          // the day under Chart 1's crosshair right now
    @Published var lastSaved = ""
    private var panel: NSPanel?
    var padOpen = false                       // the Patterns pad uses the same date capture
    var isOpen: Bool { (panel?.isVisible ?? false) || padOpen }

    func show(symbol: String, vm: ScreenerViewModel) {
        if !symbol.isEmpty { self.symbol = symbol.uppercased() }
        if panel == nil {
            let host = NSHostingController(rootView: FloatingNoteView().environmentObject(vm))
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            p.title = "Note"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentViewController = host
            p.setContentSize(NSSize(width: 360, height: 420))
            p.setFrameAutosaveName("FloatingNotePanel")
            if !p.setFrameUsingName("FloatingNotePanel"), let s = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: s.minX + 80, y: s.maxY - 120))
            }
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil); capturing = false }

    /// Called by the chart windows' timers with Chart 1's page: follows the crosshair, and a click on the chart while
    /// capturing saves the note for the day under it.
    func poll(_ web: WKWebView?, symbol sym: String?) {
        guard isOpen, let web, !web.isLoading, let sym, !sym.isEmpty else { return }
        if sym.uppercased() != symbol { symbol = sym.uppercased(); crossDay = nil }
        let body = TVRange.crossBody.replacingOccurrences(of: "return String(window.__ssCross || 0);", with: """
        if (!window.__ssPickOn) {
          document.addEventListener('mousedown', function() { if (window.__ssPicking) window.__ssPick = window.__ssCross || 0; }, true);
          window.__ssPickOn = true;
        }
        window.__ssPicking = \(capturing ? "true" : "false");
        var p = window.__ssPick || 0; window.__ssPick = 0;
        return String(window.__ssCross || 0) + ',' + String(p);
        """)
        TVRange.run(web, body) { [weak self] r in
            guard let self else { return }
            let parts = r.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2 else { return }
            if parts[0] > 0 { let d = TVRange.day(parts[0]); if d != self.crossDay { self.crossDay = d } }
            if parts[1] > 0, self.capturing { self.save(on: TVRange.day(parts[1])) }
        }
    }

    func save(on day: String) {
        DayNoteStore.shared.add(text, symbol: symbol, day: day)
        lastSaved = "Saved for \(DayNoteStore.short(day))"
        text = ""
        capturing = false
    }
}

struct FloatingNoteView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var fn = FloatingNotes.shared
    @ObservedObject private var store = DayNoteStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(fn.symbol.isEmpty ? "Open a stock on Chart 1" : fn.symbol).font(.headline)
                Spacer()
                if !fn.lastSaved.isEmpty { Text(fn.lastSaved).font(.caption).foregroundStyle(.green) }
            }
            TextEditor(text: $fn.text)
                .font(.callout)
                .frame(minHeight: 90)
                .border(Color.secondary.opacity(0.3))
            dateBar
            Divider()
            Text("Notes on \(fn.symbol)").font(.caption.bold()).foregroundStyle(.secondary)
            List {
                ForEach(store.notes(for: fn.symbol)) { n in
                    HStack(alignment: .top, spacing: 6) {
                        Text(DayNoteStore.short(n.day)).font(.caption.monospacedDigit().bold()).frame(width: 62, alignment: .leading)
                        Text(n.text).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button { store.remove(n.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("Delete this note")
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(10)
        .frame(minWidth: 300, minHeight: 320)
    }

    @ViewBuilder private var dateBar: some View {
        if fn.capturing {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "scope").foregroundStyle(.orange)
                    Text(fn.crossDay.map { DayNoteStore.short($0) } ?? "move over Chart 1…")
                        .font(.title3.monospacedDigit().bold()).foregroundStyle(.orange)
                    Spacer()
                    Button("Save for this day") { if let d = fn.crossDay { fn.save(on: d) } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(fn.crossDay == nil)
                    Button("Cancel") { fn.capturing = false }
                }
                Text("Put Chart 1's crosshair on the day and click the candle (or press ⌘↩).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        } else {
            HStack {
                Button { fn.capturing = true; fn.lastSaved = "" } label: { Label("Pick the date on Chart 1", systemImage: "scope") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(fn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fn.symbol.isEmpty)
                Spacer()
                Button("Today") { fn.save(on: AlertSchedule.today()) }
                    .disabled(fn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fn.symbol.isEmpty)
                    .help("Save the note for today without picking a date")
            }
        }
    }
}

/// The chart window's button for the pad.
struct FloatingNoteButton: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let symbol: String
    var body: some View {
        Button { FloatingNotes.shared.show(symbol: symbol, vm: vm) } label: { Label("Note", systemImage: "note.text.badge.plus") }
            .help("A floating note pad over Chart 1 — write, then click the candle on Chart 1 to save the note for that day")
    }
}
