import SwiftUI
import TokenBarCore

@main
struct TokenBarApp: App {
    @State private var store: LimitsStore
    @State private var settings: DockSettings
    @State private var dock: DockController
    @State private var loginItem = LoginItem()
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
            LimitsPanel(store: store, settings: settings, loginItem: loginItem, dockVisible: $dockVisible)
        } label: {
            // The label lives as long as the app, unlike the popover content.
            MenuBarLabel(store: store, settings: settings)
                .task {
                    store.start()
                    if dockVisible { dock.show() }
                    loginItem.enableOnFirstLaunch()
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

struct LimitsPanel: View {
    let store: LimitsStore
    let settings: DockSettings
    let loginItem: LoginItem
    @Binding var dockVisible: Bool
    @AppStorage("panel.customizeExpanded") private var customizeExpanded = false

    private static let maxScrollHeight: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .vertical) {
                panelContent
                ScrollView {
                    panelContent
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: Self.maxScrollHeight)
            }

            HStack(spacing: 8) {
                Button("Refresh") { Task { await store.refresh(force: true) } }
                    .disabled(store.isRefreshing)
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .task { await store.refresh() }
    }

    private var panelContent: some View {
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
            LoginItemToggle(loginItem: loginItem)
            DisclosureGroup("Customize", isExpanded: $customizeExpanded) {
                CustomizeSection(settings: settings).padding(.top, 6)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var used: Double? { window.currentUsedPercent() }

    var body: some View {
        let shown = display.value(used)
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
        switch used ?? 0 {
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
            HStack(spacing: 8) {
                Text("Dock size")
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
                Slider(value: $settings.scale, in: DockScale.range, step: DockScale.step)
                Image(systemName: "circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Picker("AI limits", selection: $settings.limitDisplay) {
                Text("Used").tag(LimitDisplay.used)
                Text("Remaining").tag(LimitDisplay.remaining)
            }
            .pickerStyle(.segmented)
            Picker("Menu bar", selection: $settings.menuBar) {
                Text("Most urgent tool").tag(MenuBarMode.urgent)
                Divider()
                ForEach(ProviderID.displayOrder) { id in
                    Text(id.displayName).tag(MenuBarMode.tool(id))
                }
                Divider()
                Text("Icon only, number from \(Int(MenuBarMode.quietThreshold))%").tag(MenuBarMode.iconOnly)
            }
            .pickerStyle(.menu)
            group("AI tools", note: "Turned-off tools are not checked at all.") {
                ForEach(ProviderID.displayOrder) { id in
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
