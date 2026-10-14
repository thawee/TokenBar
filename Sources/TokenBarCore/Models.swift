import Foundation

public enum ProviderID: String, CaseIterable, Sendable, Identifiable {
    case claude, codex, copilot, antigravity

    public var id: String { rawValue }

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
