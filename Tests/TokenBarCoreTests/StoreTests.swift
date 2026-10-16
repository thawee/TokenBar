import Foundation
import Testing
@testable import TokenBarCore

/// Returns queued results in order, then repeats the last one.
private final class FakeProvider: LimitsProvider, @unchecked Sendable {
    let id: ProviderID
    let minInterval: TimeInterval
    private let lock = NSLock()
    private var results: [Result<LimitsReading, ProviderError>]
    private(set) var calls = 0

    init(_ id: ProviderID, interval: TimeInterval = 300, _ results: [Result<LimitsReading, ProviderError>]) {
        self.id = id
        self.minInterval = interval
        self.results = results
    }

    func fetch() async throws -> LimitsReading {
        let result = lock.withLock {
            calls += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
        return try result.get()
    }
}

private func reading(_ percent: Double, resetsAt: Date? = nil) -> LimitsReading {
    LimitsReading(
        plan: nil,
        windows: [LimitWindow(label: "5-hour", kind: .session, usedPercent: percent, resetsAt: resetsAt)],
        observedAt: Date()
    )
}

@MainActor @Test func failureKeepsLastReadingAndRetriesWithinAMinute() async {
    let fake = FakeProvider(.claude, [.success(reading(40)), .failure(.failed("HTTP 500")), .success(reading(50))])
    let store = LimitsStore(providers: [fake])
    let t0 = Date()

    await store.refresh(now: t0)
    await store.refresh(now: t0.addingTimeInterval(301))
    #expect(store.states[.claude]?.reading?.windows.first?.usedPercent == 40)
    #expect(store.states[.claude]?.error == .failed("HTTP 500"))

    await store.refresh(now: t0.addingTimeInterval(301 + 30))
    #expect(fake.calls == 2, "not due yet: 30 s after a failure")
    await store.refresh(now: t0.addingTimeInterval(301 + 61))
    #expect(fake.calls == 3)
    #expect(store.states[.claude]?.reading?.windows.first?.usedPercent == 50)
    #expect(store.states[.claude]?.error == nil)
}

@MainActor @Test func forceRespectsThirtySecondFloor() async {
    let fake = FakeProvider(.copilot, [.success(reading(10))])
    let store = LimitsStore(providers: [fake])
    let t0 = Date()
    await store.refresh(now: t0)
    await store.refresh(force: true, now: t0.addingTimeInterval(10))
    #expect(fake.calls == 1)
    await store.refresh(force: true, now: t0.addingTimeInterval(31))
    #expect(fake.calls == 2)
}

@MainActor @Test func notConfiguredIsHiddenAndClearsReading() async {
    let fake = FakeProvider(.antigravity, interval: 0, [.success(reading(10)), .failure(.notConfigured("gone"))])
    let store = LimitsStore(providers: [fake])
    await store.refresh()
    #expect(store.visible == [.antigravity])
    await store.refresh()
    #expect(store.visible.isEmpty)
    #expect(store.states[.antigravity]?.reading == nil)
}

@MainActor @Test func headlineSkipsWindowsPastTheirReset() async {
    let stale = FakeProvider(.claude, [.success(reading(95, resetsAt: Date().addingTimeInterval(-60)))])
    let fresh = FakeProvider(.codex, [.success(reading(30, resetsAt: Date().addingTimeInterval(3600)))])
    let store = LimitsStore(providers: [stale, fresh])
    await store.refresh()
    #expect(store.headlinePercent == 30)
}

@MainActor @Test func disabledToolsAreNotFetchedAndReEnableFetchesAgain() async throws {
    let claude = FakeProvider(.claude, [.success(reading(10))])
    let codex = FakeProvider(.codex, [.success(reading(20))])
    let store = LimitsStore(providers: [claude, codex])
    store.enabled = [.codex]
    await store.refresh()
    #expect(claude.calls == 0)
    #expect(store.visible == [.codex])

    store.enabled = []
    #expect(store.visible.isEmpty)
    #expect(store.headlinePercent == nil)

    store.enabled = [.claude]
    await store.refresh()
    #expect(claude.calls == 1)
    #expect(store.visible == [.claude])
}

@MainActor @Test func mostUrgentUsesEachToolsHeadlineWindow() async throws {
    let monthly = LimitsReading(plan: nil, windows: [
        LimitWindow(label: "Premium", kind: .monthly, usedPercent: 80, resetsAt: nil),
    ], observedAt: Date())
    let session = LimitsReading(plan: nil, windows: [
        LimitWindow(label: "Weekly", kind: .weekly, usedPercent: 99, resetsAt: nil),
        LimitWindow(label: "5-hour", kind: .session, usedPercent: 40, resetsAt: nil),
    ], observedAt: Date())
    let store = LimitsStore(providers: [
        FakeProvider(.copilot, [.success(monthly)]),
        FakeProvider(.claude, [.success(session)]),
    ])
    await store.refresh()
    // Claude's 5-hour (40) stands for Claude, not its weekly 99; Copilot has only monthly.
    let urgent = try #require(store.mostUrgent())
    #expect(urgent.id == .copilot)
    #expect(urgent.usedPercent == 80)
    #expect(session.headlineWindow?.label == "5-hour")
    #expect(monthly.headlineWindow?.label == "Premium")
}

@Test func windowCurrentUsedPercentResetsAfterExpiry() {
    let now = Date()
    let expired = LimitWindow(label: "5-hour", kind: .session, usedPercent: 95, resetsAt: now.addingTimeInterval(-1))
    let active = LimitWindow(label: "5-hour", kind: .session, usedPercent: 95, resetsAt: now.addingTimeInterval(60))
    let noReset = LimitWindow(label: "Monthly", kind: .monthly, usedPercent: 50, resetsAt: nil)
    #expect(expired.currentUsedPercent(now: now) == 0)
    #expect(active.currentUsedPercent(now: now) == 95)
    #expect(noReset.currentUsedPercent(now: now) == 50)
}

