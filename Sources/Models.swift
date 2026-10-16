import Foundation

/// One check-in slot: "what did you do between `start` and `end`?"
struct Prompt: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date

    var rangeText: String {
        let s = start.formatted(date: .omitted, time: .shortened)
        let e = end.formatted(date: .omitted, time: .shortened)
        let mins = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
        return "\(s) – \(e)  (\(mins) min)"
    }
}

/// A saved log entry. `id` is the same as the Prompt it answers.
struct Entry: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case completed      // saved by the user
        case quickReply     // typed directly into the notification
        case autoSaved      // entry window timed out, partial input saved
        case skipped        // user pressed Skip
        case missed         // no response at all

        var label: String {
            switch self {
            case .completed: return "Saved"
            case .quickReply: return "Quick reply"
            case .autoSaved: return "Auto-saved"
            case .skipped: return "Skipped"
            case .missed: return "Missed"
            }
        }
    }

    var id: UUID
    var periodStart: Date
    var periodEnd: Date
    var savedAt: Date
    var text: String
    var transcript: String?
    var audioFileName: String?
    var status: Status
    var transcriptPending: Bool

    // Coach: goal alignment for this check-in
    var goalAligned: Bool? = nil          // nil = not checked
    var alignedGoal: String? = nil
    var deviationNote: String? = nil      // why the coach thinks it's off-plan
    var explanation: String? = nil        // what the user said happened
    var explanationAccepted: Bool? = nil
    var coachFeedback: String? = nil

    init(prompt: Prompt,
         text: String,
         status: Status,
         audioFileName: String? = nil,
         transcript: String? = nil,
         transcriptPending: Bool = false) {
        self.id = prompt.id
        self.periodStart = prompt.start
        self.periodEnd = prompt.end
        self.savedAt = Date()
        self.text = text
        self.transcript = transcript
        self.audioFileName = audioFileName
        self.status = status
        self.transcriptPending = transcriptPending
    }

    var timeRangeText: String {
        let s = periodStart.formatted(date: .omitted, time: .shortened)
        let e = periodEnd.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(e)"
    }
}

func mmss(_ seconds: Int) -> String {
    String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
}
