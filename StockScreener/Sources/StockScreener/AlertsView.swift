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
                .tabItem { Label("Email & alert rules", systemImage: "bell.badge") }
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
                LabeledContent("Days", value: "Emails Monday–Friday only")
                TextField("Email subject", text: $vm.settings.mv2.subject)
            } footer: {
                Text("Runs each time new data arrives in the sheet. It counts how many rows have \(vm.settings.mv2.monthColumn) / \(vm.settings.mv2.dayColumn) that don't match today's date. If any don't, it emails \"\(vm.settings.mv2.subject)\" with the count and examples, at most once a day and only Monday–Friday (no email on Sat/Sun). Months can be 10 or Oct; days can be 17 or Sat.")
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

struct BuyTriggersTab: View {
    @EnvironmentObject var vm: ScreenerViewModel
    var showIntro = true

    var body: some View {
        Form {
            if showIntro {
                Section {
                    Text("Each rule watches for stocks that meet its conditions — combine any columns with AND / OR / NOT groups, compare one column with another (e.g. CLOSE > EMA_20 × 1.02), or write a formula. When it's met the app can **Email** you (each stock at most once a day) and/or **Alert** you in the app: a pop-up when the app opens and a banner whenever new data arrives.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if vm.settings.email.username.isEmpty {
                        Label("Email isn't set up yet — add your Gmail and App Password in Alerts & Email → Email.",
                              systemImage: "envelope.badge")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            ForEach($vm.settings.buyTriggers) { $trigger in
                Section {
                    HStack {
                        Toggle("", isOn: $trigger.isEnabled).labelsHidden()
                            .help("Turn this rule on/off")
                        TextField("Name", text: $trigger.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.headline)
                        Button(role: .destructive) {
                            vm.settings.buyTriggers.removeAll { $0.id == trigger.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete rule")
                    }

                    HStack(spacing: 16) {
                        Toggle(isOn: $trigger.sendEmail) { Label("Email", systemImage: "envelope") }
                        Toggle(isOn: $trigger.alertInApp) { Label("Alert in app", systemImage: "bell") }
                    }
                    .toggleStyle(.checkbox)

                    FilterGroupEditor(group: $trigger.filter, columns: vm.headers, isRoot: true, onDelete: {})

                    ForEach(vm.triggerIssues(trigger), id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    if trigger.sendEmail {
                        TextField("Send to (optional)", text: $trigger.recipients,
                                  prompt: Text("Uses the Email tab's addresses if empty"))
                    }

                    HStack {
                        let count = vm.triggerMatchCounts[trigger.id] ?? 0
                        Text(trigger.filter.activeCount == 0 ? "Add at least one condition."
                                                             : "\(count) stock\(count == 1 ? "" : "s") match right now")
                            .font(.caption)
                            .foregroundStyle(count > 0 ? .green : .secondary)
                        Spacer()
                        if trigger.alertInApp {
                            Button("Alert now") { vm.raiseInAppAlerts(asPopup: true) }
                                .disabled(trigger.filter.activeCount == 0)
                                .help("Show the in-app alert for all rules that are met right now")
                        }
                        if trigger.sendEmail {
                            Button("Email now") { Task { await vm.checkBuyTrigger(trigger, force: true) } }
                                .disabled(vm.isSendingEmail || trigger.filter.activeCount == 0)
                                .help("Emails every stock that matches right now")
                        }
                    }
                } header: {
                    HStack {
                        Text(trigger.name.isEmpty ? "Rule" : trigger.name)
                        Spacer()
                        FormulaHelpButton()
                    }
                }
                .opacity(trigger.isEnabled ? 1 : 0.6)
            }

            Section {
                HStack {
                    Button {
                        var t = BuyTrigger(isEnabled: true, name: "Rule \(vm.settings.buyTriggers.count + 1)")
                        t.filter = vm.settings.filterGroup
                        vm.settings.buyTriggers.append(t)
                    } label: {
                        Label("New rule from the Filter screen's conditions", systemImage: "square.and.arrow.down.on.square")
                    }
                    .help("Copies the conditions currently set on the Filter screen into a new rule")
                    Spacer()
                    Button {
                        vm.settings.buyTriggers.append(BuyTrigger(isEnabled: true,
                                                                  name: "Rule \(vm.settings.buyTriggers.count + 1)"))
                    } label: {
                        Label("Empty rule", systemImage: "plus.circle")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The "E" sheet on the Filter screen.
struct EmailRulesSheet: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Email & alert rules", systemImage: "envelope.badge")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            BuyTriggersTab()
        }
        .frame(width: 640, height: 640)
    }
}

/// Pop-up / list of rules that are met right now.
struct ConditionsMetView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Conditions met", systemImage: "bell.badge.fill")
                .font(.title2.bold())
                .foregroundStyle(.orange)
            if vm.inAppAlerts.isEmpty {
                Text("None of your rules are met right now.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(vm.inAppAlerts) { alert in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(alert.name) — \(alert.stocks.count) stock\(alert.stocks.count == 1 ? "" : "s")")
                                .font(.headline)
                            FlowList(items: alert.stocks) { stock in
                                vm.selectedStock = stock
                                dismiss()
                                openWindow(id: "alertlog")
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            Text("Click a stock to see it in the Alerts list.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Edit rules…") {
                    dismiss()
                    openWindow(id: "filter")
                    vm.showRulesEditor = true
                }
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Wrapping row of small stock buttons.
struct FlowList: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button(item) { onTap(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
            }
        }
    }
}

/// Banner shown when new data meets a rule.
struct AlertsBanner: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        if vm.showAlertsBanner && !vm.inAppAlerts.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                Text(vm.inAppAlerts.map { "\($0.name): \($0.stocks.prefix(4).joined(separator: ", "))\($0.stocks.count > 4 ? " +\($0.stocks.count - 4)" : "")" }
                        .joined(separator: "   ·   "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button("View") { vm.showAlertsPopup = true }
                Button { vm.showAlertsBanner = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.14))
        }
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
