import SwiftUI
import Charts

/// "Stock History" window: animates one stock day by day over the stored snapshots (up to 30 days shown).
struct HistoryView: View {
    @EnvironmentObject var vm: ScreenerViewModel

    @State private var symbol = ""
    @State private var search = ""
    @State private var points: [HistoryStore.Point] = []
    @State private var index = 0
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var speed = 0.7
    @State private var showColumnMenu = false
    @State private var playTask: Task<Void, Never>?

    private let maxDays = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if symbol.isEmpty {
                placeholder("Pick a stock",
                            "Type a symbol above, or select a row in the Filter or Data Import table and click ▶ Animate.")
            } else if isLoading {
                ProgressView("Loading \(symbol)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if points.isEmpty {
                placeholder("No history for \(symbol) yet",
                            "The app saves one compressed snapshot per trading day from now on. Come back after a few days of imports.")
            } else {
                content
            }
            Divider()
            footer
        }
        .navigationTitle(symbol.isEmpty ? "Stock History" : "\(symbol) — last \(min(points.count, maxDays)) days")
        .onAppear {
            vm.refreshHistoryInfo()
            if let s = vm.selectedStock, s != symbol { load(s) }
        }
        .onChange(of: vm.selectedStock) { s in
            if let s, s != symbol { load(s) }
        }
        .onDisappear { stop() }
    }

    // MARK: Header: stock picker + playback

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Stock symbol", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit {
                    if let first = suggestions.first { pick(first) } else if !search.isEmpty { pick(search.uppercased()) }
                }
                .overlay(alignment: .topLeading) {
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(suggestions, id: \.self) { s in
                                Button { pick(s) } label: {
                                    Text(s).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: 200)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.2)))
                        .shadow(radius: 6)
                        .offset(y: 28)
                    }
                }
                .zIndex(10)

            Divider().frame(height: 20)

            Button { step(-1) } label: { Image(systemName: "backward.end.fill") }
                .disabled(points.isEmpty || index == 0)
            Button { isPlaying ? stop() : play() } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(points.count < 2)
            Button { step(1) } label: { Image(systemName: "forward.end.fill") }
                .disabled(points.isEmpty || index >= shown.count - 1)

            if shown.count > 1 {
                Slider(value: Binding(get: { Double(index) },
                                      set: { index = Int($0.rounded()) }),
                       in: 0...Double(shown.count - 1), step: 1)
                    .frame(minWidth: 160)
            } else {
                Spacer()
            }

            Picker("Speed", selection: $speed) {
                Text("Slow").tag(1.2)
                Text("Normal").tag(0.7)
                Text("Fast").tag(0.3)
            }
            .labelsHidden()
            .fixedSize()

            Menu {
                ForEach(vm.headers, id: \.self) { name in
                    Button {
                        toggleColumn(name)
                    } label: {
                        if columns.contains(name) { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
                Divider()
                Button("Use Filter screen columns") { vm.settings.historyColumns = [] }
            } label: {
                Label("Columns", systemImage: "rectangle.split.3x1")
            }
            .fixedSize()
        }
        .padding(10)
    }

    // MARK: Content: day card + charts

    private var shown: [HistoryStore.Point] { Array(points.suffix(maxDays)) }

    private var current: HistoryStore.Point? {
        shown.isEmpty ? nil : shown[min(index, shown.count - 1)]
    }

    private var previous: HistoryStore.Point? {
        index > 0 && index - 1 < shown.count ? shown[index - 1] : nil
    }

    /// Column names to show (and their indices in today's table).
    private var columns: [String] {
        let chosen = vm.settings.historyColumns.isEmpty
            ? vm.filterColumnIndices.map { vm.headers[$0] }
            : vm.settings.historyColumns
        let label = vm.labelIndex.map { vm.headers[$0] }
        return chosen.filter { $0 != label && vm.table.index(of: $0) != nil }
    }

    private var content: some View {
        HSplitView {
            dayCard
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            charts
                .frame(minWidth: 400)
        }
    }

    private var dayCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let cur = current {
                    Text(cur.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                        .font(.title2.bold())
                    Text("Day \(index + 1) of \(shown.count)")
                        .foregroundStyle(.secondary)

                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(columns, id: \.self) { name in
                            if let col = vm.table.index(of: name) {
                                GridRow {
                                    Text(name).foregroundStyle(.secondary).lineLimit(1)
                                    Text(cur.row.text(col).isEmpty ? "—" : cur.row.text(col))
                                        .font(.system(.body, design: .monospaced).weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(nsColor: vm.painter.color(for: cur.row, column: col) ?? .clear)))
                                        .gridColumnAlignment(.trailing)
                                    changeLabel(col: col, cur: cur)
                                }
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: index)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func changeLabel(col: Int, cur: HistoryStore.Point) -> some View {
        if let now = cur.row.number(col), let before = previous?.row.number(col), now != before {
            let up = now > before
            Text("\(up ? "▲" : "▼") \(abs(now - before).formatted(.number.precision(.fractionLength(0...2))))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(up ? .green : .red)
        } else {
            Text("").font(.caption)
        }
    }

    private var charts: some View {
        let numeric = columns.compactMap { name -> (String, Int)? in
            guard let c = vm.table.index(of: name),
                  shown.contains(where: { $0.row.number(c) != nil }) else { return nil }
            return (name, c)
        }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(numeric, id: \.0) { name, col in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(name).font(.headline).lineLimit(1)
                            Spacer()
                            if let v = current?.row.number(col) {
                                Text(v.formatted(.number.precision(.fractionLength(0...2))))
                                    .font(.headline.monospacedDigit())
                            }
                        }
                        Chart {
                            ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                                if let y = p.row.number(col) {
                                    LineMark(x: .value("Day", p.date), y: .value(name, y))
                                        .foregroundStyle(Color.accentColor.opacity(i <= index ? 1 : 0.25))
                                    if i == index {
                                        PointMark(x: .value("Day", p.date), y: .value(name, y))
                                            .symbolSize(70)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            if let cur = current {
                                RuleMark(x: .value("Today", cur.date))
                                    .foregroundStyle(.secondary.opacity(0.4))
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 4)) {
                                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            }
                        }
                        .frame(height: 140)
                        .animation(.easeInOut(duration: 0.25), value: index)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(vm.historyDays.count) day\(vm.historyDays.count == 1 ? "" : "s") stored")
            Text(ByteCountFormatter.string(fromByteCount: Int64(vm.historyBytes), countStyle: .file) + " compressed")
            if let first = vm.historyDays.first, let last = vm.historyDays.last {
                Text("\(first) → \(last)")
            }
            Spacer()
            Stepper("Keep \(vm.settings.historyKeepDays) days", value: $vm.settings.historyKeepDays, in: 30...365, step: 5)
                .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "play.square.stack")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private var suggestions: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Array(vm.allSymbols.filter { $0.localizedCaseInsensitiveContains(q) }
            .sorted { a, b in
                let ap = a.lowercased().hasPrefix(q.lowercased()), bp = b.lowercased().hasPrefix(q.lowercased())
                return ap != bp ? ap : a < b
            }
            .prefix(8))
    }

    private func pick(_ s: String) {
        search = ""
        vm.selectedStock = s
        load(s)
    }

    private func load(_ s: String) {
        stop()
        symbol = s
        isLoading = true
        Task {
            let result = await vm.loadHistory(for: s)
            guard symbol == s else { return }
            points = result
            index = 0
            isLoading = false
            if shown.count > 1 { play() }
        }
    }

    private func toggleColumn(_ name: String) {
        var list = vm.settings.historyColumns.isEmpty ? columns : vm.settings.historyColumns
        if list.contains(name) { list.removeAll { $0 == name } } else { list.append(name) }
        vm.settings.historyColumns = list
    }

    private func step(_ delta: Int) {
        stop()
        index = max(0, min(shown.count - 1, index + delta))
    }

    private func play() {
        guard shown.count > 1 else { return }
        if index >= shown.count - 1 { index = 0 }
        isPlaying = true
        playTask?.cancel()
        playTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(speed * 1_000_000_000))
                if Task.isCancelled { break }
                if index >= shown.count - 1 {
                    isPlaying = false
                    break
                }
                withAnimation(.easeInOut(duration: 0.25)) { index += 1 }
            }
        }
    }

    private func stop() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }
}
