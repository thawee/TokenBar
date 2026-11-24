import Foundation
import Darwin
import Testing
@testable import TokenBarCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func identifiesKapitsaServeWithPortAndBudget() throws {
    let args = ["/Users/me/.local/libexec/kapitsa-flint/kapitsa", "serve", "--model", "/m/flint", "--port", "8001",
                "--mem-budget", "24"]
    let match = try #require(LocalServerParsing.identify(args))
    #expect(match.kind == .kapitsa)
    #expect(match.port == 8001)
    #expect(match.budget == UInt64(24) * 1_073_741_824)
    let equals = try #require(LocalServerParsing.identify(["kapitsa", "serve", "--port=9000", "--mem-budget=12.5"]))
    #expect(equals.port == 9000)
    #expect(equals.budget == UInt64(12.5 * 1_073_741_824))
}

@Test func kapitsaDefaultsAndAgentCommandsAreNotServers() throws {
    let match = try #require(LocalServerParsing.identify(["/opt/homebrew/bin/kapitsa", "serve"]))
    #expect(match.port == 8000)
    #expect(match.budget == nil)
    #expect(LocalServerParsing.identify(["/opt/homebrew/bin/kapitsa", "claude"]) == nil)
    #expect(LocalServerParsing.identify(["/opt/homebrew/bin/kapitsa"]) == nil)
}

@Test func identifiesSplashServerButNotOtherPython() throws {
    let args = ["/opt/homebrew/opt/splash/libexec/python/bin/python3", "-u", "-P", "-m", "server.server", "/link",
                "--model", "org/Repo", "--binary", "/opt/homebrew/opt/splash/libexec/engine/splash", "--port", "8001"]
    let match = try #require(LocalServerParsing.identify(args))
    #expect(match.kind == .splash)
    #expect(match.port == 8001)
    #expect(LocalServerParsing.identify(["python3", "-m", "server.server", "--binary", "/usr/bin/other"]) == nil)
    #expect(LocalServerParsing.identify(["python3", "-m", "http.server", "8000"]) == nil)
}

@Test func identifiesSplashPrivateInstallByEngineExecutable() throws {
    let args = ["/Users/me/.local/bin/splash-private/1.4.1-copilot/python/bin/python3",
                "-u", "-P", "-m", "server.server", "/Users/me/Library/Application Support/Splash/models/org/Repo",
                "--model", "org/Repo", "--binary", "/Users/me/.local/bin/splash-private/1.4.1-copilot/engine/splash",
                "--port=8000"]
    let match = try #require(LocalServerParsing.identify(args))
    #expect(match.kind == .splash)
    #expect(match.port == 8000)
    #expect(LocalServerParsing.identify(["python3", "-m", "server.server", "--binary", "/tmp/splash/engine/other"]) == nil)
}

@Test func parsesProcArgs() {
    var bytes: [UInt8] = withUnsafeBytes(of: Int32(3)) { Array($0) }
    bytes += Array("/bin/kapitsa".utf8)
    bytes += [0, 0, 0, 0]
    for arg in ["kapitsa", "serve", "--port=8001", "HOME=/Users/me"] {
        bytes += Array(arg.utf8)
        bytes.append(0)
    }
    #expect(LocalServerParsing.procArgs(Data(bytes)) == ["kapitsa", "serve", "--port=8001"])
    #expect(LocalServerParsing.procArgs(Data([1, 0])) == nil)
}

@Test func kapitsaReadsActiveModelAndNamesPathsById() throws {
    var server = LocalServer(kind: .kapitsa, port: 8000, status: .ready)
    LocalServerParsing.kapitsa(try fixture("kapitsa-models.json"), into: &server)
    #expect(server.status == .ready)
    #expect(server.model == "flint")
    #expect(server.contextLength == 65536)
    #expect(server.slots == 1)

    var loading = LocalServer(kind: .kapitsa, port: 8000, status: .ready)
    LocalServerParsing.kapitsa(Data(#"{"data":[]}"#.utf8), into: &loading)
    #expect(loading.status == .loading)
}

@Test func splashReadsStatus() throws {
    var server = LocalServer(kind: .splash, port: 8001, status: .ready)
    LocalServerParsing.splash(try fixture("splash-status.json"), into: &server)
    #expect(server.status == .ready)
    #expect(server.model == "Qwen3.8-27B-GGUF")
    #expect(server.memoryUsed == 18_253_611_008)
    #expect(server.memoryLimit == 25_769_803_776)
    #expect(server.limitSource == .server)
    #expect(server.memoryPercent.map { ($0 * 10).rounded() / 10 } == 70.8)
    #expect(server.decodeTokensPerSecond == 38.7)
    #expect(server.inputTokens == 182_340)
    #expect(server.outputTokens == 20_511)
    #expect(server.requestsCompleted == 57)
    #expect(server.queued == 2)
}

@Test func splashMissingFieldsStayNilAndNotReadyIsLoading() {
    var server = LocalServer(kind: .splash, port: 8000, status: .ready)
    LocalServerParsing.splash(Data(#"{"ready": false, "metrics": {"decode_tokens_per_second": true}}"#.utf8), into: &server)
    #expect(server.status == .loading)
    #expect(server.decodeTokensPerSecond == nil)
    #expect(server.memoryPercent == nil)
    #expect(server.limitSource == nil)
}

@Test func missedPollKeepsLastReadingButNeverAnsweredIsStarting() {
    var ready = LocalServer(kind: .kapitsa, port: 8000, status: .ready)
    ready.model = "flint"
    ready.memoryUsed = 10
    ready.memoryLimit = 100
    var missed = LocalServer(kind: .kapitsa, port: 8000, status: .notAnswering)
    missed.memoryUsed = 20

    let kept = LocalServerParsing.merge(missed, previous: ready)
    #expect(kept.status == .notAnswering)
    #expect(kept.model == "flint")
    #expect(kept.memoryUsed == 20)
    #expect(kept.memoryLimit == 100)

    #expect(LocalServerParsing.merge(missed, previous: nil).status == .loading)
    #expect(LocalServerParsing.merge(missed, previous: LocalServer(kind: .kapitsa, port: 8000, status: .loading)).status == .loading)
    #expect(LocalServerParsing.merge(missed, previous: LocalServer(kind: .splash, port: 8000, status: .ready)).status == .loading)
    // A second miss keeps the reading too.
    #expect(LocalServerParsing.merge(missed, previous: kept).model == "flint")
    #expect(LocalServerParsing.merge(ready, previous: kept) == ready)
}

/// Finds and reads the servers running on this machine, and times the process scan.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE"] == "1"))
func liveLocalServers() async {
    let clock = ContinuousClock()
    var processes: [ServerProcess] = []
    let scan = clock.measure { processes = LocalServerProbe.scan() }
    print("LIVE local scan: \(scan), found \(processes.map { "\($0.kind) pid \($0.pid) port \($0.port)" })")
    for process in processes {
        let server = await LocalServerProbe.read(process)
        print("LIVE local \(server.kind):\(server.port) \(server.status) model=\(server.model ?? "-")",
              "memory=\(server.memoryUsed ?? 0)/\(server.memoryLimit ?? 0) (\(server.limitSource.map { "\($0)" } ?? "-"))",
              "context=\(server.contextLength ?? 0) slots=\(server.slots ?? 0) decode=\(server.decodeTokensPerSecond ?? 0)")
    }
}

@Test func identifiesLlamaServerAndRejectsCLI() throws {
    let standard = try #require(LocalServerParsing.identify(["/opt/homebrew/bin/llama-server", "-m", "model.gguf"]))
    #expect(standard.kind.rawValue == "llamaCpp")
    #expect(standard.port == 9931)
    #expect(LocalServerParsing.identify(["llama-server", "--port=8080"])?.port == 8080)
    #expect(LocalServerParsing.identify(["llama-server", "--port", "9000"])?.port == 9000)
    #expect(LocalServerParsing.identify(["llama-cli", "-m", "model.gguf"]) == nil)
}

@Test func llamaReadsPropertiesWithoutInventingMemoryLimit() throws {
    let kind = try #require(LocalServerKind(rawValue: "llamaCpp"))
    var server = LocalServer(kind: kind, port: 9931, status: .ready)
    LocalServerParsing.llamaCpp(Data(#"{"model_path":"/models/Qwen.gguf","total_slots":4,"default_generation_settings":{"n_ctx":8192}}"#.utf8), into: &server)
    #expect(server.status == .ready)
    #expect(server.model == "Qwen.gguf")
    #expect(server.contextLength == 8192)
    #expect(server.slots == 4)
    #expect(server.memoryLimit == nil)
    #expect(server.memoryPercent == nil)
    LocalServerParsing.llamaCpp(Data(#"{"error":{"code":503}}"#.utf8), into: &server)
    #expect(server.status == .loading)
}

@Test func llamaUsesAliasAndMiBBudget() async throws {
    for flags in [["--alias", "qwen3.8-27b-local", "--memory-budget", "24576"],
                  ["--alias=qwen3.8-27b-local", "--memory-budget=24576"]] {
        let match = try #require(LocalServerParsing.identify(["llama-server"] + flags))
        #expect(match.budget == UInt64(24) * 1_073_741_824)
        let process = ServerProcess(kind: match.kind, pid: 0, port: 0, budget: match.budget, alias: match.alias)
        let server = await LocalServerProbe.read(process)
        #expect(server.model == "qwen3.8-27b-local")
        #expect(server.memoryLimit == UInt64(24) * 1_073_741_824)
        #expect(server.limitSource == .budget)
    }
    for value in ["0", "-1", "invalid", "1.5", "18446744073709551615"] {
        #expect(LocalServerParsing.identify(["llama-server", "--memory-budget", value])?.budget == nil)
    }
}

/// Counts reads in flight, to show they overlap.
private actor InFlight {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

@Test(.timeLimit(.minutes(1))) func readsAllServersAtOnceInOrder() async {
    let processes = [8000, 8001, 9931].map { ServerProcess(kind: .kapitsa, pid: 1, port: $0, budget: nil) }
    let inFlight = InFlight()
    let servers = await LocalServerProbe.readAll(processes) { process in
        await inFlight.enter()
        // Each read waits until all have started; a serial loop would never finish.
        while await inFlight.peak < processes.count { await Task.yield() }
        await inFlight.leave()
        return LocalServer(kind: process.kind, port: process.port, status: .ready)
    }
    #expect(servers.map(\.port) == [8000, 8001, 9931])
    #expect(await inFlight.peak == 3)
}

@Test func identifiesOMLXLaunchersAndRejectsOtherCommands() throws {
    for args in [["omlx", "serve", "--port=8766"], ["/usr/bin/python3", "/opt/bin/omlx", "serve", "--port", "8766"],
                 ["python3", "-u", "-m", "omlx", "serve", "--port", "8766"], ["omlx-server", "--port=8766"]] {
        let match = try #require(LocalServerParsing.identify(args))
        #expect(match.kind == .omlx)
        #expect(match.port == 8766)
    }
    #expect(LocalServerParsing.identify(["omlx-server"])?.port == 8000)
    #expect(LocalServerParsing.identify(["omlx", "start"]) == nil)
    #expect(LocalServerParsing.identify(["omlx", "serve", "--port=99999"]) == nil)
    #expect(LocalServerParsing.identify(["python3", "unrelated.py", "serve"]) == nil)
}

@Test func omlxConfigurationUsesCLIThenEnvironmentThenSavedSettings() {
    let settings = Data(#"{"server":{"port":8766},"auth":{"api_key":"fixture-key"}}"#.utf8)
    let saved = OMLXConfiguration(args: [], environment: [:], settings: settings)
    #expect(saved.port == 8766)
    #expect(saved.apiKey == "fixture-key")
    let env = OMLXConfiguration(args: [], environment: ["OMLX_PORT": "8767", "OMLX_API_KEY": "env-key"], settings: settings)
    #expect(env.port == 8767)
    #expect(env.apiKey == "env-key")
    let cli = OMLXConfiguration(args: ["--port=8768", "--api-key=cli-key"],
                                environment: ["OMLX_PORT": "8767", "OMLX_API_KEY": "env-key"], settings: settings)
    #expect(cli.port == 8768)
    #expect(cli.apiKey == "cli-key")
}

@Test func omlxEnvironmentDoesNotConfuseArgumentsWithEnvironment() {
    var bytes = withUnsafeBytes(of: Int32(2)) { Array($0) }
    bytes += Array("/bin/omlx\0\0omlx\0serve\0OMLX_PORT=8766\0OMLX_API_KEY=fixture-key\0OTHER=ignored\0".utf8)
    #expect(LocalServerParsing.omlxEnvironment(Data(bytes)) == ["OMLX_PORT": "8766", "OMLX_API_KEY": "fixture-key"])
}

@Test func omlxReadsStatsAndDashboardUsesDetectedPort() throws {
    var server = LocalServer(kind: .omlx, port: 8766, status: .ready)
    LocalServerParsing.omlx(try fixture("omlx-stats.json"), into: &server)
    #expect(server.model == "Qwen3.5-27B, embedding-model")
    #expect(server.memoryUsed == 18253611008)
    #expect(server.memoryLimit == 25769803776)
    #expect(server.limitSource == .server)
    #expect(server.decodeTokensPerSecond == 38.7)
    #expect(server.prefillTokensPerSecond == 612.4)
    #expect(server.inputTokens == 182340)
    #expect(server.outputTokens == 20511)
    #expect(server.requestsCompleted == 57)
    #expect(server.queued == 2)
    #expect(server.dashboardURL?.absoluteString == "http://127.0.0.1:8766/admin")
    #expect(LocalServer(kind: .splash, port: 8000, status: .ready).dashboardURL == nil)
}

@Test func omlxHandlesIdleInvalidAndMissingMetrics() {
    var server = LocalServer(kind: .omlx, port: 8000, status: .ready)
    LocalServerParsing.omlx(Data(#"{"active_models":{"models":[],"model_memory_used":false,"model_memory_max":-1},"total_requests":1e99}"#.utf8), into: &server)
    #expect(server.status == .ready)
    #expect(server.model == nil)
    #expect(server.memoryUsed == nil)
    #expect(server.memoryLimit == nil)
    #expect(server.requestsCompleted == nil)
    LocalServerParsing.omlx(Data(#"{"detail":"not stats"}"#.utf8), into: &server)
    #expect(server.status == .notAnswering)
}

@Test func omlxProbeUsesStatsRouteAndHandlesRejectedAuthentication() async {
    let process = ServerProcess(kind: .omlx, pid: -1, port: 49871, budget: nil, apiKey: "fixture-key")
    let server = await LocalServerProbe.read(process) { request in
        #expect(request.url?.path == "/admin/api/stats")
        #expect(request.url?.port == 49871)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        throw ProviderError.unauthorized("fixture")
    }
    #expect(server.status == .locked)
}

@Test func omlxProbeReadsAuthenticatedStats() async throws {
    let data = try fixture("omlx-stats.json")
    let process = ServerProcess(kind: .omlx, pid: -1, port: 49872, budget: nil, apiKey: "fixture-key")
    let server = await LocalServerProbe.read(process) { _ in data }
    #expect(server.status == .ready)
    #expect(server.memoryUsed == 18253611008)
    #expect(server.requestsCompleted == 57)
}

@Test func discoversListeningPortFromKernel() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0)
    try #require(listen(fd, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    try #require(result == 0)
    #expect(LocalServerProbe.listeningPorts(getpid()).contains(Int(UInt16(bigEndian: address.sin_port))))
}
