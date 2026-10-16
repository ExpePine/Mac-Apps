import Foundation
import SwiftUI

/// User settings kept in UserDefaults (the API key itself is in the Keychain).
@MainActor
final class AppSettings: ObservableObject {
    /// Groq model ids change over time — the Settings window can refresh the list from Groq.
    static let defaultModel = "llama-3.3-70b-versatile"

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "groqModel") }
    }
    /// Rough cap on how much of your notes is sent per request (characters, ~4 chars per token).
    @Published var contextBudget: Double {
        didSet { UserDefaults.standard.set(contextBudget, forKey: "contextBudget") }
    }
    @Published var hasKey: Bool

    init() {
        model = UserDefaults.standard.string(forKey: "groqModel") ?? Self.defaultModel
        let budget = UserDefaults.standard.double(forKey: "contextBudget")
        contextBudget = budget > 0 ? budget : 24_000
        hasKey = !(GroqClient.apiKey ?? "").isEmpty
    }

    func saveKey(_ key: String) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.set(k, account: GroqClient.keyAccount)
        hasKey = !k.isEmpty
    }

    func removeKey() {
        Keychain.delete(account: GroqClient.keyAccount)
        hasKey = false
    }
}

/// Builds the text sent to Groq from your notes and price data.
@MainActor
enum AIContext {
    static let analystRole = """
    You are a trading-research assistant for an Indian equity trader who studies NSE charts, \
    writes observations, and turns them into algorithmic trading rules. Be concrete and concise. \
    Use only the notes and price data provided; when something is not in the data, say so instead of guessing. \
    Do not give buy/sell recommendations or price targets; focus on what the notes say, what the prices did, \
    and how the trader's observations could become testable rules. Use short markdown headings and bullet points.
    """

    static func describe(_ o: Observation, outcome: ObservationOutcome?) -> String {
        var line = "- [\(Fmt.isoDayTime.string(from: o.date)) IST] \(o.timeframe.title) chart, \(o.sentiment.title)"
        if !o.tags.isEmpty { line += ", tags: \(o.tags.joined(separator: ", "))" }
        if let p = o.notedPrice { line += ", noted price \(String(format: "%.2f", p))" }
        line += "\n  Note: \(o.text.replacingOccurrences(of: "\n", with: " "))"
        if let oc = outcome {
            line += "\n  Price after: close on \(Fmt.isoDay.string(from: oc.referenceDate)) = \(String(format: "%.2f", oc.referenceClose))"
            line += "; +5 sessions \(Fmt.pct(oc.after5)); +20 sessions \(Fmt.pct(oc.after20))"
            line += "; to latest \(Fmt.pct(oc.sinceThen)); max up \(Fmt.pct(oc.maxUp)); max down \(Fmt.pct(oc.maxDown))"
        }
        return line
    }

    static func symbolBlock(_ s: TrackedSymbol, store: Store, series: QuoteSeries?, includeOutcomes: Bool) -> String {
        var out = "## \(s.ticker)\(s.displayName.isEmpty ? "" : " — \(s.displayName)") (status: \(s.status.title))\n"
        if !s.thesis.isEmpty { out += "Overall thesis: \(s.thesis.replacingOccurrences(of: "\n", with: " "))\n" }
        if !s.tags.isEmpty { out += "Tags: \(s.tags.joined(separator: ", "))\n" }
        if let last = series?.candles.last {
            out += "Latest close: \(String(format: "%.2f", last.close)) on \(Fmt.isoDay.string(from: last.date))\n"
        }
        let trades = store.trades(for: s.id)
        if !trades.isEmpty {
            out += "Trades:\n"
            for t in trades {
                out += "- \(Fmt.isoDay.string(from: t.date)) \(t.side.title) \(formatQty(t.quantity)) @ \(String(format: "%.2f", t.price))\(t.note.isEmpty ? "" : " (\(t.note))")\n"
            }
        }
        let news = store.news(for: nil).filter { $0.symbolID == s.id }.sorted { $0.date < $1.date }
        if !news.isEmpty {
            out += "News summaries the trader saved (oldest first):\n"
            for n in news { out += newsLine(n, store: store) }
        }
        let shots = store.chartShots(for: s.id).sorted { $0.date < $1.date }
            .filter { !$0.caption.isEmpty || !$0.annotations.isEmpty }
        if !shots.isEmpty {
            out += "Notes written on chart screenshots (oldest first):\n"
            for sh in shots {
                var line = "- [\(Fmt.isoDayTime.string(from: sh.date)) IST] \(sh.timeframe.title) chart"
                if !sh.caption.isEmpty { line += ": \(sh.caption.replacingOccurrences(of: "\n", with: " "))" }
                let labels = sh.annotations.map(\.text).filter { !$0.isEmpty }
                if !labels.isEmpty { line += " | labels on chart: \(labels.joined(separator: "; "))" }
                if includeOutcomes, let c = series?.candles, let oc = ObservationOutcome.compute(for: sh.date, candles: c) {
                    line += " | price after: +5 \(Fmt.pct(oc.after5)), +20 \(Fmt.pct(oc.after20)), to latest \(Fmt.pct(oc.sinceThen))"
                }
                out += line + "\n"
            }
        }
        let obs = store.observations(for: s.id).sorted { $0.date < $1.date }
        out += "Observations (oldest first):\n"
        for o in obs {
            let oc = includeOutcomes ? series.flatMap { ObservationOutcome.compute(for: o.date, candles: $0.candles) } : nil
            out += describe(o, outcome: oc) + "\n"
        }
        return out
    }

    nonisolated static func formatQty(_ q: Double) -> String {
        q == q.rounded() ? String(Int(q)) : String(format: "%.2f", q)
    }

    /// Joins symbol blocks until the budget is used; newest-activity symbols go first.
    static func knowledgeBase(store: Store, symbols: [TrackedSymbol], seriesBySymbol: [String: QuoteSeries],
                              includeOutcomes: Bool, budget: Int) -> (text: String, included: Int, omitted: Int) {
        let ordered = symbols.sorted {
            (store.lastObservationDate(for: $0.id) ?? .distantPast) > (store.lastObservationDate(for: $1.id) ?? .distantPast)
        }
        var included = 0
        func hasContent(_ s: TrackedSymbol) -> Bool {
            store.observationCount(for: s.id) > 0 || !store.trades(for: s.id).isEmpty
                || store.data.news.contains { $0.symbolID == s.id }
                || store.data.chartShots.contains { $0.symbolID == s.id }
        }
        // General market news and Pine Script change notes go first, within a small share of the budget.
        var text = extrasBlock(store: store, budget: budget / 5)
        for s in ordered where hasContent(s) {
            let block = symbolBlock(s, store: store, series: seriesBySymbol[s.yahooSymbol], includeOutcomes: includeOutcomes)
            if text.count + block.count > budget {
                if included == 0 { text += String(block.prefix(max(0, budget - text.count))); included = 1 }
                break
            }
            text += block + "\n"
            included += 1
        }
        let total = ordered.filter(hasContent).count
        return (text, included, max(0, total - included))
    }

    static func newsLine(_ n: NewsItem, store: Store) -> String {
        let body = n.text.replacingOccurrences(of: "\n", with: " ")
        let clipped = body.count > 700 ? String(body.prefix(700)) + "…" : body
        let tagList = store.tags(for: n)
        let tags = tagList.isEmpty ? "" : " {tags: \(tagList.map(\.title).joined(separator: ", "))}"
        return "- [\(Fmt.isoDay.string(from: n.date))]\(n.source.isEmpty ? "" : " (\(n.source))")\(tags) \(n.title): \(clipped)\n"
    }

    /// Market-wide news and Pine Script version notes (code is not sent).
    static func extrasBlock(store: Store, budget: Int) -> String {
        var out = ""
        let market = store.data.news.filter { $0.symbolID == nil }.sorted { $0.date > $1.date }
        if !market.isEmpty {
            out += "## Market / general news summaries (newest first)\n"
            for n in market {
                let line = newsLine(n, store: store)
                if out.count + line.count > budget { break }
                out += line
            }
            out += "\n"
        }
        if !store.data.scripts.isEmpty {
            out += "## Pine Script strategy versions (change notes only)\n"
            for sc in store.scriptsByRecent {
                for v in sc.versions.sorted(by: { $0.number < $1.number }) {
                    let line = "- \(sc.name) v\(v.number) [\(Fmt.isoDay.string(from: v.date))]: \(v.note.isEmpty ? "no note" : v.note)\n"
                    if out.count + line.count > budget { break }
                    out += line
                }
            }
            out += "\n"
        }
        return out
    }

    // MARK: Prompts

    static func summaryPrompt(_ block: String) -> String {
        """
        Summarize my observations on this stock.
        1. **Story so far** — how my view evolved over time (2–4 bullets with dates).
        2. **Recurring signals** — chart patterns, levels or conditions I keep mentioning.
        3. **Open questions / contradictions** in my notes.
        4. **Rule candidates** — 1–3 observations phrased as testable algo conditions (e.g. "close > 50-DMA and volume > 1.5× 20-day average").

        \(block)
        """
    }

    static func comparisonPrompt(_ block: String) -> String {
        """
        Compare each of my observations with what the price actually did afterward (the "Price after" lines).
        - For each observation: did it play out, fail, or is it too early? One line each, with the numbers.
        - Overall hit rate of my bullish vs bearish calls on this stock, stated as counts.
        - Which kinds of notes (timeframe, tags, wording) were more reliable here.
        - What I should check next time before writing a similar note.
        Be explicit that this is a small sample when it is.

        \(block)
        """
    }

    static func patternsPrompt(_ kb: String, omitted: Int) -> String {
        """
        Look across ALL stocks below and find patterns in how I observe charts.
        1. **Recurring setups** — the setups/conditions I describe repeatedly across different symbols (name the symbols).
        2. **What worked** — using the "Price after" numbers, which recurring setups tended to be followed by moves in the direction I expected. Give counts, not just impressions.
        3. **What didn't** — setups or habits that tended to fail.
        4. **Algo rule drafts** — 3–6 candidate rules written as precise, backtestable conditions (entry, exit/stop idea, timeframe), each linked to the notes it came from.
        5. **Blind spots** — things I rarely note (e.g. volume, market context, exits) that would make the rules testable.
        \(omitted > 0 ? "Note: \(omitted) symbol(s) were left out to fit the context limit." : "")

        \(kb)
        """
    }

    static func chatSystem(_ kb: String, omitted: Int) -> String {
        """
        \(analystRole)
        Answer questions about the trader's own NSE observation journal below. Cite symbols and dates from the notes. \
        If the answer is not in the journal, say so.\(omitted > 0 ? " (\(omitted) less recently active symbol(s) were omitted to fit the context limit.)" : "")
        Today is \(Fmt.isoDay.string(from: Date())).

        # Journal
        \(kb)
        """
    }
}
