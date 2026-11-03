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
    var state: HealthState = .normal

    var body: some View {
        // Every row has a fixed height so tiles line up regardless of the icon's shape
        // (a battery symbol is shorter than a chip) or whether a state badge is shown.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 16)
            HStack(alignment: .firstTextBaseline) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.color ?? .primary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                StateBadge(state: state)
            }
            .frame(height: 26)
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 14)
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

/// "Warning" / "Critical" capsule; nothing for Normal. Spelled out so state never relies on colour alone.
struct StateBadge: View {
    let state: HealthState

    var body: some View {
        if let color = state.color {
            Text(state.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
        }
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
    var state: HealthState = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(state.color ?? color)
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                StateBadge(state: state)
            }
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
        if macOSRunsOnBattery { return "On adapter, using battery (battery care)" }
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
    /// When the forecast's clock starts: ETAs in the summary count from here.
    private var origin: Date { Date(timeIntervalSince1970: start - step) }

    /// Human readable battery prediction as clock times, e.g. "Battery until ~18:40 (17:50–19:30)".
    var batteryText: String? {
        guard let s = summary else { return nil }
        switch s.kind {
        case "held":
            let level = s.percent.map { String(format: "Held at %.0f%%", $0) } ?? "On adapter"
            guard let unplugged = s.ifUnplugged.flatMap({ clockText($0, horizon: s.horizon) }) else { return level }
            return "\(level) · on battery until \(unplugged)"
        case "time_to_full":
            return clockText(s.eta, horizon: s.horizon).map { "Full at \($0)" }
        default:
            return clockText(s.eta, horizon: s.horizon).map { "Battery until \($0)" }
        }
    }

    /// How long the battery would last if unplugged now, shown while charging.
    var unpluggedText: String? {
        guard let s = summary, s.kind != "time_to_empty", let eta = s.ifUnplugged else { return nil }
        return clockText(eta, horizon: s.horizon).map { "Until \($0)" }
    }

    /// The battery-life estimate that applies now: on battery, or if unplugged now.
    private var runtime: ETA? {
        guard let s = summary else { return nil }
        return s.kind == "time_to_empty" ? s.eta : s.ifUnplugged
    }

    /// Chance (0–1) that the battery still has charge at `date`, from the forecast's 10th, 50th and
    /// 90th percentile run-out times (linearly between them, capped at 5% and 95%).
    func chanceOfLasting(until date: Date) -> Double? {
        guard let eta = runtime, let median = eta.seconds ?? summary?.horizon else { return nil }
        let needed = date.timeIntervalSince(origin)
        let early = eta.low ?? median * 0.8
        let late = eta.high ?? summary?.horizon ?? median * 1.2
        switch needed {
        case ..<early: return 0.95
        case ..<median: return 0.9 - 0.4 * (needed - early) / max(median - early, 1)
        case ..<late: return 0.5 - 0.4 * (needed - median) / max(late - median, 1)
        default: return eta.seconds == nil && eta.high == nil ? 0.5 : 0.05
        }
    }

    /// "~18:40 (17:50–19:30)", "~18:40 (not before 17:50)" or "after tomorrow 10:15".
    private func clockText(_ eta: ETA, horizon: Double?) -> String? {
        guard let seconds = eta.seconds else {
            return horizon.map { "after \(Format.clock(origin.addingTimeInterval($0)))" }
        }
        var text = "~" + Format.clock(origin.addingTimeInterval(seconds))
        if let low = eta.low, let high = eta.high, high > low {
            text += " (\(Format.clock(origin.addingTimeInterval(low), short: true))–\(Format.clock(origin.addingTimeInterval(high), short: true)))"
        } else if let low = eta.low, low < seconds {
            text += " (not before \(Format.clock(origin.addingTimeInterval(low), short: true)))"
        }
        return text
    }
}
