import SwiftUI
import TokenBarCore

/// The rail's size as one scale factor; every dimension follows it, so any size
/// between the smallest and largest keeps the same proportions.
enum DockScale {
    static let range: ClosedRange<Double> = 0.6...1.0
    static let step = 0.05
    static let standard = 0.85
    /// Below this the section headings no longer fit and are hidden.
    static let headingsFrom = 0.8

    static func metrics(_ scale: Double) -> DockMetrics {
        let s = CGFloat(min(max(scale, range.lowerBound), range.upperBound))
        return DockMetrics(
            width: (76 * s).rounded(), ring: (42 * s).rounded(), line: max(2.5, 4 * s),
            logo: (20 * s).rounded(), font: max(9, (12 * s).rounded()), spacing: (14 * s).rounded(),
            flare: (18 * s).rounded(), radius: (14 * s).rounded(), headers: scale >= headingsFrom
        )
    }
}

/// Whether AI limits read as how much is used or how much is left.
enum LimitDisplay: String, CaseIterable, Identifiable {
    case used, remaining

    var id: String { rawValue }

    /// The number to show for a window's used percentage.
    func value(_ used: Double?) -> Double? {
        used.map { self == .used ? $0 : 100 - $0 }
    }

    /// Near the limit either way: 90% used is 10% left.
    func isAlert(_ shown: Double) -> Bool {
        self == .used ? shown >= 90 : shown <= 10
    }

    var word: String { self == .used ? "used" : "left" }
}

/// What the menu bar item shows.
enum MenuBarMode: Hashable {
    /// The tool closest to its limit: its logo and number.
    case urgent
    /// Always this tool.
    case tool(ProviderID)
    /// Just the gauge until a limit passes `quietThreshold`, then like `urgent`.
    case iconOnly

    static let quietThreshold: Double = 70

    var rawValue: String {
        switch self {
        case .urgent: "urgent"
        case .tool(let id): "tool." + id.rawValue
        case .iconOnly: "icon"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "urgent": self = .urgent
        case "icon": self = .iconOnly
        default:
            guard rawValue.hasPrefix("tool."), let id = ProviderID(rawValue: String(rawValue.dropFirst(5))) else { return nil }
            self = .tool(id)
        }
    }
}

/// Every size-dependent number of the rail, so mini and normal share one layout.
struct DockMetrics {
    let width, ring, line, logo, font, spacing, flare, radius: CGFloat
    let headers: Bool
}

/// One ring on the rail: an AI tool's limit or a system metric.
enum DockItem: Hashable, Identifiable {
    case provider(ProviderID)
    case metric(SystemMetric)

    var id: String {
        switch self {
        case .provider(let p): "p." + p.rawValue
        case .metric(let m): "m." + m.rawValue
        }
    }
}

/// What the dock shows, persisted in UserDefaults.
@MainActor
@Observable
final class DockSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// See `DockScale`; 1.0 is the original Normal size, 0.66 about the old Mini.
    var scale: Double {
        didSet { defaults.set(scale, forKey: "dock.scale") }
    }
    var dockMetrics: DockMetrics { DockScale.metrics(scale) }
    /// Disabled tools are not fetched at all, so this also applies to the menu bar.
    var tools: Set<ProviderID> {
        didSet { defaults.set(tools.map(\.rawValue).sorted(), forKey: "dock.tools") }
    }
    var metrics: Set<SystemMetric> {
        didSet { defaults.set(metrics.map(\.rawValue).sorted(), forKey: "dock.metrics") }
    }
    /// Applies everywhere a limit is shown: dock, hover card, popover and menu bar.
    var limitDisplay: LimitDisplay {
        didSet { defaults.set(limitDisplay.rawValue, forKey: "limits.display") }
    }
    var menuBar: MenuBarMode {
        didSet { defaults.set(menuBar.rawValue, forKey: "menubar.mode") }
    }

    init() {
        scale = defaults.object(forKey: "dock.scale") as? Double ?? DockScale.standard
        limitDisplay = LimitDisplay(rawValue: defaults.string(forKey: "limits.display") ?? "") ?? .used
        menuBar = MenuBarMode(rawValue: defaults.string(forKey: "menubar.mode") ?? "") ?? .urgent
        tools = (defaults.stringArray(forKey: "dock.tools")).map { Set($0.compactMap(ProviderID.init)) }
            ?? Set(ProviderID.allCases)
        metrics = (defaults.stringArray(forKey: "dock.metrics")).map { Set($0.compactMap(SystemMetric.init)) }
            ?? Set(SystemMetric.allCases)
    }

    func binding(for id: ProviderID) -> Binding<Bool> {
        Binding(get: { self.tools.contains(id) }, set: { on in
            if on { self.tools.insert(id) } else { self.tools.remove(id) }
        })
    }

    func binding(for metric: SystemMetric) -> Binding<Bool> {
        Binding(get: { self.metrics.contains(metric) }, set: { on in
            if on { self.metrics.insert(metric) } else { self.metrics.remove(metric) }
        })
    }
}
