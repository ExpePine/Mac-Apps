import AppKit
import SwiftUI

struct EmailSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var reports: ReportService
    @ObservedObject var tracker: UsageTracker

    @State private var smtpPassword = Keychain.get(Keychain.smtpPassword)
    @State private var groqKey = Keychain.get(Keychain.groqAPIKey)

    private var sendTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: settings.reportHour, minute: settings.reportMinute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings.reportHour = c.hour ?? 8
                settings.reportMinute = c.minute ?? 0
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Email me a summary of yesterday every morning", isOn: $settings.reportEnabled)
                DatePicker("Send at", selection: sendTime, displayedComponents: .hourAndMinute)
                TextField("Send to", text: $settings.reportRecipient, prompt: Text("you@example.com"))
                Toggle("Skip days with no entries", isOn: $settings.reportSkipEmptyDays)
            } header: {
                Text("Daily summary")
            } footer: {
                Text("If your Mac is asleep at the send time, the email goes out as soon as it wakes. Separate several addresses with commas.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("SMTP server", text: $settings.smtpHost)
                TextField("Port", value: $settings.smtpPort, format: .number.grouping(.never))
                TextField("Your email (login)", text: $settings.smtpUsername, prompt: Text("you@gmail.com"))
                SecureField("App password", text: Binding(
                    get: { smtpPassword },
                    set: { smtpPassword = $0; Keychain.set($0, for: Keychain.smtpPassword) }
                ))
            } header: {
                Text("Email account (sends the email)")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gmail: use smtp.gmail.com, port 465, and an App Password (needs 2-Step Verification). Your normal Gmail password will not work.")
                    Link("Create a Gmail App Password", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                }
                .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Groq API key", text: Binding(
                    get: { groqKey },
                    set: { groqKey = $0; Keychain.set($0, for: Keychain.groqAPIKey) }
                ))
                TextField("Model", text: $settings.groqModel)
            } header: {
                Text("AI summary (Groq)")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Without a key, you still get the email with your full log, just no AI summary.")
                    Link("Get a free Groq API key", destination: URL(string: "https://console.groq.com/keys")!)
                }
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Ask for today's goals each morning", isOn: $settings.askGoalsMorning)
                Toggle("Compare each check-in with my goals", isOn: $settings.coachChecksEnabled)
            } header: {
                Text("Coach")
            } footer: {
                Text("When a check-in looks off-plan, you'll be asked what happened. Uses your Groq API key below.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Track active time on websites and apps", isOn: $settings.trackUsage)
                Toggle("Include it in the daily email", isOn: $settings.includeUsageInEmail)
                Stepper("Idle after \(settings.idleMinutes) min without keyboard/mouse",
                        value: $settings.idleMinutes, in: 1...15)
                TextField("Hide these sites", text: $settings.excludedDomains,
                          prompt: Text("e.g. hdfcbank.com, mail.google.com"))
                if !tracker.deniedBrowsers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No permission to read the tab in: \(tracker.deniedBrowsers.joined(separator: ", "))")
                            .foregroundStyle(.red)
                        Text("Turn it on in System Settings → Privacy & Security → Automation → Activity Logger.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if tracker.today.activeSeconds >= 60 {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Today so far: \(durationText(tracker.today.activeSeconds)) active").bold()
                        ForEach(tracker.today.top(tracker.today.sites, 5), id: \.name) { item in
                            Text("\(durationText(item.seconds))  \(item.name)").monospacedDigit()
                        }
                        ForEach(tracker.today.top(tracker.today.apps, 5), id: \.name) { item in
                            Text("\(durationText(item.seconds))  \(item.name)")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            } header: {
                Text("Website & app tracking")
            } footer: {
                Text("Works with Safari, Chrome, Edge, Brave, Arc, Vivaldi and Opera (each asks permission once). Firefox counts as app time only. Only domain names are stored, on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Send test email now") {
                        Task { await reports.sendTest() }
                    }
                    .disabled(reports.isSending)
                    if reports.isSending {
                        ProgressView().controlSize(.small)
                        Text("Sending…").foregroundStyle(.secondary)
                    }
                }
                Text(reports.lastStatus)
                    .font(.callout)
                    .foregroundStyle(reports.lastStatus.lowercased().contains("fail")
                                     || reports.lastStatus.hasPrefix("Add")
                                     || reports.lastStatus.hasPrefix("Fill") ? .red : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Test")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
    }
}
