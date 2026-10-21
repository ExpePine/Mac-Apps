import SwiftUI
import SamsaraCore

enum Theme {
    static let accent = Color(red: 0.93, green: 0.42, blue: 0.16)   // saffron

    static let palette: [Color] = [
        Color(red: 0.93, green: 0.42, blue: 0.16),
        Color(red: 0.16, green: 0.55, blue: 0.80),
        Color(red: 0.20, green: 0.65, blue: 0.42),
        Color(red: 0.62, green: 0.38, blue: 0.80),
        Color(red: 0.86, green: 0.30, blue: 0.42),
        Color(red: 0.85, green: 0.65, blue: 0.13),
        Color(red: 0.10, green: 0.62, blue: 0.62),
        Color(red: 0.52, green: 0.45, blue: 0.36),
        Color(red: 0.36, green: 0.42, blue: 0.86),
        Color(red: 0.55, green: 0.66, blue: 0.20),
    ]

    /// Stable colour per name (String.hashValue changes every launch, so hash by hand).
    static func color(for key: String) -> Color {
        var h = 5381
        for s in key.lowercased().unicodeScalars { h = ((h << 5) &+ h &+ Int(s.value)) & 0x7fffffff }
        return palette[h % palette.count]
    }

    static func tone(_ t: Insight.Tone) -> Color {
        switch t {
        case .info: return .blue
        case .good: return .green
        case .warning: return .orange
        }
    }

    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
}

struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

struct KPICard: View {
    let title: String
    let value: String
    let symbol: String
    var footnote: String? = nil
    var footColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(footnote ?? " ")
                .font(.caption)
                .foregroundStyle(footColor)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.symbol)
                .font(.title2)
                .foregroundStyle(Theme.tone(insight.tone))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title).font(.body.weight(.semibold))
                Text(insight.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.tone(insight.tone).opacity(0.08)))
    }
}

/// A thin proportional bar used in lists.
struct ShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color).frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

extension Double {
    var signedPercentText: String {
        (self >= 0 ? "+" : "−") + Money.percent(abs(self))
    }
}
