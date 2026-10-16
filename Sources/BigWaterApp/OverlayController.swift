import AppKit
import QuartzCore
import BigWaterCore
import BigWaterArt

@MainActor
final class OverlayController {
    var onAcknowledge: (() -> Void)?
    var onDrink: (() -> Void)?
    var onSnooze: ((Int) -> Void)?
    var onPreviewEnd: (() -> Void)?
    /// The exit animation completed on its own and the overlay is gone.
    var onFinished: (() -> Void)?

    private var canvasPanel: OverlayPanel?
    private var characterPanels: [OverlayPanel] = []
    /// Opaque reminder surfaces (compact card, speech bubble) that swallow
    /// clicks instead of passing them to the app underneath.
    private(set) var blockerPanels: [OverlayPanel] = []
    private(set) var buttonPanels: [OverlayPanel] = []
    private var buttonViews: [OverlayButtonView] = []
    private var canvas: AnimationCanvas?
    private var scene: ReminderScene?
    private var screen: NSScreen?
    private var timer: Timer?
    private var style: ReminderStyle = .animated
    private var isPreview = false
    private var actionInvoked = false
    private var lastFrameTime = 0.0
    private var lastPaintedRegions: [CGRect] = []
    private var isSuspended = false

    var isActive: Bool { scene != nil }
    var isAwaitingAcknowledgment: Bool {
        guard let scene else { return false }
        return !actionInvoked && (style == .compact || scene.isInteractive)
    }

    @discardableResult
    func start(appearance: ReminderAppearance = .init(), style: ReminderStyle = .animated,
               isPreview: Bool = false, entrance: ReminderEntrance = .random()) -> Bool {
        guard !isActive, let selected = preferredScreen() else { return false }
        self.screen = selected
        self.style = style
        self.isPreview = isPreview
        self.actionInvoked = false
        self.scene = ReminderScene(viewport: selected.frame.size,
                                   topInset: topInset(for: selected), appearance: appearance,
                                   isPreview: isPreview, entrance: entrance,
                                   visibleBounds: localVisibleBounds(for: selected))
        let panel = makePanel(frame: selected.frame, ignoresMouse: true)
        panel.title = isPreview ? "喝水提醒预览" : "喝水提醒"
        let view = AnimationCanvas(frame: CGRect(origin: .zero, size: selected.frame.size))
        view.onAcknowledge = { [weak self] in self?.acknowledge() }
        panel.contentView = view
        canvasPanel = panel
        canvas = view

        isSuspended = false
        updateWindows()
        panel.orderFrontRegardless()
        if style == .animated { startTimer() }
        return true
    }

    /// Character clicks confirm a drink and restart the regular interval,
    /// sharing the same per-reminder action guard as the drink button.
    func acknowledge() {
        guard isActive, !actionInvoked else { return }
        if isPreview {
            finishPreview()
            return
        }
        if style == .compact {
            let callback = onAcknowledge
            stop()
            callback?()
            return
        }
        guard scene?.acknowledge() == true else { return }
        actionInvoked = true
        onAcknowledge?()
        updateWindows()
    }

    /// Record the drink as soon as the user presses the button, while the
    /// character continues its exit animation.
    func confirmDrink() {
        guard isActive, !actionInvoked else { return }
        if isPreview {
            finishPreview()
            return
        }
        actionInvoked = true
        if style == .compact {
            let callback = onDrink
            stop()
            callback?()
            return
        }
        guard scene?.acknowledge() == true else {
            actionInvoked = false
            return
        }
        updateWindows()
        onDrink?()
    }

    func snooze(minutes: Int) {
        guard (minutes == 10 || minutes == 20), isActive, !actionInvoked else { return }
        guard !isPreview else {
            finishPreview()
            return
        }
        actionInvoked = true
        let callback = onSnooze
        stop()
        callback?(minutes)
    }

    func endPreview() {
        guard isActive, isPreview else { return }
        finishPreview()
    }

    func suspend() {
        isSuspended = true
        timer?.invalidate()
        timer = nil
        canvasPanel?.orderOut(nil)
        characterPanels.forEach { $0.orderOut(nil) }
        blockerPanels.forEach { $0.orderOut(nil) }
        buttonPanels.forEach { $0.orderOut(nil) }
    }

    func resume() {
        guard isActive, isSuspended, preferredScreen() != nil else { return }
        isSuspended = false
        screenParametersChanged()
        canvasPanel?.orderFrontRegardless()
        updateWindows()
        if style == .animated { startTimer() }
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
        scene?.resize(to: selected.frame.size, topInset: topInset(for: selected),
                      visibleBounds: localVisibleBounds(for: selected))
        canvasPanel?.setFrame(selected.frame, display: true)
        updateWindows()
    }

    func stop() {
        let endedPreview = isPreview && scene != nil
        timer?.invalidate()
        timer = nil
        canvasPanel?.close()
        characterPanels.forEach { $0.close() }
        blockerPanels.forEach { $0.close() }
        buttonPanels.forEach { $0.close() }
        canvasPanel = nil
        characterPanels.removeAll()
        blockerPanels.removeAll()
        lastPaintedRegions = []
        buttonPanels.removeAll()
        buttonViews.removeAll()
        canvas = nil
        scene = nil
        screen = nil
        style = .animated
        isPreview = false
        actionInvoked = false
        if endedPreview { onPreviewEnd?() }
    }

    private func finishPreview() {
        stop()
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
            onFinished?()
        } else {
            updateWindows(fullRedraw: false)
        }
    }

    /// Animation frames redraw only what moved; every other update (start,
    /// resume, screen or state changes) repaints the whole canvas.
    private func updateWindows(fullRedraw: Bool = true) {
        guard let scene, let screen else { return }
        guard !isSuspended else { return }

        var characterGlobalRegions: [CGRect] = []
        var blockerRegions: [CGRect] = []
        var buttonSpecs: [OverlayButtonSpec] = []
        var previewBadge: CGRect?

        if style == .animated {
            if scene.isInteractive {
                characterGlobalRegions = PixelArt.characterHitRegions(in: scene).map {
                    screenRect(for: $0, on: screen)
                }
                let layout = OverlayControls.animatedButtons(in: scene,
                                                             visibleBounds: localVisibleBounds(for: screen),
                                                             isPreview: isPreview)
                buttonSpecs = layout.buttons
                previewBadge = layout.badge
                if scene.phase == .reminding {
                    blockerRegions = SceneRenderer.speechRegions(for: scene).map { screenRect(for: $0, on: screen) }
                }
            }
            let hovered = characterGlobalRegions.contains { $0.contains(NSEvent.mouseLocation) }
            self.scene?.isHovered = hovered
            synchronize(&characterPanels, to: characterGlobalRegions) { [weak self] in
                let target = ClaudeClickTarget(frame: .zero)
                target.onClick = { self?.acknowledge() }
                return target
            }
            canvas?.compactCardFrame = nil
        } else {
            let layout = OverlayControls.compactLayout(visibleBounds: localVisibleBounds(for: screen),
                                                       isPreview: isPreview)
            buttonSpecs = layout.buttons
            blockerRegions = OverlayControls.compactCardRegions(layout.card).map { screenRect(for: $0, on: screen) }
            characterPanels.forEach { $0.orderOut(nil) }
            canvas?.compactCardFrame = layout.card
            self.scene?.isHovered = false
        }

        synchronize(&blockerPanels, to: blockerRegions) { ClickBlocker(frame: .zero) }
        synchronizeButtonPanels(buttonSpecs, on: screen, theme: scene.appearance.theme)
        canvas?.previewBadgeFrame = previewBadge
        canvas?.reminderAppearance = scene.appearance
        canvas?.isPreview = isPreview
        canvas?.isCompact = style == .compact
        canvas?.scene = self.scene
        let painted = style == .animated
            ? OverlayControls.animatedPaintedRegions(in: self.scene ?? scene, previewBadge: previewBadge) : []
        if fullRedraw || style != .animated || lastPaintedRegions.isEmpty {
            canvas?.needsDisplay = true
        } else {
            // Clear where the previous frame painted and draw the new frame.
            (lastPaintedRegions + painted).forEach { canvas?.setNeedsDisplay($0) }
        }
        lastPaintedRegions = painted

        let accessibilityRegions = style == .animated ? characterGlobalRegions : []
        let characterLabel = scene.appearance.character == .claude ? "Claude" : "水滴精灵"
        let actionLabel = isPreview ? "结束喝水提醒预览" : "关闭喝水提醒"
        canvas?.updateAccessibility(frame: accessibilityRegions.reduce(CGRect.null) { $0.union($1) },
                                    interactive: !accessibilityRegions.isEmpty,
                                    label: "\(characterLabel)：\(actionLabel)",
                                    buttons: buttonSpecs.map { spec in
                                        (spec.title, screenRect(for: spec.frame, on: screen),
                                         { [weak self] in self?.perform(spec.action) })
                                    })
    }

    /// Input panels sit one level below the canvas, which paints the same
    /// pixels above them. Unchanged frames are left alone.
    private func synchronize(_ panels: inout [OverlayPanel], to regions: [CGRect],
                             makeContent: () -> NSView) {
        while panels.count < regions.count {
            let panel = makePanel(frame: .zero, ignoresMouse: false)
            panel.setAccessibilityElement(false)
            panel.contentView = makeContent()
            panels.append(panel)
        }
        for (index, panel) in panels.enumerated() {
            if index < regions.count {
                if panel.frame != regions[index] { panel.setFrame(regions[index], display: false) }
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    private func synchronizeButtonPanels(_ specs: [OverlayButtonSpec], on screen: NSScreen,
                                         theme: ReminderTheme) {
        while buttonViews.count < specs.count {
            let spec = specs[buttonViews.count]
            let panel = makePanel(frame: .zero, ignoresMouse: false, level: .statusBar)
            panel.title = spec.title
            // The canvas owns one coherent accessible surface for the character
            // and all controls, while these panels deliver physical clicks.
            panel.setAccessibilityElement(false)
            let isPrimary = spec.action == .drink || spec.action == .endPreview
            let button = OverlayButtonView(frame: .zero, title: spec.title,
                                           theme: theme, isPrimary: isPrimary)
            panel.contentView = button
            buttonPanels.append(panel)
            buttonViews.append(button)
        }
        for index in buttonViews.indices {
            guard index < specs.count else {
                buttonPanels[index].orderOut(nil)
                continue
            }
            let spec = specs[index]
            let view = buttonViews[index]
            view.onPress = { [weak self] in self?.perform(spec.action) }
            let frame = screenRect(for: spec.frame, on: screen)
            if buttonPanels[index].frame != frame {
                buttonPanels[index].setFrame(frame, display: true)
                view.frame = CGRect(origin: .zero, size: spec.frame.size)
            }
            if !buttonPanels[index].isVisible { buttonPanels[index].orderFrontRegardless() }
        }
    }

    private func perform(_ action: OverlayControlAction) {
        switch action {
        case .drink: confirmDrink()
        case .snooze(let minutes): snooze(minutes: minutes)
        case .endPreview: endPreview()
        }
    }

    private func localVisibleBounds(for screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX - screen.frame.minX,
                      y: screen.frame.maxY - visible.maxY,
                      width: visible.width, height: visible.height)
    }

    private func screenRect(for localTopLeftRect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX + localTopLeftRect.minX,
               y: screen.frame.maxY - localTopLeftRect.maxY,
               width: localTopLeftRect.width, height: localTopLeftRect.height)
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func topInset(for screen: NSScreen) -> Double {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private func makePanel(frame: CGRect, ignoresMouse: Bool,
                           level: NSWindow.Level? = nil) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = ignoresMouse
        panel.level = level ?? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - (ignoresMouse ? 1 : 2))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class AnimationCanvas: NSView {
    var scene: ReminderScene?
    var onAcknowledge: (() -> Void)?
    var reminderAppearance = ReminderAppearance()
    var isPreview = false
    var isCompact = false
    var compactCardFrame: CGRect?
    var previewBadgeFrame: CGRect?
    private let accessibleCharacter = AccessibleReminderCharacter()
    private var accessibleButtons: [AccessibleReminderCharacter] = []
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        accessibleCharacter.setAccessibilityRole(.button)
        accessibleCharacter.setAccessibilityEnabled(true)
        accessibleCharacter.setAccessibilityParent(self)
        accessibleCharacter.onPress = { [weak self] in self?.onAcknowledge?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func updateAccessibility(frame: CGRect, interactive: Bool, label: String,
                             buttons: [(String, CGRect, () -> Void)]) {
        accessibleCharacter.setAccessibilityFrame(interactive ? frame : .zero)
        accessibleCharacter.setAccessibilityLabel(label)
        accessibleCharacter.setAccessibilityHelp(isPreview
            ? "点击结束预览。"
            : "点击记录一次喝水、收起提醒并重新开始计时。")
        while accessibleButtons.count < buttons.count {
            let button = AccessibleReminderCharacter()
            button.setAccessibilityRole(.button)
            button.setAccessibilityEnabled(true)
            button.setAccessibilityParent(self)
            accessibleButtons.append(button)
        }
        for (index, spec) in buttons.enumerated() {
            accessibleButtons[index].setAccessibilityLabel(spec.0)
            accessibleButtons[index].setAccessibilityFrame(spec.1)
            accessibleButtons[index].onPress = spec.2
        }
        let character: [NSAccessibilityElement] = interactive ? [accessibleCharacter] : []
        setAccessibilityChildren(character + Array(accessibleButtons.prefix(buttons.count)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        if isCompact, let compactCardFrame {
            OverlayControls.drawCompactCard(compactCardFrame, in: context,
                                            appearance: reminderAppearance, isPreview: isPreview)
        } else if let scene {
            SceneRenderer.draw(scene, in: context)
        }
        if let previewBadgeFrame {
            OverlayControls.drawPreviewBadge(previewBadgeFrame, in: context, theme: reminderAppearance.theme)
        }
    }
}

private final class AccessibleReminderCharacter: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

@MainActor
private final class ClaudeClickTarget: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The rendered canvas owns the single accessible character button.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func draw(_ dirtyRect: NSRect) {
        // A lower input surface catches clicks; the canvas paints the same pixels above it.
        WaterPalette.clay.setFill()
        dirtyRect.fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Catches clicks on an opaque reminder surface so they do nothing, rather
/// than reaching whatever app is underneath. The canvas paints over it.
@MainActor
private final class ClickBlocker: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func draw(_ dirtyRect: NSRect) {
        WaterPalette.cream.setFill()
        dirtyRect.fill()
    }
}
