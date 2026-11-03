import SwiftUI

@main
struct TempraApp: App {
    static let dashboardWindowID = "dashboard"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            SummaryView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Tempra", id: Self.dashboardWindowID) {
            DashboardView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1080, height: 720)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsKey.registerDefaults()
        let info = Bundle.main.infoDictionary
        Log.notice(.app, "Tempra \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")) started on "
                   + "\(CPUReader.chipName), \(Format.bytes(MemoryReader.totalMemory)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        AppIconManager.restore()
        Task { @MainActor in
            SystemMonitor.shared.start()
            ForecastService.shared.start()
            ChartDataCache.shared.startBackgroundRefresh()
            #if DEBUG
            DebugSnapshots.runIfRequested()
            #endif
        }
        // Tempra lives in the menu bar; show a Dock icon only while a window is open.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.updateActivationPolicy() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { AppDelegate.updateActivationPolicy() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.notice(.app, "Tempra quitting")
        MainActor.assumeIsolated { ForecastService.shared.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    static func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
                && window.className != "NSStatusBarWindow"
        }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if hasWindow { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

/// Menu bar item: icon plus the user's chosen live value, tinted orange or red when that
/// statistic is in Warning or Critical. A red dot on the icon flags any *other* metric in Critical
/// (e.g. memory while the menu bar shows CPU), so a serious problem is never invisible.
struct MenuBarLabel: View {
    @AppStorage(SettingsKey.menuBarDisplay) private var display = MenuBarDisplay.cpu.rawValue
    private let monitor = SystemMonitor.shared

    var body: some View {
        let mode = MenuBarDisplay(rawValue: display) ?? .cpu
        let symbol = monitor.hasSample ? mode.symbol(for: monitor.latest) : MenuBarDisplay.iconOnly.symbol(for: monitor.latest)
        let text = monitor.hasSample ? mode.text(for: monitor.latest) : nil
        let state = monitor.hasSample ? mode.healthMetric.map(monitor.health) ?? .normal : .normal
        let otherCritical = monitor.hasSample
            && HealthMetric.allCases.contains { $0 != mode.healthMetric && monitor.health($0) == .critical }

        if state.nsColor != nil || otherCritical {
            // Menu bar labels are drawn as monochrome templates, so colour needs a pre-rendered image.
            Image(nsImage: Self.tintedImage(symbol: symbol, text: text, color: state.nsColor ?? .labelColor,
                                            badge: otherCritical ? .systemRed : nil))
        } else {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                if let text { Text(text).monospacedDigit() }
            }
        }
    }

    static func tintedImage(symbol: String, text: String?, color: NSColor, badge: NSColor? = nil) -> NSImage {
        let fontSize = NSFont.menuBarFont(ofSize: 0).pointSize
        let config = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let label = text.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: color,
            ])
        }

        let height: CGFloat = 18, spacing: CGFloat = 4
        let iconSize = icon?.size ?? .zero
        let labelSize = label?.size() ?? .zero
        let width = ceil(iconSize.width + (label == nil ? 0 : spacing + labelSize.width))
        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            icon?.draw(in: NSRect(x: 0, y: (height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
            label?.draw(at: NSPoint(x: iconSize.width + spacing, y: (height - labelSize.height) / 2))
            if let badge {
                // A dot on the icon's top-right corner.
                let diameter: CGFloat = 6.5
                badge.setFill()
                NSBezierPath(ovalIn: NSRect(x: iconSize.width - diameter * 0.6, y: height - diameter - 1,
                                            width: diameter, height: diameter)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
