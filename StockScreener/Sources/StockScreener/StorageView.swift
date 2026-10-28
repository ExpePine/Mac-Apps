import SwiftUI
import AppKit

// MARK: - What the app stores on disk, and how big it is

struct StorageItem: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let what: String
    let bytes: Int
    let files: Int
    let compressedBytes: Int          // in .lzfse files
    let modified: Date?
    var children: [StorageItem] = []

    var compressedShare: Double { bytes > 0 ? Double(compressedBytes) / Double(bytes) : 0 }
}

enum StorageScan {
    /// Plain-English names for what's in Application Support/StockScreener.
    static let names: [String: String] = [
        "History": "Daily snapshots of your sheet (one per trading day)",
        "Delivery": "NSE delivery files (one per trading day)",
        "intraday5m": "5-minute closes for MOR / DAY",
        "datalab": "Data Lab candles and predictions",
        "5m": "5-minute candles (open, high, low, close, volume)",
        "1m": "1-minute candles (open, high, low, close, volume)",
        "tomorrow.json.lzfse": "Latest tomorrow's-candle predictions + scores",
        "prediction_log.json.lzfse": "Past predictions (to check against what happened)",
        "prices.json.lzfse": "Yahoo daily prices (about a year, every stock)",
        "multibagger_prices.json.lzfse": "Yahoo long history (5 years, for Multibaggers)",
        "Performance Runs": "Saved Performance runs",
        "Screenshots": "Chart screenshots and drawings",
        "news_history": "News per stock (with Groq labels)",
        "news_cache.json": "Gainer reasons from news + Groq",
        "bulk_deals.json.lzfse": "NSE bulk / block deals",
        "alerts.json": "Alerts that fired (history)",
        "autopredict.json": "AUTO-PREDICT combinations and results",
        "chart_links.json": "Chart 1 / Chart 2 links",
        "experiments.json": "Experiments",
        "experiments.csv.lzfse": "Experiments sheet",
        "mb_combos.json": "Saved F combinations",
        "mb_notes.json": "Your F notes per multibagger",
        "picks.json": "My Picks",
        "regime_log.json": "Sector regime changes",
        "symbols.json": "Symbols you added / hid",
        "tracker.json": "Alert Tracker",
        "watchlists.json": "Watchlists",
        "no_file_days.json": "NSE holidays found while downloading",
        "nse_trading_days.json": "NSE trading calendar",
    ]

    static func scan(_ url: URL, depth: Int = 0) -> StorageItem {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        let name = url.lastPathComponent
        let rv = try? url.resourceValues(forKeys: Set(keys))
        if rv?.isDirectory != true {
            let b = rv?.totalFileAllocatedSize ?? rv?.fileSize ?? 0
            return StorageItem(url: url, name: name, what: names[name] ?? "", bytes: b, files: 1,
                               compressedBytes: name.hasSuffix(".lzfse") ? b : 0, modified: rv?.contentModificationDate)
        }
        var bytes = 0, files = 0, comp = 0
        var newest: Date?
        var kids: [StorageItem] = []
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        if depth < 2 {
            for u in items {
                let k = scan(u, depth: depth + 1)
                bytes += k.bytes; files += k.files; comp += k.compressedBytes
                if let m = k.modified, newest.map({ m > $0 }) ?? true { newest = m }
                kids.append(k)
            }
            kids.sort { $0.bytes > $1.bytes }
        } else if let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
                let b = v.totalFileAllocatedSize ?? v.fileSize ?? 0
                bytes += b; files += 1
                if u.lastPathComponent.hasSuffix(".lzfse") { comp += b }
                if let m = v.contentModificationDate, newest.map({ m > $0 }) ?? true { newest = m }
            }
        }
        // folders whose items are all files (History, Delivery …) don't need their files listed one by one
        if kids.count > 12 && kids.allSatisfy({ $0.children.isEmpty && $0.files == 1 }) { kids = [] }
        return StorageItem(url: url, name: name, what: names[name] ?? "", bytes: bytes, files: files, compressedBytes: comp,
                           modified: newest, children: kids)
    }

    static func size(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
}

struct StorageView: View {
    @State private var root: StorageItem?
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive").foregroundStyle(.blue)
                Text("Data the app stores").font(.headline)
                if let r = root {
                    Text("\(StorageScan.size(r.bytes)) in \(r.files) files · \(String(format: "%.0f", r.compressedShare * 100))% of it compressed")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                Button("Refresh") { scan() }.disabled(scanning)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppFolders.base]) }
            }
            .controlSize(.small)
            .padding(12)
            Divider()
            if let r = root {
                List {
                    ForEach(r.children) { item in
                        if item.children.isEmpty { row(item, total: r.bytes) }
                        else {
                            DisclosureGroup { ForEach(item.children) { row($0, total: item.bytes, indent: true) } } label: { row(item, total: r.bytes) }
                        }
                    }
                }
                .listStyle(.inset)
                Text("Big stores are kept compressed (Apple's LZFSE: .lzfse files). The small .json files hold settings-like lists (notes, picks, watchlists) and are only a few KB each. TradingView sign-ins and pages are kept by macOS's web view outside this folder and aren't counted here.")
                    .font(.caption).foregroundStyle(.secondary).padding(12).fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer()
            }
        }
        .navigationTitle("Data Storage")
        .task { scan() }
    }

    private func row(_ i: StorageItem, total: Int, indent: Bool = false) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(i.what.isEmpty ? i.name : i.what).font(.callout.weight(indent ? .regular : .medium)).lineLimit(1)
                Text(i.name + (i.files > 1 ? " · \(i.files) files" : "") + (i.modified.map { " · changed " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(Color.blue.opacity(0.6)).frame(width: max(2, g.size.width * CGFloat(total > 0 ? Double(i.bytes) / Double(total) : 0)))
                }
            }
            .frame(width: 120, height: 6)
            Text(StorageScan.size(i.bytes)).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
            Text(i.compressedBytes == i.bytes && i.bytes > 0 ? "compressed" : (i.compressedBytes == 0 ? "plain" : String(format: "%.0f%% compressed", i.compressedShare * 100)))
                .font(.caption2).foregroundStyle(i.compressedBytes == 0 ? .orange : .green).frame(width: 96, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.vertical, 2)
    }

    private func scan() {
        scanning = true
        let base = AppFolders.base
        Task {
            let r = await Task.detached(priority: .utility) { StorageScan.scan(base) }.value
            root = r; scanning = false
        }
    }
}
