import SwiftUI
import TokenBarCore

enum DockSize: String, CaseIterable, Identifiable {
    case normal, mini

    var id: String { rawValue }

    var metrics: DockMetrics {
        switch self {
        case .normal: DockMetrics(width: 76, ring: 42, line: 4, logo: 20, font: 12, spacing: 14, flare: 18, radius: 14, headers: true)
        case .mini: DockMetrics(width: 50, ring: 30, line: 3, logo: 14, font: 10, spacing: 9, flare: 12, radius: 10, headers: false)
        }
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

    var size: DockSize {
        didSet { defaults.set(size.rawValue, forKey: "dock.size") }
    }
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

    init() {
        size = DockSize(rawValue: defaults.string(forKey: "dock.size") ?? "") ?? .normal
        limitDisplay = LimitDisplay(rawValue: defaults.string(forKey: "limits.display") ?? "") ?? .used
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
