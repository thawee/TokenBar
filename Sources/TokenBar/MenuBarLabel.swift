import SwiftUI
import TokenBarCore

struct MenuBarLabel: View {
    let store: LimitsStore
    let settings: DockSettings

    /// The tool to show and its used percentage; nil shows the plain gauge.
    private var item: (id: ProviderID, used: Double?)? {
        switch settings.menuBar {
        case .urgent:
            return store.mostUrgent().map { ($0.id, $0.usedPercent) }
        case .tool(let id):
            guard settings.tools.contains(id) else { return nil }
            return (id, store.states[id]?.reading?.headlineWindow?.currentUsedPercent())
        case .iconOnly:
            guard let urgent = store.mostUrgent(), urgent.usedPercent >= MenuBarMode.quietThreshold else { return nil }
            return (urgent.id, urgent.usedPercent)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if let item {
                if let image = item.id.menuBarImage {
                    Image(nsImage: image)
                } else {
                    Image(systemName: item.id.symbol)
                }
                Text(settings.limitDisplay.value(item.used).map { "\(Int($0.rounded()))%" } ?? "--")
                    .monospacedDigit()
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
        }
    }
}
