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
        AppIconManager.restore()
        Task { @MainActor in
            SystemMonitor.shared.start()
            ForecastService.shared.start()
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

/// Menu bar item: icon plus the user's chosen live value.
struct MenuBarLabel: View {
    @AppStorage(SettingsKey.menuBarDisplay) private var display = MenuBarDisplay.cpu.rawValue
    private let monitor = SystemMonitor.shared

    var body: some View {
        let mode = MenuBarDisplay(rawValue: display) ?? .cpu
        HStack(spacing: 4) {
            Image(systemName: monitor.hasSample ? mode.symbol(for: monitor.latest) : MenuBarDisplay.iconOnly.symbol(for: monitor.latest))
            if monitor.hasSample, let text = mode.text(for: monitor.latest) {
                Text(text).monospacedDigit()
            }
        }
    }
}
