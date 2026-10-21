import SwiftUI
import SamsaraCore

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case insights = "Insights"
    case transactions = "Transactions"
    case categories = "Categories"
    case vendors = "Vendors & People"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .dashboard: return "chart.bar.xaxis"
        case .insights: return "lightbulb"
        case .transactions: return "list.bullet.rectangle"
        case .categories: return "square.grid.2x2"
        case .vendors: return "bag"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var section: AppSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { SyncStatusPanel() }
        } detail: {
            VStack(spacing: 0) {
                if case .needsSignIn(let msg) = store.status {
                    Banner(text: msg, symbol: "person.crop.circle.badge.exclamationmark", color: .orange) {
                        Button("Sign in to Samsara…") { openWindow(id: "signin") }
                    }
                } else if case .failed(let msg) = store.status {
                    Banner(text: msg, symbol: "exclamationmark.triangle", color: .red) {
                        Button("Try again") { Task { await store.sync() } }
                    }
                }
                Group {
                    if store.expenses.isEmpty {
                        WelcomeView()
                    } else {
                        switch section ?? .dashboard {
                        case .dashboard: DashboardView()
                        case .insights: InsightsView()
                        case .transactions: TransactionsView()
                        case .categories: CategoriesView()
                        case .vendors: VendorsView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(section?.rawValue ?? "Samsara Expenses")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Period", selection: $store.period) {
                    ForEach(store.availablePeriods) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 150)
                .disabled(store.expenses.isEmpty)
                .help("Period to analyse")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.importWithPanel()
                } label: {
                    Label("Import CSV", systemImage: "square.and.arrow.down")
                }
                .help("Import a CSV you downloaded from Samsara")

                Button {
                    Task { await store.sync() }
                } label: {
                    if store.status == .syncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(store.status == .syncing)
                .help("Download the latest CSV from the Samsara page now (⌘R)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "csv" }) else { return false }
            store.importFile(url)
            return true
        }
    }
}

struct Banner<Actions: View>: View {
    let text: String
    let symbol: String
    let color: Color
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer()
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(color.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SyncStatusPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 4)
            HStack(spacing: 6) {
                switch store.status {
                case .syncing: ProgressView().controlSize(.mini)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .needsSignIn: Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .idle: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
                Text(statusLine).lineLimit(2)
            }
            .font(.caption)
            if let next = store.nextSync, store.status != .syncing {
                Text("Next auto-sync \(next.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var statusLine: String {
        switch store.status {
        case .ok:
            if let last = store.lastSync { return "Updated \(last.formatted(.relative(presentation: .named)))" }
            return store.status.message
        case .needsSignIn: return "Sign-in needed"
        case .failed: return "Last sync failed"
        default: return store.status.message
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "indianrupeesign.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
            Text("Samsara Expenses").font(.largeTitle.weight(.bold))
            Text("Downloads your expenses from the Samsara page automatically (the same CSV as its 📥 button) and analyses them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                Button {
                    Task { await store.sync() }
                } label: {
                    Label("Sync from Samsara", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(store.status == .syncing)

                Button("Sign in to Samsara…") { openWindow(id: "signin") }
                Button("Import CSV…") { store.importWithPanel() }
            }
            .controlSize(.large)
            if store.status == .syncing {
                ProgressView("Opening the Samsara page and pressing 📥…")
            } else if store.status != .idle {
                Text(store.status.message).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            Text("You can also drop a Samsara CSV file onto this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}
