import AppKit
import SwiftUI
import TokenBarCore

/// A borderless floating panel pinned to the left or right screen edge. Dragging moves it
/// freely; on release it snaps to the nearer edge of the screen under the pointer, and the
/// screen, side and height are remembered.
@MainActor
final class DockController {
    private let store: LimitsStore
    private let system: SystemStore
    private let local: LocalServerStore
    private let settings: DockSettings
    private var panel: NSPanel?
    private var hosting: DockHostingView?
    private var cardPanel: NSPanel?
    private var cardHosting: NSHostingView<HoverCard>?
    private var isObservingCard = false
    private let state: DockState
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var isObserving = false

    private let defaults = UserDefaults.standard
    private var side: DockSide {
        get { state.side }
        set {
            state.side = newValue
            defaults.set(newValue.rawValue, forKey: "dock.side")
        }
    }
    /// Vertical center as a fraction of the screen's visible height (0 bottom, 1 top).
    private var centerFraction: Double {
        get { defaults.object(forKey: "dock.center") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "dock.center") }
    }
    /// The display the dock lives on; falls back to the main screen if it is gone.
    private var screen: NSScreen? {
        get {
            let saved = defaults.integer(forKey: "dock.display")
            return NSScreen.screens.first { $0.displayID == saved } ?? NSScreen.main
        }
        set { defaults.set(newValue?.displayID ?? 0, forKey: "dock.display") }
    }

    init(store: LimitsStore, system: SystemStore, local: LocalServerStore, settings: DockSettings) {
        self.store = store
        self.system = system
        self.local = local
        self.settings = settings
        self.state = DockState(side: DockSide(rawValue: UserDefaults.standard.string(forKey: "dock.side") ?? "") ?? .right)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        if panel == nil { makePanel() }
        layout(animated: false)
        panel?.orderFrontRegardless()
        observeContent()
        updateSampling()
    }

    func hide() {
        setHovered(nil)
        panel?.orderOut(nil)
        updateSampling()
    }

    /// System metrics and local servers are sampled only while someone can see them.
    private func updateSampling() {
        system.setRunning(isVisible && !settings.metrics.isEmpty)
        local.enabled = settings.localServers
        local.setRunning(isVisible && !settings.localServers.isEmpty)
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above full-screen apps too; .floating can end up behind them.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true

        let hosting = DockHostingView(rootView: DockView(
            store: store,
            system: system,
            local: local,
            settings: settings,
            state: state,
            onDrag: { [weak self] ended in self?.handleDrag(ended: ended) },
            onHide: { [weak self] in
                self?.defaults.set(false, forKey: "dock.visible")
                self?.hide()
            }
        ))
        hosting.onPointer = { [weak self] point in self?.pointerMoved(to: point) }
        // Ring frames settle after every rail layout; keep an open card on its ring.
        state.onRingFramesChange = { [weak self] in self?.ringFramesChanged() }
        // Report the SwiftUI size for fittingSize, but leave window sizing to layout().
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
    }

    /// Re-measures the rail when what it shows changes: visible tools, size, enabled or
    /// newly available metrics. One chain at a time; it ends while the dock is hidden
    /// and show() starts it again.
    private func observeContent() {
        guard !isObserving else { return }
        isObserving = true
        withObservationTracking {
            _ = store.visible
            _ = settings.scale
            _ = settings.metrics
            _ = settings.combineCompute
            _ = settings.localServers
            _ = system.availableMetrics
            _ = local.ports
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObserving = false
                guard self.isVisible else { return }
                self.updateSampling()
                self.layout(animated: true)
                self.observeContent()
            }
        }
    }

    /// Ring frames settle once SwiftUI has applied a change, which can be after layout()
    /// measured the rail (switching size, a metric appearing). Re-measure if the rail
    /// no longer fits, then keep an open card on its ring.
    private func ringFramesChanged() {
        if let panel, let hosting, isVisible, dragStart == nil {
            let height = hosting.fittingSize.height
            if abs(height - panel.frame.height) > 0.5 || abs(settings.dockMetrics.width - panel.frame.width) > 0.5 {
                layout(animated: true)
                return
            }
        }
        positionCard()
    }

    /// Places the panel flush with the remembered edge of the remembered screen.
    private func layout(animated: Bool) {
        guard let panel, let hosting, let visible = screen?.visibleFrame else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: settings.dockMetrics.width, height: hosting.fittingSize.height)
        let x = side == .right ? visible.maxX - size.width : visible.minX
        let centerY = visible.minY + visible.height * centerFraction
        let y = min(max(centerY - size.height / 2, visible.minY), visible.maxY - size.height)
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    panel.invalidateShadow()
                    self?.positionCard()
                }
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
            positionCard()
        }
    }

    private func handleDrag(ended: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, panel.frame.origin)
            setHovered(nil)
        }
        guard let start = dragStart else { return }
        if !ended {
            panel.setFrameOrigin(NSPoint(
                x: start.origin.x + mouse.x - start.mouse.x,
                y: start.origin.y + mouse.y - start.mouse.y
            ))
            return
        }
        dragStart = nil
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? screen else { return }
        let visible = target.visibleFrame
        screen = target
        side = mouse.x < visible.midX ? .left : .right
        centerFraction = min(max((panel.frame.midY - visible.minY) / visible.height, 0), 1)
        layout(animated: true)
    }
}

// MARK: Hover card

extension DockController {
    /// `point` is in the rail's SwiftUI coordinates (top-left origin), nil when the pointer left.
    fileprivate func pointerMoved(to point: CGPoint?) {
        guard dragStart == nil else { return }
        let padY = settings.dockMetrics.spacing + 8
        let hit = point.flatMap { p in
            state.ringFrames
                .filter { $0.value.insetBy(dx: 0, dy: -padY).minY ... $0.value.insetBy(dx: 0, dy: -padY).maxY ~= p.y }
                .min { a, b in
                    let da = abs(a.value.midY - p.y)
                    let db = abs(b.value.midY - p.y)
                    return da != db ? da < db : a.key.id < b.key.id
                }?
                .key
        }
        setHovered(hit)
    }

    private func setHovered(_ item: DockItem?) {
        guard state.hovered != item else { return }
        state.hovered = item
        // Process lists are scanned only while their card is open.
        if case .metric(let metric)? = item { system.setProcessFocus(metric) } else { system.setProcessFocus(nil) }
        if let item {
            let hosting = cardHosting ?? makeCardPanel()
            hosting.rootView = HoverCard(item: item, store: store, system: system, local: local, settings: settings)
        }
        positionCard()
        observeCard()
    }

    /// Sizes the card to its content and puts it beside the rail on the screen-interior
    /// side, centered on the hovered ring and kept on screen. Hides it when nothing is
    /// hovered or the hovered tool has left the rail.
    func positionCard() {
        guard let item = state.hovered, isVisible, let panel, let card = cardPanel, let hosting = cardHosting else {
            cardPanel?.orderOut(nil)
            return
        }
        guard let ring = state.ringFrames[item] else {
            setHovered(nil)
            return
        }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let gap: CGFloat = 6
        let x = side == .right ? panel.frame.minX - gap - size.width : panel.frame.maxX + gap
        var y = panel.frame.maxY - ring.midY - size.height / 2
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        card.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        card.invalidateShadow()
        card.orderFrontRegardless()
    }

    /// Re-measures the open card when its data changes (limit rows, errors, a new
    /// system sample). One chain at a time; it ends once nothing is hovered.
    private func observeCard() {
        guard !isObservingCard, let item = state.hovered else { return }
        isObservingCard = true
        withObservationTracking {
            switch item {
            case .provider(let id): _ = store.states[id]
            case .metric:
                _ = system.snapshot
                _ = system.topProcesses
            case .local: _ = local.servers
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObservingCard = false
                self.positionCard()
                self.observeCard()
            }
        }
    }

    private func makeCardPanel() -> NSHostingView<HoverCard> {
        let card = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = true
        card.level = .statusBar
        card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Click-through, so it never steals the hover from the rail underneath.
        card.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: HoverCard(item: .provider(.claude), store: store, system: system, local: local, settings: settings))
        hosting.sizingOptions = [.intrinsicContentSize]
        card.contentView = hosting
        cardPanel = card
        cardHosting = hosting
        return hosting
    }
}

/// Reports pointer movement over the rail even while another app is active;
/// SwiftUI's onHover only fires in the active app.
final class DockHostingView: NSHostingView<DockView> {
    var onPointer: ((CGPoint?) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["dock"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["dock": true]
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        report(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        onPointer?(nil)
        super.rightMouseDown(with: event)
    }

    private func report(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onPointer?(CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y))
    }
}

private extension NSScreen {
    var displayID: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }
}
