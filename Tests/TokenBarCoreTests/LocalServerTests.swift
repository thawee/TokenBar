import Foundation
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
