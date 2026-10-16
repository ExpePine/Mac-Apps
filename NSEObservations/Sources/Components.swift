import SwiftUI
import AppKit

/// Lightweight markdown: headings, bullets, numbered lines and inline styles.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    inline(s)
                        .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, 4)
                case .bullet(let indent, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(s)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(n).foregroundStyle(.secondary).monospacedDigit()
                        inline(s)
                    }
                case .paragraph(let s):
                    inline(s)
                }
            }
        }
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(Int, String)
        case bullet(Int, String)
        case numbered(String, String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet(indent, String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), dot > line.startIndex,
                      line[line.startIndex..<dot].allSatisfy(\.isNumber),
                      line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                out.append(.numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}

/// Card wrapper used across the app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }
}

struct TagChips: View {
    let tags: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { t in
                Text("#\(t)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
    }
}

/// Shows a saved AI analysis with copy/delete actions.
struct AnalysisCard: View {
    let analysis: SavedAnalysis
    var onDelete: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(analysis.kind.title, systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Text("\(Fmt.day.string(from: analysis.createdAt)) · \(analysis.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(analysis.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete")
                }
                MarkdownText(text: analysis.text)
                Text("AI-generated from your notes. Check it against the chart before acting on it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }
}

struct InlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fetches price series for many symbols (best effort) for AI context.
@MainActor
func loadSeries(for symbols: [TrackedSymbol], store: Store) async -> [String: QuoteSeries] {
    var result: [String: QuoteSeries] = [:]
    await withTaskGroup(of: (String, QuoteSeries?).self) { group in
        for s in symbols {
            let earliest = store.observations(for: s.id).map(\.date).min() ?? Date()
            let from = min(earliest.addingTimeInterval(-30 * 86_400),
                           Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date())
            let sym = s.yahooSymbol
            group.addTask {
                let series = try? await MarketDataService.shared.series(for: sym, from: from)
                return (sym, series)
            }
        }
        for await (sym, series) in group {
            if let series { result[sym] = series }
        }
    }
    return result
}
