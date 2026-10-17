import SwiftUI

/// "Column names": give the sheet's columns (e.g. var 1 … var 10) real names used everywhere in the app.
struct ColumnNamesEditor: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var drafts: [String: String] = [:]   // sheet name -> real name
    @State private var search = ""
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Column names").font(.title2.bold())
            Text("Give your sheet's columns their real names. The names you set here are used everywhere: both tables, column pickers, filters, formulas, cell colors, the MV2 check, buy triggers and emails. Filters you already built are updated to the new names automatically. Leave a name blank to use the sheet's own name.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if vm.sheetColumnNames.isEmpty {
                Text("Import data first — the column list comes from the sheet.")
                    .foregroundStyle(.orange)
                    .padding(.vertical, 20)
            } else {
                HStack {
                    TextField("Search columns", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $showAll) {
                        Text("var columns & renamed").tag(false)
                        Text("All columns").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                    GridRow {
                        Text("In the sheet").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("Real name").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(visibleColumns, id: \.self) { original in
                            GridRow {
                                Text(original)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 180, alignment: .leading)
                                    .lineLimit(1)
                                VStack(alignment: .leading, spacing: 2) {
                                    TextField(original, text: binding(for: original))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 280)
                                    if let problem = problems[original] {
                                        Text(problem).font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 360)

                if visibleColumns.isEmpty {
                    Text(showAll ? "No columns match your search." : "No \"var\" columns found. Choose \"All columns\" to rename any column.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Clear all names") {
                    drafts = [:]
                }
                .disabled(drafts.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    vm.applyColumnNames(drafts)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty || vm.sheetColumnNames.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            drafts = vm.settings.columnAliases
        }
    }

    private func binding(for original: String) -> Binding<String> {
        Binding(
            get: { drafts[original] ?? "" },
            set: { drafts[original] = $0 }
        )
    }

    /// Sheet columns to list: by default the dummy "var" columns plus anything already renamed.
    private var visibleColumns: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return vm.sheetColumnNames.filter { original in
            if !q.isEmpty {
                let real = drafts[original] ?? ""
                return original.localizedCaseInsensitiveContains(q) || real.localizedCaseInsensitiveContains(q)
            }
            if showAll { return true }
            let isVar = original.range(of: #"^\s*var[\s_-]*\d+\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
            let renamed = !(drafts[original] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            return isVar || renamed
        }
    }

    /// Names that would clash with another column (names must be unique so filters know which column you mean).
    private var problems: [String: String] {
        var out: [String: String] = [:]
        let originals = vm.sheetColumnNames
        let final = originals.map { orig -> String in
            let d = (drafts[orig] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty ? orig : d
        }
        for (i, orig) in originals.enumerated() {
            let name = final[i]
            let draft = (drafts[orig] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.isEmpty else { continue }
            if name.contains("]") {
                out[orig] = "Names can't contain ]"
                continue
            }
            for (j, other) in final.enumerated() where j != i && SheetTable.normalize(other) == SheetTable.normalize(name) {
                out[orig] = "Already used by \"\(originals[j])\""
                break
            }
        }
        return out
    }
}
