import AppKit
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var store: AppStore
    @State private var showImport = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("These facts frame every resume — header, roles, dates, education.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { showImport = true } label: { Label("Import from my existing resume…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.borderedProminent)
                }
            }
            Section("You") {
                TextField("Full name", text: $store.data.profile.name)
                TextField("Headline / target role", text: $store.data.profile.headline,
                          prompt: Text("e.g. Product Development Leader – Embedded & IoT"))
                TextField("Location", text: $store.data.profile.location, prompt: Text("Ahmedabad, India"))
                HStack {
                    TextField("Phone", text: $store.data.profile.phone)
                    TextField("Email", text: $store.data.profile.email)
                }
                TextField("LinkedIn URL", text: $store.data.profile.linkedin)
            }
            Section("Roles (most recent first)") {
                ForEach($store.data.profile.roles) { $r in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("Company", text: $r.company)
                            TextField("Title", text: $r.title)
                        }
                        HStack {
                            TextField("Location", text: $r.location)
                            TextField("Start", text: $r.start, prompt: Text("Oct 2024")).frame(width: 110)
                            TextField("End", text: $r.end).frame(width: 110)
                            Button {
                                let id = r.id
                                store.data.profile.roles.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button("Add role") { store.data.profile.roles.append(RoleEntry()) }.buttonStyle(.borderless)
            }
            Section("Education") {
                ForEach($store.data.profile.education) { $e in
                    HStack {
                        TextField("Qualification", text: $e.qualification)
                        TextField("Institution", text: $e.institution)
                        TextField("Location", text: $e.location)
                        TextField("Year", text: $e.year).frame(width: 70)
                        Button {
                            let id = e.id
                            store.data.profile.education.removeAll { $0.id == id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add education") { store.data.profile.education.append(EducationEntry()) }.buttonStyle(.borderless)
            }
            Section("Additional details") {
                TextField("Languages", text: $store.data.profile.languages)
                TextField("Certifications", text: $store.data.profile.certifications)
                TextField("Technical skills", text: $store.data.profile.technicalSkills, axis: .vertical).lineLimit(1...4)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showImport) { ImportResumeSheet() }
    }
}

struct ImportResumeSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import your current resume").font(.title2.bold())
            Text("Paste the text of your CV or LinkedIn profile. Empty profile fields get filled, and each achievement becomes a story you can refine. Nothing is embellished.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .frame(minHeight: 340)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    let t = text
                    store.run("Reading your resume…") { try await store.importResume(text: t) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 50)
            }
        }
        .padding(20)
        .frame(width: 680)
    }
}

struct MasterResumeView: View {
    @EnvironmentObject var store: AppStore
    @State private var allowPlaceholders = UserDefaults.standard.bool(forKey: "allowPlaceholders")

    private var doc: Binding<ResumeDoc> {
        Binding(get: { store.data.masterResume ?? ResumeDoc() },
                set: { store.data.masterResume = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Master resume").font(.title2.bold())
                    Text("Your best general resume, built only from your stories — not tied to one job.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Mode", selection: $allowPlaceholders) {
                    Text("Facts only").tag(false)
                    Text("Allow [VERIFY]").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Button {
                    store.run("Writing your master resume…") { try await store.buildMaster(allowPlaceholders: allowPlaceholders) }
                } label: { Label(store.data.masterResume == nil ? "Build" : "Rebuild", systemImage: "doc.badge.gearshape") }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()
            if store.data.masterResume != nil {
                ResumePreview(doc: doc,
                              fileName: store.data.profile.name.isEmpty ? "Resume" : "\(store.data.profile.name) - Resume",
                              missing: store.data.masterMissing)
            } else {
                EmptyHint(icon: "doc.richtext", title: "No master resume yet",
                          message: "Fill in your Profile and add stories (or interview), then press Build.")
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var key = Keychain.load()
    @AppStorage("groqModel") private var model = AppStore.defaultModel
    @AppStorage("allowPlaceholders") private var allowPlaceholders = false
    @AppStorage("autoProcess") private var autoProcess = true
    @AppStorage("autoDepth") private var autoDepth = AutoDepth.resume.rawValue
    @State private var models: [String] = []
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                SecureField("Groq API key", text: $key, prompt: Text("gsk_…"))
                    .onSubmit { Keychain.save(key); status = "Saved to Keychain." }
                HStack {
                    Button("Save key") { Keychain.save(key); status = "Saved to Keychain."; store.resumeAutoAfterPause() }
                    Button("Test & list models") { Task { await test() } }
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                TextField("Model ID", text: $model)
                HStack {
                    TextField("Tokens per minute (your plan)", value: Binding(
                        get: { GroqClient.tpmLimit(for: model) },
                        set: { GroqClient.setTPMLimit($0, for: model) }), format: .number)
                    Text("learned automatically").font(.caption).foregroundStyle(.secondary)
                }
                if !models.isEmpty {
                    Picker("Models on your account", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                Text("Groq")
            } footer: {
                Text("Get a key at console.groq.com/keys. Groq's model line-up changes — use 'Test & list models' to see what's live and pick a large text model. On the free tier each request must fit in about 8,000 tokens per minute, so the app sends your most relevant stories (not all of them) and waits when Groq asks it to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Process new jobs automatically in the background", isOn: $autoProcess)
                Picker("Go as far as", selection: $autoDepth) {
                    ForEach(AutoDepth.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .disabled(!autoProcess)
            } header: {
                Text("Background processing")
            } footer: {
                Text("Each new JD is processed one at a time while you keep browsing. On Groq's free tier, all steps use roughly 15–25K tokens per job against a daily allowance of about 200K, so expect around 8–12 full jobs a day. Choose a shorter depth to process more jobs. If the daily allowance runs out, the queue pauses and picks up again later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Allow [VERIFY] placeholders by default", isOn: $allowPlaceholders)
                Text("Off: resumes contain only facts from your profile and stories. On: the app may add clearly marked [VERIFY] bullets for missing requirements, for you to confirm or delete. You can switch per resume.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                Text(AppStore.storeURL.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppStore.storeURL]) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 720)
    }

    private func test() async {
        Keychain.save(key)
        status = "Checking…"
        do {
            models = try await GroqClient(apiKey: key, model: model).listModels()
            status = models.contains(model) ? "Connected. '\(model)' is available." : "Connected, but '\(model)' isn't in your list — pick one below."
        } catch {
            status = error.localizedDescription
        }
    }
}
