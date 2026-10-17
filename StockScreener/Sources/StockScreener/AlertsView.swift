import SwiftUI

/// "Alerts & Email" window: email setup, the MV2 date check, buy triggers, and a history log.
struct AlertsView: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        TabView {
            EmailSettingsTab()
                .tabItem { Label("Email", systemImage: "envelope") }
            MV2CheckTab()
                .tabItem { Label("MV2 check", systemImage: "calendar.badge.exclamationmark") }
            BuyTriggersTab()
                .tabItem { Label("Buy triggers", systemImage: "bell.badge") }
            AlertHistoryTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .padding(12)
        .navigationTitle("Alerts & Email")
    }
}

// MARK: - Email

private struct EmailSettingsTab: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @State private var password = Keychain.get(Keychain.smtpPassword)

    var body: some View {
        Form {
            Section {
                TextField("SMTP server", text: $vm.settings.email.host)
                TextField("Port", value: $vm.settings.email.port, format: .number.grouping(.never))
                TextField("Your email (login)", text: $vm.settings.email.username, prompt: Text("you@gmail.com"))
                SecureField("App Password", text: Binding(
                    get: { password },
                    set: { password = $0; Keychain.set($0, for: Keychain.smtpPassword) }
                ))
            } header: {
                Text("Sending account")
            } footer: {
                Text("Gmail: smtp.gmail.com, port 465, and an App Password (needs 2-Step Verification). Your normal Gmail password won't work. The password is stored in your Mac's Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Send alerts to", text: $vm.settings.email.recipients,
                          prompt: Text("me@example.com, partner@example.com"))
            } footer: {
                Text("Separate several addresses with commas. Leave empty to send to yourself.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Send test email") { Task { await vm.sendTestEmail() } }
                        .disabled(vm.isSendingEmail)
                    if vm.isSendingEmail { ProgressView().controlSize(.small) }
                    Spacer()
                    if let last = vm.alertState.log.first(where: { $0.title == "Test email" }) {
                        Label(last.success ? "Sent" : "Failed", systemImage: last.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(last.success ? .green : .red)
                            .help(last.detail)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - MV2 check

private struct MV2CheckTab: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Email me when MV2 is not updated", isOn: $vm.settings.mv2.isEnabled)
                ColumnPicker(title: "Month column", selection: $vm.settings.mv2.monthColumn)
                ColumnPicker(title: "Day column", selection: $vm.settings.mv2.dayColumn)
                Toggle("Skip weekends", isOn: $vm.settings.mv2.skipWeekends)
                TextField("Email subject", text: $vm.settings.mv2.subject)
            } footer: {
                Text("Runs each time new data arrives in the sheet. On weekends (when skipped) Friday's date counts as current. If no row's \(vm.settings.mv2.monthColumn) and \(vm.settings.mv2.dayColumn) match today's date, it emails \"\(vm.settings.mv2.subject)\" — at most once a day. Months can be 10 or Oct; days can be 17 or Sat.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Right now") {
                let status = vm.mv2Status()
                Label(status.text, systemImage: icon(status.state))
                    .foregroundStyle(color(status.state))
                if vm.alertState.mv2Alerted {
                    Text("Alert email already sent today.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check now") { Task { await vm.checkMV2(force: true) } }
                        .disabled(vm.isSendingEmail)
                        .help("Runs the check immediately and emails if MV2 isn't dated today")
                    if vm.isSendingEmail { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func icon(_ s: MV2Status.State) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .notUpdated: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(_ s: MV2Status.State) -> Color {
        switch s {
        case .ok: return .green
        case .notUpdated: return .orange
        case .unknown: return .secondary
        }
    }
}

// MARK: - Buy triggers

private struct BuyTriggersTab: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        Form {
            Section {
                Text("A buy trigger emails you when stocks meet all (or any) of its conditions across several columns. It's checked each time new data arrives; each stock is emailed at most once a day per trigger.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($vm.settings.buyTriggers) { $trigger in
                Section {
                    HStack {
                        Toggle("", isOn: $trigger.isEnabled).labelsHidden()
                            .help("Turn this trigger on/off")
                        TextField("Name", text: $trigger.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.headline)
                        Button(role: .destructive) {
                            vm.settings.buyTriggers.removeAll { $0.id == trigger.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete trigger")
                    }

                    Picker("Match", selection: $trigger.matchMode) {
                        ForEach(MatchMode.allCases) { Text($0.rawValue).tag($0) }
                    }

                    ForEach($trigger.conditions) { $rule in
                        RuleRow(rule: $rule, columns: vm.headers, showColor: false) {
                            $trigger.conditions.wrappedValue.removeAll { $0.id == rule.id }
                        }
                    }
                    Button {
                        $trigger.conditions.wrappedValue.append(Rule(column: vm.headers.first ?? ""))
                    } label: {
                        Label("Add condition", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)

                    TextField("Send to (optional)", text: $trigger.recipients,
                              prompt: Text("Uses the Email tab's addresses if empty"))

                    HStack {
                        let count = vm.buyMatches(trigger).count
                        Text(trigger.conditions.isEmpty ? "Add at least one condition."
                                                        : "\(count) stock\(count == 1 ? "" : "s") match right now")
                            .font(.caption)
                            .foregroundStyle(count > 0 ? .green : .secondary)
                        Spacer()
                        Button("Check now") { Task { await vm.checkBuyTrigger(trigger, force: true) } }
                            .disabled(vm.isSendingEmail || trigger.conditions.isEmpty)
                            .help("Emails every stock that matches right now")
                    }
                }
                .opacity(trigger.isEnabled ? 1 : 0.6)
            }

            Section {
                Button {
                    vm.settings.buyTriggers.append(BuyTrigger(isEnabled: false,
                                                              name: "Buy trigger \(vm.settings.buyTriggers.count + 1)"))
                } label: {
                    Label("Add another trigger", systemImage: "plus.circle")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

private struct AlertHistoryTab: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.alertState.log.isEmpty {
                Text("No alerts yet. Checks run each time new data arrives in the sheet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.alertState.log) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(entry.success ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.title).fontWeight(.semibold)
                                Spacer()
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.detail).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Spacer()
                    Button("Clear history") { vm.alertState.log.removeAll() }
                }
            }
        }
    }
}

// MARK: - Shared

/// Picker over the sheet's columns that keeps a typed name even if the column isn't in the data yet.
struct ColumnPicker: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            if !vm.headers.contains(selection) {
                Text(selection.isEmpty ? "Choose…" : "\(selection)\(vm.resolveColumn(selection) == nil ? " (not found)" : "")")
                    .tag(selection)
            }
            ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
        }
    }
}
