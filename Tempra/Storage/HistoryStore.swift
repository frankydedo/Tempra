import Foundation
import SQLite3

/// A point on a history chart.
struct ChartPoint: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let value: Double
}

struct BatteryHealthPoint: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let health: Double
    let cycleCount: Int
}

/// Persists samples in SQLite at three resolutions:
///  - `raw`    every sample, kept for 24 hours
///  - `minute` 1-minute averages, kept for 30 days
///  - `hour`   1-hour averages, kept forever
/// plus one battery-health row per day and the latest forecasts written by the Python worker.
actor HistoryStore {
    static let rawRetention: TimeInterval = 24 * 3600
    static let minuteRetention: TimeInterval = 30 * 24 * 3600

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tempra", isDirectory: true)
    }

    static var databaseURL: URL { directory.appendingPathComponent("history.sqlite") }

    private var db: OpaquePointer?
    private let columns = Metric.allCases.map(\.rawValue)

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if sqlite3_open(Self.databaseURL.path, &db) != SQLITE_OK {
            Log.error(.store, "Could not open \(Self.databaseURL.path): \(String(cString: sqlite3_errmsg(db)))")
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 3000)
        let cols = columns.map { "\($0) REAL" }.joined(separator: ", ")
        let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS raw (ts REAL PRIMARY KEY, \(cols));
        CREATE TABLE IF NOT EXISTS minute (ts REAL PRIMARY KEY, \(cols));
        CREATE TABLE IF NOT EXISTS hour (ts REAL PRIMARY KEY, \(cols));
        CREATE TABLE IF NOT EXISTS battery_daily (day REAL PRIMARY KEY, health REAL, cycle_count INTEGER, nominal INTEGER, design INTEGER);
        CREATE TABLE IF NOT EXISTS forecasts (metric TEXT PRIMARY KEY, generated_at REAL, payload TEXT);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """
        sqlite3_exec(db, schema, nil, nil, nil)
        Self.migrate(db, columns: columns)
    }

    /// Adds columns for metrics introduced after the database was created.
    private static func migrate(_ db: OpaquePointer?, columns: [String]) {
        for table in ["raw", "minute", "hour"] {
            var existing = Set<String>()
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let name = sqlite3_column_text(stmt, 1) { existing.insert(String(cString: name)) }
                }
            }
            sqlite3_finalize(stmt)
            for column in columns where !existing.contains(column) {
                sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN \(column) REAL", nil, nil, nil)
            }
        }
    }

    // MARK: Writing

    func insert(_ snapshot: Snapshot) {
        let placeholders = Array(repeating: "?", count: columns.count + 1).joined(separator: ", ")
        let sql = "INSERT OR REPLACE INTO raw (ts, \(columns.joined(separator: ", "))) VALUES (\(placeholders))"
        withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, snapshot.date.timeIntervalSince1970)
            for (i, metric) in Metric.allCases.enumerated() {
                if let value = metric.value(from: snapshot), value.isFinite {
                    sqlite3_bind_double(stmt, Int32(i + 2), value)
                } else {
                    sqlite3_bind_null(stmt, Int32(i + 2))
                }
            }
            sqlite3_step(stmt)
        }
    }

    func recordBatteryHealth(_ battery: BatteryInfo, at date: Date = Date()) {
        guard battery.designCapacity > 0 else { return }
        let day = Calendar.current.startOfDay(for: date).timeIntervalSince1970
        withStatement("INSERT OR REPLACE INTO battery_daily (day, health, cycle_count, nominal, design) VALUES (?, ?, ?, ?, ?)") { stmt in
            sqlite3_bind_double(stmt, 1, day)
            sqlite3_bind_double(stmt, 2, battery.health)
            sqlite3_bind_int64(stmt, 3, Int64(battery.cycleCount))
            sqlite3_bind_int64(stmt, 4, Int64(battery.nominalCapacity))
            sqlite3_bind_int64(stmt, 5, Int64(battery.designCapacity))
            sqlite3_step(stmt)
        }
    }

    /// Averages recent raw samples into minutes and minutes into hours, then prunes old rows.
    /// Idempotent: it re-aggregates a trailing window, so it is safe to call at any cadence.
    func rollUpAndPrune(now: Date = Date()) {
        let t = now.timeIntervalSince1970
        let currentMinute = (t / 60).rounded(.down) * 60
        let currentHour = (t / 3600).rounded(.down) * 3600
        let averages = columns.map { "AVG(\($0))" }.joined(separator: ", ")
        let list = columns.joined(separator: ", ")

        exec("""
        INSERT OR REPLACE INTO minute (ts, \(list))
        SELECT CAST(ts / 60 AS INTEGER) * 60 AS bucket, \(averages) FROM raw
        WHERE ts >= \(currentMinute - 15 * 60) AND ts < \(currentMinute) GROUP BY bucket;
        INSERT OR REPLACE INTO hour (ts, \(list))
        SELECT CAST(ts / 3600 AS INTEGER) * 3600 AS bucket, \(averages) FROM minute
        WHERE ts >= \(currentHour - 3 * 3600) AND ts < \(currentHour) GROUP BY bucket;
        DELETE FROM raw WHERE ts < \(t - Self.rawRetention);
        DELETE FROM minute WHERE ts < \(t - Self.minuteRetention);
        """)
    }

    func deleteAll() {
        exec("DELETE FROM raw; DELETE FROM minute; DELETE FROM hour; DELETE FROM battery_daily; DELETE FROM forecasts; VACUUM;")
    }

    // MARK: Reading

    /// Returns `metric` between `from` and `to`, averaged into buckets of `bucket` seconds.
    /// Picks the coarsest table that still has enough resolution and retention.
    func series(_ metric: Metric, from: Date, to: Date = Date(), bucket: TimeInterval) -> [ChartPoint] {
        let span = to.timeIntervalSince(from)
        let table = span <= 6 * 3600 ? "raw" : (span <= Self.minuteRetention + 3600 ? "minute" : "hour")
        let sql = """
        SELECT CAST(ts / ? AS INTEGER) * ? AS bucket, AVG(\(metric.rawValue)) FROM \(table)
        WHERE ts >= ? AND ts <= ? AND \(metric.rawValue) IS NOT NULL
        GROUP BY bucket ORDER BY bucket
        """
        var points: [ChartPoint] = []
        withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, bucket)
            sqlite3_bind_double(stmt, 2, bucket)
            sqlite3_bind_double(stmt, 3, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, to.timeIntervalSince1970)
            while sqlite3_step(stmt) == SQLITE_ROW {
                points.append(ChartPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                                         value: sqlite3_column_double(stmt, 1)))
            }
        }
        return points
    }

    func batteryHealthHistory() -> [BatteryHealthPoint] {
        var points: [BatteryHealthPoint] = []
        withStatement("SELECT day, health, cycle_count FROM battery_daily ORDER BY day") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                points.append(BatteryHealthPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                                                 health: sqlite3_column_double(stmt, 1),
                                                 cycleCount: Int(sqlite3_column_int64(stmt, 2))))
            }
        }
        return points
    }

    func forecasts() -> [String: Data] {
        var result: [String: Data] = [:]
        withStatement("SELECT metric, payload FROM forecasts") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let metric = sqlite3_column_text(stmt, 0), let payload = sqlite3_column_text(stmt, 1) else { continue }
                result[String(cString: metric)] = Data(String(cString: payload).utf8)
            }
        }
        return result
    }

    func meta(_ key: String) -> String? {
        var value: String?
        withStatement("SELECT value FROM meta WHERE key = ?") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
                value = String(cString: text)
            }
        }
        return value
    }

    func setMeta(_ key: String, _ value: String) {
        withStatement("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    /// Size of the database files on disk, in bytes.
    func diskSize() -> Int64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let path = Self.databaseURL.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64
            return total + (size ?? 0)
        }
    }

    // MARK: Helpers

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        body(stmt)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
