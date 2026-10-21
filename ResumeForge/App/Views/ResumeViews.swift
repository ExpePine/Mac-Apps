import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Live PDF preview + edit + export for any ResumeDoc.
struct ResumePreview: View {
    @EnvironmentObject var store: AppStore
    @Binding var doc: ResumeDoc
    let fileName: String
    var missing: [String] = []

    @State private var editing = false
    @State private var confirmVerify = false

    var body: some View {
        let pdf = ResumePDFRenderer.render(doc, template: store.template(for: doc))
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if doc.mode == "benchmark" {
                    Label("Target resume — not you. Use it to see what 'great' looks like.", systemImage: "target")
                        .foregroundStyle(.secondary)
                } else {
                    if doc.verifyCount > 0 {
                        Label("\(doc.verifyCount) [VERIFY] placeholder\(doc.verifyCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if doc.unsourcedCount > 0 {
                        Label("\(doc.unsourcedCount) bullet\(doc.unsourcedCount == 1 ? "" : "s") not linked to a story — check them",
                              systemImage: "link.badge.plus")
                            .foregroundStyle(.secondary)
                            .help("These bullets didn't cite one of your stories. Make sure every claim is true before sending.")
                    }
                    if doc.verifyCount == 0 && doc.unsourcedCount == 0 {
                        Label("Every bullet traces back to your stories", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
                Picker("Template", selection: Binding(
                    get: { store.template(for: doc).id },
                    set: { doc.templateID = $0 })) {
                    ForEach(store.allTemplates) { t in Text(t.name).tag(t.id) }
                }
                .frame(maxWidth: 220)
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                Button {
                    if doc.verifyCount > 0 && doc.mode != "benchmark" { confirmVerify = true } else { export(pdf) }
                } label: { Label("Export PDF…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
            }
            .font(.callout)
            .padding(10)

            if !missing.isEmpty {
                DisclosureGroup("Not covered by your stories (\(missing.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(missing, id: \.self) { Text("• " + $0).font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            PDFKitView(data: pdf)
        }
        .sheet(isPresented: $editing) { ResumeEditor(doc: $doc) }
        .confirmationDialog("This resume still has [VERIFY] placeholders.",
                            isPresented: $confirmVerify) {
            Button("Edit them first") { editing = true }
            Button("Export anyway") { export(pdf) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Placeholders are not facts. Confirm or delete each one before sending this to anyone.")
        }
    }

    private func export(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let safe = fileName.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        panel.nameFieldStringValue = safe + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
}

struct PDFKitView: NSViewRepresentable {
    let data: Data

    final class Coordinator { var last = Data() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .underPageBackgroundColor
        v.document = PDFDocument(data: data)
        context.coordinator.last = data
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        guard context.coordinator.last != data else { return }
        context.coordinator.last = data
        v.document = PDFDocument(data: data)
    }
}

struct ResumeEditor: View {
    @Binding var doc: ResumeDoc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit resume").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            Form {
                Section("Header") {
                    TextField("Name", text: $doc.name)
                    TextField("Contact line", text: $doc.contactLine)
                }
                Section("Summary") {
                    TextEditor(text: $doc.summary).frame(minHeight: 110)
                }
                ForEach($doc.experience) { $role in
                    Section {
                        TextField("Company", text: $role.company)
                        TextField("Title", text: $role.title)
                        HStack {
                            TextField("Location", text: $role.location)
                            TextField("Dates", text: $role.dates)
                        }
                        ForEach($role.bullets) { $b in
                            HStack(alignment: .top) {
                                TextField("Bullet", text: $b.text, axis: .vertical).lineLimit(1...6)
                                Button {
                                    let id = b.id
                                    $role.wrappedValue.bullets.removeAll { $0.id == id }
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            Button("Add bullet") { $role.wrappedValue.bullets.append(ResumeBullet()) }
                            Spacer()
                            Button("Remove role", role: .destructive) {
                                let id = role.id
                                doc.experience.removeAll { $0.id == id }
                            }
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        Text(role.company.isEmpty ? "Role" : role.company)
                    }
                }
                Section("Key achievements") {
                    ForEach($doc.achievements) { $a in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                TextField("Label", text: $a.label).fontWeight(.semibold)
                                TextField("Text", text: $a.text, axis: .vertical).lineLimit(1...5)
                            }
                            Button {
                                let id = a.id
                                doc.achievements.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add achievement") { doc.achievements.append(ResumeAchievement()) }
                        .buttonStyle(.borderless)
                }
                Section("Education") {
                    ForEach($doc.education) { $e in
                        TextField("Qualification", text: $e.qualification)
                        HStack {
                            TextField("Institution", text: $e.institution)
                            TextField("Location", text: $e.location)
                            TextField("Year", text: $e.year).frame(width: 140)
                        }
                    }
                }
                Section("Additional details") {
                    ForEach($doc.additional) { $l in
                        HStack(alignment: .top) {
                            TextField("Label", text: $l.label).frame(width: 150)
                            TextField("Value", text: $l.value, axis: .vertical).lineLimit(1...4)
                        }
                    }
                    Button("Add line") { doc.additional.append(LabeledLine()) }.buttonStyle(.borderless)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 760, minHeight: 680)
    }
}
