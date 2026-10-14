import SwiftUI
import TokenBarCore

enum DockSide: String {
    case left, right
}

/// The rail body plus concave fillets where it meets the screen edge.
/// Drawn for the right edge; mirrored for the left.
struct DockShape: Shape {
    var radius: CGFloat = 14
    var flare: CGFloat = 18
    /// Open for the outline, so no line is drawn along the screen edge itself.
    var closed = true

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, f = flare, r = radius
        var p = Path()
        p.move(to: CGPoint(x: w, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - f, y: f), control: CGPoint(x: w, y: f))
        p.addLine(to: CGPoint(x: r, y: f))
        p.addQuadCurve(to: CGPoint(x: 0, y: f + r), control: CGPoint(x: 0, y: f))
        p.addLine(to: CGPoint(x: 0, y: h - f - r))
        p.addQuadCurve(to: CGPoint(x: r, y: h - f), control: CGPoint(x: 0, y: h - f))
        p.addLine(to: CGPoint(x: w - f, y: h - f))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w, y: h - f))
        if closed { p.closeSubpath() }
        return p
    }
}

/// Ring color, logo and fallback glyph per tool. Logos live in Contents/Resources/Icons
/// (see Resources/Icons/NOTICE.md); the SF Symbol is used when a file is missing.
extension ProviderID {
    @MainActor private static var logos: [ProviderID: NSImage] = [:]

    @MainActor var logo: NSImage? {
        if let cached = Self.logos[self] { return cached }
        guard let url = Bundle.main.resourceURL?.appending(path: "Icons/\(rawValue).svg"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        // Single-color marks are tinted to match the rail; Antigravity keeps its colors.
        image.isTemplate = self != .antigravity
        Self.logos[self] = image
        return image
    }

    /// The logo as a 16 pt template image for the menu bar, so it follows the menu bar's
    /// light or dark appearance. Antigravity's multicolor logo becomes its silhouette.
    @MainActor var menuBarImage: NSImage? {
        guard let logo, let image = logo.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(white: 0.85)
        case .copilot: Color(red: 0.66, green: 0.52, blue: 0.98)
        case .antigravity: Color(red: 0.36, green: 0.56, blue: 1.0)
        }
    }

    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "terminal"
        case .copilot: "airplane"
        case .antigravity: "chevron.up"
        }
    }
}

extension SystemMetric {
    var tint: Color {
        switch self {
        case .cpu: Color(red: 0.33, green: 0.82, blue: 0.80)
        case .memory: Color(red: 0.45, green: 0.85, blue: 0.48)
        case .gpu: Color(red: 0.96, green: 0.45, blue: 0.70)
        case .temperature: Color(red: 0.98, green: 0.72, blue: 0.30)
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "cube.transparent"
        case .temperature: "thermometer.medium"
        }
    }

    /// Ring fill: percentages as is; temperature on a 0-100 °C scale.
    func fraction(_ value: Double) -> Double { min(max(value / 100, 0), 1) }

    func label(_ value: Double) -> String {
        self == .temperature ? "\(Int(value.rounded()))°" : "\(Int(value.rounded()))%"
    }

    func isAlert(_ value: Double) -> Bool { value >= 90 }
}

/// State the controller changes without rebuilding the view tree.
@MainActor
@Observable
final class DockState {
    var side: DockSide
    var hovered: DockItem?
    /// Ring frames in the "dock" coordinate space (top-left origin), for hover hit-testing.
    @ObservationIgnored var ringFrames: [DockItem: CGRect] = [:] {
        didSet { if ringFrames != oldValue { onRingFramesChange?() } }
    }
    @ObservationIgnored var onRingFramesChange: (() -> Void)?

    init(side: DockSide) {
        self.side = side
    }
}

private struct RingFramesKey: PreferenceKey {
    static let defaultValue: [DockItem: CGRect] = [:]
    static func reduce(value: inout [DockItem: CGRect], nextValue: () -> [DockItem: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private let alertRed = Color(red: 1, green: 0.45, blue: 0.4)

struct DockView: View {
    let store: LimitsStore
    let system: SystemStore
    let settings: DockSettings
    let state: DockState
    let onDrag: (_ ended: Bool) -> Void

    private var m: DockMetrics { settings.size.metrics }

    /// Enabled metrics this Mac can report, in a fixed order.
    private var metrics: [SystemMetric] {
        SystemMetric.allCases.filter { settings.metrics.contains($0) && system.availableMetrics.contains($0) }
    }

    var body: some View {
        VStack(spacing: m.spacing) {
            if !metrics.isEmpty {
                header("SYSTEM")
                ForEach(metrics) { metric in
                    let value = system.snapshot?.value(metric)
                    ring(.metric(metric)) {
                        RingGauge(m: m, tint: metric.tint, value: value,
                                  fraction: value.map(metric.fraction) ?? 0,
                                  label: { $0.map(metric.label) ?? "--" }, alert: metric.isAlert,
                                  highlighted: state.hovered == .metric(metric), animated: false) {
                            Image(systemName: metric.symbol)
                                .font(.system(size: m.logo * 0.72, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                    }
                }
            }
            if !store.visible.isEmpty && !metrics.isEmpty {
                Capsule().fill(.white.opacity(0.14)).frame(width: m.ring * 0.6, height: 1)
            }
            if !store.visible.isEmpty {
                header(settings.limitDisplay == .used ? "AI USED" : "AI LEFT")
                ForEach(store.visible) { id in
                    let shown = settings.limitDisplay.value(store.states[id]?.reading?.headlineWindow?.usedPercent)
                    ring(.provider(id)) {
                        RingGauge(m: m, tint: id.tint, value: shown,
                                  fraction: (shown ?? 0) / 100,
                                  label: percentText, alert: settings.limitDisplay.isAlert,
                                  highlighted: state.hovered == .provider(id)) {
                            ProviderLogo(id: id, size: m.logo)
                        }
                    }
                }
            }
            if store.visible.isEmpty && metrics.isEmpty {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: m.logo * 0.8))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.vertical, m.flare + (m.headers ? 16 : 12))
        .frame(width: m.width)
        .background {
            DockShape(radius: m.radius, flare: m.flare)
                .fill(LinearGradient(
                    colors: [Color(red: 0.12, green: 0.21, blue: 0.40), Color(red: 0.06, green: 0.11, blue: 0.22)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(DockShape(radius: m.radius, flare: m.flare, closed: false).stroke(.white.opacity(0.14), lineWidth: 1))
                .scaleEffect(x: state.side == .left ? -1 : 1)
        }
        .coordinateSpace(name: "dock")
        .onPreferenceChange(RingFramesKey.self) { frames in
            MainActor.assumeIsolated { state.ringFrames = frames }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in onDrag(false) }
                .onEnded { _ in onDrag(true) }
        )
    }

    @ViewBuilder private func header(_ text: String) -> some View {
        if m.headers {
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func ring<Content: View>(_ item: DockItem, @ViewBuilder content: () -> Content) -> some View {
        content().background(GeometryReader { geo in
            Color.clear.preference(key: RingFramesKey.self, value: [item: geo.frame(in: .named("dock"))])
        })
    }
}

struct ProviderLogo: View {
    let id: ProviderID
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let logo = id.logo {
                Image(nsImage: logo).resizable().scaledToFit().frame(width: size, height: size)
            } else {
                Image(systemName: id.symbol).font(.system(size: size * 0.75, weight: .semibold))
            }
        }
        .foregroundStyle(.white.opacity(0.92))
    }
}

/// "Resets in 1h 23m" within a day, otherwise "Resets Tue 07:00".
func resetText(_ date: Date, now: Date = Date()) -> String {
    let seconds = date.timeIntervalSince(now)
    guard seconds > 0 else { return "Resetting now" }
    guard seconds >= 86_400 else {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? "Resets in \(minutes / 60)h \(minutes % 60)m" : "Resets in \(minutes)m"
    }
    return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

private func percentText(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))%" } ?? "--"
}

struct RingGauge<Center: View>: View {
    let m: DockMetrics
    let tint: Color
    let value: Double?
    let fraction: Double
    let label: (Double?) -> String
    let alert: (Double) -> Bool
    var highlighted = false
    /// Off for system metrics: they change every 2 s, and animating each change keeps
    /// SwiftUI redrawing at display rate.
    var animated = true
    @ViewBuilder let center: () -> Center

    var body: some View {
        VStack(spacing: m.headers ? 5 : 3) {
            ZStack {
                Circle().fill(.white.opacity(highlighted ? 0.08 : 0))
                Circle().stroke(.white.opacity(0.10), lineWidth: m.line)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: m.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(animated ? .easeOut(duration: 0.6) : nil, value: fraction)
                center()
            }
            .frame(width: m.ring, height: m.ring)
            .scaleEffect(highlighted ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: highlighted)
            Text(label(value))
                .font(.system(size: m.font, weight: .semibold).monospacedDigit())
                .foregroundStyle(value.map(alert) == true ? alertRed : .white.opacity(0.9))
        }
    }
}

// MARK: Hover cards

struct HoverCard: View {
    let item: DockItem
    let store: LimitsStore
    let system: SystemStore
    let settings: DockSettings

    static let width: CGFloat = 232

    var body: some View {
        Group {
            switch item {
            case .provider(let id): LimitCardContent(id: id, state: store.states[id], display: settings.limitDisplay)
            case .metric(let metric): MetricCardContent(metric: metric, snapshot: system.snapshot)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.08, green: 0.14, blue: 0.28).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14), lineWidth: 1))
        )
    }
}

private struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

private struct LimitCardContent: View {
    let id: ProviderID
    let state: ProviderState?
    let display: LimitDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderLogo(id: id, size: 16)
                Text(id.displayName).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if let plan = state?.reading?.plan {
                    Text(plan.capitalized)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(id.tint.opacity(0.25)))
                }
            }
            ForEach(Array((state?.reading?.windows ?? []).enumerated()), id: \.offset) { _, window in
                let shown = display.value(window.usedPercent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(window.label).font(.system(size: 11))
                        Spacer()
                        Text(shown.map { "\(percentText($0)) \(display.word)" } ?? "--")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(shown.map(display.isAlert) == true ? alertRed : .white)
                    }
                    UsageBar(fraction: (shown ?? 0) / 100, tint: id.tint)
                    if let resetsAt = window.resetsAt {
                        Text(resetText(resetsAt))
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            if let error = state?.error {
                Text(error.message).font(.system(size: 10)).foregroundStyle(alertRed.opacity(0.9))
            }
            if let observed = state?.reading?.observedAt {
                Text("Updated \(observed, format: .relative(presentation: .named))")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

private struct MetricCardContent: View {
    let metric: SystemMetric
    let snapshot: SystemSnapshot?

    private var value: Double? { snapshot?.value(metric) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: metric.symbol).font(.system(size: 13, weight: .semibold))
                Text(metric.displayName).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(value.map(metric.label) ?? "--")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(value.map(metric.isAlert) == true ? alertRed : .white)
            }
            UsageBar(fraction: value.map(metric.fraction) ?? 0, tint: metric.tint)
            ForEach(details, id: \.self) { line in
                Text(line).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var details: [String] {
        guard let s = snapshot else { return [] }
        switch metric {
        case .cpu:
            return ["\(ProcessInfo.processInfo.activeProcessorCount) cores, all combined"]
        case .memory:
            guard let used = s.memoryUsed else { return [] }
            let gb = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_073_741_824) }
            return ["\(gb(used)) of \(gb(s.memoryTotal)) GB used", "App memory, wired and compressed"]
        case .gpu:
            return ["Includes drawing the screen, not only local models"]
        case .temperature:
            let c = { (label: String, value: Double?) in value.map { String(format: "%@ %.1f°C", label, $0) } }
            return [c("CPU die average", s.cpuTemperature), c("CPU hottest point", s.cpuTemperatureMax),
                    c("GPU die average", s.gpuTemperature)].compactMap { $0 }
        }
    }
}
