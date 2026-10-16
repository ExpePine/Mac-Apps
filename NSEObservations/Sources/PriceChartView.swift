import SwiftUI
import Charts

enum ChartStyle: String, CaseIterable, Identifiable {
    case line, candles
    var id: String { rawValue }
    var systemImage: String { self == .line ? "chart.xyaxis.line" : "chart.bar.xaxis" }
    var title: String { self == .line ? "Line" : "Candles" }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case m1 = "1M", m3 = "3M", m6 = "6M", y1 = "1Y", y2 = "2Y", y5 = "5Y", notes = "Notes"
    var id: String { rawValue }

    func startDate(firstNote: Date?) -> Date {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .m1: return cal.date(byAdding: .month, value: -1, to: now) ?? now
        case .m3: return cal.date(byAdding: .month, value: -3, to: now) ?? now
        case .m6: return cal.date(byAdding: .month, value: -6, to: now) ?? now
        case .y1: return cal.date(byAdding: .year, value: -1, to: now) ?? now
        case .y2: return cal.date(byAdding: .year, value: -2, to: now) ?? now
        case .y5: return cal.date(byAdding: .year, value: -5, to: now) ?? now
        case .notes:
            let base = firstNote ?? (cal.date(byAdding: .month, value: -6, to: now) ?? now)
            return cal.date(byAdding: .day, value: -21, to: base) ?? base
        }
    }
}

private struct ChartMarker: Identifiable {
    let id: UUID
    let date: Date
    let price: Double
    let color: Color
    let label: String
    let isTrade: Bool
}

struct PriceChartView: View {
    let candles: [Candle]
    let observations: [Observation]
    let trades: [Trade]
    let style: ChartStyle

    @State private var hover: Candle?

    private var lo: Double { candles.map(\.low).min() ?? 0 }
    private var hi: Double { candles.map(\.high).max() ?? 1 }
    private var pad: Double { max((hi - lo) * 0.08, hi * 0.005) }

    /// Close of the first session on/after `date`, if it falls inside the visible range.
    private func priceOn(_ date: Date) -> (Date, Double)? {
        let day = Calendar.ist.startOfDay(for: date)
        guard let first = candles.first, day >= first.date,
              let c = candles.first(where: { $0.date >= day }) else { return nil }
        return (c.date, c.close)
    }

    private var markers: [ChartMarker] {
        var out: [ChartMarker] = []
        for o in observations {
            if let hit = priceOn(o.date) {
                out.append(ChartMarker(id: o.id, date: hit.0, price: hit.1, color: o.sentiment.color,
                                       label: o.text, isTrade: false))
            }
        }
        for t in trades {
            if let hit = priceOn(t.date) {
                out.append(ChartMarker(id: t.id, date: hit.0, price: t.price, color: t.side.color,
                                       label: "\(t.side.title) \(AIContext.formatQty(t.quantity)) @ \(Fmt.rupees(t.price))",
                                       isTrade: true))
            }
        }
        return out
    }

    var body: some View {
        let markers = self.markers
        Chart {
            if style == .line {
                ForEach(candles) { c in
                    AreaMark(x: .value("Date", c.date),
                             yStart: .value("Base", lo - pad),
                             yEnd: .value("Close", c.close))
                        .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", c.date), y: .value("Close", c.close))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            } else {
                ForEach(candles) { c in
                    RuleMark(x: .value("Date", c.date, unit: .day),
                             yStart: .value("Low", c.low),
                             yEnd: .value("High", c.high))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(c.close >= c.open ? Color.green : Color.red)
                    RectangleMark(x: .value("Date", c.date, unit: .day),
                                  yStart: .value("Open", c.open),
                                  yEnd: .value("Close", c.close == c.open ? c.open + (hi - lo) * 0.001 : c.close),
                                  width: .ratio(0.7))
                        .foregroundStyle(c.close >= c.open ? Color.green : Color.red)
                }
            }

            ForEach(markers) { m in
                PointMark(x: .value("Date", m.date), y: .value("Price", m.price))
                    .symbol(m.isTrade ? BasicChartSymbolShape.triangle : BasicChartSymbolShape.circle)
                    .symbolSize(m.isTrade ? 90 : 70)
                    .foregroundStyle(m.color)
            }

            if let h = hover {
                RuleMark(x: .value("Date", h.date))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let origin = geo[proxy.plotAreaFrame].origin
                            if let date: Date = proxy.value(atX: location.x - origin.x) {
                                hover = nearest(to: date)
                            }
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let h = hover {
                HoverCard(candle: h, notes: markers.filter { $0.date == h.date })
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func nearest(to date: Date) -> Candle? {
        guard !candles.isEmpty else { return nil }
        // Candles are sorted by date: binary search for the closest one.
        var lo = 0, hi = candles.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if candles[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(candles[lo - 1].date.timeIntervalSince(date)) < abs(candles[lo].date.timeIntervalSince(date)) {
            return candles[lo - 1]
        }
        return candles[lo]
    }
}

private struct HoverCard: View {
    let candle: Candle
    let notes: [ChartMarker]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Fmt.day.string(from: candle.date))
                .font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 1) {
                GridRow { label("O"); value(candle.open); label("H"); value(candle.high) }
                GridRow { label("L"); value(candle.low); label("C"); value(candle.close) }
            }
            ForEach(notes) { n in
                HStack(alignment: .top, spacing: 5) {
                    Circle().fill(n.color).frame(width: 6, height: 6).padding(.top, 4)
                    Text(n.label).font(.caption).lineLimit(3)
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.quaternary))
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary)
    }

    private func value(_ v: Double) -> some View {
        Text(Fmt.price.string(from: NSNumber(value: v)) ?? "").font(.caption.monospacedDigit())
    }
}
