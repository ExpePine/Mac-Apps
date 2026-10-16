import SwiftUI
import AppKit

// MARK: - Workspace: the screenshots of one stock, worked on in place

struct ShotWorkspace: View {
    @EnvironmentObject private var store: Store
    let symbolID: UUID

    @State private var currentID: UUID?
    @State private var shot: ChartShot?
    @State private var selectedLabel: UUID?
    @State private var editingLabel: UUID?
    @State private var dropTargeted = false
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var copied = false

    private var shots: [ChartShot] { store.chartShots(for: symbolID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filmstrip

            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }

            if shot != nil {
                canvas
                detailsRow
                captionBox
            } else {
                emptyState
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            ShotImport.collect(providers) { add($0) }
            return true
        }
        .onAppear(perform: loadInitial)
        .onChange(of: shots.count) { _ in
            // A screenshot was added elsewhere (e.g. ⌥⌘N) — jump to it if asked.
            if let f = store.focusShotID, shots.contains(where: { $0.id == f }) { select(f); store.focusShotID = nil }
            if shot == nil, let first = shots.first { select(first.id) }
        }
        .onDisappear(perform: persist)
        .confirmationDialog("Delete this screenshot?", isPresented: $confirmDelete) {
            Button("Delete Screenshot", role: .destructive) {
                guard let id = currentID else { return }
                store.deleteChartShot(id)
                shot = nil
                currentID = nil
                if let next = shots.first { select(next.id) }
            }
        } message: {
            Text("The image and everything written on it are removed from the app.")
        }
    }

    // MARK: Filmstrip (newest first)

    private var filmstrip: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(shots) { s in
                        Button { select(s.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Group {
                                    if let img = store.image(s.imageFile) {
                                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Color.gray.opacity(0.3)
                                    }
                                }
                                .frame(width: 132, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(s.id == currentID ? Color.accentColor : Color.primary.opacity(0.1),
                                            lineWidth: s.id == currentID ? 2.5 : 1))
                                Text(TimeFmt.dayShort.string(from: s.date))
                                    .font(.caption.weight(s.id == currentID ? .semibold : .regular))
                                Text("\(TimeFmt.time.string(from: s.date)) · \(s.timeframe.title)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            VStack(spacing: 6) {
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity) }
                    .help("Paste the chart image on your clipboard (TradingView: camera ▸ Copy chart image)")
                Button { add(ShotImport.chooseFiles()) } label: { Label("Add…", systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }
            }
            .frame(width: 110)
            .controlSize(.small)
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack {
            Color.black.opacity(0.92)
            if let s = shot, let img = store.image(s.imageFile) {
                AnnotationCanvas(
                    image: img,
                    annotations: Binding(get: { shot?.annotations ?? [] }, set: { shot?.annotations = $0 }),
                    selected: $selectedLabel,
                    editing: $editingLabel,
                    onCommit: persist
                )
                .padding(10)
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3)
            }
        }
        .aspectRatio(canvasAspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 820)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text(editingLabel != nil ? "Type, then press Return or click elsewhere"
                 : "Click the chart to write · click a label to style it · double-click to edit · drag to move")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.black.opacity(0.45), in: Capsule())
                .padding(10)
                .allowsHitTesting(false)
        }
    }

    /// Width / height of the current screenshot (plus the canvas padding), so the chart fills the canvas.
    private var canvasAspect: CGFloat {
        guard let s = shot, let size = store.image(s.imageFile)?.size, size.width > 0, size.height > 0 else { return 16 / 9 }
        return (size.width + 20) / (size.height + 20)
    }

    // MARK: Details

    private var detailsRow: some View {
        HStack(spacing: 12) {
            DatePicker("Date", selection: Binding(get: { shot?.date ?? Date() }, set: { shot?.date = $0; persist() }),
                       displayedComponents: [.date, .hourAndMinute])
                .fixedSize()
            Picker("Chart", selection: Binding(get: { shot?.timeframe ?? .daily }, set: { shot?.timeframe = $0; persist() })) {
                ForEach(ChartTimeframe.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Spacer()
            if let s = shot, let img = store.image(s.imageFile) {
                Button {
                    ShotExport.copy(img, s.annotations)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy Image", systemImage: copied ? "checkmark" : "doc.on.doc") }
                Button {
                    let ticker = store.symbol(s.symbolID)?.ticker ?? "chart"
                    ShotExport.save(img, s.annotations, suggestedName: "\(ticker)_\(Fmt.isoDay.string(from: s.date)).png")
                } label: { Label("Export PNG…", systemImage: "square.and.arrow.up") }
            }
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .help("Delete this screenshot")
        }
    }

    private var captionBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your observations on this chart").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { shot?.caption ?? "" }, set: { shot?.caption = $0; persist() }))
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("Add your first TradingView screenshot").font(.title3.weight(.semibold))
            Text("Copy the chart image in TradingView (camera icon ▸ Copy chart image) and click Paste, or drop screenshot files here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack {
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.borderedProminent)
                Button { add(ShotImport.chooseFiles()) } label: { Label("Choose Files…", systemImage: "photo.badge.plus") }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .background(dropTargeted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
    }

    // MARK: Actions

    private func loadInitial() {
        if let f = store.focusShotID, shots.contains(where: { $0.id == f }) {
            select(f)
            store.focusShotID = nil
        } else if let first = shots.first {
            select(first.id)
        }
    }

    private func select(_ id: UUID) {
        persist()
        currentID = id
        shot = store.chartShot(id)
        selectedLabel = nil
        editingLabel = nil
    }

    private func persist() {
        guard var s = shot, store.chartShot(s.id) != nil else { return }
        s.annotations.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.id != editingLabel }
        if s != store.chartShot(s.id) { store.upsert(s) }
    }

    private func paste() {
        if let img = ImageIO.pasteboardImage() {
            add([(img, Date())])
            message = nil
        } else {
            message = "No image on the clipboard. In TradingView use the camera icon ▸ Copy chart image."
        }
    }

    private func add(_ items: [(image: NSImage, date: Date)]) {
        guard !items.isEmpty else { return }
        let ids = store.addChartShots(items, symbolID: symbolID)
        if let newest = ids.last { select(newest) }
    }
}

// MARK: - Canvas with in-place text

struct AnnotationCanvas: View {
    let image: NSImage
    @Binding var annotations: [ShotAnnotation]
    @Binding var selected: UUID?
    @Binding var editing: UUID?
    var onCommit: () -> Void

    @State private var dragStart: [UUID: CGPoint] = [:]
    @FocusState private var fieldFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let rect = AnnotatedImageView.fitRect(image.size, in: geo.size)
            let scale = max(rect.width / 1000, 0.6)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { loc in
                        guard rect.width > 0 else { return }
                        tapEmpty(CGPoint(x: loc.x / rect.width, y: loc.y / rect.height))
                    }
                    .offset(x: rect.minX, y: rect.minY)

                ForEach($annotations) { $a in
                    label($a, rect: rect, scale: scale)
                }

                if let id = selected, editing != id, let i = annotations.firstIndex(where: { $0.id == id }) {
                    LabelToolbar(annotation: $annotations[i],
                                 onEdit: { editing = id },
                                 onDelete: {
                                     annotations.removeAll { $0.id == id }
                                     selected = nil
                                     onCommit()
                                 },
                                 onChange: onCommit)
                        .position(x: min(max(rect.minX + annotations[i].x * rect.width, rect.minX + 170), rect.maxX - 170),
                                  y: max(rect.minY + annotations[i].y * rect.height - annotations[i].size * scale - 30, rect.minY + 22))
                }
            }
        }
    }

    @ViewBuilder
    private func label(_ a: Binding<ShotAnnotation>, rect: CGRect, scale: CGFloat) -> some View {
        let ann = a.wrappedValue
        let point = CGPoint(x: rect.minX + ann.x * rect.width, y: rect.minY + ann.y * rect.height)
        if editing == ann.id {
            TextField("Type your note…", text: a.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: max(10, CGFloat(ann.size) * scale), weight: .semibold))
                .foregroundColor(ann.color)
                .lineLimit(1...8)
                .focused($fieldFocused)
                .onSubmit(finishEditing)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minWidth: 160, maxWidth: max(200, rect.width * 0.45))
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.accentColor, lineWidth: 2))
                .position(point)
                .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        } else {
            AnnotationLabel(annotation: ann, scale: scale, selected: selected == ann.id, maxWidth: rect.width * 0.6)
                .onTapGesture(count: 2) {
                    selected = ann.id
                    editing = ann.id
                }
                .onTapGesture {
                    if editing != nil { finishEditing() }
                    selected = ann.id
                }
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { v in
                            guard rect.width > 0, let i = annotations.firstIndex(where: { $0.id == ann.id }) else { return }
                            let start = dragStart[ann.id] ?? CGPoint(x: ann.x, y: ann.y)
                            if dragStart[ann.id] == nil { dragStart[ann.id] = start; selected = ann.id }
                            annotations[i].x = min(max(start.x + v.translation.width / rect.width, 0), 1)
                            annotations[i].y = min(max(start.y + v.translation.height / rect.height, 0), 1)
                        }
                        .onEnded { _ in
                            dragStart[ann.id] = nil
                            onCommit()
                        }
                )
                .position(point)
        }
    }

    private func tapEmpty(_ p: CGPoint) {
        if editing != nil { finishEditing(); return }
        if selected != nil { selected = nil; return }
        let a = ShotAnnotation(text: "", x: p.x, y: p.y)
        annotations.append(a)
        selected = a.id
        editing = a.id
    }

    private func finishEditing() {
        if let id = editing, let i = annotations.firstIndex(where: { $0.id == id }),
           annotations[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.remove(at: i)
            selected = nil
        }
        editing = nil
        fieldFocused = false
        onCommit()
    }
}

// MARK: - Floating toolbar for the selected label

struct LabelToolbar: View {
    @Binding var annotation: ShotAnnotation
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onChange: () -> Void

    private let colors = ["yellow", "white", "orange", "red", "green", "teal", "blue", "purple"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { name in
                Circle()
                    .fill(ShotAnnotation.color(named: name))
                    .frame(width: 15, height: 15)
                    .overlay(Circle().stroke(Color.primary.opacity(0.3)))
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3).opacity(annotation.colorName == name ? 1 : 0))
                    .onTapGesture { annotation.colorName = name; onChange() }
            }
            Divider().frame(height: 16)
            Button { annotation.size = max(12, annotation.size - 4); onChange() } label: { Image(systemName: "textformat.size.smaller") }
                .help("Smaller")
            Button { annotation.size = min(64, annotation.size + 4); onChange() } label: { Image(systemName: "textformat.size.larger") }
                .help("Larger")
            Button { annotation.background.toggle(); onChange() } label: {
                Image(systemName: annotation.background ? "rectangle.fill" : "rectangle")
            }
            .help("Background behind text")
            Button(action: onEdit) { Image(systemName: "pencil") }.help("Edit text")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Delete label")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .fixedSize()
    }
}
