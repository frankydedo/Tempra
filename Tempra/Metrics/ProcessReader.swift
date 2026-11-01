import Foundation

/// Lists running processes with their CPU and memory use. `ps` can see CPU and resident memory for every process
/// (including root-owned ones) without extra privileges, unlike libproc for other users' pids.
enum ProcessReader {
    static func all() async -> [ProcessSample] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-Aceo", "pid=,pcpu=,rss=,user=,comm="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            let samples: [ProcessSample] = lines.compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                guard parts.count == 5, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = UInt64(parts[2]) else {
                    return nil
                }
                return ProcessSample(pid: pid, name: parts[4].trimmingCharacters(in: .whitespaces), user: String(parts[3]), cpu: cpu, memory: rss * 1024)
            }
            return samples
        }.value
    }
}
