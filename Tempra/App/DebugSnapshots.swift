#if DEBUG
import SwiftUI

/// Debug-only: `Tempra -TempraSnapshotDir /path` renders the main views into PNG files
/// (using the app's own windows, so no screen-recording permission is needed) and quits.
@MainActor
enum DebugSnapshots {
    static func runIfRequested() {
        guard let dir = UserDefaults.standard.string(forKey: "TempraSnapshotDir") else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            var windows: [(String, NSWindow)] = []
            windows.append(("summary", window(SummaryView(), width: 360)))
            windows.append(("dashboard", window(DashboardView(), width: 1080, height: 720)))
            let range = UserDefaults.standard.string(forKey: "TempraSnapshotRange").flatMap(TimeRange.init(rawValue:)) ?? .m15
            let sections: [(String, AnyView)] = [
                ("overview", AnyView(OverviewSection(range: range))),
                ("cpu", AnyView(CPUSection(range: range))),
                ("gpu", AnyView(GPUSection(range: range))),
                ("memory", AnyView(MemorySection(range: range))),
                ("thermals", AnyView(ThermalSection(range: range))),
                ("battery", AnyView(BatterySection(range: range))),
                ("io", AnyView(IOSection(range: range))),
                ("processes", AnyView(ProcessesSection())),
                ("forecasts", AnyView(ForecastsSection())),
                ("settings", AnyView(SettingsView())),
            ]
            for (name, view) in sections {
                windows.append((name, window(view.padding(20), width: name == "settings" ? 520 : 900)))
            }
            for (name, color) in [("menubar-warning", NSColor.systemOrange), ("menubar-critical", NSColor.systemRed)] {
                let image = MenuBarLabel.tintedImage(symbol: "memorychip", text: "54%", color: color)
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("\(name).png"))
                }
            }
            try? await Task.sleep(for: .seconds(4))
            for (name, window) in windows {
                guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func window(_ view: some View, width: CGFloat, height: CGFloat? = nil) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height).fixedSize(horizontal: false, vertical: height == nil))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? max(size.height, 200)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -3000, y: 0))
        window.orderFrontRegardless()
        return window
    }
}
#endif
