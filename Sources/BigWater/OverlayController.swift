import AppKit
import QuartzCore
import BigWaterCore
import BigWaterArt

@MainActor
final class OverlayController {
    var onAcknowledge: (() -> Void)?
    private var canvasPanel: OverlayPanel?
    private var clickPanels: [OverlayPanel] = []
    private var canvas: AnimationCanvas?
    private var scene: ReminderScene?
    private var screen: NSScreen?
    private var timer: Timer?
    private var lastFrameTime = 0.0
    private var isSuspended = false

    var isActive: Bool { scene != nil }

    @discardableResult
    func start() -> Bool {
        guard !isActive, let selected = preferredScreen() else { return false }
        screen = selected
        scene = ReminderScene(viewport: selected.frame.size, topInset: topInset(for: selected))
        let panel = makePanel(frame: selected.frame, ignoresMouse: true)
        let view = AnimationCanvas(frame: CGRect(origin: .zero, size: selected.frame.size))
        view.onAcknowledge = { [weak self] in self?.acknowledge() }
        panel.contentView = view
        canvasPanel = panel
        canvas = view

        // Rendering is click-through. Positive hit regions follow the sprite's
        // actual pixels; transparent gaps, the rope and water remain usable.
        isSuspended = false
        updateWindows()
        panel.orderFrontRegardless()
        startTimer()
        return true
    }

    func acknowledge() {
        guard scene?.acknowledge() == true else { return }
        clickPanels.forEach { $0.orderOut(nil) }
        onAcknowledge?()
        updateWindows()
    }

    func suspend() {
        isSuspended = true
        timer?.invalidate()
        timer = nil
        canvasPanel?.orderOut(nil)
        clickPanels.forEach { $0.orderOut(nil) }
    }

    func resume() {
        guard isActive, isSuspended, preferredScreen() != nil else { return }
        isSuspended = false
        screenParametersChanged()
        canvasPanel?.orderFrontRegardless()
        updateWindows()
        startTimer()
    }

    func screenParametersChanged() {
        guard isActive else { return }
        let originalID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let surviving = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == originalID
        }
        guard let selected = surviving ?? preferredScreen() else {
            suspend()
            return
        }
        screen = selected
        scene?.resize(to: selected.frame.size, topInset: topInset(for: selected))
        canvasPanel?.setFrame(selected.frame, display: true)
        updateWindows()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        canvasPanel?.close()
        clickPanels.forEach { $0.close() }
        canvasPanel = nil
        clickPanels.removeAll()
        canvas = nil
        scene = nil
        screen = nil
    }

    private func startTimer() {
        timer?.invalidate()
        lastFrameTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let current = CACurrentMediaTime()
        let elapsed = min(current - lastFrameTime, 1.0 / 12)
        lastFrameTime = current
        scene?.advance(by: elapsed)
        if scene?.phase == .finished {
            stop()
        } else {
            updateWindows()
        }
    }

    private func updateWindows() {
        guard let scene, let screen else { return }
        guard !isSuspended else { return }
        if scene.isInteractive {
            let regions = PixelArt.claudeHitRegions(in: scene).map {
                CGRect(x: screen.frame.minX + $0.minX,
                       y: screen.frame.maxY - $0.maxY, width: $0.width, height: $0.height)
            }
            while clickPanels.count < regions.count {
                let panel = makePanel(frame: .zero, ignoresMouse: false)
                let target = ClaudeClickTarget(frame: .zero)
                target.onClick = { [weak self] in self?.acknowledge() }
                panel.contentView = target
                clickPanels.append(panel)
            }
            for (index, panel) in clickPanels.enumerated() {
                if index < regions.count {
                    panel.setFrame(regions[index], display: false)
                    if !panel.isVisible { panel.orderFrontRegardless() }
                } else {
                    panel.orderOut(nil)
                }
            }
            self.scene?.isHovered = regions.contains { $0.contains(NSEvent.mouseLocation) }
            let accessibilityFrame = regions.reduce(CGRect.null) { $0.union($1) }
            canvas?.updateAccessibility(frame: accessibilityFrame.isNull ? .zero : accessibilityFrame,
                                        interactive: !accessibilityFrame.isNull)
        } else {
            canvas?.updateAccessibility(frame: .zero, interactive: false)
            clickPanels.forEach { $0.orderOut(nil) }
        }
        canvas?.scene = self.scene
        canvas?.needsDisplay = true
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func topInset(for screen: NSScreen) -> Double {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private func makePanel(frame: CGRect, ignoresMouse: Bool) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = ignoresMouse
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - (ignoresMouse ? 1 : 2))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class AnimationCanvas: NSView {
    var scene: ReminderScene?
    var onAcknowledge: (() -> Void)?
    private let accessibleClaude = AccessibleClaude()
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        accessibleClaude.setAccessibilityRole(.button)
        accessibleClaude.setAccessibilityEnabled(true)
        accessibleClaude.setAccessibilityLabel("Claude：点我，喝水去")
        accessibleClaude.setAccessibilityHelp("点击停止扔水，让 Claude 沿绳子爬回去。")
        accessibleClaude.setAccessibilityParent(self)
        accessibleClaude.onPress = { [weak self] in self?.onAcknowledge?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func updateAccessibility(frame: CGRect, interactive: Bool) {
        accessibleClaude.setAccessibilityFrame(frame)
        setAccessibilityChildren(interactive ? [accessibleClaude] : [])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        if let scene { SceneRenderer.draw(scene, in: context) }
    }
}

private final class AccessibleClaude: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

private final class ClaudeClickTarget: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The rendered canvas owns the single accessible Claude button.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func draw(_ dirtyRect: NSRect) {
        // Opaque input surfaces sit one window level below the rendered sprite.
        // Its identical pixel silhouette covers them completely, while the
        // window server has a real surface to deliver physical mouse clicks to.
        WaterPalette.clay.setFill()
        dirtyRect.fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
