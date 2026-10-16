import SwiftUI

private enum Scope: String, CaseIterable, Identifiable {
    case all = "All", holding = "Holding", watching = "Watching", tg = "Obs / TG", opn = "Obs / OPN", exited = "Exited"
    var id: String { rawValue }

    func includes(_ s: TrackedSymbol) -> Bool {
        switch self {
        case .all: return s.status != .archived
        case .holding: return s.status == .holding
        case .watching: return s.status == .watching
        case .tg: return s.status == .observationTG
        case .opn: return s.status == .observationOPN
        case .exited: return s.status == .exited
        }
    }
}

// MARK: - Patterns across symbols

struct PatternsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var settings: AppSettings

    @State private var scope: Scope = .all
    @State private var includePrices = true
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?

    private var history: [SavedAnalysis] { store.analyses(for: nil, kind: .patterns) }
    private var totalNotes: Int { store.data.observations.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Patterns")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Find the setups you keep writing about across stocks, check which ones the price confirmed, and draft them as algo rules.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    StatTile(title: "Symbols", value: "\(store.symbols.count)")
                    StatTile(title: "Observations", value: "\(totalNotes)")
                    StatTile(title: "Trades", value: "\(store.data.trades.count)")
                    StatTile(title: "Holding", value: "\(store.symbols(with: .holding).count)")
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 16) {
                            Picker("Symbols", selection: $scope) {
                                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                            Toggle("Include what price did after each note", isOn: $includePrices)
                        }
                        HStack {
                            Button {
                                Task { await analyze() }
                            } label: {
                                Label("Find Patterns", systemImage: "sparkles")
                                    .padding(.horizontal, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(busy || totalNotes == 0)
                            if busy {
                                ProgressView().controlSize(.small)
                                Text(status).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if totalNotes == 0 {
                            Text("Add a few observations first — this works best with notes on several symbols.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if !settings.hasKey {
                            InlineError(message: "Add your Groq API key in Settings (⌘,) to use AI analysis.")
                        }
                        if let error { InlineError(message: error) }
                    }
                }

                ForEach(history) { a in
                    AnalysisCard(analysis: a) { store.deleteAnalysis(a.id) }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Patterns")
    }

    private func analyze() async {
        busy = true
        error = nil
        defer { busy = false }
        let symbols = store.symbols.filter { scope.includes($0) && store.observationCount(for: $0.id) > 0 }
        var series: [String: QuoteSeries] = [:]
        if includePrices {
            status = "Loading prices for \(symbols.count) symbol\(symbols.count == 1 ? "" : "s")…"
            series = await loadSeries(for: symbols, store: store)
        }
        let kb = AIContext.knowledgeBase(store: store, symbols: symbols, seriesBySymbol: series,
                                         includeOutcomes: includePrices, budget: Int(settings.contextBudget))
        guard !kb.text.isEmpty else {
            error = "No observations in this scope."
            return
        }
        status = "Asking Groq…"
        let model = settings.model
        do {
            let text = try await GroqClient.complete(
                messages: [GroqMessage(role: "system", content: AIContext.analystRole),
                           GroqMessage(role: "user", content: AIContext.patternsPrompt(kb.text, omitted: kb.omitted))],
                model: model)
            var footer = ""
            if kb.omitted > 0 {
                footer = "\n\n_Covered \(kb.included) symbols; \(kb.omitted) left out to fit the context limit (raise it in Settings)._"
            }
            store.add(SavedAnalysis(kind: .patterns, symbolID: nil, text: text + footer, model: model))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Chat with your notes

struct ChatView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var settings: AppSettings

    @State private var input = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmClear = false
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Which stocks did I turn bullish on most recently, and what did I see?",
        "What do I usually notice before a breakout works?",
        "Where were my bearish calls wrong?",
        "List every note where I mentioned volume.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.data.chat.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Ask Your Notes")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                Text("Questions are answered from your observations and trades, with what price did after each note.")
                                    .foregroundStyle(.secondary)
                                ForEach(suggestions, id: \.self) { s in
                                    Button {
                                        input = s
                                        Task { await send() }
                                    } label: {
                                        Text(s)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(busy)
                                }
                            }
                            .padding(.bottom, 10)
                        }
                        ForEach(store.data.chat) { m in
                            ChatBubble(message: m).id(m.id)
                        }
                        if busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading your notes…").foregroundStyle(.secondary)
                            }
                            .id("busy")
                        }
                        if let error { InlineError(message: error) }
                    }
                    .padding(24)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: store.data.chat.count) { _ in
                    if let last = store.data.chat.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onChange(of: busy) { b in
                    if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your observations…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { Task { await send() } }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
            }
            .padding(14)
            .background(.bar)
        }
        .navigationTitle("Ask Your Notes")
        .toolbar {
            ToolbarItem {
                Button { confirmClear = true } label: { Label("Clear Chat", systemImage: "trash") }
                    .disabled(store.data.chat.isEmpty)
                    .help("Clear Chat")
            }
        }
        .confirmationDialog("Clear the whole chat?", isPresented: $confirmClear) {
            Button("Clear Chat", role: .destructive) { store.clearChat() }
        }
        .onAppear { inputFocused = true }
    }

    private func send() async {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        input = ""
        error = nil
        store.appendChat(ChatMessage(role: .user, content: q))
        busy = true
        defer { busy = false }

        let symbols = store.symbols
        let series = await loadSeries(for: symbols.filter { store.observationCount(for: $0.id) > 0 }, store: store)
        let kb = AIContext.knowledgeBase(store: store, symbols: symbols, seriesBySymbol: series,
                                         includeOutcomes: true, budget: Int(settings.contextBudget))
        var messages = [GroqMessage(role: "system", content: AIContext.chatSystem(kb.text, omitted: kb.omitted))]
        // Recent turns only, to leave room for the journal.
        for m in store.data.chat.suffix(12) {
            messages.append(GroqMessage(role: m.role.rawValue, content: m.content))
        }
        do {
            let answer = try await GroqClient.complete(messages: messages, model: settings.model)
            store.appendChat(ChatMessage(role: .assistant, content: answer))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 3)
                MarkdownText(text: message.content)
                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var directory: SymbolDirectory
    @EnvironmentObject private var settings: AppSettings

    @State private var keyField = ""
    @State private var models: [String] = []
    @State private var message: String?
    @State private var working = false

    var body: some View {
        TabView {
            Form {
                Section {
                    if settings.hasKey {
                        LabeledContent("API key") {
                            HStack {
                                Label("Saved in Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                                Button("Remove", role: .destructive) { settings.removeKey(); models = [] }
                            }
                        }
                    } else {
                        SecureField("API key", text: $keyField, prompt: Text("gsk_…"))
                        Button("Save Key") {
                            do {
                                try settings.saveKey(keyField)
                                keyField = ""
                                Task { await refreshModels() }
                            } catch {
                                message = error.localizedDescription
                            }
                        }
                        .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Groq")
                } footer: {
                    Text("Create a key at console.groq.com. It's stored only in your Mac's Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        TextField("Model", text: $settings.model)
                        if !models.isEmpty {
                            Menu("Choose") {
                                ForEach(models, id: \.self) { m in Button(m) { settings.model = m } }
                            }
                            .fixedSize()
                        }
                        Button {
                            Task { await refreshModels() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Load the models your key can use")
                        .disabled(!settings.hasKey || working)
                    }
                    Button("Test Connection") { Task { await test() } }
                        .disabled(!settings.hasKey || working)
                    VStack(alignment: .leading) {
                        Slider(value: $settings.contextBudget, in: 6_000...120_000, step: 2_000) {
                            Text("Notes sent per request")
                        }
                        Text("About \(Int(settings.contextBudget / 4).formatted()) tokens. Free Groq tiers have per-minute token limits; lower this if you see rate-limit errors.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Default is \(AppSettings.defaultModel). Groq retires models over time — use the refresh button to see what's currently available.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if working { ProgressView().controlSize(.small) }
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("AI", systemImage: "sparkles") }

            Form {
                Section {
                    LabeledContent("Saved at") {
                        Text(store.fileURL.path).font(.caption).textSelection(.enabled).lineLimit(2)
                    }
                    HStack {
                        Button("Show in Finder") { store.revealDataFile() }
                        Button("Export Backup…") { store.exportJSON() }
                        Button("Import Backup…") { store.importJSON() }
                    }
                } header: {
                    Text("Your journal")
                } footer: {
                    Text("Everything stays on this Mac. Export Backup saves notes, trades, news and Pine Script versions as one JSON file; screenshot images live in the Attachments folder, so copy that folder too for a full backup. Import merges a backup into your current journal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Symbols") {
                        Text("\(directory.equityCount.formatted()) NSE equities + \(SymbolDirectory.indices.count) indices")
                    }
                    LabeledContent("Source") {
                        Text(directory.updated.map { "\(directory.sourceDescription), \(Fmt.day.string(from: $0))" } ?? directory.sourceDescription)
                    }
                    HStack {
                        Button("Refresh from NSE") { Task { await directory.refresh(userInitiated: true) } }
                            .disabled(directory.refreshing)
                        if directory.refreshing { ProgressView().controlSize(.small) }
                    }
                    if let err = directory.refreshError {
                        Text(err).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("NSE symbol list")
                } footer: {
                    Text("Used for search-as-you-type when adding symbols. The app tries to refresh it from NSE weekly; if NSE blocks the request, the current list keeps working.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Saved in the app") {
                        HStack {
                            Text("\(store.data.scripts.count) script\(store.data.scripts.count == 1 ? "" : "s"), \(store.data.scripts.reduce(0) { $0 + $1.versions.count }) versions")
                            Button("Show in Finder") { store.revealFolder(store.scriptsFolder) }
                        }
                    }
                    LabeledContent("Safe folder") {
                        HStack {
                            if let name = store.mirrorFolderName {
                                Label(name, systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                                Button("Change…") { store.chooseMirrorFolder() }
                                Button("Stop") { store.stopMirroring() }
                            } else {
                                Text("Not set").foregroundStyle(.secondary)
                                Button("Choose Folder…") { store.chooseMirrorFolder() }
                            }
                        }
                    }
                    if store.mirrorFolderName != nil {
                        Button("Copy All Versions Again") { store.copyAllScriptsToMirror() }
                    }
                } header: {
                    Text("Pine Scripts")
                } footer: {
                    Text("Every version is saved as a .pine file inside the app. Pick a safe folder (for example in iCloud Drive or a backup disk) and each new version is also copied there automatically, organised as Script Name/v3_date.pine. Deleting a version in the app never deletes these files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Screenshots") {
                    HStack {
                        Text("Chart screenshots you attach are stored in the app's Attachments folder.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Finder") { store.revealFolder(store.attachmentsFolder) }
                    }
                }
                Section("Prices") {
                    Text("Daily OHLC comes from Yahoo Finance's public chart endpoint using the .NS suffix (e.g. RELIANCE → RELIANCE.NS). It is unofficial and can change or rate-limit without notice. For indices, enter the Yahoo symbol directly, e.g. ^NSEI for Nifty 50.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 620, height: 680)
        .task { if settings.hasKey && models.isEmpty { await refreshModels() } }
    }

    private func refreshModels() async {
        working = true
        defer { working = false }
        do {
            models = try await GroqClient.models()
            message = models.contains(settings.model) ? nil : "“\(settings.model)” isn't in your key's model list — pick one from Choose."
        } catch {
            message = error.localizedDescription
        }
    }

    private func test() async {
        working = true
        defer { working = false }
        do {
            let reply = try await GroqClient.complete(
                messages: [GroqMessage(role: "user", content: "Reply with just: OK")], model: settings.model)
            message = "Connected — \(settings.model) replied “\(reply.prefix(40))”."
        } catch {
            message = error.localizedDescription
        }
    }
}
