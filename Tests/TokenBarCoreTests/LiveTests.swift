import Foundation
import Testing
import TokenBarCore

/// Hits the real sources on this machine. Run with `LIVE=1 swift test --filter live`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE"] == "1"))
func liveProviders() async {
    let providers: [any LimitsProvider] = [ClaudeProvider(), CodexProvider(), CopilotProvider(), AntigravityProvider()]
    for provider in providers {
        do {
            let reading = try await provider.fetch()
            let windows = reading.windows.map { w in
                "\(w.label)=\(w.usedPercent.map { String(Int($0)) } ?? "?")% reset=\(w.resetsAt.map { "\($0)" } ?? "-")"
            }
            print("LIVE \(provider.id): plan=\(reading.plan ?? "-") \(windows.joined(separator: ", "))")
        } catch {
            print("LIVE \(provider.id): \(error)")
        }
    }
}
