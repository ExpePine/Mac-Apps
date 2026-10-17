import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var link = ""
    @State private var minutes = 5
    @State private var staleHours = 24
    @State private var dateColumn = ""
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Google Sheet")
                .font(.title2.bold())

            Text("Open the tab that has your data, copy the link from the browser, and paste it here. The sheet must be shared as \"Anyone with the link → Viewer\", or published via File → Share → Publish to web.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://docs.google.com/spreadsheets/d/…/edit#gid=0", text: $link)
                .textFieldStyle(.roundedBorder)

            if !link.isEmpty {
                if let url = SheetService.csvURL(from: link) {
                    Text("Will fetch: \(url.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("This doesn't look like a Google Sheets link.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Stepper("Auto-refresh every \(minutes) min", value: $minutes, in: 1...240)

            Toggle("Open Stock Screener at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { newValue in
                    loginMessage = LoginItem.set(newValue)
                    if loginMessage == nil && newValue && LoginItem.needsApproval {
                        loginMessage = "Approve it in System Settings → General → Login Items."
                    }
                    openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
                }
            if let loginMessage {
                Text(loginMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            Text("Is the data updated?")
                .font(.headline)

            Stepper("Warn if no new data for \(staleHours) hours", value: $staleHours, in: 1...168)

            Picker("Date column (optional)", selection: $dateColumn) {
                Text("None").tag("")
                if !dateColumn.isEmpty && !vm.headers.contains(dateColumn) {
                    Text(dateColumn).tag(dateColumn)
                }
                ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
            }
            Text("If your sheet has a date column, pick it. The app then warns when the newest row isn't from the latest weekday. Exchange holidays aren't known yet. Column names appear here after the first download.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    vm.updateSource(link: link, minutes: minutes, staleHours: staleHours, dateColumn: dateColumn)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(SheetService.csvURL(from: link) == nil)
            }
        }
        .padding(24)
        .frame(width: 580)
        .onAppear {
            link = vm.settings.sheetLink
            minutes = vm.settings.refreshMinutes
            staleHours = vm.settings.staleAfterHours
            dateColumn = vm.settings.dateColumn
            openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
        }
    }
}
