import Darwin
import Foundation

public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let name: String
    /// CPU: percent of one core (can exceed 100). Memory: bytes.
    public let value: Double

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, value: Double) {
        self.pid = pid
        self.name = name
        self.value = value
    }
}

/// Finds the heaviest processes. Only run while someone is looking at the list: each
/// call walks every process.
public enum ProcessSampler {
    /// Top CPU users across all processes, from `ps`. Its %CPU is a short decaying
    /// average, per core like Activity Monitor; system processes need `ps` because
    /// their usage cannot be read without root.
    public static func topCPU(limit: Int = 5) -> [ProcessUsage] {
        guard let output = try? Shell.run("/bin/ps", ["-axo", "pid=,%cpu=,comm="], timeout: 5) else { return [] }
        return Array(parsePS(output).filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(limit))
    }

    /// Top memory users by physical footprint, Activity Monitor's "Memory" column. Only
    /// processes owned by this user can be read without root.
    public static func topMemory(limit: Int = 5) -> [ProcessUsage] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let usages = pids.prefix(Int(max(found, 0))).compactMap { pid -> ProcessUsage? in
            guard pid > 0, let footprint = footprint(pid), footprint > 0 else { return nil }
            return ProcessUsage(pid: pid, name: name(pid), value: Double(footprint))
        }
        return Array(usages.sorted { $0.value > $1.value }.prefix(limit))
    }

    /// Parses `ps -axo pid=,%cpu=,comm=` lines: pid, percent, then the executable path,
    /// which may contain spaces. The name is the path's last component.
    static func parsePS(_ text: String) -> [ProcessUsage] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]) else { return nil }
            let path = parts[2].trimmingCharacters(in: .whitespaces)
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return ProcessUsage(pid: pid, name: name, value: cpu)
        }
    }

    private static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    private static func name(_ pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            return URL(fileURLWithPath: string(path)).lastPathComponent
        }
        var short = [CChar](repeating: 0, count: 64)
        proc_name(pid, &short, UInt32(short.count))
        return string(short)
    }

    /// A NUL-terminated C buffer as a String.
    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
