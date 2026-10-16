import AppKit
import BigWaterCore
import BigWaterArt

enum OverlayControlAction: Equatable {
    case drink
    case snooze(Int)
    case endPreview
}

struct OverlayButtonSpec {
    let action: OverlayControlAction
    let title: String
    let frame: CGRect
}

enum OverlayControls {
    /// Include the fixed badge and its 2pt shadow when an animation frame is
    /// repainted. Keeping it in the previous frame also clears it on departure.
    static func animatedPaintedRegions(in scene: ReminderScene, previewBadge: CGRect?) -> [CGRect] {
        var regions = SceneRenderer.paintedRegions(of: scene)
        if let previewBadge {
            regions.append(CGRect(x: previewBadge.minX, y: previewBadge.minY,
                                  width: previewBadge.width + 2, height: previewBadge.height + 2).integral)
        }
        return regions
    }

    static func animatedButtons(in scene: ReminderScene, visibleBounds: CGRect,
                                isPreview: Bool) -> (buttons: [OverlayButtonSpec], badge: CGRect?) {
        guard scene.phase == .reminding else { return ([], nil) }
        let width = 204.0
        let primaryHeight = 42.0
        let rowHeight = 34.0
        let gap = 8.0
        let totalHeight = isPreview ? primaryHeight : primaryHeight + gap + rowHeight
        // Anchor to the resting point, not the swaying character, so a
        // button never moves between a press and its release.
        let anchor = scene.target
        let origin = clampedOrigin(size: CGSize(width: width, height: totalHeight),
                                   desired: CGPoint(x: anchor.x - width / 2, y: anchor.y + 58),
                                   within: visibleBounds)
        let primary = CGRect(origin: origin, size: CGSize(width: width, height: primaryHeight))
        let buttons: [OverlayButtonSpec]
        if isPreview {
            buttons = [OverlayButtonSpec(action: .endPreview, title: "结束预览", frame: primary)]
        } else {
            let smallWidth = (width - gap) / 2
            buttons = [
                OverlayButtonSpec(action: .drink, title: "我刚喝过水", frame: primary),
                OverlayButtonSpec(action: .snooze(10), title: "10 分钟后",
                                  frame: CGRect(x: origin.x, y: origin.y + primaryHeight + gap,
                                                width: smallWidth, height: rowHeight)),
                OverlayButtonSpec(action: .snooze(20), title: "20 分钟后",
                                  frame: CGRect(x: origin.x + smallWidth + gap,
                                                y: origin.y + primaryHeight + gap,
                                                width: smallWidth, height: rowHeight))
            ]
        }
        let badge = isPreview
            ? CGRect(x: origin.x, y: max(visibleBounds.minY, origin.y - 25), width: 55, height: 20)
            : nil
        return (buttons, badge)
    }

    /// Fixed corners map to corresponding entrances; random retains the
    /// reminder's existing randomized edge and position.
    static func reminderEntrance(for position: ReminderPosition,
                                 randomEntrance: ReminderEntrance) -> ReminderEntrance {
        switch position {
        case .random: return randomEntrance
        case .topLeft: return ReminderEntrance(edge: .top, position: 0)
        case .topRight: return ReminderEntrance(edge: .top, position: 1)
        case .bottomLeft: return ReminderEntrance(edge: .bottom, position: 0)
        case .bottomRight: return ReminderEntrance(edge: .bottom, position: 1)
        }
    }

    static func compactLayout(visibleBounds: CGRect,
                              isPreview: Bool,
                              position: ReminderPosition = .random)
        -> (card: CGRect, buttons: [OverlayButtonSpec]) {
        let cardWidth = min(276.0, max(220.0, visibleBounds.width - 20))
        let cardHeight = min(204.0, max(174.0, visibleBounds.height - 20))
        let desiredCardOrigin: CGPoint
        switch position {
        case .random, .bottomRight:
            // Keep the established default compact-card location.
            desiredCardOrigin = CGPoint(x: visibleBounds.maxX - cardWidth - 18,
                                        y: visibleBounds.maxY - cardHeight - 18)
        case .topLeft:
            desiredCardOrigin = CGPoint(x: visibleBounds.minX + 18, y: visibleBounds.minY + 18)
        case .topRight:
            desiredCardOrigin = CGPoint(x: visibleBounds.maxX - cardWidth - 18,
                                        y: visibleBounds.minY + 18)
        case .bottomLeft:
            desiredCardOrigin = CGPoint(x: visibleBounds.minX + 18,
                                        y: visibleBounds.maxY - cardHeight - 18)
        }
        let cardOrigin = clampedOrigin(size: CGSize(width: cardWidth, height: cardHeight),
                                       desired: desiredCardOrigin,
                                       within: visibleBounds)
        let card = CGRect(origin: cardOrigin, size: CGSize(width: cardWidth, height: cardHeight))
        let inset = 18.0
        let primaryY = card.minY + card.height - 94
        let primary = CGRect(x: card.minX + inset, y: primaryY,
                             width: card.width - inset * 2, height: 40)
        if isPreview {
            return (card, [OverlayButtonSpec(action: .endPreview, title: "结束预览", frame: primary)])
        }
        let gap = 8.0
        let smallWidth = (primary.width - gap) / 2
        return (card, [
            OverlayButtonSpec(action: .drink, title: "我刚喝过水", frame: primary),
            OverlayButtonSpec(action: .snooze(10), title: "10 分钟后",
                              frame: CGRect(x: primary.minX, y: primary.maxY + 8,
                                            width: smallWidth, height: 32)),
            OverlayButtonSpec(action: .snooze(20), title: "20 分钟后",
                              frame: CGRect(x: primary.minX + smallWidth + gap, y: primary.maxY + 8,
                                            width: smallWidth, height: 32))
        ])
    }

    /// The card's fully painted body, matching `drawCompactCard` minus its
    /// stepped corners and offset shadow.
    static func compactCardRegions(_ card: CGRect) -> [CGRect] {
        [CGRect(x: card.minX, y: card.minY + 4, width: card.width, height: card.height - 8),
         CGRect(x: card.minX + 4, y: card.minY, width: card.width - 8, height: card.height)]
    }

    static func drawCompactCard(_ frame: CGRect, in context: CGContext,
                                appearance: ReminderAppearance, isPreview: Bool) {
        let accent = WaterPalette.accents(for: appearance.theme)
        PixelArt.rect(context, frame.minX + 4, frame.minY + 5, frame.width, frame.height, accent.dark)
        PixelArt.rect(context, frame.minX + 2, frame.minY + 2, frame.width - 4,
                      frame.height - 4, WaterPalette.cream)
        PixelArt.rect(context, frame.minX, frame.minY + 4, frame.width, frame.height - 8, accent.dark)
        PixelArt.rect(context, frame.minX + 4, frame.minY, frame.width - 8, frame.height, accent.dark)
        PixelArt.rect(context, frame.minX + 4, frame.minY + 4, frame.width - 8,
                      frame.height - 8, WaterPalette.cream)

        let iconCenter = CGPoint(x: frame.minX + 43, y: frame.minY + 48)
        if appearance.character == .claude {
            PixelArt.bottle(in: context, at: iconCenter, scale: 1.35, theme: appearance.theme)
        } else {
            context.saveGState()
            context.translateBy(x: iconCenter.x, y: iconCenter.y)
            context.scaleBy(x: 0.5, y: 0.5)
            PixelArt.droplet(in: context, at: .zero, phase: .reminding, poseTime: 0,
                             theme: appearance.theme)
            context.restoreGState()
        }
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: WaterPalette.ink
        ]
        (isPreview ? "喝水提醒预览" : "该喝水啦")
            .draw(at: CGPoint(x: frame.minX + 76, y: frame.minY + 20), withAttributes: textAttributes)
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: WaterPalette.rope
        ]
        (isPreview ? "这是一次预览，不会记录喝水" : "休息一下，喝几口水")
            .draw(at: CGPoint(x: frame.minX + 76, y: frame.minY + 45), withAttributes: detailAttributes)
        if isPreview {
            drawPreviewBadge(CGRect(x: frame.maxX - 58, y: frame.minY + 76, width: 44, height: 18),
                             in: context, theme: appearance.theme)
        }
    }

    static func drawPreviewBadge(_ frame: CGRect, in context: CGContext, theme: ReminderTheme) {
        let accent = WaterPalette.accents(for: theme)
        PixelArt.rect(context, frame.minX + 2, frame.minY + 2, frame.width, frame.height, accent.dark)
        PixelArt.rect(context, frame.minX, frame.minY, frame.width - 2, frame.height - 2, accent.light)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: accent.dark
        ]
        ("预览" as NSString).draw(at: CGPoint(x: frame.minX + 9, y: frame.minY + 2),
                                  withAttributes: attributes)
    }

    private static func clampedOrigin(size: CGSize, desired: CGPoint, within bounds: CGRect) -> CGPoint {
        let minX = bounds.minX + 8
        let minY = bounds.minY + 8
        return CGPoint(x: min(max(desired.x, minX), max(minX, bounds.maxX - size.width - 8)),
                       y: min(max(desired.y, minY), max(minY, bounds.maxY - size.height - 8)))
    }
}

@MainActor
final class OverlayButtonView: NSView {
    var onPress: (() -> Void)?
    let title: String
    let theme: ReminderTheme
    let isPrimary: Bool
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    init(frame: CGRect, title: String, theme: ReminderTheme, isPrimary: Bool) {
        self.title = title
        self.theme = theme
        self.isPrimary = isPrimary
        super.init(frame: frame)
        setAccessibilityElement(false)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
        setAccessibilityLabel(title)
        setAccessibilityHelp("按下以执行：\(title)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let invoke = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if invoke { onPress?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let accent = WaterPalette.accents(for: theme)
        let fill: NSColor
        if isPrimary {
            fill = isPressed ? accent.dark : (isHovered ? accent.light : accent.base)
        } else {
            fill = isPressed ? accent.light : (isHovered ? NSColor.white : WaterPalette.cream)
        }
        PixelArt.rect(context, 0, 0, bounds.width, bounds.height, accent.dark)
        PixelArt.rect(context, 3, 3, bounds.width - 6, bounds.height - 6, fill)
        if isHovered {
            PixelArt.rect(context, 5, 5, 3, 3, accent.light)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isPrimary ? 13 : 12, weight: .semibold),
            .foregroundColor: isPressed && isPrimary ? WaterPalette.cream : WaterPalette.ink
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: (bounds.width - textSize.width) / 2,
                                             y: (bounds.height - textSize.height) / 2 - 1),
                                 withAttributes: attributes)
    }
}
