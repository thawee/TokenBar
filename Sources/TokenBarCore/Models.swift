import Foundation

public enum ProviderID: String, CaseIterable, Sendable, Identifiable {
    case claude, codex, copilot, antigravity

    public var id: String { rawValue }

    public static var displayOrder: [ProviderID] {
        allCases.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "GitHub Copilot"
        case .antigravity: "Antigravity"
        }
    }
}

public enum WindowKind: Sendable, Equatable {
    case session, weekly, monthly, other
}

public struct LimitWindow: Sendable, Equatable {
    public let label: String
    public let kind: WindowKind
    /// 0...100, nil when the provider reports the window without a value.
    public let usedPercent: Double?
    public let resetsAt: Date?

    public init(label: String, kind: WindowKind, usedPercent: Double?, resetsAt: Date?) {
        self.label = label
        self.kind = kind
        self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
        self.resetsAt = resetsAt
    }

    /// Returns 0 when the window's reset time has already passed; otherwise `usedPercent`.
    public func currentUsedPercent(now: Date = Date()) -> Double? {
        guard let usedPercent else { return nil }
        if let resetsAt, resetsAt <= now { return 0 }
        return usedPercent
    }
}

public struct LimitsReading: Sendable, Equatable {
    public let plan: String?
    public let windows: [LimitWindow]
    /// When the data was observed (file mtime for local sources, fetch time for network ones).
    public let observedAt: Date

    public init(plan: String?, windows: [LimitWindow], observedAt: Date) {
        self.plan = plan
        self.windows = windows
        self.observedAt = observedAt
    }
}

extension LimitsReading {
    /// The window that stands for the tool: its 5-hour window, or its first one when it
    /// has none (Copilot only has a monthly quota).
    public var headlineWindow: LimitWindow? {
        windows.first { $0.kind == .session } ?? windows.first
    }
}

public enum ProviderError: Error, Sendable, Equatable {
    /// Tool not installed or not signed in. Not an error from the user's point of view.
    case notConfigured(String)
    /// The tool is installed but its local process is not running (Antigravity).
    case notRunning(String)
    case unauthorized(String)
    case rateLimited
    case failed(String)

    public var message: String {
        switch self {
        case .notConfigured(let m), .notRunning(let m), .unauthorized(let m), .failed(let m): m
        case .rateLimited: "Rate limited by the provider, will retry later"
        }
    }
}
