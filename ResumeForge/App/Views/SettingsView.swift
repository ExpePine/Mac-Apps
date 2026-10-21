import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        TabView {
            ProvidersSettings()
                .tabItem { Label("AI Providers", systemImage: "cpu") }
            ProcessingSettings()
                .tabItem { Label("Processing", systemImage: "gearshape.2") }
            FeedSettingsView()
                .tabItem { Label("Job Feed", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .environmentObject(store)
        .frame(width: 700, height: 680)
    }
}

// MARK: - AI providers

struct ProvidersSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var providers = ProviderSettings.all
    @State private var selected: ProviderKind? = ProviderSettings.all.first?.kind
    @AppStorage("redactContact") private var redact = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Order = which is tried first").font(.caption).foregroundStyle(.secondary).padding(8)
                List(selection: $selected) {
                    ForEach(providers) { p in
                        HStack {
                            Image(systemName: p.isUsable ? "checkmark.circle.fill" : (p.apiKey.isEmpty ? "circle" : "pause.circle"))
                                .foregroundStyle(p.isUsable ? .green : .secondary)
                            Text(p.kind.title)
                            Spacer()
                            if p.vision { Image(systemName: "eye").foregroundStyle(.secondary).help("Can read images") }
                        }
                        .tag(p.kind)
                    }
                    .onMove { from, to in
                        providers.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                }
                HStack {
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }.help("Try earlier")
                    Button { move(1) } label: { Image(systemName: "arrow.down") }.help("Try later")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 230)
            Divider()
            if let k = selected, let i = providers.firstIndex(where: { $0.kind == k }) {
                ProviderEditor(config: $providers[i], onChange: save).id(k)
            } else {
                EmptyHint(icon: "cpu", title: "Pick a provider", message: "")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep my contact details private (never send name, phone, email or LinkedIn to AI providers)", isOn: $redact)
                Text("The resume header is filled in on your Mac from your Profile, so the AI doesn't need them. Your work stories and the JDs are still sent to the provider you use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private func move(_ d: Int) {
        guard let k = selected, let i = providers.firstIndex(where: { $0.kind == k }) else { return }
        let j = i + d
        guard providers.indices.contains(j) else { return }
        providers.swapAt(i, j)
        save()
    }

    private func save() {
        ProviderSettings.all = providers
        store.resumeAutoAfterPause()
    }
}

struct ProviderEditor: View {
    @EnvironmentObject var store: AppStore
    @Binding var config: ProviderConfig
    var onChange: () -> Void

    @State private var key = ""
    @State private var models: [String] = []
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                Toggle("Use this provider", isOn: $config.enabled)
                SecureField("API key", text: $key, prompt: Text("Paste your key"))
                    .onSubmit(saveKey)
                HStack {
                    Button("Save key", action: saveKey)
                    Button("Test & list models") { Task { await test() } }
                    if !config.kind.keyURL.isEmpty, let url = URL(string: config.kind.keyURL) {
                        Link("Get a key", destination: url)
                    }
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text(config.kind.title)
            }
            Section {
                TextField("Model", text: $config.model, prompt: Text("Use 'Test & list models' to pick"))
                if !models.isEmpty {
                    Picker("Available models", selection: $config.model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                        if !models.contains(config.model) { Text(config.model).tag(config.model) }
                    }
                }
                TextField("Base URL", text: $config.baseURL)
                    .font(.callout.monospaced())
                Toggle("Can read images (needed for template screenshots)", isOn: $config.vision)
                HStack {
                    TextField("Max tokens per request", value: Binding(
                        get: { AIClient.tpmLimit(for: config) },
                        set: { AIClient.setTPMLimit($0, for: config) }), format: .number)
                    Text("learned automatically").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !config.kind.privacyNote.isEmpty {
                        Label(config.kind.privacyNote, systemImage: "hand.raised").font(.caption)
                    }
                    Text("Free model line-ups change often, so pick a large, current text model from the list. When a provider runs out of free quota, the app moves on to the next one in your order.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { key = config.apiKey }
        .onChange(of: config) { _ in onChange() }
    }

    private func saveKey() {
        Keychain.save(key, account: config.kind.keychainAccount)
        status = key.isEmpty ? "Key removed." : "Saved to Keychain."
        onChange()
    }

    private func test() async {
        saveKey()
        status = "Checking…"
        do {
            models = try await AIClient(provider: config).listModels()
            if config.model.isEmpty, let first = models.first { config.model = first }
            status = models.contains(config.model)
                ? "Connected. \(models.count) models available; '\(config.model)' is one of them."
                : "Connected, but '\(config.model)' isn't listed — pick one from Available models."
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - Processing

struct ProcessingSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("allowPlaceholders") private var allowPlaceholders = false
    @AppStorage("autoProcess") private var autoProcess = true
    @AppStorage("autoDepth") private var autoDepth = AutoDepth.resume.rawValue
    @AppStorage("defaultTemplate") private var defaultTemplate = ""

    var body: some View {
        Form {
            Section {
                Toggle("Process new jobs automatically in the background", isOn: $autoProcess)
                Picker("Go as far as", selection: $autoDepth) {
                    ForEach(AutoDepth.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .disabled(!autoProcess)
            } header: {
                Text("Background processing")
            } footer: {
                Text("Each new JD is processed one at a time while you keep browsing. If every provider runs out of free quota, the queue pauses and resumes later. A shorter depth leaves more quota for other jobs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Allow [VERIFY] placeholders by default", isOn: $allowPlaceholders)
                Text("Off: resumes contain only facts from your profile and stories. On: the app may add clearly marked [VERIFY] bullets for missing requirements, for you to confirm or delete. You can switch per resume.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Default template", selection: $defaultTemplate) {
                    ForEach(store.allTemplates) { t in Text(t.name).tag(t.id.uuidString) }
                }
            }
            Section("Data") {
                Text(AppStore.storeURL.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppStore.storeURL]) }
            }
        }
        .formStyle(.grouped)
    }
}
