import Foundation
import Observation

public struct ProviderState: Sendable, Equatable {
    /// Last good reading. Kept when a later fetch fails so the UI shows stale data, not nothing.
    public var reading: LimitsReading?
    public var error: ProviderError?
    public var lastAttempt: Date?
}

@MainActor
@Observable
public final class LimitsStore {
    public private(set) var states: [ProviderID: ProviderState] = [:]
    public private(set) var isRefreshing = false
    /// A refresh was asked for while one was running; run it once that one finishes.
    @ObservationIgnored private var refreshPending = false
    private let providers: [any LimitsProvider]
    private var loop: Task<Void, Never>?

    /// Tools the user wants. Disabled ones are never fetched (no Keychain read, no
    /// network) and drop out of `visible`; re-enabled ones are fetched right away.
    public var enabled: Set<ProviderID> = Set(ProviderID.allCases) {
        didSet {
            guard enabled != oldValue else { return }
            for id in oldValue.subtracting(enabled) { states[id] = nil }
            if !enabled.subtracting(oldValue).isEmpty { Task { await refresh() } }
        }
    }

    public init(providers: [any LimitsProvider] = [
        ClaudeProvider(), CodexProvider(), CopilotProvider(), AntigravityProvider(),
    ]) {
        self.providers = providers
    }

    /// Providers worth showing: anything with data, or an error other than "not set up".
    public var visible: [ProviderID] {
        ProviderID.displayOrder.filter { id in
            guard let state = states[id] else { return false }
            if state.reading != nil { return true }
            if case .notConfigured = state.error { return false }
            return state.error != nil
        }
    }

    /// The most urgent tool's usage percentage.
    public var headlinePercent: Double? { mostUrgent()?.usedPercent }

    /// The tool closest to its limit, by each tool's headline window. Windows whose
    /// reset has passed are skipped: their percentage is from before the reset.
    public func mostUrgent(now: Date = Date()) -> (id: ProviderID, usedPercent: Double)? {
        visible
            .compactMap { id -> (id: ProviderID, usedPercent: Double)? in
                guard let window = states[id]?.reading?.headlineWindow,
                      let used = window.usedPercent,
                      window.resetsAt.map({ $0 > now }) ?? true
                else { return nil }
                return (id, used)
            }
            .max { $0.usedPercent < $1.usedPercent }
    }

    /// Seconds before a provider is fetched again. A transient failure retries after a
    /// minute instead of waiting out a full network interval; `force` (popover opened,
    /// Refresh pressed) still keeps network providers at least 30 s apart.
    func interval(for provider: any LimitsProvider, force: Bool) -> TimeInterval {
        var interval = provider.minInterval
        switch states[provider.id]?.error {
        case .failed?, .unauthorized?: interval = min(interval, 60)
        default: break
        }
        return force ? min(interval, 30) : interval
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Fetches every provider whose interval has elapsed. Skipped while another refresh
    /// is in flight (the loop, the popover and the button can all trigger one).
    public func refresh(force: Bool = false, now: Date = Date()) async {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        let due = providers.filter { provider in
            guard enabled.contains(provider.id) else { return false }
            guard let last = states[provider.id]?.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= interval(for: provider, force: force)
        }
        guard !due.isEmpty else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshPending {
                refreshPending = false
                Task { await refresh() }
            }
        }
        for provider in due { states[provider.id, default: ProviderState()].lastAttempt = now }

        await withTaskGroup(of: (ProviderID, Result<LimitsReading, ProviderError>).self) { group in
            for provider in due {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetch())) }
                    catch let error as ProviderError { return (provider.id, .failure(error)) }
                    catch { return (provider.id, .failure(.failed(error.localizedDescription))) }
                }
            }
            for await (id, result) in group {
                // Turned off while the fetch was in flight.
                guard enabled.contains(id) else { continue }
                switch result {
                case .success(let reading):
                    states[id]?.reading = reading
                    states[id]?.error = nil
                case .failure(let error):
                    states[id]?.error = error
                    // A provider that is no longer set up should not keep showing old numbers.
                    if case .notConfigured = error { states[id]?.reading = nil }
                }
            }
        }
    }
}
