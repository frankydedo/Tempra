import AppKit

/// The app icon variants the user can pick in Settings. They share one drawing (a history line
/// flowing into three forecast bands) and differ only in palette and glass style. `indigo` is
/// compiled into the bundle (Tempra/Resources/AppIcon.icon); the others are Icon Composer renders
/// shipped as PNGs (see design/make_icons.py and design/export_icons.sh).
enum AppIconChoice: String, CaseIterable, Identifiable {
    case indigo = "Indigo"
    case night = "Night"
    case dawn = "Dawn"
    case aurora = "Aurora"
    case sky = "Sky"
    case graphite = "Graphite"

    static let `default` = AppIconChoice.indigo

    var id: String { rawValue }

    var title: String { rawValue }

    var image: NSImage? {
        Bundle.main.url(forResource: rawValue, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}

@MainActor
enum AppIconManager {
    static var current: AppIconChoice {
        UserDefaults.standard.string(forKey: SettingsKey.appIcon).flatMap(AppIconChoice.init(rawValue:)) ?? .default
    }

    /// Applies `choice` to the Dock (while Tempra shows a window) and to the app bundle in Finder,
    /// Launchpad and Login Items. Returns false if the bundle's icon could not be changed
    /// (e.g. the app sits in a read-only location); the Dock icon still changes.
    @discardableResult
    static func apply(_ choice: AppIconChoice) -> Bool {
        UserDefaults.standard.set(choice.rawValue, forKey: SettingsKey.appIcon)
        let custom = choice == .default ? nil : choice.image
        NSApp.applicationIconImage = custom
        return NSWorkspace.shared.setIcon(custom, forFile: Bundle.main.bundlePath, options: [])
    }

    /// Re-applies the saved choice at launch. Reinstalling the app replaces the bundle and drops
    /// its custom Finder icon, so restore it when it is missing.
    static func restore() {
        let choice = current
        let marker = (Bundle.main.bundlePath as NSString).appendingPathComponent("Icon\r")
        guard choice != .default else {
            // Drop a custom icon left over from a variant that no longer exists.
            if FileManager.default.fileExists(atPath: marker) {
                NSWorkspace.shared.setIcon(nil, forFile: Bundle.main.bundlePath, options: [])
            }
            return
        }
        NSApp.applicationIconImage = choice.image
        if !FileManager.default.fileExists(atPath: marker) {
            NSWorkspace.shared.setIcon(choice.image, forFile: Bundle.main.bundlePath, options: [])
        }
    }
}
