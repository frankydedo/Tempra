import Foundation

enum SettingsKey {
    static let menuBarDisplay = "menuBarDisplay"
    static let sampleInterval = "sampleInterval"
    static let forecastModel = "forecastModel"
    static let forecastEnabled = "forecastEnabled"

    static let defaultSampleInterval: Double = 3

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            menuBarDisplay: MenuBarDisplay.cpu.rawValue,
            sampleInterval: defaultSampleInterval,
            forecastModel: ForecastModel.small.rawValue,
            forecastEnabled: true,
        ])
    }
}

/// What the menu bar item shows next to the icon.
enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case iconOnly, cpu, memory, temperature, battery, power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .cpu: "CPU usage"
        case .memory: "Memory pressure"
        case .temperature: "SoC temperature"
        case .battery: "Battery level"
        case .power: "Power draw"
        }
    }

    func text(for s: Snapshot) -> String? {
        switch self {
        case .iconOnly: nil
        case .cpu: Metric.cpu.format(s.cpuTotal)
        case .memory: Metric.memPressure.format(s.memPressure)
        case .temperature: s.socTemp.map(Metric.socTemp.format)
        case .battery: s.battery.map { Metric.batteryPercent.format($0.percent) }
        case .power: s.battery?.systemPower.map(Metric.systemPower.format)
        }
    }
}

/// Timestral checkpoints the app offers.
enum ForecastModel: String, CaseIterable, Identifiable {
    case small = "mistralai/Timestral-5M"
    case medium = "mistralai/Timestral-28M"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Timestral 5M (fastest, 21 MB)"
        case .medium: "Timestral 28M (more accurate, 111 MB)"
        }
    }
}
