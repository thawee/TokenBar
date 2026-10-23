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
                Image(nsImage: .railGlyph)
                    .accessibilityLabel("TokenBar")
            }
        }
    }
}

extension NSImage {
    /// The app icon as a menu bar template: the rail outline holding three ring gauges.
    @MainActor static let railGlyph: NSImage = {
        let width: CGFloat = 8, height: CGFloat = 19
        let pad: CGFloat = 1.6, line: CGFloat = 1.3
        let fills: [CGFloat] = [0.72, 0.45, 0.88]  // as in the app icon
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let corner = width / 2 - 0.5
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()

            let ring = width - 2 * pad
            let gap = (height - 2 * pad - 3 * ring) / 2
            let radius = ring / 2 - line / 2
            ctx.setLineWidth(line)
            ctx.setLineCap(.round)
            for (i, fill) in fills.enumerated() {
                let center = CGPoint(x: width / 2, y: height - pad - ring / 2 - CGFloat(i) * (ring + gap))
                ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.3).cgColor)
                ctx.strokePath()
                ctx.addArc(center: center, radius: radius, startAngle: .pi / 2,
                           endAngle: .pi / 2 - 2 * .pi * fill, clockwise: true)
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
