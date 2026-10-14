import Darwin
import Foundation
import IOKit
import Observation

public enum SystemMetric: String, CaseIterable, Sendable, Identifiable {
    case cpu, memory, gpu, temperature

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .temperature: "Temperature"
        }
    }
}

public struct SystemSnapshot: Sendable, Equatable {
    public var cpuPercent: Double?
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64
    public var gpuPercent: Double?
    /// CPU die average and hottest point, and GPU die average, in °C (SMC).
    public var cpuTemperature: Double?
    public var cpuTemperatureMax: Double?
    public var gpuTemperature: Double?

    public var memoryPercent: Double? {
        guard let used = memoryUsed, memoryTotal > 0 else { return nil }
        return Double(used) / Double(memoryTotal) * 100
    }

    public func value(_ metric: SystemMetric) -> Double? {
        switch metric {
        case .cpu: cpuPercent
        case .memory: memoryPercent
        case .gpu: gpuPercent
        case .temperature: cpuTemperature
        }
    }
}

/// Reads system load with Mach/IOKit calls and die temperatures from the SMC. Every
/// handle is opened once; any piece that is unavailable reports nil.
public actor SystemSampler {
    private let host = mach_host_self()
    private var previousTicks: CPUTicks?
    private let gpuService: io_service_t
    /// Resolved lazily on the first sample, off the main thread: without the CPU-die
    /// aggregate keys it has to walk the SMC key table once.
    private lazy var dies = DieTemperatures()
    /// Temperature moves slowly and reading the GPU keys costs a few ms, so it is
    /// refreshed every 10 s instead of on every sample.
    private var lastTemps: (cpu: Double?, cpuMax: Double?, gpu: Double?)?
    private var lastTempsAt: ContinuousClock.Instant?
    private let tempsInterval: Duration = .seconds(10)

    public init() {
        gpuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    }

    deinit {
        if gpuService != 0 { IOObjectRelease(gpuService) }
        mach_port_deallocate(mach_task_self_, host)
    }

    public func sample() -> SystemSnapshot {
        let ticks = cpuTicks()
        let cpu = zip(previousTicks, ticks).flatMap { SystemMath.cpuPercent(from: $0, to: $1) }
        previousTicks = ticks ?? previousTicks
        let now = ContinuousClock.now
        if lastTempsAt.map({ now - $0 >= tempsInterval }) ?? true {
            lastTemps = dies?.read()
            lastTempsAt = now
        }
        let temps = lastTemps
        return SystemSnapshot(
            cpuPercent: cpu,
            memoryUsed: memoryUsed(),
            memoryTotal: ProcessInfo.processInfo.physicalMemory,
            gpuPercent: gpuPercent(),
            cpuTemperature: temps?.cpu,
            cpuTemperatureMax: temps?.cpuMax,
            gpuTemperature: temps?.gpu
        )
    }

    private func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    private func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return SystemMath.memoryUsed(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(pageSize)
        )
    }

    private func gpuPercent() -> Double? {
        guard gpuService != 0,
              let stats = IORegistryEntryCreateCFProperty(
                gpuService, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? [String: Any],
              let value = stats["Device Utilization %"] as? NSNumber
        else { return nil }
        return value.doubleValue
    }
}

struct CPUTicks: Equatable {
    var user, system, idle, nice: UInt64
}

/// The arithmetic, kept apart from the system calls so it can be tested.
enum SystemMath {
    static func cpuPercent(from a: CPUTicks, to b: CPUTicks) -> Double? {
        guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else { return nil }
        let busy = Double((b.user - a.user) + (b.system - a.system) + (b.nice - a.nice))
        let total = busy + Double(b.idle - a.idle)
        return total > 0 ? busy / total * 100 : nil
    }

    /// Activity Monitor's "Memory Used": app memory (internal minus purgeable) + wired + compressed.
    static func memoryUsed(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                           compressedPages: UInt64, pageSize: UInt64) -> UInt64 {
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return (app + wiredPages + compressedPages) * pageSize
    }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// Samples while running and publishes the latest snapshot to the UI.
@MainActor
@Observable
public final class SystemStore {
    public private(set) var snapshot: SystemSnapshot?
    /// Metrics this Mac can report. Only assigned when it changes, so views that lay
    /// out by it are not invalidated on every sample.
    public private(set) var availableMetrics: Set<SystemMetric> = []
    public let interval: Duration
    private let sampler = SystemSampler()
    private var loop: Task<Void, Never>?

    public init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    public var isRunning: Bool { loop != nil }

    private func publish(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        let available = Set(SystemMetric.allCases.filter { snapshot.value($0) != nil })
        if available != availableMetrics { availableMetrics = available }
    }

    public func setRunning(_ running: Bool) {
        if running, loop == nil {
            loop = Task { [weak self, sampler, interval] in
                // The first CPU reading needs a previous sample to diff against.
                _ = await sampler.sample()
                // Sleeps throw on cancellation, which ends the loop before another sample.
                do {
                    while true {
                        try await Task.sleep(for: .milliseconds(500))
                        let snapshot = await sampler.sample()
                        try Task.checkCancellation()
                        self?.publish(snapshot)
                        try await Task.sleep(for: interval - .milliseconds(500))
                    }
                } catch {}
            }
        } else if !running, let task = loop {
            task.cancel()
            loop = nil
        }
    }
}
