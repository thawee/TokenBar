import Foundation
import IOKit

/// Read-only access to the System Management Controller, where Apple Silicon exposes its
/// CPU and GPU die temperatures. Works without root. Key meanings are undocumented and
/// differ between chips, so readings outside 15...130 °C are treated as idle-cluster
/// sentinels or non-temperature keys and dropped.
final class SMC {
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    /// The key's value in °C, or nil when it is missing or not a plausible temperature.
    func temperature(_ key: String) -> Double? {
        guard let value = read(key), (15...130).contains(value) else { return nil }
        return value
    }

    func read(_ key: String) -> Double? {
        var input = SMCKeyData()
        input.key = SMC.fourCC(key)
        input.data8 = SMC.readKeyInfo
        guard let info = call(&input) else { return nil }
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = SMC.readBytes
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
        return SMC.decode(bytes, type: SMC.string(info.keyInfo.dataType))
    }

    /// Every key name starting with `prefix`. Walks the whole key table (a few thousand
    /// keys), so call it once and keep the result.
    func keys(withPrefix prefixes: [String]) -> [String] {
        guard let count = read("#KEY").map(Int.init), count > 0 else { return [] }
        return (0..<count).compactMap { index in
            var input = SMCKeyData()
            input.data8 = SMC.readIndex
            input.data32 = UInt32(index)
            guard let output = call(&input), output.key != 0 else { return nil }
            let name = SMC.string(output.key)
            return prefixes.contains(where: name.hasPrefix) ? name : nil
        }
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(connection, SMC.kernelIndex, &input, size, &output, &size)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static let kernelIndex: UInt32 = 2
    private static let readBytes: UInt8 = 5
    private static let readIndex: UInt8 = 8
    private static let readKeyInfo: UInt8 = 9

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
    }

    /// Decodes the SMC data types that carry temperatures and counts.
    static func decode(_ b: [UInt8], type: String) -> Double? {
        switch type {
        case "flt " where b.count >= 4:
            // Little-endian IEEE float on Apple Silicon.
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case "ioft" where b.count >= 4:
            // 16.16 fixed point, little-endian (not a float).
            return Double(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24) / 65536
        case "sp78" where b.count >= 2:
            // Signed 7.8 fixed point, big-endian.
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "ui32" where b.count >= 4:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "ui16" where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui8 " where b.count >= 1:
            return Double(b[0])
        default:
            return nil
        }
    }
}

/// The AppleSMC user-client struct (80 bytes); field order and sizes must match the kernel's.
struct SMCKeyData {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct PLimitData { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
    /// 12 bytes in C. Swift would let the next fields reuse the 3 tail-padding bytes,
    /// shifting everything after it, so the padding is spelled out.
    struct KeyInfo {
        var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

/// CPU and GPU die temperatures from the SMC, resolved once per machine.
final class DieTemperatures {
    private let smc: SMC
    private let cpuAggregate: Bool
    private let cpuKeys: [String]
    private let gpuKeys: [String]

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc
        // TCMb / TCMz are the SMC's own CPU-die average and maximum where the chip has
        // them (seen on M3 Pro). Otherwise average the per-core keys, as Stats and macmon do.
        if smc.temperature("TCMb") != nil {
            cpuAggregate = true
            cpuKeys = []
        } else {
            cpuAggregate = false
            cpuKeys = smc.keys(withPrefix: ["Tp", "Te"])
        }
        gpuKeys = smc.keys(withPrefix: ["Tg"])
        guard cpuAggregate || !cpuKeys.isEmpty || !gpuKeys.isEmpty else { return nil }
    }

    func read() -> (cpu: Double?, cpuMax: Double?, gpu: Double?) {
        let cpuValues = cpuAggregate ? [] : cpuKeys.compactMap(smc.temperature)
        let cpu = cpuAggregate ? smc.temperature("TCMb") : SystemMath.average(cpuValues)
        let cpuMax = cpuAggregate ? smc.temperature("TCMz") : cpuValues.max()
        return (cpu, cpuMax, SystemMath.average(gpuKeys.compactMap(smc.temperature)))
    }
}
