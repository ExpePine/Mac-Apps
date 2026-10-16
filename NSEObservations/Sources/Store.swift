import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// All notes live in one JSON file in the app's Application Support folder.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var data = AppData()
    @Published var lastError: String?
    /// A screenshot to show when its stock page opens (set by Timeline clicks and quick capture).
    @Published var focusShotID: UUID?

    let fileURL: URL

    /// `fileURL`/`seed` are only used by screenshot mode, so sample data never touches your journal.
    init(fileURL custom: URL? = nil, seed: AppData? = nil) {
        if let custom {
            fileURL = custom
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let dir = base.appendingPathComponent("NSEObservations", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("observations.json")
        }
        if let seed {
            data = seed
            save()
        } else {
            load()
        }
    }

    // MARK: Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let raw = try Data(contentsOf: fileURL)
            data = try Self.decoder.decode(AppData.self, from: raw)
        } catch {
            // Keep the unreadable file aside instead of overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            lastError = "Couldn't read saved notes (\(error.localizedDescription)). A copy was kept at \(backup.lastPathComponent)."
        }
    }

    private func save() {
        do {
            let raw = try Self.encoder.encode(data)
            try raw.write(to: fileURL, options: .atomic)
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Queries

    var symbols: [TrackedSymbol] { data.symbols }

    func symbol(_ id: UUID) -> TrackedSymbol? { data.symbols.first { $0.id == id } }

    func symbols(with status: SymbolStatus) -> [TrackedSymbol] {
        data.symbols.filter { $0.status == status }.sorted { $0.ticker < $1.ticker }
    }

    func observations(for symbolID: UUID) -> [Observation] {
        data.observations.filter { $0.symbolID == symbolID }.sorted { $0.date > $1.date }
    }

    func trades(for symbolID: UUID) -> [Trade] {
        data.trades.filter { $0.symbolID == symbolID }.sorted { $0.date < $1.date }
    }

    func analyses(for symbolID: UUID?, kind: AnalysisKind) -> [SavedAnalysis] {
        data.analyses.filter { $0.symbolID == symbolID && $0.kind == kind }.sorted { $0.createdAt > $1.createdAt }
    }

    func observationCount(for symbolID: UUID) -> Int {
        data.observations.reduce(0) { $0 + ($1.symbolID == symbolID ? 1 : 0) }
    }

    func lastObservationDate(for symbolID: UUID) -> Date? {
        data.observations.filter { $0.symbolID == symbolID }.map(\.date).max()
    }

    /// Net quantity held and average buy price (simple average-cost method).
    func position(for symbolID: UUID) -> (qty: Double, avg: Double)? {
        var qty = 0.0, cost = 0.0
        for t in trades(for: symbolID) {
            switch t.side {
            case .buy:
                cost += t.quantity * t.price
                qty += t.quantity
            case .sell:
                guard qty > 0 else { continue }
                let avg = cost / qty
                let q = min(t.quantity, qty)
                qty -= q
                cost -= q * avg
            }
        }
        return qty > 0 ? (qty, cost / qty) : nil
    }

    func matches(_ s: TrackedSymbol, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        if s.ticker.lowercased().contains(q) || s.displayName.lowercased().contains(q) { return true }
        if s.tags.contains(where: { $0.contains(q) }) || s.thesis.lowercased().contains(q) { return true }
        return data.observations.contains {
            $0.symbolID == s.id && ($0.text.lowercased().contains(q) || $0.tags.contains(where: { $0.contains(q) }))
        }
    }

    // MARK: Mutations

    func upsert(_ symbol: TrackedSymbol) {
        if let i = data.symbols.firstIndex(where: { $0.id == symbol.id }) {
            data.symbols[i] = symbol
        } else {
            data.symbols.append(symbol)
        }
        save()
    }

    func existingSymbol(ticker: String) -> TrackedSymbol? {
        let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        return data.symbols.first { $0.ticker.uppercased() == t }
    }

    func deleteSymbol(_ id: UUID) {
        data.symbols.removeAll { $0.id == id }
        data.observations.filter { $0.symbolID == id }.flatMap(\.imageFiles).forEach(deleteImage)
        data.observations.removeAll { $0.symbolID == id }
        data.news.removeAll { $0.symbolID == id }
        data.chartShots.filter { $0.symbolID == id }.map(\.imageFile).forEach(deleteImage)
        data.chartShots.removeAll { $0.symbolID == id }
        for i in data.scripts.indices { data.scripts[i].symbolIDs.removeAll { $0 == id } }
        data.trades.removeAll { $0.symbolID == id }
        data.analyses.removeAll { $0.symbolID == id }
        save()
    }

    func setStatus(_ status: SymbolStatus, for id: UUID) {
        guard let i = data.symbols.firstIndex(where: { $0.id == id }) else { return }
        data.symbols[i].status = status
        save()
    }

    func upsert(_ obs: Observation) {
        var o = obs
        o.updatedAt = Date()
        if let i = data.observations.firstIndex(where: { $0.id == o.id }) {
            data.observations[i] = o
        } else {
            data.observations.append(o)
        }
        save()
    }

    func deleteObservation(_ id: UUID) {
        if let o = data.observations.first(where: { $0.id == id }) {
            o.imageFiles.forEach(deleteImage)
        }
        data.observations.removeAll { $0.id == id }
        save()
    }

    func upsert(_ trade: Trade) {
        if let i = data.trades.firstIndex(where: { $0.id == trade.id }) {
            data.trades[i] = trade
        } else {
            data.trades.append(trade)
        }
        save()
    }

    func deleteTrade(_ id: UUID) {
        data.trades.removeAll { $0.id == id }
        save()
    }

    func add(_ analysis: SavedAnalysis) {
        data.analyses.append(analysis)
        // Keep the newest 10 per (symbol, kind) so the file stays small.
        let same = data.analyses.filter { $0.symbolID == analysis.symbolID && $0.kind == analysis.kind }
            .sorted { $0.createdAt > $1.createdAt }
        if same.count > 10 {
            let drop = Set(same.dropFirst(10).map(\.id))
            data.analyses.removeAll { drop.contains($0.id) }
        }
        save()
    }

    func deleteAnalysis(_ id: UUID) {
        data.analyses.removeAll { $0.id == id }
        save()
    }

    func appendChat(_ msg: ChatMessage) {
        data.chat.append(msg)
        save()
    }

    func clearChat() {
        data.chat.removeAll()
        save()
    }

    // MARK: Import / export

    func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NSE-Observations-\(Fmt.isoDay.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.encoder.encode(data).write(to: url, options: .atomic)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Merges a backup: items with the same id are replaced by the backup's version.
    func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try Self.decoder.decode(AppData.self, from: Data(contentsOf: url))
            func merge<T: Identifiable>(_ a: [T], _ b: [T]) -> [T] where T.ID == UUID {
                var dict = Dictionary(a.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
                for item in b { dict[item.id] = item }
                return Array(dict.values)
            }
            data.symbols = merge(data.symbols, incoming.symbols)
            data.observations = merge(data.observations, incoming.observations)
            data.trades = merge(data.trades, incoming.trades)
            data.analyses = merge(data.analyses, incoming.analyses)
            data.chat = merge(data.chat, incoming.chat).sorted { $0.date < $1.date }
            data.news = merge(data.news, incoming.news)
            data.scripts = merge(data.scripts, incoming.scripts)
            data.chartShots = merge(data.chartShots, incoming.chartShots)
            save()
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
        }
    }

    func revealDataFile() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: Folders

    var dataFolder: URL { fileURL.deletingLastPathComponent() }

    var attachmentsFolder: URL {
        let u = dataFolder.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    var scriptsFolder: URL {
        let u = dataFolder.appendingPathComponent("PineScripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func revealFolder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Observation images

    /// Full-size images: only a handful are kept in memory at a time.
    private static let fullCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.countLimit = 16; return c
    }()
    private static let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.countLimit = 400; return c
    }()

    func imageURL(_ name: String) -> URL { attachmentsFolder.appendingPathComponent(name) }

    func image(_ name: String) -> NSImage? {
        if let hit = Self.fullCache.object(forKey: name as NSString) { return hit }
        guard let img = NSImage(contentsOf: imageURL(name)) else { return nil }
        Self.fullCache.setObject(img, forKey: name as NSString)
        return img
    }

    /// Small preview for lists and filmstrips (decoded at reduced size).
    func thumbnail(_ name: String, maxPixel: Int = 420) -> NSImage? {
        let key = "\(name)#\(maxPixel)" as NSString
        if let hit = Self.thumbCache.object(forKey: key) { return hit }
        guard let img = ImageCompression.thumbnail(at: imageURL(name), maxPixel: maxPixel) else { return nil }
        Self.thumbCache.setObject(img, forKey: key)
        return img
    }

    /// Compresses (HEIC, capped size) and writes an image to the Attachments folder; returns the file name.
    func saveImage(_ image: NSImage) -> String? {
        guard let out = ImageCompression.compress(image) else {
            lastError = "Couldn't read that image."
            return nil
        }
        let name = "\(UUID().uuidString).\(out.ext)"
        do {
            try out.data.write(to: imageURL(name), options: .atomic)
            return name
        } catch {
            lastError = "Couldn't save image: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Converting older PNG screenshots

    @Published private(set) var compressionStatus: String?
    private var compressing = false

    /// Image files still stored as PNG (from earlier versions of the app).
    var legacyImageNames: [String] {
        let names = data.chartShots.map(\.imageFile) + data.observations.flatMap(\.imageFiles)
        return Array(Set(names.filter { $0.lowercased().hasSuffix(".png") }))
    }

    /// Re-encodes PNG screenshots with the current compression settings. Safe to run repeatedly.
    func compressLegacyImages() async {
        let names = legacyImageNames
        guard !names.isEmpty, !compressing else { return }
        compressing = true
        defer { compressing = false }
        var saved: Int64 = 0, done = 0
        for name in names {
            compressionStatus = "Compressing \(done + 1) of \(names.count)…"
            let src = imageURL(name)
            let quality = ImageCompression.quality.value, maxPx = ImageCompression.maxPixels
            let result: (data: Data, ext: String)? = await Task.detached(priority: .utility) {
                guard let cg = ImageCompression.cgImage(at: src) else { return nil }
                return ImageCompression.compress(cg, quality: quality, maxPixels: maxPx)
            }.value
            guard let out = result else { continue }
            let oldSize = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            // Only replace when it actually saves space.
            guard out.data.count < oldSize else { continue }
            let newName = "\(UUID().uuidString).\(out.ext)"
            do { try out.data.write(to: imageURL(newName), options: .atomic) } catch { continue }
            for i in data.chartShots.indices where data.chartShots[i].imageFile == name {
                data.chartShots[i].imageFile = newName
            }
            for i in data.observations.indices {
                if let a = data.observations[i].attachments, a.contains(name) {
                    data.observations[i].attachments = a.map { $0 == name ? newName : $0 }
                }
            }
            save()
            deleteImage(name)
            saved += Int64(oldSize - out.data.count)
            done += 1
        }
        compressionStatus = done == 0 ? nil : "Compressed \(done) image\(done == 1 ? "" : "s"), saved \(ImageCompression.format(saved))."
    }

    func deleteImage(_ name: String) {
        Self.fullCache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: imageURL(name))
    }

    // MARK: News

    func news(for symbolID: UUID?) -> [NewsItem] {
        data.news.filter { symbolID == nil || $0.symbolID == symbolID }.sorted { $0.date > $1.date }
    }

    func upsert(_ item: NewsItem) {
        if let i = data.news.firstIndex(where: { $0.id == item.id }) { data.news[i] = item } else { data.news.append(item) }
        save()
    }

    func deleteNews(_ id: UUID) {
        data.news.removeAll { $0.id == id }
        save()
    }

    // MARK: Chart screenshots

    func chartShots(for symbolID: UUID) -> [ChartShot] {
        data.chartShots.filter { $0.symbolID == symbolID }.sorted { $0.date > $1.date }
    }

    func chartShot(_ id: UUID) -> ChartShot? { data.chartShots.first { $0.id == id } }

    func upsert(_ shot: ChartShot) {
        if let i = data.chartShots.firstIndex(where: { $0.id == shot.id }) { data.chartShots[i] = shot } else { data.chartShots.append(shot) }
        save()
    }

    func deleteChartShot(_ id: UUID) {
        if let s = chartShot(id) { deleteImage(s.imageFile) }
        data.chartShots.removeAll { $0.id == id }
        save()
    }

    /// Saves images as new chart screenshots for a symbol and returns their ids (oldest first).
    @discardableResult
    func addChartShots(_ items: [(image: NSImage, date: Date)], symbolID: UUID) -> [UUID] {
        var ids: [UUID] = []
        for item in items.sorted(by: { $0.date < $1.date }) {
            guard let name = saveImage(item.image) else { continue }
            let shot = ChartShot(symbolID: symbolID, date: item.date, imageFile: name)
            data.chartShots.append(shot)
            ids.append(shot.id)
        }
        save()
        return ids
    }

    // MARK: News tags

    var newsTagDefs: [NewsTag] { data.newsTagDefs ?? NewsTag.defaults }

    /// Tags on a summary, in the order of your tag list.
    func tags(for n: NewsItem) -> [NewsTag] {
        let keys = Set(n.tags ?? [])
        return newsTagDefs.filter { keys.contains($0.id) }
    }

    func usageCount(ofTag id: String) -> Int {
        data.news.reduce(0) { $0 + (($1.tags ?? []).contains(id) ? 1 : 0) }
    }

    /// A fresh tag with the first colour not yet used.
    func makeTag(title: String) -> NewsTag {
        let used = Set(newsTagDefs.map(\.colorName))
        let color = NewsTag.paletteNames.first { !used.contains($0) } ?? "gray"
        return NewsTag(id: "tag-\(UUID().uuidString)", title: title, colorName: color, icon: "tag.fill")
    }

    /// Saves your tag list; tags you removed are also taken off every summary.
    func saveTagDefs(_ defs: [NewsTag]) {
        let keep = Set(defs.map(\.id))
        for i in data.news.indices {
            if let t = data.news[i].tags {
                let filtered = t.filter { keep.contains($0) }
                data.news[i].tags = filtered.isEmpty ? nil : filtered
            }
        }
        data.newsTagDefs = defs
        save()
    }

    func addTagDef(_ tag: NewsTag) {
        saveTagDefs(newsTagDefs + [tag])
    }

    // MARK: Pine scripts

    func script(_ id: UUID) -> PineScript? { data.scripts.first { $0.id == id } }

    var scriptsByRecent: [PineScript] { data.scripts.sorted { $0.updatedAt > $1.updatedAt } }

    func upsert(_ script: PineScript) {
        if let i = data.scripts.firstIndex(where: { $0.id == script.id }) { data.scripts[i] = script } else { data.scripts.append(script) }
        save()
    }

    func deleteScript(_ id: UUID) {
        data.scripts.removeAll { $0.id == id }
        save()
    }

    /// Adds a new version (numbered after the latest), writes it to disk and to the safe folder.
    @discardableResult
    func addVersion(to scriptID: UUID, code: String, note: String, date: Date = Date()) -> ScriptVersion? {
        guard let i = data.scripts.firstIndex(where: { $0.id == scriptID }) else { return nil }
        let previous = data.scripts[i].latest
        var v = ScriptVersion(number: (previous?.number ?? 0) + 1, date: date, code: code, note: note)
        if let prev = previous, let diff = LineDiff.compute(LineDiff.lines(prev.code), LineDiff.lines(code)) {
            v.linesAdded = diff.filter { if case .added = $0 { return true } else { return false } }.count
            v.linesRemoved = diff.filter { if case .removed = $0 { return true } else { return false } }.count
        }
        v.fileName = writeScriptFile(scriptName: data.scripts[i].name, version: v)
        data.scripts[i].versions.append(v)
        save()
        return v
    }

    func deleteVersion(_ versionID: UUID, of scriptID: UUID) {
        guard let i = data.scripts.firstIndex(where: { $0.id == scriptID }) else { return }
        // The file on disk is kept on purpose: the folder is your safety net.
        data.scripts[i].versions.removeAll { $0.id == versionID }
        save()
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    func relativeScriptPath(scriptName: String, version: ScriptVersion) -> String {
        "\(Self.safeFileName(scriptName))/v\(version.number)_\(Self.fileStamp.string(from: version.date)).pine"
    }

    private func writeScriptFile(scriptName: String, version: ScriptVersion) -> String? {
        let rel = relativeScriptPath(scriptName: scriptName, version: version)
        let url = scriptsFolder.appendingPathComponent(rel)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try version.code.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Couldn't write script file: \(error.localizedDescription)"
            return nil
        }
        mirror(code: version.code, relativePath: rel)
        return rel
    }

    // MARK: Safe folder (a folder you choose, e.g. in iCloud Drive)

    @Published private(set) var mirrorFolderName: String? = MirrorBookmark.resolve()?.lastPathComponent

    var mirrorFolderPath: String? { MirrorBookmark.resolve()?.path }

    func chooseMirrorFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a safe folder (for example in iCloud Drive). Every Pine Script version will also be saved there."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bm = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bm, forKey: MirrorBookmark.key)
            mirrorFolderName = url.lastPathComponent
            copyAllScriptsToMirror()
        } catch {
            lastError = "Couldn't remember that folder: \(error.localizedDescription)"
        }
    }

    func stopMirroring() {
        UserDefaults.standard.removeObject(forKey: MirrorBookmark.key)
        mirrorFolderName = nil
    }

    private func mirror(code: String, relativePath: String) {
        guard let root = MirrorBookmark.resolve() else { return }
        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }
        let url = root.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try code.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Saved inside the app, but couldn't copy to your safe folder: \(error.localizedDescription)"
        }
    }

    /// Writes every stored version to the safe folder (existing files are overwritten with the same content).
    func copyAllScriptsToMirror() {
        for s in data.scripts {
            for v in s.versions {
                mirror(code: v.code, relativePath: v.fileName ?? relativeScriptPath(scriptName: s.name, version: v))
            }
        }
    }

    func exportScriptVersion(_ v: ScriptVersion, scriptName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Self.safeFileName(scriptName))_v\(v.number).pine"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try v.code.write(to: url, atomically: true, encoding: .utf8) }
        catch { lastError = "Export failed: \(error.localizedDescription)" }
    }
}

/// Security-scoped bookmark to the Pine Script safe folder the user picked.
enum MirrorBookmark {
    static let key = "pineSafeFolderBookmark"

    static func resolve() -> URL? {
        guard let bm = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
