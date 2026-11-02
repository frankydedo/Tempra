import AppKit
import Observation
import SwiftUI

/// Whether Tempra's windows are on screen. Charts and sparklines only redraw while visible.
@MainActor
@Observable
final class UIVisibility {
    static let shared = UIVisibility()
    var dashboard = false
    var summary = false
    private init() {}
}

/// History chart data, shared by every chart. Visible charts refresh it at their own cadence; while
/// nothing is visible, a background pass re-queries every chart used recently once a minute (no
/// drawing), so a dashboard opened later shows current data straight away instead of an empty page.
@MainActor
final class ChartDataCache {
    static let shared = ChartDataCache()

    struct Key: Hashable {
        let metric: Metric
        let range: TimeRange
    }

    struct Entry {
        var points: [ChartPoint] = []
        var powerSpans: [PowerSpan] = []
        var lastUsed = Date()
    }

    private var entries: [Key: Entry] = [:]
    private var backgroundRefresh: Task<Void, Never>?
    private let store = SystemMonitor.shared.store

    static let hiddenRefreshInterval: TimeInterval = 60
    private static let maxEntries = 40

    func cached(_ key: Key) -> Entry? { entries[key] }

    /// Queries the store, caches and returns the result.
    @discardableResult
    func load(_ key: Key) async -> Entry {
        let to = Date()
        let from = to.addingTimeInterval(-key.range.seconds)
        var entry = Entry(points: await store.series(key.metric, from: from, to: to, bucket: key.range.bucket))
        if key.metric == .batteryPercent {
            async let adapter = store.series(.onAC, from: from, to: to, bucket: key.range.bucket)
            async let charging = store.series(.charging, from: from, to: to, bucket: key.range.bucket)
            async let batteryPower = store.series(.batteryPower, from: from, to: to, bucket: key.range.bucket)
            entry.powerSpans = PowerSpan.spans(adapter: await adapter, charging: await charging,
                                               batteryPower: await batteryPower, bucket: key.range.bucket)
        }
        entries[key] = entry
        trim()
        return entry
    }

    /// Starts the once-a-minute refresh of recently used charts (idempotent).
    func startBackgroundRefresh() {
        guard backgroundRefresh == nil else { return }
        backgroundRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.hiddenRefreshInterval))
                guard let self, !UIVisibility.shared.dashboard else { continue }
                for key in self.entries.keys where Date().timeIntervalSince(self.entries[key]?.lastUsed ?? .distantPast) < 86400 {
                    let lastUsed = self.entries[key]?.lastUsed
                    var entry = await self.load(key)
                    entry.lastUsed = lastUsed ?? Date()
                    self.entries[key] = entry
                }
            }
        }
    }

    private func trim() {
        guard entries.count > Self.maxEntries else { return }
        let oldest = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(entries.count - Self.maxEntries)
        for (key, _) in oldest { entries[key] = nil }
    }
}

/// A stretch of time on the power adapter, shaded on the battery chart.
struct PowerSpan: Identifiable, Sendable {
    enum Kind: CaseIterable, Sendable {
        case charging, notCharging

        var label: String { self == .charging ? "Charging" : "On adapter, not charging" }
        var color: Color { self == .charging ? .green : .yellow }
        var opacity: Double { self == .charging ? 0.16 : 0.18 }
    }

    var id: Date { start }
    let kind: Kind
    let start: Date
    var end: Date

    /// Merges buckets where the Mac was mostly on the adapter into continuous spans, split by
    /// whether the battery was charging. History recorded before the charging state was stored
    /// falls back to the battery's power flow (charging = energy going in).
    static func spans(adapter: [ChartPoint], charging: [ChartPoint], batteryPower: [ChartPoint],
                      bucket: TimeInterval) -> [PowerSpan] {
        let chargingByDate = Dictionary(charging.map { ($0.date, $0.value) }, uniquingKeysWith: { a, _ in a })
        let powerByDate = Dictionary(batteryPower.map { ($0.date, $0.value) }, uniquingKeysWith: { a, _ in a })
        var spans: [PowerSpan] = []
        for point in adapter where point.value >= 0.5 {
            let isCharging = chargingByDate[point.date].map { $0 >= 0.5 } ?? ((powerByDate[point.date] ?? 0) > 0.5)
            let kind: Kind = isCharging ? .charging : .notCharging
            let end = point.date.addingTimeInterval(bucket)
            if let last = spans.last, last.kind == kind, point.date.timeIntervalSince(last.end) <= bucket * 1.5 {
                spans[spans.count - 1].end = end
            } else {
                spans.append(PowerSpan(kind: kind, start: point.date, end: end))
            }
        }
        return spans
    }
}

/// Reports whether the hosting window is actually on screen (not closed, minimised or fully covered).
struct WindowVisibilityReader: NSViewRepresentable {
    /// Receives the hosting window, e.g. to close the menu bar panel from inside it.
    var onWindow: ((NSWindow?) -> Void)?
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObservingView()
        view.onChange = onChange
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        var onWindow: ((NSWindow?) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { onChange?(false); return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
