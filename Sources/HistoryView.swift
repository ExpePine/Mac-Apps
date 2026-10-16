import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var store: EntryStore
    @ObservedObject var settings: SettingsStore
    @StateObject private var player = AudioPlayer()
    @State private var search = ""
    @State private var hideMissed = false

    private var filtered: [Entry] {
        store.entries.filter { e in
            if hideMissed && (e.status == .missed || e.status == .skipped) { return false }
            guard !search.isEmpty else { return true }
            return e.text.localizedCaseInsensitiveContains(search)
                || (e.transcript ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [Entry]
        var id: Date { day }
    }

    private var days: [DayGroup] {
        let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.periodEnd) }
        return groups.keys.sorted(by: >).map { day in
            DayGroup(day: day, entries: (groups[day] ?? []).sorted { $0.periodEnd > $1.periodEnd })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search entries", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Hide missed/skipped", isOn: $hideMissed)
                Spacer()
                Button("Export CSV…", action: exportCSV)
            }
            .padding(12)

            Divider()

            if days.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(store.entries.isEmpty ? "No entries yet. Your first check-in will show up here."
                                               : "Nothing matches.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(days) { group in
                        Section(header: Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))) {
                            ForEach(group.entries) { entry in
                                EntryRow(entry: entry, store: store, settings: settings, player: player)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .onDisappear { player.stop() }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "activity-log.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.csvString().write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct EntryRow: View {
    let entry: Entry
    let store: EntryStore
    let settings: SettingsStore
    @ObservedObject var player: AudioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.timeRangeText).font(.headline).monospacedDigit()
                StatusBadge(status: entry.status)
                Spacer()
                if let url = store.audioURL(for: entry) {
                    Button {
                        player.toggle(id: entry.id, url: url)
                    } label: {
                        Image(systemName: player.playingID == entry.id ? "stop.circle" : "play.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help("Play voice note")
                }
            }

            if !entry.text.isEmpty {
                Text(entry.text).textSelection(.enabled)
            }
            if let t = entry.transcript, !t.isEmpty, !entry.text.contains(t) {
                Label(t, systemImage: "waveform")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if entry.transcriptPending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Converting voice note to text…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
            if store.audioURL(for: entry) != nil {
                Button("Transcribe voice note again") {
                    store.transcribeInBackground(entry.id, localeID: settings.speechLocaleID)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(entry.id) }
        }
    }
}

private struct StatusBadge: View {
    let status: Entry.Status

    private var color: Color {
        switch status {
        case .completed, .quickReply: return .green
        case .autoSaved: return .orange
        case .skipped: return .gray
        case .missed: return .red
        }
    }

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
