import AppKit
import SwiftUI

struct PromptView: View {
    @ObservedObject var session: PromptSession
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            editor
            recordingRow
            if let msg = session.errorMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { editorFocused = true }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What did you do?")
                    .font(.title2.weight(.semibold))
                Text(session.prompt.rangeText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            CountdownRing(remaining: session.remaining, total: session.totalSeconds)
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $session.text)
                .font(.body)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
            if session.text.isEmpty {
                Text("Type here, or press Record and just talk…")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 140)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }

    private var recordingRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await session.toggleRecording() }
            } label: {
                Label(session.isRecording ? "Stop" : "Record",
                      systemImage: session.isRecording ? "stop.circle.fill" : "mic.circle.fill")
            }
            .tint(session.isRecording ? .red : .accentColor)
            .disabled(session.isTranscribing)
            .keyboardShortcut("r", modifiers: .command)

            if session.isRecording {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(mmss(session.recordingSeconds)).monospacedDigit()
            } else if session.isTranscribing {
                ProgressView().controlSize(.small)
                Text("Converting speech to text…").foregroundStyle(.secondary)
            } else if session.hasAudio {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text("Voice note attached").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var buttons: some View {
        HStack {
            Button("Skip") { session.finish(.skipped) }
            Button("+1 min") { session.extend() }
            Spacer()
            Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
            Button("Save") { session.finish(.completed) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!session.canSave)
        }
    }
}

struct CountdownRing: View {
    let remaining: Int
    let total: Int

    private var fraction: Double { total > 0 ? Double(remaining) / Double(total) : 0 }
    private var color: Color { remaining <= 30 ? .red : .accentColor }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
            Text(mmss(remaining))
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel("\(remaining) seconds left")
    }
}
