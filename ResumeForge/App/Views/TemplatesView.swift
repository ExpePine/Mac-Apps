import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Resume designs: drop a screenshot of a CV you like → the AI reads its design → the app renders your resume that way.
struct TemplatesView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("defaultTemplate") private var defaultTemplate = ""
    @State private var selected: UUID? = TemplateSpec.classicID
    @State private var dropTargeted = false
    @State private var newName = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(store.allTemplates) { t in
                        HStack(spacing: 10) {
                            thumb(t)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.headline).lineLimit(2)
                                Text(t.layout == "sidebar" ? "Two columns" : "Single column")
                                    .font(.caption).foregroundStyle(.secondary)
                                if isDefault(t) { Pill(text: "default", color: .green) }
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(t.id)
                        .contextMenu {
                            Button("Make default") { defaultTemplate = t.id.uuidString }
                            if !t.builtIn {
                                Button("Delete", role: .destructive) { delete(t.id) }
                            }
                        }
                    }
                }
                Divider()
                dropZone
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            if let id = selected, let i = store.data.templates?.firstIndex(where: { $0.id == id }) {
                TemplateEditor(spec: Binding(
                    get: { store.data.templates?[i] ?? .classic },
                    set: { v in store.data.templates?[i] = v }))
                .id(id)
            } else {
                TemplatePreviewPane(spec: .classic, note: "The built-in layout from your reference resume. Drop a screenshot on the left to add your own designs.")
            }
        }
    }

    private func isDefault(_ t: TemplateSpec) -> Bool {
        defaultTemplate.isEmpty ? t.builtIn : defaultTemplate == t.id.uuidString
    }

    @ViewBuilder
    private func thumb(_ t: TemplateSpec) -> some View {
        if let d = t.thumbnail, let img = NSImage(data: d) {
            Image(nsImage: img).resizable().scaledToFit().frame(width: 44, height: 60)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
        } else {
            RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 44, height: 60)
                .overlay(Image(systemName: "doc.plaintext").foregroundStyle(.secondary))
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.plus").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("Drop a CV screenshot here").font(.callout.bold())
            TextField("Name (optional)", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
            Button("Choose image…") { choose() }
            Text("Needs a provider that can read images, e.g. Gemini").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
        .padding(8)
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls { add(u) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        if panel.runModal() == .OK { for u in panel.urls { add(u) } }
    }

    private func add(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let name = newName
        newName = ""
        store.run("Reading the design of \(url.lastPathComponent)…") {
            let t = try await store.addTemplate(from: data, name: name)
            selected = t.id
        }
    }

    private func delete(_ id: UUID) {
        if selected == id { selected = TemplateSpec.classicID }
        store.data.templates?.removeAll { $0.id == id }
        if defaultTemplate == id.uuidString { defaultTemplate = "" }
    }
}

struct TemplateEditor: View {
    @Binding var spec: TemplateSpec

    var body: some View {
        HSplitView {
            Form {
                Section("Template") {
                    TextField("Name", text: $spec.name)
                    if !spec.notes.isEmpty {
                        Label(spec.notes, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    if let d = spec.thumbnail, let img = NSImage(data: d) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 220)
                    }
                }
                Section("Type") {
                    Picker("Font style", selection: $spec.font) { Text("Serif").tag("serif"); Text("Sans-serif").tag("sans") }
                    TextField("Font name (if installed)", text: $spec.fontName)
                    Stepper("Body size \(spec.baseSize, specifier: "%.1f") pt", value: $spec.baseSize, in: 8.5...12.5, step: 0.5)
                }
                Section("Header") {
                    Stepper("Name size \(Int(spec.nameSize)) pt", value: $spec.nameSize, in: 14...34)
                    Picker("Alignment", selection: $spec.nameAlign) { Text("Left").tag("left"); Text("Centre").tag("center"); Text("Right").tag("right") }
                    Toggle("Name in capitals", isOn: $spec.nameCaps)
                    ColorField(title: "Name colour", hex: $spec.nameColor)
                    Toggle("Coloured band behind header", isOn: $spec.headerBand)
                    if spec.headerBand { ColorField(title: "Band colour", hex: $spec.headerBandColor) }
                }
                Section("Section headings") {
                    Picker("Style", selection: $spec.headingStyle) {
                        Text("Line under").tag("rule"); Text("Filled band").tag("band"); Text("Side bar").tag("bar"); Text("Plain").tag("none")
                    }
                    Toggle("Capitals", isOn: $spec.headingCaps)
                    Stepper("Size \(spec.headingSize, specifier: "%.1f") pt", value: $spec.headingSize, in: 9...18, step: 0.5)
                    ColorField(title: "Heading colour", hex: $spec.headingColor)
                    ColorField(title: "Accent colour", hex: $spec.accentColor)
                }
                Section("Layout") {
                    Picker("Columns", selection: $spec.layout) { Text("Single column").tag("single"); Text("With sidebar").tag("sidebar") }
                    if spec.layout == "sidebar" {
                        Picker("Sidebar side", selection: $spec.sidebarSide) { Text("Left").tag("left"); Text("Right").tag("right") }
                        Slider(value: $spec.sidebarWidth, in: 0.22...0.42) { Text("Sidebar width") }
                        ColorField(title: "Sidebar background", hex: $spec.sidebarBackground)
                        ForEach(["summary", "experience", "achievements", "education", "additional"], id: \.self) { s in
                            Toggle("\(TemplateSpec.defaultTitles[s] ?? s) in sidebar", isOn: Binding(
                                get: { spec.sidebarSections.contains(s) },
                                set: { on in
                                    spec.sidebarSections.removeAll { $0 == s }
                                    if on { spec.sidebarSections.append(s) }
                                }))
                        }
                    }
                    Picker("Bullet", selection: $spec.bullet) {
                        ForEach(["●", "•", "–", "▪", "›", "✓"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Dates", selection: $spec.datesAlign) { Text("Right-aligned").tag("right"); Text("Inline under title").tag("inline") }
                    Toggle("Company names in capitals", isOn: $spec.companyCaps)
                    Stepper("Margins \(Int(spec.margin)) pt", value: $spec.margin, in: 24...72, step: 2)
                }
                Section("Section order & titles") {
                    ForEach(Array(spec.sectionOrder.enumerated()), id: \.element) { idx, s in
                        HStack {
                            TextField(TemplateSpec.defaultTitles[s] ?? s, text: Binding(
                                get: { spec.sectionTitles[s] ?? "" },
                                set: { spec.sectionTitles[s] = $0 }))
                            Button { moveSection(idx, -1) } label: { Image(systemName: "arrow.up") }.disabled(idx == 0)
                            Button { moveSection(idx, 1) } label: { Image(systemName: "arrow.down") }.disabled(idx == spec.sectionOrder.count - 1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 320, idealWidth: 360)

            TemplatePreviewPane(spec: spec, note: nil)
        }
    }

    private func moveSection(_ i: Int, _ d: Int) {
        let j = i + d
        guard spec.sectionOrder.indices.contains(j) else { return }
        spec.sectionOrder.swapAt(i, j)
    }
}

struct ColorField: View {
    let title: String
    @Binding var hex: String
    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { Color(nsColor: NSColor(hex: hex)) },
            set: { c in
                let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
                hex = String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
            }), supportsOpacity: false)
    }
}

/// Renders a sample (your master resume if you have one) with the template.
struct TemplatePreviewPane: View {
    @EnvironmentObject var store: AppStore
    let spec: TemplateSpec
    let note: String?

    var body: some View {
        VStack(spacing: 0) {
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary).padding(10)
                Divider()
            }
            PDFKitView(data: ResumePDFRenderer.render(sample, template: spec))
        }
        .frame(minWidth: 380)
    }

    private var sample: ResumeDoc {
        if let m = store.data.masterResume { return m }
        if let t = store.data.jobs.compactMap(\.tailored).first { return t }
        return .sample
    }
}

extension ResumeDoc {
    /// Placeholder content for previewing templates before you've built a resume.
    static let sample: ResumeDoc = {
        var d = ResumeDoc()
        d.name = "Your Name"
        d.contactLine = "City, India | P: +91 00000 00000 | you@example.com"
        d.summary = "Sample text — build your Master Resume to preview templates with your own content. Product leader with 15+ years of experience across hardware, firmware and connected products, leading cross-functional teams from concept to mass production."
        d.experience = [
            ResumeRole(company: "Current Company", location: "City, India", title: "Senior Role", dates: "Jan 2022 - Present",
                       bullets: [ResumeBullet(text: "Led a cross-functional team of 12 to launch a new product line, taking it from concept to production in 9 months."),
                                 ResumeBullet(text: "Introduced a stage-gate review process that cut late design changes and improved first-pass yield.")]),
            ResumeRole(company: "Previous Company", location: "City, India", title: "Earlier Role", dates: "2016 - 2021",
                       bullets: [ResumeBullet(text: "Built the hardware team from scratch and shipped three connected devices to enterprise customers.")])
        ]
        d.achievements = [ResumeAchievement(label: "Team Leadership", text: "Grew and mentored engineering teams across hardware and software."),
                          ResumeAchievement(label: "Recognition", text: "Co-inventor on published patents.")]
        d.education = [ResumeEducation(qualification: "Degree Name", institution: "University", location: "City, India", year: "Graduated: 2010")]
        d.additional = [LabeledLine(label: "Languages", value: "English, Hindi"), LabeledLine(label: "Technical Skills", value: "Skill one, skill two, skill three")]
        return d
    }()
}
