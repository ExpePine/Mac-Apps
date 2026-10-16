import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Shows stored reports in the same layout as the morning email.
struct ReportsView: View {
    let reports: ReportService
    @ObservedObject var archive: ReportArchive

    @State private var kind: ReportKind = .day
    @State private var anchor = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var generating = false
    @State private var progress = ""

    private var interval: DateInterval { archive.interval(kind, containing: anchor) }
    private var isCurrentPeriod: Bool { interval.contains(Date()) }

    /// HTML for the selected period (nil = daily report not generated yet).
    private var html: String? {
        _ = archive.version   // refresh after saves
        switch kind {
        case .day:
            return archive.load(anchor).map(RecapRenderer.html)
        default:
            return RecapRenderer.html(archive.aggregate(kind, containing: anchor))
        }
    }

    private var missing: [Date] { _ = archive.version; return archive.missingDays(kind, containing: anchor) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if kind != .day && !missing.isEmpty { missingBanner }
            content
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $kind) {
                ForEach(ReportKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            HStack(spacing: 4) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous \(kind.rawValue.lowercased())")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isCurrentPeriod)
                    .help("Next \(kind.rawValue.lowercased())")
            }
            .buttonStyle(.borderless)

            Text(archive.label(kind, interval))
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Button("Today") { anchor = Date() }
                .disabled(isCurrentPeriod)

            Menu {
                Button("Timeline data (CSV)…", action: exportCSV)
                Button("Report (HTML)…", action: exportHTML).disabled(html == nil)
                Divider()
                Button("Show reports folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([archive.directory])
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var missingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
            Text("\(missing.count) day\(missing.count == 1 ? "" : "s") in this period \(missing.count == 1 ? "has" : "have") no stored report, so categories and successes are incomplete.")
                .font(.callout)
            Spacer()
            if generating {
                ProgressView().controlSize(.small)
                Text(progress).font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Generate \(missing.count)") { Task { await generate(missing) } }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let html {
            ReportWebView(html: html)
                .overlay(alignment: .topTrailing) {
                    if kind == .day && !generating {
                        Button { Task { await generate([anchor]) } } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .padding(12)
                        .help("Rebuild this day's report from the latest log")
                    }
                }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(archive.hasActivity(anchor) ? "No report for this day yet" : "No activity on this day")
                    .font(.title3.weight(.semibold))
                if archive.hasActivity(anchor) {
                    Text(Calendar.current.isDateInToday(anchor)
                         ? "Today's report is created tomorrow morning. You can build one for today so far."
                         : "Build it from this day's check-ins and screen time.")
                        .foregroundStyle(.secondary)
                    if generating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(Calendar.current.isDateInToday(anchor) ? "Generate (so far)" : "Generate report") {
                            Task { await generate([anchor]) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func step(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: kind.calendarComponent, value: delta, to: anchor) {
            anchor = min(d, Date())
        }
    }

    private func generate(_ days: [Date]) async {
        generating = true
        for (i, day) in days.enumerated() {
            progress = "\(i + 1) of \(days.count)…"
            await reports.generateReport(for: day)
        }
        progress = ""
        generating = false
    }

    private var fileStem: String {
        let f = DateFormatter()
        switch kind {
        case .day: f.dateFormat = "yyyy-MM-dd"
        case .week: f.dateFormat = "yyyy-'W'ww"
        case .month: f.dateFormat = "yyyy-MM"
        case .year: f.dateFormat = "yyyy"
        }
        return f.string(from: interval.start)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "activity-timeline-\(fileStem).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? archive.timelineCSV(kind, containing: anchor).write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportHTML() {
        guard let html else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(kind.recapKind.lowercased())-report-\(fileStem).html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Displays the report HTML exactly as the email renders it.
struct ReportWebView: NSViewRepresentable {
    let html: String

    final class Coordinator {
        var lastHTML = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }
}
