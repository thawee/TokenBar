import Foundation
import Testing
@testable import TokenBarCore

@Test func cpuPercentFromTickDelta() {
    let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
    let b = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
    // busy 60+20+20 = 100, idle 100
    #expect(SystemMath.cpuPercent(from: a, to: b) == 50)
    #expect(SystemMath.cpuPercent(from: a, to: a) == nil, "no ticks elapsed")
    #expect(SystemMath.cpuPercent(from: b, to: a) == nil, "counters went backwards")
}

@Test func memoryUsedMatchesActivityMonitorFormula() {
    let used = SystemMath.memoryUsed(internalPages: 1000, purgeablePages: 200, wiredPages: 300,
                                     compressedPages: 100, pageSize: 16384)
    #expect(used == (800 + 300 + 100) * 16384)
    #expect(SystemMath.memoryUsed(internalPages: 10, purgeablePages: 20, wiredPages: 0,
                                  compressedPages: 0, pageSize: 4096) == 0)
}

@Test func smcStructMatchesKernelLayout() {
    #expect(MemoryLayout<SMCKeyData>.stride == 80)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.keyInfo) == 28)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.data32) == 44)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.bytes) == 48)
}

@Test func smcDecodesTemperatureTypes() {
    // 98.25 as a little-endian float
    let f = Float(98.25).bitPattern
    let flt = [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: f >> $0) }
    #expect(SMC.decode(flt, type: "flt ") == 98.25)
    // 45.5 in 16.16 fixed point, little-endian
    #expect(SMC.decode([0x00, 0x80, 0x2D, 0x00], type: "ioft") == 45.5)
    // sp78 is signed: 0xFB00 is -5 °C, not 251
    #expect(SMC.decode([0xFB, 0x00], type: "sp78") == -5)
    #expect(SMC.decode([0x00, 0x00, 0x0A, 0xF0], type: "ui32") == 2800)
    #expect(SMC.decode([1, 2], type: "si32") == nil)
    #expect(SMC.fourCC("TCMb") == 0x54434D62)
    #expect(SMC.string(0x54434D62) == "TCMb")
}

@Test func averageOfEmptyIsNil() {
    #expect(SystemMath.average([]) == nil)
    #expect(SystemMath.average([90, 100]) == 95)
}

@Test func snapshotValuesPerMetric() {
    let s = SystemSnapshot(cpuPercent: 12, memoryUsed: 9, memoryTotal: 36, gpuPercent: 40,
                           cpuTemperature: 66, cpuTemperatureMax: 70, gpuTemperature: 60)
    #expect(s.value(.cpu) == 12)
    #expect(s.value(.memory) == 25)
    #expect(s.value(.gpu) == 40)
    #expect(s.value(.temperature) == 66)
}

/// Reads the real sensors. Run with `LIVE=1 swift test --filter liveSystem`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE"] == "1"))
func liveSystemSample() async throws {
    let sampler = SystemSampler()
    _ = await sampler.sample()
    try await Task.sleep(for: .seconds(1))
    let s = await sampler.sample()
    print("LIVE system:", s)
    #expect(s.cpuPercent != nil)
    #expect(s.memoryUsed != nil)
}

@MainActor @Test func systemStoreStopsPublishingWhenStopped() async throws {
    let store = SystemStore(interval: .milliseconds(600))
    store.setRunning(true)
    #expect(store.isRunning)
    // The first sample also resolves the SMC keys (a few hundred ms), so wait for it
    // rather than assuming a fixed delay.
    let deadline = ContinuousClock.now + .seconds(5)
    while store.snapshot == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    let first = try #require(store.snapshot)
    #expect(store.availableMetrics.contains(.cpu))

    store.setRunning(false)
    #expect(!store.isRunning)
    try await Task.sleep(for: .milliseconds(1500))
    #expect(store.snapshot == first, "no sample published after stop")
}

@Test func parsesPSLinesWithSpacesInPaths() {
    let text = """
      429  44.9 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
     1214   4.6 /Applications/Azure VPN Client.app/Contents/MacOS/Azure VPN Client
        1   0.0 /sbin/launchd
    junk line
    """
    let rows = ProcessSampler.parsePS(text)
    #expect(rows.map(\.pid) == [429, 1214, 1])
    #expect(rows[0].name == "WindowServer")
    #expect(rows[1].name == "Azure VPN Client")
    #expect(rows[1].value == 4.6)
}

@Test func topMemoryReadsOwnProcesses() {
    let top = ProcessSampler.topMemory(limit: 5)
    #expect(!top.isEmpty)
    #expect(top.count <= 5)
    #expect(zip(top, top.dropFirst()).allSatisfy { $0.value >= $1.value })
}

@MainActor @Test func processFocusScansOnlyCPUAndMemoryAndClearsOnChange() async throws {
    let store = SystemStore(interval: .milliseconds(300))
    store.setProcessFocus(.gpu)
    #expect(store.processMetric == nil, "GPU has no process list")

    store.setProcessFocus(.memory)
    #expect(store.processMetric == .memory)
    let deadline = ContinuousClock.now + .seconds(5)
    while store.topProcesses.isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!store.topProcesses.isEmpty)

    store.setProcessFocus(.cpu)
    #expect(store.processMetric == .cpu)
    #expect(store.topProcesses.isEmpty, "switching clears the old list")

    store.setProcessFocus(nil)
    #expect(store.processMetric == nil)
    try await Task.sleep(for: .milliseconds(700))
    #expect(store.topProcesses.isEmpty, "no scan published after focus cleared")
}
