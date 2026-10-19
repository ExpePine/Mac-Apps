import SwiftUI

struct StoriesView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""

    private var filtered: [Story] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.data.stories }
        return store.data.stories.filter {
            ($0.title + " " + $0.company + " " + $0.text + " " + $0.skills.joined(separator: " ")).lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selectedStoryID) {
                    ForEach(filtered) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.title.isEmpty ? "Untitled story" : s.title).font(.headline).lineLimit(2)
                            Text([s.company, s.period].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Pill(text: s.origin, color: s.origin == "interview" ? .purple : .accentColor)
                                if !s.metrics.isEmpty { Pill(text: "\(s.metrics.count) metrics", color: .green) }
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(s.id)
                        .contextMenu { Button("Delete", role: .destructive) { store.deleteStory(s.id) } }
                    }
                }
                .searchable(text: $search, placement: .sidebar, prompt: "Search stories")
                Divider()
                HStack {
                    Button { store.newStory() } label: { Label("New story", systemImage: "plus") }
                    Spacer()
                    Button { store.startInterview(jobID: nil, gapID: nil) } label: { Label("Interview me", systemImage: "bubble.left.and.bubble.right") }
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)

            Group {
                if let id = store.selectedStoryID, store.storyIndex(id) != nil {
                    StoryEditor(story: Binding(
                        get: { store.storyIndex(id).map { store.data.stories[$0] } ?? Story() },
                        set: { v in if let i = store.storyIndex(id) { store.data.stories[i] = v } }
                    )).id(id)
                } else {
                    EmptyHint(icon: "book",
                              title: store.data.stories.isEmpty ? "Your story bank is empty" : "Pick a story",
                              message: "Write down what you actually did — the situation, your actions, the numbers. Messy is fine. The app turns stories into resume bullets, and never adds facts you didn't give it.")
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StoryEditor: View {
    @EnvironmentObject var store: AppStore
    @Binding var story: Story

    private var companies: [String] {
        Array(Set(store.data.profile.roles.map(\.company).filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $story.title, prompt: Text("e.g. Launched fingerprint scanner line in 9 months"))
                HStack {
                    TextField("Company", text: $story.company)
                    if !companies.isEmpty {
                        Menu("Pick") {
                            ForEach(companies, id: \.self) { c in Button(c) { story.company = c } }
                        }
                        .fixedSize()
                    }
                }
                HStack {
                    TextField("Your role", text: $story.role)
                    TextField("Period", text: $story.period, prompt: Text("e.g. 2023–2024"))
                }
            }
            Section {
                TextEditor(text: $story.text)
                    .font(.body)
                    .frame(minHeight: 240)
            } header: {
                Text("The story")
            } footer: {
                Text("Situation → what YOU did → result. Include numbers if you have them (team size, ₹, %, units, time).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                CommaField(title: "Metrics (comma-separated)", values: $story.metrics)
                CommaField(title: "Skills shown (comma-separated)", values: $story.skills)
            }
            Section {
                HStack {
                    Text("Updated \(story.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete story", role: .destructive) { store.deleteStory(story.id) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: story.text) { _ in story.updatedAt = Date() }
    }
}
