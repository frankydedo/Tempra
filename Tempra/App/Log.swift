import Foundation
import os

/// App logging. Every event goes to the unified log (Console.app, or
/// `log stream --predicate 'subsystem == "com.fdedominicis.tempra"'`) and is mirrored to
/// ~/Library/Logs/Tempra/Tempra.log, which is easy to read, share and attach to a bug report.
/// Log state changes and decisions, not every sample.
enum Log {
    enum Category: String {
        case app, monitor, battery, health, forecast, store
    }

    static let directory: URL = {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Tempra", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var fileURL: URL { directory.appendingPathComponent("Tempra.log") }

    static func info(_ category: Category, _ message: String) { write(category, message, type: .info) }
    static func notice(_ category: Category, _ message: String) { write(category, message, type: .default) }
    static func error(_ category: Category, _ message: String) { write(category, message, type: .error) }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.fdedominicis.tempra"
    private static let loggers: [Category: Logger] = Dictionary(uniqueKeysWithValues: [Category.app, .monitor, .battery, .health, .forecast, .store]
        .map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })
    private static let file = LogFile()

    private static func write(_ category: Category, _ message: String, type: OSLogType) {
        loggers[category]?.log(level: type, "\(message, privacy: .public)")
        let level = type == .error ? "ERROR " : ""
        file.append("[\(category.rawValue)] \(level)\(message)")
    }
}

/// Appends timestamped lines to Tempra.log on a background queue, rotating at 5 MB (one backup kept).
private final class LogFile: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fdedominicis.tempra.log")
    private let maxSize: UInt64 = 5_000_000
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func append(_ line: String) {
        let date = Date()
        queue.async { [self] in
            let url = Log.fileURL
            let data = Data("\(formatter.string(from: date)) \(line)\n".utf8)
            rotateIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
              size > maxSize else { return }
        let backup = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
