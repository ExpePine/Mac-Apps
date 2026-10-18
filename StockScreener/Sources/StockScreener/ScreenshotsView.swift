import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "S" window: screenshots for each stock, newest first, with drawing / annotation tools.
struct ScreenshotsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @State private var search = ""
    @State private var shots: [Screenshot] = []
    @State private var selected: Screenshot?
    @State private var meta = ScreenshotMeta()
    @State private var image: NSImage?
    @State private var tool: Annotation.Tool = .arrow
    @State private var color = "#FF3B30"
    @State private var width = 4.0
    @State private var undoStack: [[Annotation]] = []
    @State private var redoStack: [[Annotation]] = []
    @State private var eraser = false
    @State private var message: String?
    @State private var pendingText: CGPoint?
    @State private var textInput = ""
    @State private var isCapturing = false

    private var symbol: String { vm.shotSymbol ?? "" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                editor
            }
        }
        .navigationTitle(symbol.isEmpty ? "Screenshots" : "Screenshots — \(symbol)")
        .onAppear { reload() }
        .onChange(of: vm.shotSymbol) { _ in reload() }
        .alert("Text", isPresented: Binding(get: { pendingText != nil }, set: { if !$0 { pendingText = nil } })) {
            TextField("Label", text: $textInput)
            Button("Add") {
                if let p = pendingText, !textInput.isEmpty {
                    change { $0.append(Annotation(tool: .text, color: color, width: width, points: [p], text: textInput)) }
                }
                pendingText = nil
            }
            Button("Cancel", role: .cancel) { pendingText = nil }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Stock symbol", text: $search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !search.isEmpty { vm.shotSymbol = search.uppercased(); search = "" } }
            List(selection: Binding(get: { vm.shotSymbol }, set: { if let s = $0 { vm.shotSymbol = s } })) {
                Section(search.isEmpty ? "Stocks with screenshots" : "Matching stocks") {
                    ForEach(symbolList, id: \.self) { sym in
                        HStack {
                            Text(sym).fontWeight(sym == symbol ? .semibold : .regular)
                            Spacer()
                            if let d = vm.shotIndex[ScreenshotStore.safe(sym)] {
                                Text(age(d)).font(.caption2).foregroundStyle(.secondary)
                                Circle().fill(Date().timeIntervalSince(d) < 7 * 86_400 ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .tag(sym)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: 220)

            Divider()
            HStack {
                Text(symbol.isEmpty ? "Pick a stock" : "\(symbol) · \(shots.count) screenshot\(shots.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
            }
            List(selection: Binding(get: { selected }, set: { s in select(s) })) {
                ForEach(shots) { shot in
                    HStack(spacing: 8) {
                        ShotThumb(url: shot.url)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shot.date.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                            Text(age(shot.date)).font(.caption).foregroundStyle(Date().timeIntervalSince(shot.date) < 7 * 86_400 ? .green : .orange)
                        }
                    }
                    .tag(shot)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
                        Button("Move to Trash", role: .destructive) { delete(shot) }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(8)
    }

    private var symbolList: [String] {
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        if q.isEmpty {
            var list = vm.shotIndex.sorted { $0.value > $1.value }.map(\.key)
            if !symbol.isEmpty && !list.contains(ScreenshotStore.safe(symbol)) { list.insert(symbol, at: 0) }
            return list
        }
        let all = Set(vm.rows.map { vm.rowKey($0).uppercased() }).union(vm.shotIndex.keys)
        return all.filter { $0.contains(q) }.sorted().prefix(200).map { $0 }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { capture() } label: { Label("Capture area", systemImage: "camera.viewfinder") }
                    .disabled(symbol.isEmpty || isCapturing)
                    .help("Drag over any part of the screen (press Space to pick a window). The app hides while you capture.")
                Button { pasteImage() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(symbol.isEmpty)
                    .help("Save the image on the clipboard as a new screenshot (⇧⌘V)")
                Button { importFile() } label: { Label("Import…", systemImage: "photo.badge.plus") }
                    .disabled(symbol.isEmpty)
                Spacer()
                Button { copyAnnotated() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(image == nil).help("Copy the image with your drawings")
                Button { exportAnnotated() } label: { Label("Export PNG…", systemImage: "square.and.arrow.up") }
                    .disabled(image == nil)
                Button(role: .destructive) { if let s = selected { delete(s) } } label: { Image(systemName: "trash") }
                    .disabled(selected == nil).help("Move this screenshot to the Trash")
            }
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { eraser ? nil : tool }, set: { if let t = $0 { tool = t; eraser = false } })) {
                    ForEach(Annotation.Tool.allCases, id: \.self) { t in
                        Image(systemName: icon(t)).help(t.rawValue.capitalized).tag(Optional(t))
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Toggle(isOn: $eraser) { Image(systemName: "eraser") }.toggleStyle(.button).help("Eraser: click a drawing to remove it")
                ForEach(Self.palette, id: \.self) { hex in
                    Circle().fill(Color(hex: hex))
                        .overlay(Circle().stroke(Color.primary.opacity(hex == color ? 0.9 : 0.2), lineWidth: hex == color ? 2 : 1))
                        .frame(width: 16, height: 16)
                        .onTapGesture { color = hex }
                }
                Slider(value: $width, in: 1...14).frame(width: 90).help("Line width")
                Spacer()
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).disabled(undoStack.isEmpty)
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(redoStack.isEmpty)
                Button("Clear") { change { $0.removeAll() } }.disabled(meta.annotations.isEmpty)
            }
            .controlSize(.small)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            if let image, let shot = selected {
                AnnotationCanvas(image: image, annotations: meta.annotations, tool: eraser ? nil : tool,
                                 color: color, width: width,
                                 onAdd: { a in change { $0.append(a) } },
                                 onErase: { id in change { $0.removeAll { $0.id == id } } },
                                 onText: { p in textInput = ""; pendingText = p })
                    .id(shot.id)
                Divider()
                HStack {
                    Image(systemName: "note.text").foregroundStyle(.secondary)
                    TextField("Note for this screenshot", text: Binding(get: { meta.note }, set: { meta.note = $0; persist() }))
                        .textFieldStyle(.plain)
                }
                .padding(8)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(symbol.isEmpty ? "Pick a stock on the left, or click S in the Filter" : "No screenshots for \(symbol) yet")
                        .font(.title3)
                    Text("Capture an area of the screen, paste an image (⇧⌘V), import a file, or drop images here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: Actions

    private func reload() {
        guard !symbol.isEmpty else { shots = []; select(nil); return }
        shots = ScreenshotStore.list(symbol)
        select(shots.first)
    }

    private func select(_ shot: Screenshot?) {
        selected = shot
        undoStack = []; redoStack = []
        if let shot {
            image = NSImage(contentsOf: shot.url)
            meta = ScreenshotStore.meta(shot)
        } else {
            image = nil
            meta = ScreenshotMeta()
        }
    }

    private func change(_ edit: (inout [Annotation]) -> Void) {
        undoStack.append(meta.annotations)
        redoStack.removeAll()
        edit(&meta.annotations)
        persist()
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(meta.annotations)
        meta.annotations = last
        persist()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(meta.annotations)
        meta.annotations = next
        persist()
    }

    private func persist() {
        if let s = selected { ScreenshotStore.saveMeta(meta, for: s) }
    }

    private func add(_ img: NSImage) {
        guard !symbol.isEmpty else { return }
        do {
            let shot = try ScreenshotStore.save(img, symbol: symbol)
            vm.refreshShotIndex()
            shots = ScreenshotStore.list(symbol)
            select(shots.first { $0.url == shot.url })
            message = "Saved \(shot.date.formatted(date: .abbreviated, time: .standard))"
        } catch {
            message = "Couldn't save the image: \(error.localizedDescription)"
        }
    }

    private func pasteImage() {
        if let img = NSImage(pasteboard: NSPasteboard.general) { add(img) } else { message = "No image on the clipboard." }
    }

    private func capture() {
        isCapturing = true
        message = "Drag over the area to capture… (Esc cancels)"
        let before = NSPasteboard.general.changeCount
        NSApp.hide(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-c"]          // interactive area, to the clipboard
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                isCapturing = false
                if NSPasteboard.general.changeCount != before, let img = NSImage(pasteboard: NSPasteboard.general) {
                    add(img)
                } else {
                    message = "Capture cancelled. (If nothing is captured, allow Stock Screener under System Settings → Privacy & Security → Screen Recording.)"
                }
            }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let img = NSImage(contentsOf: url) { add(img) } }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let img = NSImage(contentsOf: url) else { return }
                    DispatchQueue.main.async { add(img) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    DispatchQueue.main.async { add(img) }
                }
            }
        }
    }

    private func delete(_ shot: Screenshot) {
        ScreenshotStore.delete(shot)
        vm.refreshShotIndex()
        shots = ScreenshotStore.list(symbol)
        select(shots.first)
    }

    @MainActor private func renderAnnotated() -> NSImage? {
        guard let image else { return nil }
        let px = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let size = px.width > 0 ? px : image.size
        let view = ZStack {
            Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
            Canvas { ctx, sz in for a in meta.annotations { AnnotationCanvas.draw(a, in: &ctx, size: sz) } }
                .frame(width: size.width, height: size.height)
        }
        let r = ImageRenderer(content: view)
        r.scale = 1
        return r.nsImage
    }

    private func copyAnnotated() {
        guard let img = renderAnnotated() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        message = "Copied with drawings."
    }

    private func exportAnnotated() {
        guard let img = renderAnnotated(), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(symbol) \(selected?.date.formatted(.iso8601.year().month().day()) ?? "").png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }

    private func age(_ d: Date) -> String {
        let days = Int(Date().timeIntervalSince(d) / 86_400)
        return days == 0 ? "today" : days == 1 ? "1 day ago" : "\(days) days ago"
    }

    private func icon(_ t: Annotation.Tool) -> String {
        switch t {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        }
    }

    static let palette = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF", "#AF52DE", "#FFFFFF", "#000000"]
}

/// Small thumbnail, loaded once.
struct ShotThumb: View {
    let url: URL
    @State private var img: NSImage?
    var body: some View {
        Group {
            if let img { Image(nsImage: img).resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
        }
        .frame(width: 64, height: 40).clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            let u = url
            img = await Task.detached { NSImage(contentsOf: u).map { ShotThumb.shrink($0) } }.value
        }
    }
    static func shrink(_ image: NSImage) -> NSImage {
        let target = NSSize(width: 160, height: 100)
        let scale = min(target.width / max(1, image.size.width), target.height / max(1, image.size.height), 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        return out
    }
}

/// The image with its drawings; drawing gestures add new marks.
struct AnnotationCanvas: View {
    let image: NSImage
    let annotations: [Annotation]
    let tool: Annotation.Tool?           // nil = eraser
    let color: String
    let width: Double
    let onAdd: (Annotation) -> Void
    let onErase: (UUID) -> Void
    let onText: (CGPoint) -> Void
    @State private var current: Annotation?

    var body: some View {
        GeometryReader { geo in
            let fit = fitted(image.size, in: geo.size)
            ZStack {
                Image(nsImage: image).resizable().frame(width: fit.width, height: fit.height)
                Canvas { ctx, size in
                    for a in annotations { Self.draw(a, in: &ctx, size: size) }
                    if let current { Self.draw(current, in: &ctx, size: size) }
                }
                .frame(width: fit.width, height: fit.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let p = CGPoint(x: g.location.x / fit.width, y: g.location.y / fit.height)
                    guard let tool else { return }
                    if tool == .text { return }
                    if current == nil {
                        let start = CGPoint(x: g.startLocation.x / fit.width, y: g.startLocation.y / fit.height)
                        current = Annotation(tool: tool, color: color, width: width, points: [start, p])
                    } else if tool == .pen || tool == .highlighter {
                        current?.points.append(p)
                    } else {
                        current?.points = [current!.points[0], p]
                    }
                }.onEnded { g in
                    let p = CGPoint(x: g.location.x / fit.width, y: g.location.y / fit.height)
                    guard let tool else {
                        if let hit = nearest(p, fit) { onErase(hit) }
                        return
                    }
                    if tool == .text { onText(p); return }
                    if var a = current {
                        let moved = hypot((a.points.last!.x - a.points[0].x) * fit.width, (a.points.last!.y - a.points[0].y) * fit.height)
                        if moved > 3 || a.points.count > 2 {
                            if tool == .pen || tool == .highlighter { a.points = simplify(a.points) }
                            onAdd(a)
                        }
                    }
                    current = nil
                })
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.opacity(0.04))
    }

    private func fitted(_ img: CGSize, in box: CGSize) -> CGSize {
        guard img.width > 0, img.height > 0 else { return box }
        let s = min(box.width / img.width, box.height / img.height)
        return CGSize(width: img.width * s, height: img.height * s)
    }

    /// The mark closest to `p` (within ~12 px), for the eraser.
    private func nearest(_ p: CGPoint, _ size: CGSize) -> UUID? {
        var best: (UUID, CGFloat)?
        for a in annotations {
            var pts = a.points
            if a.tool == .rectangle || a.tool == .ellipse, pts.count == 2 {
                let (p0, p1) = (pts[0], pts[1])
                pts = [p0, CGPoint(x: p1.x, y: p0.y), p1, CGPoint(x: p0.x, y: p1.y), p0]
            }
            for q in pts {
                let d = hypot((q.x - p.x) * size.width, (q.y - p.y) * size.height)
                if d < 12, d < (best?.1 ?? .infinity) { best = (a.id, d) }
            }
            if pts.count >= 2 {
                for i in 1..<pts.count {
                    let d = segmentDistance(p, pts[i - 1], pts[i], size)
                    if d < 10, d < (best?.1 ?? .infinity) { best = (a.id, d) }
                }
            }
        }
        return best?.0
    }

    private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ s: CGSize) -> CGFloat {
        let ax = a.x * s.width, ay = a.y * s.height, bx = b.x * s.width, by = b.y * s.height
        let px = p.x * s.width, py = p.y * s.height
        let dx = bx - ax, dy = by - ay
        let len = dx * dx + dy * dy
        let t = len > 0 ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len)) : 0
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }

    /// Drops points closer than ~0.15% of the image to keep files small.
    private func simplify(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts {
            if let l = out.last, hypot(p.x - l.x, p.y - l.y) < 0.0015 { continue }
            out.append(p)
        }
        return out
    }

    static func draw(_ a: Annotation, in ctx: inout GraphicsContext, size: CGSize) {
        guard let first = a.points.first else { return }
        let c = Color(hex: a.color)
        let lw = max(1, a.width * size.width / 1000)
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        let p0 = pt(first), p1 = pt(a.points.last ?? first)
        let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        switch a.tool {
        case .pen, .highlighter:
            var path = Path()
            path.move(to: p0)
            for p in a.points.dropFirst() { path.addLine(to: pt(p)) }
            if a.tool == .highlighter {
                ctx.stroke(path, with: .color(c.opacity(0.35)), style: StrokeStyle(lineWidth: lw * 4, lineCap: .butt, lineJoin: .round))
            } else {
                ctx.stroke(path, with: .color(c), style: style)
            }
        case .line, .arrow:
            var path = Path()
            path.move(to: p0); path.addLine(to: p1)
            ctx.stroke(path, with: .color(c), style: style)
            if a.tool == .arrow {
                let angle = atan2(p1.y - p0.y, p1.x - p0.x)
                let head = max(10, lw * 4)
                var h = Path()
                h.move(to: p1)
                h.addLine(to: CGPoint(x: p1.x - head * cos(angle - .pi / 7), y: p1.y - head * sin(angle - .pi / 7)))
                h.addLine(to: CGPoint(x: p1.x - head * cos(angle + .pi / 7), y: p1.y - head * sin(angle + .pi / 7)))
                h.closeSubpath()
                ctx.fill(h, with: .color(c))
            }
        case .rectangle:
            ctx.stroke(Path(CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))),
                       with: .color(c), style: style)
        case .ellipse:
            ctx.stroke(Path(ellipseIn: CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))),
                       with: .color(c), style: style)
        case .text:
            let fontSize = max(10, a.width * 5 * size.width / 1000)
            let text = Text(a.text).font(.system(size: fontSize, weight: .bold)).foregroundColor(c)
            ctx.draw(text, at: p0, anchor: .topLeading)
        }
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(h, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
