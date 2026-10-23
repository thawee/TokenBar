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

extension LocalServerKind {
    var tint: Color {
        switch self {
        case .kapitsa: Color(red: 0.82, green: 0.90, blue: 0.32)
        case .splash: Color(red: 0.62, green: 0.70, blue: 1.0)
        }
    }

    var symbol: String {
        switch self {
        case .kapitsa: "atom"
        case .splash: "drop.fill"
        }
    }
}

extension LocalServer {
    /// What VoiceOver reads for the ring.
    var spoken: String {
        switch status {
        case .loading: return "Starting"
        case .notAnswering: return "Not answering"
        case .locked: return "Needs an API key"
        case .ready:
            guard let percent = memoryPercent else { return "Running" }
            return "Memory \(Int(percent.rounded())) percent of its limit" + (model.map { ", \($0)" } ?? "")
        }
    }
}

extension SystemMetric {
    var tint: Color {
        switch self {
        case .cpu: Color(red: 0.33, green: 0.82, blue: 0.80)
        case .memory: Color(red: 0.45, green: 0.85, blue: 0.48)
        case .gpu: Color(red: 0.96, green: 0.45, blue: 0.70)
        case .storage: Color(red: 0.35, green: 0.75, blue: 1.0)
        case .temperature: Color(red: 0.98, green: 0.72, blue: 0.30)
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "cube.fill"
        case .storage: "internaldrive"
        case .temperature: "thermometer.medium"
        }
    }

    /// Ring fill: percentages as is; temperature on a 0-100 °C scale.
    func fraction(_ value: Double) -> Double { min(max(value / 100, 0), 1) }

    func label(_ value: Double) -> String {
        self == .temperature ? "\(Int(value.rounded()))°" : "\(Int(value.rounded()))%"
    }

    func isAlert(_ value: Double) -> Bool { value >= 90 }

    /// What VoiceOver reads for a value.
    func spoken(_ value: Double?) -> String {
        guard let value else { return "Measuring" }
        let n = Int(value.rounded())
        switch self {
        case .temperature: return "\(n) degrees Celsius"
        case .storage: return "\(n) percent full"
        default: return "\(n) percent"
        }
    }
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

/// Lightest red that keeps 4.5:1 for the alert number on the rail's top color.
private let alertRed = Color(red: 1, green: 0.48, blue: 0.42)

struct DockView: View {
    let store: LimitsStore
    let system: SystemStore
    let local: LocalServerStore
    let settings: DockSettings
    let state: DockState
    let onDrag: (_ ended: Bool) -> Void
    var onHide: (() -> Void)? = nil

    private var m: DockMetrics { settings.dockMetrics }

    /// Enabled metrics this Mac can report, in a fixed order. GPU folds into the CPU
    /// ring when combined.
    private var metrics: [SystemMetric] {
        let shown = SystemMetric.allCases.filter { settings.metrics.contains($0) && system.availableMetrics.contains($0) }
        return isCombined && shown.contains(.cpu) ? shown.filter { $0 != .gpu } : shown
    }

    private var isCombined: Bool { settings.combinesGPU(available: system.availableMetrics) }

    var body: some View {
        VStack(spacing: m.spacing) {
            if !metrics.isEmpty {
                header("SYSTEM")
                ForEach(metrics) { metric in
                    let gpu = metric == .cpu && isCombined ? system.snapshot?.value(.gpu) : nil
                    let own = system.snapshot?.value(metric)
                    // Combined, the label shows the busier of the two.
                    let value = gpu.map { max($0, own ?? 0) } ?? own
                    ring(.metric(metric)) {
                        RingGauge(m: m, tint: metric.tint, value: value,
                                  fraction: own.map(metric.fraction) ?? 0,
                                  label: { $0.map(metric.label) ?? "--" }, alert: metric.isAlert,
                                  highlighted: state.hovered == .metric(metric), animated: false,
                                  inner: metric == .cpu && isCombined
                                    ? InnerRing(tint: SystemMetric.gpu.tint, value: gpu) : nil,
                                  ringAlert: own.map(metric.isAlert) == true) {
                            Image(systemName: metric.symbol)
                                .font(.system(size: metric == .cpu && isCombined
                                                ? max(10, m.logo * 0.55) : max(10, m.logo * 0.72),
                                              weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(gpu == nil ? metric.displayName : "CPU and GPU")
                        .accessibilityValue(gpu == nil ? metric.spoken(own)
                                            : "CPU \(metric.spoken(own)), GPU \(SystemMetric.gpu.spoken(gpu))")
                    }
                }
            }
            if !store.visible.isEmpty && !metrics.isEmpty {
                Capsule().fill(.white.opacity(0.14)).frame(width: m.ring * 0.6, height: 1)
            }
            if !store.visible.isEmpty {
                header(settings.limitDisplay == .used ? "AI USED" : "AI LEFT")
                ForEach(store.visible) { id in
                    let providerState = store.states[id]
                    let used = providerState?.reading?.headlineWindow?.currentUsedPercent()
                    let shown = settings.limitDisplay.value(used)
                    ring(.provider(id)) {
                        RingGauge(m: m, tint: id.tint, value: shown,
                                  fraction: (shown ?? 0) / 100,
                                  label: percentText, alert: settings.limitDisplay.isAlert,
                                  hasError: providerState?.error != nil,
                                  highlighted: state.hovered == .provider(id)) {
                            ProviderLogo(id: id, size: m.logo)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(id.displayName)
                        .accessibilityValue(spokenLimit(providerState, shown: shown))
                    }
                }
            }
            if !local.servers.isEmpty && !(store.visible.isEmpty && metrics.isEmpty) {
                Capsule().fill(.white.opacity(0.14)).frame(width: m.ring * 0.6, height: 1)
            }
            if !local.servers.isEmpty {
                header("LOCAL")
                ForEach(local.servers) { server in
                    let percent = server.memoryPercent
                    ring(.local(port: server.port)) {
                        RingGauge(m: m, tint: server.kind.tint, value: percent,
                                  fraction: min((percent ?? 0) / 100, 1),
                                  label: percentText, alert: { $0 >= 90 },
                                  highlighted: state.hovered == .local(port: server.port), animated: false) {
                            Image(systemName: server.kind.symbol)
                                .font(.system(size: max(10, m.logo * 0.72), weight: .semibold))
                                .foregroundStyle(.white.opacity(server.status == .ready ? 0.92 : 0.55))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(server.kind.displayName)
                        .accessibilityValue(server.spoken)
                    }
                }
            }
            if store.visible.isEmpty && metrics.isEmpty && local.servers.isEmpty {
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
        .contextMenu {
            Button("Refresh Limits") {
                Task { await store.refresh(force: true) }
            }
            .disabled(store.isRefreshing)
            Button(settings.limitDisplay == .used ? "Show Remaining %" : "Show Used %") {
                settings.limitDisplay = settings.limitDisplay == .used ? .remaining : .used
            }
            if let onHide {
                Divider()
                Button("Hide Side Dock") { onHide() }
            }
            Divider()
            Button("Quit TokenBar") { NSApplication.shared.terminate(nil) }
        }
    }

    /// The headline window as the hover card would show it: name, number, reset, error.
    private func spokenLimit(_ state: ProviderState?, shown: Double?) -> String {
        let window = state?.reading?.headlineWindow
        var parts = [shown.map { "\(window?.label ?? "Limit") \(Int($0.rounded())) percent \(settings.limitDisplay.word)" }
                     ?? "No reading"]
        if let resetsAt = window?.resetsAt { parts.append(resetText(resetsAt)) }
        if let error = state?.error { parts.append(error.message) }
        return parts.joined(separator: ", ")
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

/// A second ring inside the main one, for a combined CPU and GPU slot.
struct InnerRing {
    let tint: Color
    let value: Double?
}

struct RingGauge<Center: View>: View {
    let m: DockMetrics
    let tint: Color
    let value: Double?
    let fraction: Double
    let label: (Double?) -> String
    let alert: (Double) -> Bool
    var hasError = false
    var highlighted = false
    /// Off for system metrics: they change every 2 s, and animating each change keeps
    /// SwiftUI redrawing at display rate.
    var animated = true
    var inner: InnerRing?
    /// The outer arc's own alert state, when the label shows another value (combined).
    var ringAlert: Bool?
    @ViewBuilder let center: () -> Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAlert: Bool { value.map(alert) == true }
    private var isRingAlert: Bool { ringAlert ?? isAlert }

    var body: some View {
        VStack(spacing: m.headers ? 5 : 3) {
            ZStack {
                Circle().fill(.white.opacity(highlighted ? 0.08 : 0))
                // A filled disc, so an alert does not rest on arc color alone (Claude's
                // brand color is close to the alert red).
                Circle().fill(alertRed.opacity(isAlert ? 0.22 : 0))
                Circle().stroke(.white.opacity(0.10), lineWidth: m.line)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(isRingAlert ? alertRed : tint, style: StrokeStyle(lineWidth: m.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(animated && !reduceMotion ? .easeOut(duration: 0.6) : nil, value: fraction)
                if let inner {
                    let fill = inner.value.map { min(max($0 / 100, 0), 1) } ?? 0
                    ZStack {
                        Circle().stroke(.white.opacity(0.10), lineWidth: m.line)
                        Circle()
                            .trim(from: 0, to: fill)
                            .stroke(inner.value.map(alert) == true ? alertRed : inner.tint,
                                    style: StrokeStyle(lineWidth: m.line, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .padding(m.line * 1.75)
                }
                center()
                    .opacity(hasError && value == nil ? 0.55 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if hasError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: max(9, (m.ring * 0.30).rounded())))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, alertRed)
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: m.ring, height: m.ring)
            .scaleEffect(highlighted && !reduceMotion ? 1.08 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: highlighted)
            Text(label(value))
                .font(.system(size: m.font, weight: .semibold).monospacedDigit())
                .foregroundStyle(isAlert || (hasError && value == nil) ? alertRed : .white.opacity(0.9))
        }
    }
}

// MARK: Hover cards

struct HoverCard: View {
    let item: DockItem
    let store: LimitsStore
    let system: SystemStore
    let local: LocalServerStore
    let settings: DockSettings

    static let width: CGFloat = 232

    var body: some View {
        Group {
            switch item {
            case .provider(let id): LimitCardContent(id: id, state: store.states[id], display: settings.limitDisplay)
            case .metric(let metric):
                VStack(alignment: .leading, spacing: 14) {
                    MetricCardContent(metric: metric, snapshot: system.snapshot,
                                      processes: system.processMetric == metric ? system.topProcesses : nil)
                    if metric == .cpu && settings.combinesGPU(available: system.availableMetrics) {
                        MetricCardContent(metric: .gpu, snapshot: system.snapshot, processes: nil)
                    }
                }
            case .local(let port):
                if let server = local.servers.first(where: { $0.port == port }) {
                    LocalCardContent(server: server)
                }
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
                let shown = display.value(window.currentUsedPercent())
                let isAlert = shown.map(display.isAlert) == true
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(window.label).font(.system(size: 11))
                        Spacer()
                        Text(shown.map { "\(percentText($0)) \(display.word)" } ?? "--")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(isAlert ? alertRed : .white)
                    }
                    UsageBar(fraction: (shown ?? 0) / 100, tint: isAlert ? alertRed : id.tint)
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
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

private struct MetricCardContent: View {
    let metric: SystemMetric
    let snapshot: SystemSnapshot?
    /// nil when this metric has no process list; empty while the first scan runs.
    let processes: [ProcessUsage]?

    private var value: Double? { snapshot?.value(metric) }
    private var isAlert: Bool { value.map(metric.isAlert) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: metric.symbol).font(.system(size: 13, weight: .semibold))
                Text(metric.displayName).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(value.map(metric.label) ?? "--")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isAlert ? alertRed : .white)
            }
            UsageBar(fraction: value.map(metric.fraction) ?? 0, tint: isAlert ? alertRed : metric.tint)
            ForEach(details, id: \.self) { line in
                Text(line).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
            if let processes {
                ProcessList(metric: metric, processes: processes)
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
        case .storage:
            guard let used = s.storageUsed, let total = s.storageTotal else { return [] }
            // Three significant digits: "462 GB", not "462.47 GB".
            let formatter = ByteCountFormatter()
            formatter.isAdaptive = false
            let size = { (bytes: UInt64) in formatter.string(fromByteCount: Int64(bytes)) }
            return ["\(size(used)) of \(size(total)) used", "\(size(total - used)) available, as in Finder"]
        case .temperature:
            let c = { (label: String, value: Double?) in value.map { String(format: "%@ %.1f°C", label, $0) } }
            return [c("CPU die average", s.cpuTemperature), c("CPU hottest point", s.cpuTemperatureMax),
                    c("GPU die average", s.gpuTemperature)].compactMap { $0 }
        }
    }
}

private struct LocalCardContent: View {
    let server: LocalServer

    private var percent: Double? { server.memoryPercent }
    private var isAlert: Bool { (percent ?? 0) >= 90 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: server.kind.symbol).font(.system(size: 13, weight: .semibold))
                Text(server.kind.displayName).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(percentText(percent))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isAlert ? alertRed : .white)
            }
            UsageBar(fraction: (percent ?? 0) / 100, tint: isAlert ? alertRed : server.kind.tint)
            ForEach(details, id: \.self) { line in
                Text(line).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var details: [String] {
        let gb = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_073_741_824) }
        let count = { (n: Int) in n.formatted(.number.notation(.compactName)) }
        var lines: [String] = []
        switch server.status {
        case .loading: lines.append("Starting: the server does not answer yet")
        case .notAnswering: lines.append("Not answering (busy?): last reading shown")
        case .locked: lines.append("API key set, so model details are hidden")
        case .ready: break
        }
        if let model = server.model { lines.append(model) }
        if let used = server.memoryUsed {
            let limit = server.memoryLimit.map { " of \(gb($0))" } ?? ""
            let source = switch server.limitSource {
            case .budget?: " (--mem-budget)"
            case .gpuDefault?: " (macOS GPU limit)"
            case .server?: " (\(server.kind.displayName) limit)"
            case nil: ""
            }
            lines.append("\(gb(used))\(limit) GB\(source)")
        }
        if let context = server.contextLength {
            let slots = server.slots.map { $0 == 1 ? ", 1 request at a time" : ", \($0) requests at a time" } ?? ""
            // Context sizes are powers of two: 65,536 is "64K", as the servers write it.
            let size = context % 1024 == 0 ? "\(context / 1024)K" : count(context)
            lines.append("\(size) context\(slots)")
        }
        if let decode = server.decodeTokensPerSecond {
            let prefill = server.prefillTokensPerSecond.map { String(format: ", reads %.0f", $0) } ?? ""
            lines.append(String(format: "Writes %.1f tokens/s", decode) + prefill + " (average)")
        }
        if let input = server.inputTokens, let output = server.outputTokens {
            lines.append("\(count(input)) tokens in, \(count(output)) out")
        }
        if let completed = server.requestsCompleted {
            lines.append("\(completed) requests" + (server.queued.map { $0 > 0 ? ", \($0) waiting" : "" } ?? ""))
        }
        lines.append("Port \(server.port)")
        return lines
    }
}

private struct ProcessList: View {
    let metric: SystemMetric
    let processes: [ProcessUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric == .cpu ? "TOP PROCESSES" : "TOP PROCESSES (YOURS)")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 4)
            if processes.isEmpty {
                ForEach(0..<5, id: \.self) { row in
                    HStack(spacing: 8) {
                        Text(row == 0 ? "Measuring..." : " ")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer(minLength: 4)
                    }
                }
            }
            ForEach(processes) { process in
                HStack(spacing: 8) {
                    Text(process.name)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(value(process.value))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            if metric == .cpu {
                Text("Percent of one core, like Activity Monitor")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func value(_ v: Double) -> String {
        if metric == .cpu { return String(format: "%.1f%%", v) }
        let gb = v / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", v / 1_048_576)
    }
}
