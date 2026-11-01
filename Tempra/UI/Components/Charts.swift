import Charts
import SwiftUI

/// Time windows offered by history charts.
enum TimeRange: String, CaseIterable, Identifiable {
    case m15 = "15m", h1 = "1h", h6 = "6h", h24 = "24h", d7 = "7d", d30 = "30d"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .m15: 15 * 60
        case .h1: 3600
        case .h6: 6 * 3600
        case .h24: 24 * 3600
        case .d7: 7 * 86400
        case .d30: 30 * 86400
        }
    }

    /// Averaging bucket that keeps charts around 200–400 points.
    var bucket: TimeInterval {
        switch self {
        case .m15: 3
        case .h1: 15
        case .h6: 60
        case .h24: 300
        case .d7: 1800
        case .d30: 7200
        }
    }

    var refreshInterval: TimeInterval { self <= .h1 ? 5 : 60 }

    static func <= (lhs: TimeRange, rhs: TimeRange) -> Bool { lhs.seconds <= rhs.seconds }
}

/// Tiny line chart without axes, used in tiles.
struct Sparkline: View {
    let points: [ChartPoint]
    let color: Color
    var domain: ClosedRange<Double>?

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain ?? autoDomain)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.clipped() }
    }

    private var autoDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.15, abs(hi) * 0.05, 0.001)
        return (lo - pad)...(hi + pad)
    }
}

/// History chart for one metric with an optional Timestral forecast band appended on the right.
struct HistoryChart: View {
    let metric: Metric
    let range: TimeRange
    var forecast: Forecast?
    var height: CGFloat = 180

    @State private var points: [ChartPoint] = []
    @State private var powerSpans: [PowerSpan] = []
    @State private var hover: Date?
    private let monitor = SystemMonitor.shared

    /// A stretch of time on the power adapter, shaded on the battery chart.
    struct PowerSpan: Identifiable {
        enum Kind: CaseIterable {
            case charging, notCharging

            var label: String { self == .charging ? "Charging" : "On adapter, not charging" }
            var color: Color { self == .charging ? .green : .yellow }
            var opacity: Double { self == .charging ? 0.16 : 0.18 }
        }

        var id: Date { start }
        let kind: Kind
        let start: Date
        var end: Date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chart
            if !powerSpans.isEmpty {
                HStack(spacing: 14) {
                    ForEach(PowerSpan.Kind.allCases.filter { kind in powerSpans.contains { $0.kind == kind } }, id: \.self) { kind in
                        Label {
                            Text(kind.label)
                        } icon: {
                            RoundedRectangle(cornerRadius: 2).fill(kind.color.opacity(kind.opacity * 2.2)).frame(width: 14, height: 9)
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        let forecastPoints = visibleForecast
        let domain = metric.yDomain ?? autoDomain(forecastPoints)
        return Chart {
            ForEach(powerSpans) { span in
                RectangleMark(xStart: .value("From", span.start), xEnd: .value("To", span.end),
                              yStart: .value("Bottom", domain.lowerBound), yEnd: .value("Top", domain.upperBound))
                    .foregroundStyle(span.kind.color.opacity(span.kind.opacity))
            }
            ForEach(points) { point in
                // Fill down to the axis minimum (not zero) so the area never spills below the plot.
                AreaMark(x: .value("Time", point.date), yStart: .value("Base", domain.lowerBound),
                         yEnd: .value(metric.title, point.value), series: .value("Series", "history"))
                    .foregroundStyle(LinearGradient(colors: [metric.color.opacity(0.25), metric.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value(metric.title, point.value), series: .value("Series", "history"))
                    .foregroundStyle(metric.color)
                    .interpolationMethod(.monotone)
            }
            ForEach(forecastPoints) { p in
                AreaMark(x: .value("Time", p.date), yStart: .value("Low", p.low), yEnd: .value("High", p.high),
                         series: .value("Series", "band"))
                    .foregroundStyle(metric.color.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Forecast", p.median), series: .value("Series", "forecast"))
                    .foregroundStyle(metric.color.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.monotone)
            }
            if let now = forecastPoints.first?.date {
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .trailing, alignment: .top, spacing: 4) {
                        Text("Forecast").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let hover, let label = label(at: hover) {
                RuleMark(x: .value("Selected", hover))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(label).font(.caption.monospacedDigit().weight(.semibold))
                            Text(hover, format: range <= .h24 ? .dateTime.hour().minute() : .dateTime.month().day().hour())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(metric.format(v)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: range <= .h24 ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                    .font(.caption2)
            }
        }
        .chartXSelection(value: $hover)
        .frame(height: height)
        .overlay {
            if points.isEmpty {
                Text("Collecting data…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(metric.rawValue)-\(range.rawValue)") {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(range.refreshInterval))
            }
        }
    }

    /// Forecast points after the latest real sample, starting from that sample so the dashed
    /// median and the band fan out of the history line instead of overlapping it. Forecasts are
    /// computed periodically, so their first steps may already be in the past.
    private var visibleForecast: [Forecast.Point] {
        guard let forecast, range <= .h24, let last = points.last else { return [] }
        // Show at most half of the visible window into the future so history stays readable.
        let end = last.date.addingTimeInterval(max(range.seconds * 0.5, forecast.step * 6))
        let future = forecast.points().filter { $0.date > last.date && $0.date <= end }
        guard !future.isEmpty else { return [] }
        return [Forecast.Point(date: last.date, median: last.value, low: last.value, high: last.value)] + future
    }

    private func load() async {
        let to = Date()
        let from = to.addingTimeInterval(-range.seconds)
        points = await monitor.store.series(metric, from: from, to: to, bucket: range.bucket)
        if metric == .batteryPercent {
            let store = monitor.store
            async let adapter = store.series(.onAC, from: from, to: to, bucket: range.bucket)
            async let charging = store.series(.charging, from: from, to: to, bucket: range.bucket)
            async let batteryPower = store.series(.batteryPower, from: from, to: to, bucket: range.bucket)
            powerSpans = Self.spans(adapter: await adapter, charging: await charging,
                                    batteryPower: await batteryPower, bucket: range.bucket)
        }
    }

    /// Merges buckets where the Mac was mostly on the adapter into continuous spans, split by
    /// whether the battery was charging. History recorded before the charging state was stored
    /// falls back to the battery's power flow (charging = energy going in).
    private static func spans(adapter: [ChartPoint], charging: [ChartPoint], batteryPower: [ChartPoint],
                              bucket: TimeInterval) -> [PowerSpan] {
        let chargingByDate = Dictionary(charging.map { ($0.date, $0.value) }, uniquingKeysWith: { a, _ in a })
        let powerByDate = Dictionary(batteryPower.map { ($0.date, $0.value) }, uniquingKeysWith: { a, _ in a })
        var spans: [PowerSpan] = []
        for point in adapter where point.value >= 0.5 {
            let isCharging = chargingByDate[point.date].map { $0 >= 0.5 } ?? ((powerByDate[point.date] ?? 0) > 0.5)
            let kind: PowerSpan.Kind = isCharging ? .charging : .notCharging
            let end = point.date.addingTimeInterval(bucket)
            if let last = spans.last, last.kind == kind, point.date.timeIntervalSince(last.end) <= bucket * 1.5 {
                spans[spans.count - 1].end = end
            } else {
                spans.append(PowerSpan(kind: kind, start: point.date, end: end))
            }
        }
        return spans
    }

    private func label(at date: Date) -> String? {
        if let p = points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
           abs(p.date.timeIntervalSince(date)) < range.bucket * 3 {
            return metric.format(p.value)
        }
        if let p = visibleForecast.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) {
            return "≈ \(metric.format(p.median)) (\(metric.format(p.low))–\(metric.format(p.high)))"
        }
        return nil
    }

    private func autoDomain(_ forecast: [Forecast.Point]) -> ClosedRange<Double> {
        let values = points.map(\.value) + forecast.flatMap { [$0.low, $0.high] }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.1, abs(hi) * 0.05, 0.001)
        let lower = metric.unit == .celsius ? lo - pad : max(0, lo - pad)
        return lower...(hi + pad)
    }
}
