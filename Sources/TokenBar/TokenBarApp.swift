import SwiftUI
import TokenBarCore

@main
struct TokenBarApp: App {
    @State private var store: LimitsStore
    @State private var settings: DockSettings
    @State private var dock: DockController
    @AppStorage("dock.visible") private var dockVisible = true

    init() {
        let store = LimitsStore()
        let settings = DockSettings()
        store.enabled = settings.tools
        _store = State(initialValue: store)
        _settings = State(initialValue: settings)
        _dock = State(initialValue: DockController(store: store, system: SystemStore(), settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            LimitsPanel(store: store, settings: settings, dockVisible: $dockVisible)
        } label: {
            // The label lives as long as the app, unlike the popover content.
            MenuBarLabel(percent: settings.limitDisplay.value(store.headlinePercent))
                .task {
                    store.start()
                    if dockVisible { dock.show() }
                }
                .onChange(of: dockVisible) { _, visible in
                    visible ? dock.show() : dock.hide()
                }
                .onChange(of: settings.tools) { _, tools in
                    store.enabled = tools
                }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let percent: Double?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            if let percent { Text("\(Int(percent.rounded()))%").monospacedDigit() }
        }
    }
}

struct LimitsPanel: View {
    let store: LimitsStore
    let settings: DockSettings
    @Binding var dockVisible: Bool
    @AppStorage("panel.customizeExpanded") private var customizeExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.visible.isEmpty {
                Text(settings.tools.isEmpty ? "All AI tools are turned off"
                     : store.states.isEmpty ? "Loading..." : "No supported tools found")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.visible) { id in
                if let state = store.states[id] {
                    ProviderSection(id: id, state: state, display: settings.limitDisplay)
                }
            }
            Divider()
            Toggle("Show side dock", isOn: $dockVisible)
                .toggleStyle(.switch)
                .controlSize(.mini)
            DisclosureGroup("Customize", isExpanded: $customizeExpanded) {
                CustomizeSection(settings: settings).padding(.top, 6)
            }
            .font(.callout)
            HStack {
                Button("Refresh") { Task { await store.refresh(force: true) } }
                    .disabled(store.isRefreshing)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .task { await store.refresh(force: true) }
    }
}

struct ProviderSection: View {
    let id: ProviderID
    let state: ProviderState
    let display: LimitDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(id.displayName).font(.headline)
                if let plan = state.reading?.plan {
                    Text(plan.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let observed = state.reading?.observedAt {
                    Text(observed, format: .relative(presentation: .numeric))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            // Labels can repeat (two Antigravity groups mapping to one name), so key by position.
            ForEach(Array((state.reading?.windows ?? []).enumerated()), id: \.offset) { _, window in
                WindowRow(window: window, display: display)
            }
            if let error = state.error {
                Label(error.message, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct WindowRow: View {
    let window: LimitWindow
    let display: LimitDisplay

    var body: some View {
        let shown = display.value(window.usedPercent)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label).font(.callout)
                Spacer()
                Text(shown.map { "\(Int($0.rounded()))% \(display.word)" } ?? "n/a")
                    .font(.callout).monospacedDigit()
            }
            ProgressView(value: (shown ?? 0) / 100)
                .tint(tint)
            if let resetsAt = window.resetsAt {
                Text(resetText(resetsAt))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Severity follows usage whichever way the number is shown.
    private var tint: Color {
        switch window.usedPercent ?? 0 {
        case 90...: .red
        case 70..<90: .orange
        default: .green
        }
    }
}

struct CustomizeSection: View {
    @Bindable var settings: DockSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Dock size", selection: $settings.size) {
                Text("Normal").tag(DockSize.normal)
                Text("Mini").tag(DockSize.mini)
            }
            .pickerStyle(.segmented)
            Picker("AI limits", selection: $settings.limitDisplay) {
                Text("Used").tag(LimitDisplay.used)
                Text("Remaining").tag(LimitDisplay.remaining)
            }
            .pickerStyle(.segmented)
            group("AI tools", note: "Turned-off tools are not checked at all.") {
                ForEach(ProviderID.allCases) { id in
                    Toggle(id.displayName, isOn: settings.binding(for: id))
                }
            }
            group("System", note: "Whole Mac, so a local model shows up as GPU and memory load.") {
                ForEach(SystemMetric.allCases) { metric in
                    Toggle(metric.displayName, isOn: settings.binding(for: metric))
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private func group<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
