import SwiftUI
import AppKit
import PDFKit

// MARK: - Earnings summary on request
//
// 1. NSE corporate announcements for the stock (unofficial API, needs NSE's cookies):
//    https://www.nseindia.com/api/corporate-announcements?index=equities&symbol=SYM&from_date=…&to_date=…
// 2. The latest financial-results filing (PDF) and, if filed, the earnings-call transcript and investor presentation.
// 3. Their text (PDFKit) → Groq, asked to summarise using ONLY that text.
// Summaries are kept per stock until you press Refresh.

struct NSEAnnouncement: Hashable {
    let date: Date
    let desc: String
    let text: String
    let file: URL?
}

struct EarningsSummary: Codable, Identifiable {
    var id: String { symbol }
    let symbol: String
    var text: String
    var filed: Date?
    var resultsURL: String?
    var transcriptURL: String?
    var presentationURL: String?
    var made: Date
    var model: String
    var note: String = ""         // e.g. "transcript not filed yet"
}

@MainActor final class EarningsSummaryCenter: ObservableObject {
    static let shared = EarningsSummaryCenter()
    @Published private(set) var summaries: [String: EarningsSummary] = [:]
    @Published var current: String?
    @Published private(set) var working: [String: String] = [:]     // symbol → progress text
    @Published private(set) var errors: [String: String] = [:]

    private static var url: URL { AppFolders.base.appendingPathComponent("earnings_summaries.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.url), let a = try? JSONDecoder().decode([EarningsSummary].self, from: d) {
            summaries = Dictionary(a.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(Array(summaries.values)) { try? d.write(to: Self.url, options: .atomic) }
    }

    /// Shows the stock's summary, making it first if there isn't one (or `force`).
    func request(_ symbol: String, model: String, force: Bool = false) {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "NSE:", with: "")
        guard !s.isEmpty else { return }
        current = s
        if working[s] != nil || (!force && summaries[s] != nil) { return }
        errors[s] = nil
        working[s] = "Finding the latest results on NSE…"
        Task {
            do {
                let r = try await make(s, model: model)
                summaries[s] = r
                save()
            } catch {
                errors[s] = error.localizedDescription
            }
            working[s] = nil
        }
    }

    func remove(_ symbol: String) { summaries[symbol] = nil; save() }

    // MARK: Building one

    private func make(_ sym: String, model: String) async throws -> EarningsSummary {
        let ann = try await Self.announcements(sym)
        guard !ann.isEmpty else { throw GroqClient.Failure(message: "NSE returned no announcements for \(sym) in the last 6 months") }
        guard let results = Self.pickResults(ann) else {
            throw GroqClient.Failure(message: "No financial-results filing for \(sym) in NSE's announcements of the last 6 months")
        }
        // transcript / presentation filed after the results
        let after = ann.filter { $0.date >= results.date.addingTimeInterval(-3 * 86_400) }
        let transcript = after.first { Self.has($0, ["transcript"]) && $0.file != nil }
        let deck = after.first { Self.has($0, ["investor presentation", "earnings presentation", "analyst presentation"]) && $0.file != nil }

        working[sym] = "Reading the results filing…"
        let rFull = try await Self.pdfText(results.file, limit: 120_000)
        var tFull = ""
        if let t = transcript { working[sym] = "Reading the earnings-call transcript…"; tFull = (try? await Self.pdfText(t.file, limit: 80_000)) ?? "" }
        var pFull = ""
        if tFull.isEmpty, let d = deck { working[sym] = "Reading the investor presentation…"; pFull = (try? await Self.pdfText(d.file, limit: 40_000)) ?? "" }
        // Free Groq keys allow ~8,000 tokens per request (prompt + answer), so send only the lines that matter:
        // the results' key lines, and the opening of the call (management's remarks). Shrinks again if Groq says so.
        var budget = 15_000
        var rText = "", tText = "", pText = ""
        func cut() {
            let hasCall = !tFull.isEmpty || !pFull.isEmpty
            rText = Self.focus(rFull, limit: hasCall ? budget * 6 / 10 : budget)
            tText = Self.opening(tFull, limit: budget * 4 / 10)
            pText = Self.focus(pFull, limit: budget * 4 / 10)
        }
        cut()
        guard !rText.isEmpty || !tText.isEmpty else {
            throw GroqClient.Failure(message: "The results PDF has no readable text (probably a scanned image) — open it from NSE instead")
        }

        working[sym] = "Summarising with Groq…"
        let df = DateFormatter(); df.dateFormat = "d MMM yyyy"
        var text = ""
        for attempt in 0..<4 {
            var user = "Company: \(sym) (NSE)\nResults filed on NSE: \(df.string(from: results.date)) — \(results.desc)\n\n"
            user += "=== RESULTS FILING (key lines) ===\n" + (rText.isEmpty ? "(not readable)" : rText) + "\n"
            if !tText.isEmpty { user += "\n=== EARNINGS CALL TRANSCRIPT (opening remarks, cut) ===\n" + tText + "\n" }
            if !pText.isEmpty { user += "\n=== INVESTOR PRESENTATION (key lines, cut) ===\n" + pText + "\n" }
            do {
                LLMPool.shared.mainGroqModel = model
                text = try await LLMPool.shared.chatAny(system: Self.system, user: user, maxTokens: 1_600)
                break
            } catch let e as GroqClient.TooLarge {
                guard attempt < 3 else { throw GroqClient.Failure(message: "Still too large for your Groq plan's per-request limit (\(e.limit) tokens) — pick a model with a higher limit in News & AI settings") }
                let factor = e.requested > 0 && e.limit > 0 ? Double(e.limit - 1_800) / Double(e.requested - 1_600) * 0.85 : 0.6
                budget = max(2_500, Int(Double(budget) * min(0.85, max(0.3, factor))))
                cut()
                working[sym] = "Shortening for Groq's limit (try \(attempt + 2))…"
            }
        }
        var note = ""
        if transcript == nil { note = "No earnings-call transcript filed yet" + (deck == nil ? "" : " — used the investor presentation") }
        return EarningsSummary(symbol: sym, text: text.trimmingCharacters(in: .whitespacesAndNewlines), filed: results.date,
                               resultsURL: results.file?.absoluteString, transcriptURL: transcript?.file?.absoluteString,
                               presentationURL: deck?.file?.absoluteString, made: Date(), model: model, note: note)
    }

    static let system = """
    You summarise an Indian listed company's latest quarterly results for an investor, using ONLY the filing text given \
    (and the earnings-call transcript or presentation if given). Never invent or estimate numbers. If something isn't in \
    the text, write "not stated". Prefer CONSOLIDATED figures when both consolidated and standalone are given, and say which \
    you used. Keep the units exactly as in the filing (₹ crore / ₹ lakh / ₹ million). Compute YoY / QoQ % only when both \
    numbers are in the text. Do not use tables. Use this layout with these headings:

    **Headline** — one sentence.
    **Quarter** — which quarter / period, consolidated or standalone.
    **Key numbers** — one line each: Revenue from operations · EBITDA or operating profit (if stated) · Profit before tax · \
    Net profit · EPS — each as: this quarter, same quarter last year (YoY %), previous quarter (QoQ %).
    **Margins** — operating / net margin now vs a year ago, if they can be worked out from the text.
    **What stood out** — 2–5 bullets: segments, one-off / exceptional items, tax, dividend, order book, debt, auditor remarks.
    **From the earnings call** — 3–6 bullets of management commentary, guidance, demand, margins outlook, risks \
    (only if a transcript or presentation was given; otherwise write "No call transcript filed yet").
    **Tone** — Strong / Mixed / Weak, with a one-line reason based on the numbers above.
    """

    // MARK: NSE

    private static let referer = "https://www.nseindia.com/companies-listing/corporate-filings-announcements"
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "dd-MM-yyyy"; return f
    }()

    static func announcements(_ sym: String) async throws -> [NSEAnnouncement] {
        let to = Date(), from = to.addingTimeInterval(-185 * 86_400)
        let q = sym.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sym
        guard let url = URL(string: "https://www.nseindia.com/api/corporate-announcements?index=equities&symbol=\(q)&from_date=\(fmt.string(from: from))&to_date=\(fmt.string(from: to))") else { return [] }
        let obj = try await NSEDealsClient.json(url, referer: referer)
        let rows = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return rows.compactMap(parse).sorted { $0.date > $1.date }
    }

    static func parse(_ r: [String: Any]) -> NSEAnnouncement? {
        func s(_ k: [String]) -> String { for x in k { if let v = r[x] as? String, !v.isEmpty { return v } }; return "" }
        let raw = s(["sort_date", "an_dt", "dt", "exchdisstime"])
        guard let date = parseDate(raw) else { return nil }
        let file = s(["attchmntFile", "attachment", "file"])
        return NSEAnnouncement(date: date, desc: s(["desc", "subject"]), text: s(["attchmntText", "details", "text"]),
                               file: file.isEmpty || file == "-" ? nil : URL(string: file))
    }

    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for f in ["yyyy-MM-dd HH:mm:ss", "dd-MMM-yyyy HH:mm:ss", "dd-MMM-yyyy", "ddMMyyyyHHmmss", "yyyy-MM-dd"] {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "Asia/Kolkata"); df.dateFormat = f
            if let d = df.date(from: t) { return d }
        }
        return nil
    }

    static func has(_ a: NSEAnnouncement, _ words: [String]) -> Bool {
        let t = (a.desc + " " + a.text).lowercased()
        return words.contains { t.contains($0) }
    }

    /// The latest filing that IS the results (not the meeting's advance notice).
    static func pickResults(_ ann: [NSEAnnouncement]) -> NSEAnnouncement? {
        func score(_ a: NSEAnnouncement) -> Int {
            guard a.file != nil else { return 0 }
            let d = a.desc.lowercased(), t = a.text.lowercased()
            if d.contains("intimation") || t.contains("intimation of board meeting") || t.contains("will be held") { return 0 }
            if d.contains("financial result") { return 3 }
            if d.contains("outcome of board meeting") && (t.contains("result") || t.contains("financial")) { return 2 }
            if t.contains("financial results") && (t.contains("approved") || t.contains("quarter ended")) { return 1 }
            return 0
        }
        let best = ann.map { ($0, score($0)) }.filter { $0.1 > 0 }
        guard let top = best.map(\.1).max() else { return nil }
        // the newest among the strongest matches, but a newer weaker match from a later quarter wins
        let newest = best.max { $0.0.date < $1.0.date }!
        let strongest = best.filter { $0.1 == top }.max { $0.0.date < $1.0.date }!
        return newest.0.date.timeIntervalSince(strongest.0.date) > 30 * 86_400 ? newest.0 : strongest.0
    }

    private static let keyWords = ["revenue", "income from operations", "total income", "other income", "expenses", "ebitda", "operating profit",
                                   "profit before", "profit after", "net profit", "profit for the", "tax", "exceptional", "earnings per share", "eps",
                                   "segment", "dividend", "quarter ended", "half year ended", "year ended", "consolidated", "standalone",
                                   "margin", "order book", "borrowings", "finance cost", "depreciation", "employee", "material", "loss"]

    /// The lines of a results filing that carry the numbers (statement rows, headings), in order, up to `limit` characters.
    static func focus(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out = "", seen = Set<String>()
        for l in lines {
            let low = l.lowercased()
            guard keyWords.contains(where: { low.contains($0) }), !seen.contains(low) else { continue }
            seen.insert(low)
            if out.count + l.count + 1 > limit { break }
            out += l + "\n"
        }
        if out.count < limit / 2 { out += String(text.prefix(limit - out.count)) }
        return out
    }

    /// The start of a call transcript after its cover page / disclaimer — management's opening remarks.
    static func opening(_ text: String, limit: Int) -> String {
        guard !text.isEmpty else { return "" }
        let low = text.lowercased()
        var start = text.startIndex
        for marker in ["moderator:", "good morning", "good afternoon", "good evening", "ladies and gentlemen"] {
            if let r = low.range(of: marker) { start = text.index(text.startIndex, offsetBy: low.distance(from: low.startIndex, to: r.lowerBound)); break }
        }
        return String(text[start...].prefix(limit))
    }

    static func pdfText(_ url: URL?, limit: Int) async throws -> String {
        guard let url else { return "" }
        let data = try await NSEDealsClient.raw(url, referer: referer)
        guard let doc = PDFDocument(data: data) else { return "" }
        var out = ""
        for i in 0..<doc.pageCount {
            if let t = doc.page(at: i)?.string { out += t + "\n" }
            if out.count > limit { break }
        }
        let squeezed = out.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return String(squeezed.prefix(limit))
    }
}

// MARK: - Button + window

/// "Earnings summary" button: makes (or shows) the stock's summary in the Earnings Summary window.
struct EarningsSummaryButton: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var c = EarningsSummaryCenter.shared
    let symbol: String
    var compact = true
    var body: some View {
        Button {
            c.request(symbol, model: vm.settings.groqModel)
            openWindow(id: "earnsum")
        } label: {
            if compact { Image(systemName: c.working[symbol.uppercased()] != nil ? "hourglass" : "doc.text.magnifyingglass") }
            else { Label("Earnings summary", systemImage: "doc.text.magnifyingglass") }
        }
        .help("Earnings summary of \(symbol): latest results filed on NSE (+ earnings-call transcript), summarised by Groq")
    }
}

struct EarningsSummaryView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var c = EarningsSummaryCenter.shared
    @State private var typed = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SymbolField(vm: vm, placeholder: "Symbol", text: $typed) {
                        let s = SymbolBook.clean(typed)
                        if !s.isEmpty { c.request(s, model: vm.settings.groqModel) }
                    }
                }
                .padding(8)
                List(selection: Binding(get: { c.current }, set: { c.current = $0 })) {
                    ForEach(c.summaries.values.sorted { $0.made > $1.made }) { s in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.symbol).fontWeight(.medium)
                            Text(s.filed.map { "results " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "").font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(Optional(s.symbol))
                        .contextMenu { Button("Remove", role: .destructive) { c.remove(s.symbol) } }
                    }
                    ForEach(c.working.keys.sorted().filter { c.summaries[$0] == nil }, id: \.self) { s in
                        HStack { Text(s); ProgressView().controlSize(.mini) }.tag(Optional(s))
                    }
                }
            }
            .frame(minWidth: 170, idealWidth: 200, maxWidth: 280)

            detail.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(c.current.map { "Earnings summary — \($0)" } ?? "Earnings summary")
    }

    @ViewBuilder private var detail: some View {
        if let sym = c.current {
            VStack(alignment: .leading, spacing: 0) {
                FlowLayout(spacing: 10, lineSpacing: 6) {
                    Text(sym).font(.title2.bold())
                    if let s = c.summaries[sym], let f = s.filed { Text("results filed \(f.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary) }
                    if let s = c.summaries[sym] {
                        if let u = s.resultsURL.flatMap(URL.init(string:)) { Button { NSWorkspace.shared.open(u) } label: { Label("Results PDF", systemImage: "doc.richtext") } }
                        if let u = s.transcriptURL.flatMap(URL.init(string:)) { Button { NSWorkspace.shared.open(u) } label: { Label("Call transcript", systemImage: "text.bubble") } }
                        if let u = s.presentationURL.flatMap(URL.init(string:)) { Button { NSWorkspace.shared.open(u) } label: { Label("Presentation", systemImage: "rectangle.on.rectangle") } }
                    }
                    Button {
                        if let u = URL(string: "https://www.nseindia.com/companies-listing/corporate-filings-financial-results?symbol=\(sym)") { NSWorkspace.shared.open(u) }
                    } label: { Label("NSE", systemImage: "safari") }
                    Button { vm.openChart(sym, openWindow: openWindow) } label: { Label("Chart", systemImage: "chart.xyaxis.line") }
                    AddToWatchlistButton(symbol: sym, source: "Earnings summary")
                    Spacer()
                    if let s = c.summaries[sym] {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(sym) — earnings summary\n\n" + s.text, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                    Button { c.request(sym, model: vm.settings.groqModel, force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(c.working[sym] != nil)
                }
                .controlSize(.small)
                .padding(10)
                Divider()
                if let w = c.working[sym] {
                    VStack(spacing: 8) { ProgressView(); Text(w).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let e = c.errors[sym] {
                    VStack(spacing: 8) {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).multilineTextAlignment(.center)
                        Button("Try again") { c.request(sym, model: vm.settings.groqModel, force: true) }
                    }
                    .frame(maxWidth: 480).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let s = c.summaries[sym] {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(s.text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                if line.trimmingCharacters(in: .whitespaces).isEmpty { Spacer().frame(height: 4) }
                                else { Text(Self.md(line)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                            }
                            if !s.note.isEmpty { Text(s.note).font(.caption).foregroundStyle(.orange).padding(.top, 6) }
                            Text("Made \(s.made.formatted(date: .abbreviated, time: .shortened)) by Groq (\(s.model)) from the filings' text — AI summaries can misread tables; check key numbers in the PDF. Not financial advice.")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Button("Make the earnings summary") { c.request(sym, model: vm.settings.groqModel, force: true) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            Text("Type a symbol, or press the earnings button (doc with a magnifier) on any chart / right-click a stock.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
