import AppKit
import Foundation

/// Lists running processes with the same measures as Activity Monitor:
/// - Memory is the physical footprint (includes compressed memory). `ps`'s resident size leaves
///   compressed pages out, which hides the heaviest processes (e.g. a 1.4 GB web page showed up
///   as a few hundred MB, or not at all).
/// - CPU is the share used over the last second, not `ps`'s slowly decaying average.
/// Both come from `top` with two samples, which can read every process, including root-owned
/// ones that `proc_pid_rusage` refuses. Names come from the running app (as shown in the Dock)
/// or the full executable name, since `top` truncates them.
enum ProcessReader {
    static func all() async -> [ProcessSample] {
        async let measured = measure()
        async let names = executableNames()
        let (rows, executables) = await (measured, names)
        let apps = await MainActor.run {
            Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in
                app.localizedName.map { (app.processIdentifier, $0) }
            }, uniquingKeysWith: { a, _ in a })
        }
        return rows.map { row in
            ProcessSample(pid: row.pid, name: apps[row.pid] ?? executables[row.pid] ?? row.command,
                          user: row.user, cpu: row.cpu, memory: row.memory)
        }
    }

    private struct Row {
        let pid: Int32
        let cpu: Double
        let memory: UInt64
        let user: String
        let command: String
    }

    /// `top -l 2`: the first sample's CPU is since launch; the second covers the last second.
    private static func measure() async -> [Row] {
        let (output, topPID) = await runWithPID("/usr/bin/top", ["-l", "2", "-s", "1", "-stats", "pid,cpu,mem,user,command"])
        guard let header = output.range(of: "\nPID", options: .backwards) else { return [] }
        return output[header.upperBound...].split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 4, let pid = Int32(parts[0]), pid != topPID, let cpu = Double(parts[1]),
                  let memory = bytes(parts[2]) else { return nil }
            return Row(pid: pid, cpu: cpu, memory: memory, user: String(parts[3]),
                       command: parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespaces) : "")
        }
    }

    /// Full executable names; `ps -c` doesn't truncate them like `top` does.
    private static func executableNames() async -> [Int32: String] {
        let output = await run("/bin/ps", ["-Aceo", "pid=,comm="])
        var names: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, let pid = Int32(parts[0]) {
                names[pid] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return names
    }

    /// "1335M", "943M-", "4096K+", "1.2G", "512B" → bytes.
    private static func bytes(_ text: Substring) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let unit = trimmed.last, let value = Double(trimmed.dropLast()) else { return UInt64(trimmed) }
        let scale: Double = switch unit {
        case "K": 1024
        case "M": 1024 * 1024
        case "G": 1024 * 1024 * 1024
        case "B": 1
        default: 0
        }
        return scale > 0 ? UInt64(value * scale) : nil
    }

    private static func run(_ path: String, _ arguments: [String]) async -> String {
        await runWithPID(path, arguments).output
    }

    /// Runs a tool and returns its output and its pid (so Tempra's own `top` can be left out).
    private static func runWithPID(_ path: String, _ arguments: [String]) async -> (output: String, pid: Int32) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return ("", 0) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: data, as: UTF8.self), process.processIdentifier)
        }.value
    }
}
