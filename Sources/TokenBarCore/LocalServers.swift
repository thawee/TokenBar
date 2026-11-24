import Darwin
import Foundation
import Metal
import Observation

/// Local inference servers. They have no plan limit; the dock shows how much of its
/// memory limit each one holds, where a limit is available.
public enum LocalServerKind: String, CaseIterable, Sendable, Identifiable {
    case kapitsa, splash, llamaCpp, omlx

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kapitsa: "Kapitsa"
        case .splash: "Splash"
        case .llamaCpp: "llama.cpp"
        case .omlx: "oMLX"
        }
    }
}

public struct LocalServer: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case ready
        /// The process runs but the server has not answered yet, or reports itself not ready.
        case loading
        /// It answered before but not this time (busy, or stuck); the fields are its last reading.
        case notAnswering
        /// Started with an API key, so its status needs one too.
        case locked
    }

    /// Where `memoryLimit` comes from.
    public enum LimitSource: Sendable, Equatable {
        /// An explicit command-line memory budget.
        case budget
        /// What macOS recommends for the GPU, Kapitsa's default budget (it keeps a little less).
        case gpuDefault
        /// The server's own memory governor (Splash).
        case server
    }

    public let kind: LocalServerKind
    public let port: Int
    public var status: Status
    public var model: String?
    public var memoryUsed: UInt64?
    public var memoryLimit: UInt64?
    public var limitSource: LimitSource?
    /// Kapitsa and llama.cpp: context tokens per conversation and concurrent slots.
    public var contextLength: Int?
    public var slots: Int?
    /// Splash: average speeds and totals since the server started.
    public var decodeTokensPerSecond: Double?
    public var prefillTokensPerSecond: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var requestsCompleted: Int?
    public var queued: Int?

    public var id: Int { port }

    public var dashboardURL: URL? {
        guard kind == .omlx else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/admin")
    }

    public init(kind: LocalServerKind, port: Int, status: Status) {
        self.kind = kind
        self.port = port
        self.status = status
    }

    public var memoryPercent: Double? {
        guard let used = memoryUsed, let limit = memoryLimit, limit > 0 else { return nil }
        return Double(used) / Double(limit) * 100
    }
}

/// A server process found on this Mac, before asking it anything.
struct ServerProcess: Equatable {
    let kind: LocalServerKind
    let pid: pid_t
    let port: Int
    /// The configured memory budget, in bytes.
    let budget: UInt64?
    var alias: String? = nil
    var apiKey: String? = nil
}

enum LocalServerParsing {
    static let defaultPort = 8000

    /// Identifies a server from its argv: `kapitsa serve …`, or Splash's
    /// `python3 -m server.server … --binary …/engine/splash --port N` (what `splash serve` execs).
    static func identify(_ args: [String]) -> (kind: LocalServerKind, port: Int, budget: UInt64?, alias: String?)? {
        guard let executable = args.first else { return nil }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let omlxArguments: ArraySlice<String>?
        if name == "omlx-server" {
            omlxArguments = args.dropFirst()
        } else if name == "omlx" {
            omlxArguments = args.dropFirst()
        } else if name.lowercased().hasPrefix("python"), args.count > 1 {
            let pythonArgs = args.dropFirst().drop { ["-u", "-P", "-s", "-E", "-I", "-B", "-S"].contains($0) }
            if pythonArgs.first == "-m", let module = pythonArgs.dropFirst().first, ["omlx", "omlx.cli"].contains(module) {
                omlxArguments = pythonArgs.dropFirst(2)
            } else if let script = pythonArgs.first, URL(fileURLWithPath: script).lastPathComponent == "omlx" {
                omlxArguments = pythonArgs.dropFirst()
            } else {
                omlxArguments = nil
            }
        } else {
            omlxArguments = nil
        }
        if let command = omlxArguments, name == "omlx-server" || command.first == "serve" {
            let port = option("--port", in: args).flatMap(Int.init) ?? defaultPort
            guard (1...65535).contains(port) else { return nil }
            return (.omlx, port, nil, nil)
        }
        if URL(fileURLWithPath: executable).lastPathComponent == "llama-server" {
            let mib = option("--memory-budget", in: args).flatMap(UInt64.init)
            let budget = mib.flatMap { value -> UInt64? in
                let (bytes, overflow) = value.multipliedReportingOverflow(by: 1_048_576)
                return overflow || bytes == 0 ? nil : bytes
            }
            let alias = option("--alias", in: args) ?? option("-a", in: args)
            return (.llamaCpp, option("--port", in: args).flatMap(Int.init) ?? 9931, budget, alias)
        }
        let port = option("--port", in: args).flatMap { Int($0) } ?? defaultPort
        if URL(fileURLWithPath: executable).lastPathComponent == "kapitsa", args.dropFirst().first == "serve" {
            // GiB, as GPU memory is counted.
            let budget = option("--mem-budget", in: args).flatMap(Double.init).map { UInt64($0 * 1_073_741_824) }
            return (.kapitsa, port, budget, nil)
        }
        if let module = args.firstIndex(of: "-m"), args.indices.contains(module + 1), args[module + 1] == "server.server",
           option("--binary", in: args).map({ URL(fileURLWithPath: $0).lastPathComponent == "splash" }) == true {
            return (.splash, port, nil, nil)
        }
        return nil
    }

    /// The value of `--name value` or `--name=value`.
    static func option(_ name: String, in args: [String]) -> String? {
        for (i, arg) in args.enumerated() {
            if arg == name, args.indices.contains(i + 1) { return args[i + 1] }
            if arg.hasPrefix(name + "=") { return String(arg.dropFirst(name.count + 1)) }
        }
        return nil
    }

    /// KERN_PROCARGS2: argc (Int32), the executable path, NUL padding, then argc
    /// NUL-terminated arguments (followed by the environment, which is not read).
    static func procArgs(_ data: Data) -> [String]? {
        guard data.count > 4 else { return nil }
        let argc = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0 else { return nil }
        var index = data.startIndex + 4
        // Skip the executable path and its padding.
        while index < data.endIndex, data[index] != 0 { index += 1 }
        while index < data.endIndex, data[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < data.endIndex {
            let end = data[index...].firstIndex(of: 0) ?? data.endIndex
            args.append(String(decoding: data[index..<end], as: UTF8.self))
            index = end + 1
        }
        return args.count == argc ? args : nil
    }

    static func omlxEnvironment(_ data: Data) -> [String: String] {
        guard let args = procArgs(data) else { return [:] }
        var index = data.startIndex + 4
        while index < data.endIndex, data[index] != 0 { index += 1 }
        while index < data.endIndex, data[index] == 0 { index += 1 }
        for _ in args {
            while index < data.endIndex, data[index] != 0 { index += 1 }
            if index < data.endIndex { index += 1 }
        }
        var result: [String: String] = [:]
        for entry in data[index...].split(separator: 0) {
            let pair = String(decoding: entry, as: UTF8.self).split(separator: "=", maxSplits: 1)
            if pair.count == 2, ["OMLX_PORT", "OMLX_API_KEY", "OMLX_BASE_PATH"].contains(String(pair[0])) {
                result[String(pair[0])] = String(pair[1])
            }
        }
        return result
    }

    /// Kapitsa's `/v1/models`: the active model. A model loaded from a directory is named
    /// by its path, so it falls back to its id.
    static func kapitsa(_ data: Data, into server: inout LocalServer) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]],
              let active = models.first(where: { $0["active"] as? Bool == true })
        else {
            server.status = .loading
            return
        }
        let display = active["display_name"] as? String
        server.model = display.flatMap { $0.contains("/") ? nil : $0 } ?? active["id"] as? String
        server.contextLength = active["context_length"] as? Int
        server.slots = active["slots"] as? Int
    }

    /// llama-server's read-only `/props` endpoint (also available without --metrics).
    static func llamaCpp(_ data: Data, into server: inout LocalServer) {
        struct Properties: Decodable {
            struct Settings: Decodable { let n_ctx: Int? }
            let model_path: String?
            let total_slots: Int?
            let default_generation_settings: Settings?
        }
        guard let props = try? JSONDecoder().decode(Properties.self, from: data),
              props.model_path != nil || props.total_slots != nil else {
            server.status = .loading
            return
        }
        server.model = props.model_path.map { URL(fileURLWithPath: $0).lastPathComponent }
        server.contextLength = props.default_generation_settings?.n_ctx
        server.slots = props.total_slots
    }

    /// Splash's `/status`; every field is optional.
    static func splash(_ data: Data, into server: inout LocalServer) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            server.status = .loading
            return
        }
        func value(_ path: [String]) -> Any? {
            path.reduce(root as Any?) { ($0 as? [String: Any])?[$1] }
        }
        func value(_ path: String...) -> Any? { value(path) }
        /// Numbers only: JSON true and false also bridge to NSNumber.
        func number(_ path: String...) -> Double? {
            guard let n = value(path) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }
        if value("ready") as? Bool == false { server.status = .loading }
        server.model = (value("instance", "model") as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        server.memoryUsed = number("memory_actual", "current_bytes").map { UInt64(max($0, 0)) }
        server.memoryLimit = number("memory_governor", "limit_bytes").map { UInt64(max($0, 0)) }
        server.limitSource = server.memoryLimit == nil ? nil : .server
        server.decodeTokensPerSecond = number("metrics", "decode_tokens_per_second")
        server.prefillTokensPerSecond = number("metrics", "prefill_tokens_per_second")
        server.inputTokens = number("metrics", "prefill_input_tokens").map { Int($0) }
        server.outputTokens = number("metrics", "decode_output_tokens").map { Int($0) }
        server.requestsCompleted = number("requests", "completed").map { Int($0) }
        server.queued = number("scheduler", "queued").map { Int($0) }
    }
}

extension LocalServerParsing {
    /// A server that misses a poll keeps its last reading, since a busy server can be slow
    /// to answer. One that has never answered (or was another kind on that port) is starting.
    static func merge(_ fresh: LocalServer, previous: LocalServer?) -> LocalServer {
        guard fresh.status == .notAnswering else { return fresh }
        guard var kept = previous, kept.kind == fresh.kind, kept.status != .loading else {
            var starting = fresh
            starting.status = .loading
            return starting
        }
        kept.status = .notAnswering
        // Kapitsa's memory comes from the process, so it is still current.
        if let used = fresh.memoryUsed { kept.memoryUsed = used }
        if let limit = fresh.memoryLimit {
            kept.memoryLimit = limit
            kept.limitSource = fresh.limitSource
        }
        return kept
    }
}

/// Finds server processes and asks each one for its state.
enum LocalServerProbe {
    /// Server processes, one per port. Only known server executables and `python…` have
    /// their arguments read.
    static func scan() -> [ServerProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var byPort: [Int: (process: ServerProcess, footprint: UInt64)] = [:]
        for pid in pids.prefix(Int(max(found, 0))) where pid > 0 {
            var name = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let short = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard short == "kapitsa" || short == "llama-server" || short == "omlx" || short == "omlx-server"
                    || short.lowercased().hasPrefix("python"),
                  let data = processArguments(pid), let args = LocalServerParsing.procArgs(data),
                  let match = LocalServerParsing.identify(args)
            else { continue }
            let configuration = match.kind == .omlx
                ? OMLXConfiguration.load(args: args, environment: LocalServerParsing.omlxEnvironment(data)) : nil
            let port = configuration.map { listeningPorts(pid).first ?? $0.port } ?? match.port
            // A launcher and the server it starts share a port; keep the one holding the model.
            let footprint = ProcessSampler.footprint(pid) ?? 0
            if let existing = byPort[port], existing.footprint >= footprint { continue }
            byPort[port] = (ServerProcess(kind: match.kind, pid: pid, port: port, budget: match.budget,
                                         alias: match.alias, apiKey: configuration?.apiKey), footprint)
        }
        return byPort.values.map(\.process).sorted { ($0.kind.rawValue, $0.port) < ($1.kind.rawValue, $1.port) }
    }

    static func arguments(_ pid: pid_t) -> [String]? {
        processArguments(pid).flatMap(LocalServerParsing.procArgs)
    }

    private static func processArguments(_ pid: pid_t) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Data(buffer.prefix(size))
    }

    /// Bundled oMLX servers may have no flags; ask the kernel for their listening port.
    static func listeningPorts(_ pid: pid_t) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let bytes = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        return Array(Set(fds.prefix(Int(max(bytes, 0)) / MemoryLayout<proc_fdinfo>.stride).compactMap { fd -> Int? in
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
            var info = socket_fdinfo()
            let count = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard count == MemoryLayout<socket_fdinfo>.size, info.psi.soi_kind == SOCKINFO_TCP else { return nil }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
            return Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
        })).sorted()
    }

    /// Kapitsa's default budget. Asking Metal costs about 2 MB and 60 ms, so it is asked
    /// once (a static is initialized on first use), and only for a Kapitsa started
    /// without --mem-budget.
    private static let gpuLimit: UInt64? = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize

    /// Reads every server at once, so one that hangs costs its timeout once, not per server.
    /// Results keep the order of `processes`.
    static func readAll(
        _ processes: [ServerProcess],
        read: @escaping @Sendable (ServerProcess) async -> LocalServer = { await LocalServerProbe.read($0) }
    ) async -> [LocalServer] {
        await withTaskGroup(of: (Int, LocalServer).self) { group in
            for (index, process) in processes.enumerated() {
                group.addTask { (index, await read(process)) }
            }
            var results: [(Int, LocalServer)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func read(
        _ process: ServerProcess,
        send: @Sendable (URLRequest) async throws -> Data = { try await HTTP.send($0) }
    ) async -> LocalServer {
        var server = LocalServer(kind: process.kind, port: process.port, status: .ready)
        let path = switch process.kind {
        case .kapitsa: "v1/models"
        case .splash: "status"
        case .llamaCpp: "props"
        case .omlx: "admin/api/stats"
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(process.port)/\(path)")!)
        // Polls run one at a time every 5 s, so a slow answer can be waited for.
        request.timeoutInterval = 3
        if process.kind == .omlx, let key = OMLXCredentials.key(port: process.port) ?? process.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let data = try await send(request)
            switch process.kind {
            case .kapitsa: LocalServerParsing.kapitsa(data, into: &server)
            case .splash: LocalServerParsing.splash(data, into: &server)
            case .llamaCpp: LocalServerParsing.llamaCpp(data, into: &server)
            case .omlx: LocalServerParsing.omlx(data, into: &server)
            }
        } catch ProviderError.unauthorized {
            server.status = .locked
        } catch {
            server.status = .notAnswering
        }
        if process.kind == .omlx, server.memoryUsed == nil {
            server.memoryUsed = ProcessSampler.footprint(process.pid)
        }
        if process.kind == .llamaCpp {
            if let alias = process.alias { server.model = alias }
            server.memoryUsed = ProcessSampler.footprint(process.pid)
            if let budget = process.budget {
                server.memoryLimit = budget
                server.limitSource = .budget
            }
        }
        if process.kind == .kapitsa {
            server.memoryUsed = ProcessSampler.footprint(process.pid)
            if let budget = process.budget {
                server.memoryLimit = budget
                server.limitSource = .budget
            } else if let limit = gpuLimit {
                server.memoryLimit = limit
                server.limitSource = .gpuDefault
            }
        }
        return server
    }
}

/// Polls local servers while running and publishes what it finds.
@MainActor
@Observable
public final class LocalServerStore {
    public private(set) var servers: [LocalServer] = []
    /// The servers' ports, only assigned when they change, so the rail lays out again
    /// when a server starts or stops and not on every poll.
    public private(set) var ports: [Int] = []
    /// Kinds the user wants; others are not looked for.
    public var enabled: Set<LocalServerKind> = Set(LocalServerKind.allCases) {
        didSet { if enabled != oldValue { publish(servers) } }
    }
    public let interval: Duration
    private var loop: Task<Void, Never>?

    public init(interval: Duration = .seconds(5)) {
        self.interval = interval
    }

    private func publish(_ found: [LocalServer]) {
        let shown = found.filter { enabled.contains($0.kind) }
        if shown != servers { servers = shown }
        let ports = shown.map(\.port)
        if ports != self.ports { self.ports = ports }
    }

    public func setRunning(_ running: Bool) {
        if running, loop == nil {
            loop = Task { [weak self, interval] in
                // Last reading per port, for servers that miss a poll.
                var previous: [Int: LocalServer] = [:]
                do {
                    while true {
                        let processes = await Task.detached(priority: .utility) { LocalServerProbe.scan() }.value
                        let wanted = self?.enabled ?? []
                        let fresh = await LocalServerProbe.readAll(processes.filter { wanted.contains($0.kind) })
                        let found = fresh.map { LocalServerParsing.merge($0, previous: previous[$0.port]) }
                        previous = Dictionary(found.map { ($0.port, $0) }, uniquingKeysWith: { a, _ in a })
                        try Task.checkCancellation()
                        self?.publish(found)
                        try await Task.sleep(for: interval)
                    }
                } catch {}
            }
        } else if !running, let task = loop {
            task.cancel()
            loop = nil
            publish([])
        }
    }
}
