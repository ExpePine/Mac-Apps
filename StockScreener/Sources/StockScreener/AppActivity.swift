import SwiftUI
import Combine

/// What the app is doing right now (downloads, counts, scans) and a short log of what it did — shown in small text
/// in the status strip at the bottom of the main window. It listens to the busy / progress / status values the
/// app's parts already publish, so nothing else has to report to it.
@MainActor final class AppActivity: ObservableObject {
    static let shared = AppActivity()

    struct Line: Identifiable { let id = UUID(); let time: Date; let text: String }

    /// source → what it's doing now (only while busy)
    @Published private(set) var active: [(src: String, text: String)] = []
    @Published private(set) var log: [Line] = []

    private var bag = Set<AnyCancellable>()
    private var started = false

    /// Busy state of one part: text while working, nil when idle. Start and finish go into the log;
    /// progress updates in between only change the live line.
    func set(_ src: String, _ text: String?) {
        let i = active.firstIndex { $0.src == src }
        if let text, !text.isEmpty {
            if let i { if active[i].text != text { active[i].text = text } }
            else { active.append((src, text)); add("\(src) · \(text)") }
        } else if let i {
            active.remove(at: i)
            add("\(src) · done")
        }
    }

    /// A one-off message (a part's status text, an error).
    func note(_ src: String, _ text: String?) {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
        add("\(src) · \(t)")
    }

    private func add(_ s: String) {
        if let last = log.last, last.text == s, Date().timeIntervalSince(last.time) < 5 { return }
        log.append(Line(time: Date(), text: s))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    // MARK: listening

    func start(_ vm: ScreenerViewModel) {
        guard !started else { return }
        started = true
        add("App started")

        func count(_ p: (Int, Int)) -> String { p.1 > 0 ? "\(p.0)/\(p.1)" : "working…" }
        func pct(_ p: Double) -> String { p > 0 ? "\(Int((p * 100).rounded()))%" : "starting…" }
        func watch<P: Publisher>(_ src: String, _ p: P) where P.Output == String?, P.Failure == Never {
            p.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] t in self?.set(src, t) }.store(in: &bag)
        }
        func notes<P: Publisher>(_ src: String, _ p: P) where P.Output == String?, P.Failure == Never {
            p.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] t in self?.note(src, t) }.store(in: &bag)
        }

        // Google Sheet + prices
        watch("Google Sheet", vm.$isLoading.map { on -> String? in on ? "loading…" : nil })
        vm.$lastFetchFailed.removeDuplicates().filter { $0 }.sink { [weak self] _ in self?.note("Google Sheet", "fetch failed") }.store(in: &bag)
        watch("Yahoo prices", vm.$isFetchingPrices.combineLatest(vm.$priceProgress).map { on, p -> String? in on ? count(p) : nil })

        // NSE delivery
        let dc = DeliveryCenter.shared
        watch("NSE delivery", dc.$isLoading.combineLatest(dc.$progress).map { on, p -> String? in on ? count((p.done, p.total)) : nil })
        notes("NSE delivery", dc.$status)

        // formulas
        let fd = FormulaDaysCenter.shared
        watch("Formula counts", fd.$running.combineLatest(fd.$progress).map { on, p -> String? in on ? pct(p) : nil })
        let fm = FormulaMarks.shared
        watch("F marks", fm.$running.combineLatest(fm.$progress).map { on, p -> String? in on ? (p.isEmpty ? "working…" : p) : nil })
        let lt = LeadTimeCenter.shared
        watch("Lead time", lt.$running.combineLatest(lt.$progress).map { on, p -> String? in on ? pct(p) : nil })
        let wa = WeightsAuto.shared
        watch("Auto weights", wa.$running.combineLatest(wa.$progress).map { on, p -> String? in on ? pct(p) : nil })

        // screenshots, live quotes, scans
        let qc = QuickCenter.shared
        watch("Quick look", qc.$running.combineLatest(qc.$progress).map { on, p -> String? in on ? (p.isEmpty ? "taking screenshots…" : p) : nil })
        watch("Live quotes", LiveQuotes.shared.$progress.map { p -> String? in p.total > 0 && p.done < p.total ? count((p.done, p.total)) : nil })
        let mb = MultibaggerCenter.shared
        watch("Multibaggers", mb.$progress.map { p -> String? in p.total > 0 && p.done < p.total ? count((p.done, p.total)) : nil })
        notes("Multibaggers", mb.$status)
        let nr = NSERepair.shared
        watch("NSE repair", nr.$running.combineLatest(nr.$progress).map { on, p -> String? in on ? count((p.done, p.total)) : nil })

        // deals, news, results, earnings
        let dl = DealsCenter.shared
        watch("Bulk / block deals", dl.$busy.map { on -> String? in on ? "downloading…" : nil })
        watch("Deals history", dl.$fillRunning.combineLatest(dl.$fillProgress).map { on, p -> String? in on ? count((p.done, p.total)) : nil })
        notes("Deals", dl.$status)
        let nt = NewsTimeline.shared
        watch("News", nt.$busy.map { b -> String? in b.map { "fetching \($0)" } })
        notes("News", nt.$status)
        notes("Results growth", ResultsGrowthCenter.shared.$status)
        let ec = EarningsCenter.shared
        watch("Earnings", ec.$busy.map { on -> String? in on ? "working…" : nil })
        notes("Earnings", ec.$status)
        watch("Earnings summary", EarningsSummaryCenter.shared.$working.map { w -> String? in w.isEmpty ? nil : (w.count == 1 ? w.keys.first! : "\(w.count) stocks") })
        let id5 = Intraday5mCenter.shared
        watch("Intraday 5m", id5.$busy.combineLatest(id5.$progress).map { on, p -> String? in on ? count(p) : nil })
        notes("Intraday 5m", id5.$status)
        let tl = TimingLabCenter.shared
        watch("Timing lab", tl.$busy.combineLatest(tl.$progress).map { on, p -> String? in on ? count(p) : nil })
        notes("Timing lab", tl.$status)
        let ap = AutoPredictCenter.shared
        watch("Auto predict", ap.$running.map { on -> String? in on ? "working…" : nil })
        notes("Auto predict", ap.$status)
    }
}

/// The small live line in the status strip: what's running now (with a spinner), or the last thing that happened.
/// Click it for the recent log.
struct ActivityStrip: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var a = AppActivity.shared
    @State private var showLog = false

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        Button { showLog.toggle() } label: { line }
            .buttonStyle(.plain)
            .help("What the app is doing — click for the recent log")
            .popover(isPresented: $showLog, arrowEdge: .top) { ActivityLogView() }
            .onAppear { a.start(vm) }
    }

    @ViewBuilder private var line: some View {
        HStack(spacing: 5) {
            if a.active.isEmpty {
                Image(systemName: "checkmark.circle").foregroundStyle(.green.opacity(0.7))
                if let l = a.log.last {
                    Text(Self.clock.string(from: l.time) + "  " + l.text).lineLimit(1).truncationMode(.tail)
                } else {
                    Text("idle")
                }
            } else {
                ProgressView().controlSize(.mini)
                Text(a.active.map { "\($0.src): \($0.text)" }.joined(separator: "  ·  ")).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}

/// The last few hundred activity lines, newest at the bottom.
struct ActivityLogView: View {
    @ObservedObject private var a = AppActivity.shared
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Copy") {
                    let s = a.log.map { Self.clock.string(from: $0.time) + "  " + $0.text }.joined(separator: "\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
                }
                .controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(a.log) { l in
                            Text(Self.clock.string(from: l.time) + "  " + l.text)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .id(l.id)
                        }
                    }
                }
                .onAppear { if let id = a.log.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                .onChange(of: a.log.count) { _ in if let id = a.log.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .padding(10)
        .frame(width: 520, height: 320)
    }
}
