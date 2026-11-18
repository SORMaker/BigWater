import AppKit
import BigWaterCore
import BigWaterArt

/// A connected display the person can pick for reminders.
struct Display: Identifiable, Equatable {
    /// The display's UUID, which stays the same across reconnecting.
    let id: String
    let name: String

    @MainActor static var connected: [Display] {
        NSScreen.screens.compactMap { screen in screen.displayID.map { Display(id: $0, name: screen.localizedName) } }
    }
}

private extension NSScreen {
    var displayID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)),
              let text = CFUUIDCreateString(kCFAllocatorDefault, uuid.takeRetainedValue())
        else { return nil }
        return text as String
    }

    static func preferred(for placement: Placement) -> NSScreen? {
        // `screens.first` is the system's primary display. `NSScreen.main`
        // follows keyboard focus and can be any of them.
        let primary = screens.first
        switch placement.screen {
        case .mouse:
            return screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? main ?? primary
        case .main:
            return primary
        case .selected:
            return screens.first { $0.displayID != nil && $0.displayID == placement.displayID } ?? primary
        }
    }

    /// The display as the reminder sees it: top-left origin, with the part
    /// the menu bar and the Dock leave free.
    var space: ScreenSpace {
        ScreenSpace(size: frame.size,
                    visible: CGRect(x: visibleFrame.minX - frame.minX, y: frame.maxY - visibleFrame.maxY,
                                    width: visibleFrame.width, height: visibleFrame.height))
    }

    /// A rectangle in the reminder's coordinates as a window frame.
    func frame(for rect: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Shows a reminder in borderless panels above everything else, without ever
/// taking keyboard focus.
///
/// One panel the size of the display paints the whole picture and lets every
/// click through. Clicks are caught by small panels just beneath it that
/// cover exactly the mascot, the bubble and the card, so everything else on
/// the desktop stays clickable. Buttons are panels of their own on top.
@MainActor
final class OverlayWindows: OverlaySurface {
    var onAction: ((OverlayAction) -> Void)?

    private var screen: NSScreen?
    private var canvasPanel: OverlayPanel?
    private var canvas: CanvasView?
    private var mascotPanels: [OverlayPanel] = []
    private(set) var solidPanels: [OverlayPanel] = []
    private(set) var buttonPanels: [OverlayPanel] = []
    private var lastPainted: [CGRect] = []
    private var isHidden = false

    var pointer: CGPoint? {
        guard let screen else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
    }

    func open(on placement: Placement) -> ScreenSpace? {
        guard let chosen = NSScreen.preferred(for: placement) else { return nil }
        close()
        screen = chosen
        let panel = Self.makePanel(level: .canvas)
        panel.setFrame(chosen.frame, display: false)
        let view = CanvasView(frame: CGRect(origin: .zero, size: chosen.frame.size))
        view.onPress = { [weak self] in self?.onAction?(.drink) }
        panel.contentView = view
        canvasPanel = panel
        canvas = view
        return chosen.space
    }

    func refit(to placement: Placement) -> ScreenSpace? {
        let current = screen?.displayID
        let same = current.flatMap { id in NSScreen.screens.first { $0.displayID == id } }
        guard let chosen = same ?? NSScreen.preferred(for: placement) else { return nil }
        screen = chosen
        canvasPanel?.setFrame(chosen.frame, display: true)
        return chosen.space
    }

    func show(_ reminder: Reminder, layout: OverlayLayout, repaintAll: Bool) {
        guard let screen, let canvas, let canvasPanel, !isHidden else { return }
        let theme = reminder.scene.look.theme
        canvasPanel.title = reminder.isPreview ? "喝水提醒预览" : "喝水提醒"

        let mascotFrames = layout.mascot.map(screen.frame(for:))
        sync(&mascotPanels, to: mascotFrames) { [weak self] in
            let view = ClickCatcher(frame: .zero)
            view.onClick = { self?.onAction?(.drink) }
            return view
        }
        sync(&solidPanels, to: layout.solid.map(screen.frame(for:))) { ClickBlocker(frame: .zero) }
        syncButtons(layout.buttons, on: screen, theme: theme)

        canvas.reminder = reminder
        canvas.parts = layout
        if repaintAll || lastPainted.isEmpty {
            canvas.needsDisplay = true
        } else {
            // Clear where the last frame painted, then draw this one.
            (lastPainted + layout.painted).forEach { canvas.setNeedsDisplay($0) }
        }
        lastPainted = layout.painted
        if !canvasPanel.isVisible { canvasPanel.orderFrontRegardless() }

        let mascotName = reminder.scene.look.mascot.spokenName
        canvas.describe(mascotFrame: mascotFrames.reduce(CGRect.null) { $0.union($1) },
                        label: "\(mascotName)：\(reminder.isPreview ? "结束喝水提醒预览" : "去喝水")",
                        help: reminder.isPreview ? "点击结束预览。"
                            : "点击后角色陪你喝水约 20 秒，喝完记录一次喝水并重新开始计时。",
                        buttons: layout.buttons.map { button in
                            (button.title, screen.frame(for: button.frame), { [weak self] in self?.onAction?(button.action) })
                        })
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        guard hidden else { return }
        ([canvasPanel].compactMap { $0 } + mascotPanels + solidPanels + buttonPanels).forEach { $0.orderOut(nil) }
    }

    func close() {
        ([canvasPanel].compactMap { $0 } + mascotPanels + solidPanels + buttonPanels).forEach { $0.close() }
        canvasPanel = nil
        canvas = nil
        mascotPanels = []
        solidPanels = []
        buttonPanels = []
        lastPainted = []
        screen = nil
        isHidden = false
    }

    /// Reuses panels from frame to frame, and leaves alone any that did not move.
    private func sync(_ panels: inout [OverlayPanel], to frames: [CGRect], content: () -> NSView) {
        while panels.count < frames.count {
            let panel = Self.makePanel(level: .input)
            panel.contentView = content()
            panels.append(panel)
        }
        for (index, panel) in panels.enumerated() {
            if index < frames.count {
                if panel.frame != frames[index] { panel.setFrame(frames[index], display: false) }
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    private func syncButtons(_ buttons: [OverlayButton], on screen: NSScreen, theme: Theme) {
        while buttonPanels.count < buttons.count {
            let panel = Self.makePanel(level: .buttons)
            panel.contentView = OverlayButtonView(theme: theme)
            buttonPanels.append(panel)
        }
        for (index, panel) in buttonPanels.enumerated() {
            guard index < buttons.count, let view = panel.contentView as? OverlayButtonView else {
                panel.orderOut(nil)
                continue
            }
            // The same panel serves whichever button is in this place now.
            let button = buttons[index]
            view.title = button.title
            view.isPrimary = button.isPrimary
            view.onPress = { [weak self] in self?.onAction?(button.action) }
            panel.title = button.title
            let frame = screen.frame(for: button.frame)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private enum Level {
        /// Paints everything; clicks pass through it.
        case canvas
        /// Catches clicks just beneath the canvas, which paints over it.
        case input
        /// Draws and handles itself, above the canvas.
        case buttons
    }

    private static func makePanel(level: Level) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = level == .canvas
        let top = NSWindow.Level.statusBar.rawValue
        panel.level = NSWindow.Level(rawValue: level == .buttons ? top : (level == .canvas ? top - 1 : top - 2))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        // VoiceOver reads the reminder from the canvas alone.
        if level != .canvas { panel.setAccessibilityElement(false) }
        return panel
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Paints the reminder, and is the one place VoiceOver finds it: the mascot
/// and the buttons are its accessible children.
@MainActor
private final class CanvasView: NSView {
    var reminder: Reminder?
    var parts: OverlayLayout?
    var onPress: (() -> Void)?
    private let mascotElement = PressableElement()
    private var buttonElements: [PressableElement] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        mascotElement.setAccessibilityParent(self)
        mascotElement.onPress = { [weak self] in self?.onPress?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func describe(mascotFrame: CGRect, label: String, help: String, buttons: [(String, CGRect, () -> Void)]) {
        let clickable = !mascotFrame.isNull
        mascotElement.setAccessibilityFrame(clickable ? mascotFrame : .zero)
        mascotElement.setAccessibilityLabel(label)
        mascotElement.setAccessibilityHelp(help)
        while buttonElements.count < buttons.count {
            let element = PressableElement()
            element.setAccessibilityParent(self)
            buttonElements.append(element)
        }
        for (element, button) in zip(buttonElements, buttons) {
            element.setAccessibilityLabel(button.0)
            element.setAccessibilityFrame(button.1)
            element.onPress = button.2
        }
        setAccessibilityChildren((clickable ? [mascotElement] : []) + buttonElements.prefix(buttons.count))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        guard let reminder, let layout = parts else { return }
        let scene = reminder.scene
        if let card = layout.card {
            Painter.card(card, look: scene.look, isPreview: reminder.isPreview,
                         drinkProgress: scene.phase == .drinking ? scene.drinkProgress : nil, in: context)
        } else {
            Painter.scene(scene, in: context)
        }
        if let badge = layout.badge { Painter.badge(badge, theme: scene.look.theme, in: context) }
    }
}

private final class PressableElement: NSAccessibilityElement {
    var onPress: (() -> Void)?

    override init() {
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// Catches clicks on the mascot. The canvas above paints the mascot itself.
@MainActor
private final class ClickCatcher: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        // A window only receives clicks where it is not fully transparent.
        // Nearly transparent is enough, and cannot flash when this panel
        // moves a frame before the canvas repaints.
        NSColor(white: 0, alpha: 0.01).setFill()
        dirtyRect.fill()
    }
}

/// Swallows clicks on the bubble and the card so they do nothing, rather
/// than land on whatever app is underneath.
@MainActor
private final class ClickBlocker: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        Palette.cream.setFill()
        dirtyRect.fill()
    }
}

@MainActor
final class OverlayButtonView: NSView {
    var onPress: (() -> Void)?
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var isPrimary = false { didSet { if isPrimary != oldValue { needsDisplay = true } } }
    private let theme: Theme
    private var state = Painter.ButtonState() { didSet { if state != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        state.isHovered = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        state = .init()
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) { state.isPressed = true }

    override func mouseUp(with event: NSEvent) {
        let inside = state.isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        state.isPressed = false
        if inside { onPress?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Painter.button(title, isPrimary: isPrimary, state: state, size: bounds.size, theme: theme, in: context)
    }
}
