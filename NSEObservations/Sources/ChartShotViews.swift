import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Importing images with their dates

enum ShotImport {
    /// Image files with their creation date (TradingView exports keep the capture time there).
    static func chooseFiles() -> [(image: NSImage, date: Date)] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose TradingView screenshots"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(load)
    }

    static func load(_ url: URL) -> (image: NSImage, date: Date)? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (img, values?.creationDate ?? values?.contentModificationDate ?? Date())
    }

    static func handleDrop(_ providers: [NSItemProvider], add: @escaping ([(image: NSImage, date: Date)]) -> Void) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), let item = load(url) else { return }
                    DispatchQueue.main.async { add([item]) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    DispatchQueue.main.async { add([(img, Date())]) }
                }
            }
        }
    }
}

// MARK: - Image with text labels on top

/// Shows an image fitted to the available space with annotations positioned on it.
struct AnnotatedImageView: View {
    let image: NSImage
    let annotations: [ShotAnnotation]
    var selectedID: UUID? = nil
    var editable = false
    /// Tap on the image (not on a label); point is normalised 0…1.
    var onTap: ((CGPoint) -> Void)? = nil
    var onSelect: ((UUID) -> Void)? = nil
    var onMove: ((UUID, CGPoint) -> Void)? = nil

    @State private var dragStart: [UUID: CGPoint] = [:]

    static func fitRect(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    var body: some View {
        GeometryReader { geo in
            let rect = Self.fitRect(image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .onTapGesture(coordinateSpace: .local) { loc in
                        guard rect.width > 0 else { return }
                        onTap?(CGPoint(x: loc.x / rect.width, y: loc.y / rect.height))
                    }
                    .offset(x: rect.minX, y: rect.minY)

                ForEach(annotations) { a in
                    AnnotationLabel(annotation: a, scale: rect.width / 1000, selected: editable && a.id == selectedID,
                                    maxWidth: rect.width * 0.6)
                        .onTapGesture { onSelect?(a.id) }
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { v in
                                    guard editable, rect.width > 0 else { return }
                                    let start = dragStart[a.id] ?? CGPoint(x: a.x, y: a.y)
                                    if dragStart[a.id] == nil { dragStart[a.id] = start; onSelect?(a.id) }
                                    let nx = min(max(start.x + v.translation.width / rect.width, 0), 1)
                                    let ny = min(max(start.y + v.translation.height / rect.height, 0), 1)
                                    onMove?(a.id, CGPoint(x: nx, y: ny))
                                }
                                .onEnded { _ in dragStart[a.id] = nil },
                            including: editable ? .all : .subviews
                        )
                        .position(x: rect.minX + a.x * rect.width, y: rect.minY + a.y * rect.height)
                }
            }
        }
    }
}

struct AnnotationLabel: View {
    let annotation: ShotAnnotation
    let scale: CGFloat
    var selected = false
    var maxWidth: CGFloat = 400

    var body: some View {
        Text(annotation.text.isEmpty ? "Text" : annotation.text)
            .font(.system(size: max(8, annotation.size * scale), weight: .semibold))
            .foregroundStyle(annotation.color.opacity(annotation.text.isEmpty ? 0.6 : 1))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: max(maxWidth, 40))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, max(3, 6 * scale))
            .padding(.vertical, max(2, 3 * scale))
            .background(annotation.background ? Color.black.opacity(annotation.colorName == "black" ? 0 : 0.6) : Color.clear,
                        in: RoundedRectangle(cornerRadius: max(3, 5 * scale), style: .continuous))
            .background(annotation.background && annotation.colorName == "black" ? Color.white.opacity(0.8) : Color.clear,
                        in: RoundedRectangle(cornerRadius: max(3, 5 * scale), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: max(3, 5 * scale), style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
            )
    }
}

enum ShotExport {
    /// Renders the screenshot with its labels at (up to) the image's own resolution.
    @MainActor
    static func render(_ image: NSImage, _ annotations: [ShotAnnotation]) -> NSImage? {
        let longest: CGFloat = 2400
        let s = image.size
        guard s.width > 0, s.height > 0 else { return nil }
        let k = min(1, longest / max(s.width, s.height))
        let size = CGSize(width: s.width * k, height: s.height * k)
        let renderer = ImageRenderer(content: AnnotatedImageView(image: image, annotations: annotations)
            .frame(width: size.width, height: size.height))
        renderer.scale = 1
        return renderer.nsImage
    }

    @MainActor
    static func save(_ image: NSImage, _ annotations: [ShotAnnotation], suggestedName: String) {
        guard let out = render(image, annotations), let png = ImageIO.png(from: out) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }

    @MainActor
    static func copy(_ image: NSImage, _ annotations: [ShotAnnotation]) {
        guard let out = render(image, annotations) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([out])
    }
}

// MARK: - Screenshots tab on a symbol page

struct ChartShotsSection: View {
    @EnvironmentObject private var store: Store
    let symbolID: UUID
    let candles: [Candle]
    var openEditor: (UUID) -> Void

    @State private var dropTargeted = false
    @State private var message: String?

    private var shots: [ChartShot] { store.chartShots(for: symbolID) }

    private struct DayGroup: Identifiable {
        let id: Date
        let shots: [ChartShot]
    }

    private var groups: [DayGroup] {
        let cal = Calendar.ist
        let g = Dictionary(grouping: shots) { cal.startOfDay(for: $0.date) }
        return g.keys.sorted(by: >).map { DayGroup(id: $0, shots: (g[$0] ?? []).sorted { $0.date > $1.date }) }
    }

    private static let dayHeader: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM yyyy"; f.timeZone = Calendar.ist.timeZone; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(shots.count) chart screenshot\(shots.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .help("Paste a screenshot from the clipboard (TradingView: Alt+S copies the chart image)")
                Button { add(ShotImport.chooseFiles()) } label: { Label("Add Screenshots…", systemImage: "photo.badge.plus") }
            }

            dropZone

            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }

            ForEach(groups) { g in
                Text(Self.dayHeader.string(from: g.id))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(g.shots) { shot in
                        ChartShotCard(shot: shot, outcome: ObservationOutcome.compute(for: shot.date, candles: candles)) {
                            openEditor(shot.id)
                        }
                    }
                }
            }

            let noteImages = store.observations(for: symbolID).flatMap(\.imageFiles)
            if !noteImages.isEmpty {
                Text("Images attached to observations").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                AttachmentThumbnails(names: noteImages)
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop TradingView screenshots here").font(.callout.weight(.medium))
                Text("Files keep their capture date. Then click a screenshot to write on it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            ShotImport.handleDrop(providers) { add($0) }
            return true
        }
    }

    private func paste() {
        if let img = ImageIO.pasteboardImage() {
            add([(img, Date())])
            message = nil
        } else {
            message = "No image on the clipboard. In TradingView use the camera icon ▸ Copy chart image, or ⌃⇧⌘4 to copy part of the screen."
        }
    }

    private func add(_ items: [(image: NSImage, date: Date)]) {
        guard !items.isEmpty else { return }
        let ids = store.addChartShots(items, symbolID: symbolID)
        // Open the editor straight away for a single new screenshot.
        if ids.count == 1, let id = ids.first { openEditor(id) }
    }
}

struct ChartShotCard: View {
    @EnvironmentObject private var store: Store
    let shot: ChartShot
    var outcome: ObservationOutcome?
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Color.black.opacity(0.85)
                    if let img = store.image(shot.imageFile) {
                        AnnotatedImageView(image: img, annotations: shot.annotations)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 6) {
                    Text(TimeFmt.time.string(from: shot.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("· \(shot.timeframe.title)").font(.caption).foregroundStyle(.secondary)
                    if !shot.annotations.isEmpty {
                        Label("\(shot.annotations.count)", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let oc = outcome {
                        Text("since \(Fmt.pct(oc.sinceThen))").font(.caption.weight(.medium)).foregroundStyle(oc.sinceThen.changeColor)
                    }
                }
                Text(shot.caption.isEmpty ? "No observations written yet — click to annotate." : shot.caption)
                    .font(.callout)
                    .foregroundStyle(shot.caption.isEmpty ? .tertiary : .primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open to annotate")
    }
}

enum TimeFmt {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = Calendar.ist.timeZone; return f
    }()
}

// MARK: - Annotation editor

struct ChartShotEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let shotID: UUID

    @State private var shot: ChartShot?
    @State private var selected: UUID?
    @State private var placing = false
    @State private var confirmDelete = false
    @State private var copied = false

    private var selectedIndex: Int? {
        guard let shot, let selected else { return nil }
        return shot.annotations.firstIndex { $0.id == selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            if shot != nil {
                HStack(spacing: 0) {
                    imagePane
                    Divider()
                    sidePanel.frame(width: 320)
                }
                Divider()
                footer
            } else {
                EmptyStateView(systemImage: "photo", title: "Screenshot not found", message: "It may have been deleted.")
            }
        }
        .frame(minWidth: 1000, idealWidth: 1200, minHeight: 640, idealHeight: 760)
        .onAppear {
            shot = store.chartShot(shotID)
            if let s = shot, s.annotations.isEmpty, s.caption.isEmpty { placing = true }
        }
        .confirmationDialog("Delete this screenshot?", isPresented: $confirmDelete) {
            Button("Delete Screenshot", role: .destructive) {
                store.deleteChartShot(shotID)
                dismiss()
            }
        } message: {
            Text("The image and its notes are removed from the app.")
        }
    }

    // MARK: Image

    private var imagePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    placing.toggle()
                } label: {
                    Label(placing ? "Click on the chart to place text" : "Add Text", systemImage: "character.textbox")
                }
                .buttonStyle(.borderedProminent)
                .tint(placing ? .orange : .accentColor)
                .keyboardShortcut("t", modifiers: .command)
                .help("Add a text label (⌘T), then click where it should go")
                if selected != nil {
                    Button(role: .destructive) { deleteSelected() } label: { Label("Delete Label", systemImage: "trash") }
                }
                Spacer()
                Text("Drag labels to move them").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            ZStack {
                Color.black.opacity(0.9)
                if let s = shot, let img = store.image(s.imageFile) {
                    AnnotatedImageView(
                        image: img,
                        annotations: s.annotations,
                        selectedID: selected,
                        editable: true,
                        onTap: { p in
                            if placing { addLabel(at: p) } else { selected = nil }
                        },
                        onSelect: { selected = $0; placing = false },
                        onMove: { id, p in
                            guard let i = shot?.annotations.firstIndex(where: { $0.id == id }) else { return }
                            shot?.annotations[i].x = p.x
                            shot?.annotations[i].y = p.y
                        }
                    )
                    .padding(12)
                    .onHover { inside in
                        if placing && inside { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                    }
                }
            }
        }
    }

    // MARK: Side panel

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = shot, let sym = store.symbol(s.symbolID) {
                    Text(sym.ticker).font(.title3.weight(.bold))
                }
                Group {
                    DatePicker("Date", selection: Binding(get: { shot?.date ?? Date() }, set: { shot?.date = $0 }),
                               displayedComponents: [.date, .hourAndMinute])
                    Picker("Chart", selection: Binding(get: { shot?.timeframe ?? .daily }, set: { shot?.timeframe = $0 })) {
                        ForEach(ChartTimeframe.allCases) { Text($0.title).tag($0) }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your observations").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { shot?.caption ?? "" }, set: { shot?.caption = $0 }))
                        .font(.body)
                        .frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }

                Divider()

                if let i = selectedIndex {
                    labelEditor(i)
                } else {
                    Text("Select a label on the chart to edit it, or click Add Text.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if let s = shot, !s.annotations.isEmpty {
                    Divider()
                    Text("Labels").font(.callout).foregroundStyle(.secondary)
                    ForEach(s.annotations) { a in
                        Button { selected = a.id; placing = false } label: {
                            HStack {
                                Circle().fill(a.color).frame(width: 8, height: 8)
                                Text(a.text.isEmpty ? "(empty)" : a.text).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(a.id == selected ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
    }

    private func labelEditor(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Label").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { shot?.annotations[safe: i]?.text ?? "" },
                                     set: { shot?.annotations[i].text = $0 }))
                .font(.body)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack(spacing: 6) {
                ForEach(ShotAnnotation.colorNames, id: \.self) { name in
                    Circle()
                        .fill(ShotAnnotation.color(named: name))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25)))
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3)
                            .opacity(shot?.annotations[safe: i]?.colorName == name ? 1 : 0))
                        .onTapGesture { shot?.annotations[i].colorName = name }
                        .help(name.capitalized)
                }
            }
            HStack {
                Text("Size").font(.caption)
                Slider(value: Binding(get: { shot?.annotations[safe: i]?.size ?? 22 }, set: { shot?.annotations[i].size = $0 }),
                       in: 12...60)
            }
            Toggle("Dark background behind text",
                   isOn: Binding(get: { shot?.annotations[safe: i]?.background ?? true }, set: { shot?.annotations[i].background = $0 }))
                .font(.caption)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Screenshot", systemImage: "trash") }
            Spacer()
            if let s = shot, let img = store.image(s.imageFile) {
                Button {
                    ShotExport.copy(img, s.annotations)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy Image", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .help("Copy the screenshot with your labels")
                Button {
                    let ticker = store.symbol(s.symbolID)?.ticker ?? "chart"
                    ShotExport.save(img, s.annotations, suggestedName: "\(ticker)_\(Fmt.isoDay.string(from: s.date)).png")
                } label: { Label("Export PNG…", systemImage: "square.and.arrow.up") }
            }
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") {
                if var s = shot {
                    s.annotations.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    store.upsert(s)
                }
                dismiss()
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(12)
    }

    // MARK: Actions

    private func addLabel(at p: CGPoint) {
        let a = ShotAnnotation(text: "", x: p.x, y: p.y)
        shot?.annotations.append(a)
        selected = a.id
        placing = false
    }

    private func deleteSelected() {
        guard let id = selected else { return }
        shot?.annotations.removeAll { $0.id == id }
        selected = nil
    }
}
