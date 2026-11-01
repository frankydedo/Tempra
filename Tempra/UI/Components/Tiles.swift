import SwiftUI

/// Compact metric tile used in the menu bar summary and the dashboard overview.
struct StatTile: View {
    let title: String
    let systemImage: String
    let value: String
    var detail: String?
    var color: Color = .accentColor
    var points: [ChartPoint] = []
    var domain: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if !points.isEmpty {
                Sparkline(points: points, color: color, domain: domain)
                    .frame(height: 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Card container with a title, used throughout the dashboard.
struct Card<Content: View>: View {
    let title: String
    var systemImage: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let systemImage {
                    Label(title, systemImage: systemImage).font(.headline)
                } else {
                    Text(title).font(.headline)
                }
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Label/value row for detail lists.
struct InfoRow: View {
    let label: String
    let value: String
    var color: Color?

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(color ?? .primary)
        }
        .font(.callout)
    }
}

/// Large number with a caption underneath.
struct BigStat: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Horizontal stacked bar (e.g. memory breakdown).
struct SegmentBar: View {
    struct Segment: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments) { s in
                        Rectangle()
                            .fill(s.color)
                            .frame(width: max(0, geo.size.width * s.value / max(total, 1)))
                    }
                    Spacer(minLength: 0)
                }
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 12)
            HStack(spacing: 12) {
                ForEach(segments) { s in
                    HStack(spacing: 4) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                        Text(s.label).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

extension Snapshot {
    var batteryStateText: String {
        guard let b = battery else { return "No battery" }
        if b.isCharging { return "Charging" }
        if b.onAC { return b.percent >= 99 || b.isFullyCharged ? "Fully charged" : "On adapter, not charging" }
        return "On battery"
    }

    var thermalStateText: String {
        switch thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

extension Forecast {
    /// Human readable battery prediction, e.g. "Empty in ~2h 10m (1h 50m–2h 40m)".
    var batteryText: String? {
        guard let s = summary else { return nil }
        switch s.kind {
        case "held":
            let level = s.percent.map { String(format: "Held at %.0f%%", $0) } ?? "On adapter"
            guard let unplugged = s.ifUnplugged.flatMap({ Self.etaText($0, horizon: s.horizon) }) else { return level }
            return "\(level) · \(unplugged) on battery"
        case "time_to_full":
            return Self.etaText(s.eta, horizon: s.horizon).map { "Full in \($0)" }
        default:
            return Self.etaText(s.eta, horizon: s.horizon).map { "Empty in \($0)" }
        }
    }

    /// Battery life if unplugged now, shown while charging or on the adapter.
    var unpluggedText: String? {
        guard let s = summary, s.kind != "time_to_empty", let eta = s.ifUnplugged else { return nil }
        return Self.etaText(eta, horizon: s.horizon).map { "\($0) if unplugged now" }
    }

    /// "~2h 10m (1h 50m–2h 40m)", "~2h 10m (at least 1h 50m)" or "more than 12h".
    private static func etaText(_ eta: ETA, horizon: Double?) -> String? {
        guard let seconds = eta.seconds else {
            return horizon.map { "more than \(Format.duration(seconds: $0))" }
        }
        var text = "~\(Format.duration(seconds: seconds))"
        if let low = eta.low, let high = eta.high, high > low {
            text += " (\(Format.duration(seconds: low))–\(Format.duration(seconds: high)))"
        } else if let low = eta.low, low < seconds {
            text += " (at least \(Format.duration(seconds: low)))"
        }
        return text
    }
}
