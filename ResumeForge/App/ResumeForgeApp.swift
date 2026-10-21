import SwiftUI

@main
struct ResumeForgeApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 720)
                // Jobs arrive from the Safari extension as resumeforge://import?job=… links.
                // Route them into the existing window instead of opening a new one.
                .handlesExternalEvents(preferring: Set(["*"]), allowing: Set(["*"]))
                .onOpenURL { url in store.handleOpenURL(url) }
        }
        .handlesExternalEvents(matching: Set(["*"]))
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Save Now") { store.saveNow() }.keyboardShortcut("s")
            }
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationSplitView {
            List(selection: $store.section) {
                ForEach(SidebarSection.allCases) { s in
                    Label(s.rawValue, systemImage: s.icon).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch store.section ?? .jobs {
            case .jobs: JobsView()
            case .stories: StoriesView()
            case .interview: InterviewView()
            case .master: MasterResumeView()
            case .templates: TemplatesView()
            case .feed: FeedView()
            case .profile: ProfileView()
            }
        }
        .overlay(alignment: .bottom) {
            if let busy = store.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 18)
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { store.errorMessage != nil },
                                    set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

// MARK: - Small shared views

struct EmptyHint: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Comma-separated editor for [String] that doesn't fight the cursor while typing.
struct CommaField: View {
    let title: String
    @Binding var values: [String]
    @State private var text = ""

    var body: some View {
        TextField(title, text: $text)
            .onAppear { text = values.joined(separator: ", ") }
            .onChange(of: text) { newValue in
                values = newValue.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
    }
}
