import CoreGraphics
import Foundation

/// One reminder on screen, from the moment it appears until it is gone:
/// either the animated mascot or the small card. It holds every rule about
/// what a click does, and leaves windows and drawing to others.
public struct Reminder: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Shown from the settings; any click ends it and nothing is recorded.
        case preview
        /// Waiting for the person to answer.
        case asking
        /// Drinking along. A "later" can still replace the drink.
        case drinking
        /// Answered, and on its way out.
        case leaving
    }

    public enum Event: Equatable, Sendable {
        /// The drink-along ran to its end. This is when a drink counts.
        case drinkFinished
        /// Nothing is left on screen.
        case gone
    }

    public let style: ReminderStyle
    public let corner: Corner
    public private(set) var scene: ReminderScene
    /// Put off, or drunk to the end: no click changes it any more.
    public private(set) var isAnswered = false

    public init(style: ReminderStyle, look: Look, corner: Corner = .random, screen: ScreenSpace,
                isPreview: Bool = false, entrance: Entrance = .random(),
                drinkTime: Double = ReminderScene.standardDrinkTime, seed: UInt64 = .random(in: .min ... .max)) {
        self.style = style
        self.corner = corner
        scene = ReminderScene(screen: screen, look: look, entrance: Entrance(corner: corner, otherwise: entrance),
                              isPreview: isPreview, drinkTime: drinkTime, seed: seed)
        // A card has no entrance to wait for.
        if style == .compact { scene.advance(by: ReminderScene.entranceTime + 0.1) }
    }

    public var isPreview: Bool { scene.isPreview }

    public var stage: Stage {
        if isPreview { return .preview }
        if isAnswered { return .leaving }
        // A click during the entrance already commits to the drink.
        return scene.phase == .drinking || scene.willDrinkOnArrival ? .drinking : .asking
    }

    /// Nothing of it is left on screen: the mascot went, or the card closed.
    private var isGone: Bool { scene.phase == .gone || (style == .compact && stage == .leaving) }

    /// The card only moves while its drink bar fills.
    public var isAnimating: Bool { style == .animated || scene.phase == .drinking }

    /// "I'm going to drink": from the button, the mascot or the menu. The
    /// reminder stays up for the whole drink, so a reflex click dismisses
    /// nothing. False when it changes nothing.
    @discardableResult
    public mutating func drink() -> Bool {
        stage == .asking && scene.beginDrinking()
    }

    /// "Later". False when the reminder was already answered.
    @discardableResult
    public mutating func putOff() -> Bool {
        guard stage == .asking || stage == .drinking else { return false }
        isAnswered = true
        return true
    }

    /// Moves the reminder on, and says what happened on the way. Each event
    /// is reported once.
    public mutating func advance(by elapsed: Double) -> [Event] {
        let wasGone = isGone
        scene.advance(by: elapsed)
        var events: [Event] = []
        if !isAnswered && !isPreview && scene.hasFinishedDrink {
            isAnswered = true
            events.append(.drinkFinished)
        }
        // The mascot takes its bow first; a card simply closes.
        if isGone && !wasGone { events.append(.gone) }
        return events
    }

    public mutating func fit(_ screen: ScreenSpace) { scene.fit(screen) }

    /// Lights the mascot up under the pointer, while a click on it still counts.
    public mutating func hover(at pointer: CGPoint?) {
        scene.isHovered = style == .animated && scene.isClickable
            && pointer.map { point in scene.mascotArea.contains { $0.contains(point) } } == true
    }

    public var layout: OverlayLayout { OverlayLayout(self) }
}

public enum OverlayAction: Equatable, Sendable {
    case drink
    case snooze(Int)
    case endPreview

    public static let snoozeChoices = [10, 20]
}

public struct OverlayButton: Equatable, Sendable {
    public var action: OverlayAction
    public var frame: CGRect

    public var title: String {
        switch action {
        case .drink: return "去喝水"
        case .snooze(let minutes): return "\(minutes) 分钟后"
        case .endPreview: return "结束预览"
        }
    }

    public var isPrimary: Bool { action == .drink || action == .endPreview }
}

/// Where every part of a reminder sits on its display for one frame. Points,
/// origin at the top left of the display.
public struct OverlayLayout: Equatable, Sendable {
    public var buttons: [OverlayButton] = []
    /// The "preview" tag of an animated preview.
    public var badge: CGRect?
    /// The card of a compact reminder.
    public var card: CGRect?
    /// The mascot's own pixels: a click here starts the drink.
    public var mascot: [CGRect] = []
    /// Opaque parts that swallow clicks rather than pass them to the app
    /// underneath: the speech bubble and the card.
    public var solid: [CGRect] = []
    /// Everything drawn this frame, so only that much is repainted.
    public var painted: [CGRect] = []

    init(_ reminder: Reminder) {
        let scene = reminder.scene
        switch reminder.style {
        case .animated:
            if scene.isClickable { mascot = scene.mascotArea }
            if scene.phase == .asking || scene.phase == .drinking {
                solid = scene.bubbleArea
                placeButtons(under: scene)
            }
            painted = scene.paintedArea
            if let badge {
                // With its 2-point shadow.
                painted.append(CGRect(x: badge.minX, y: badge.minY, width: badge.width + 2,
                                      height: badge.height + 2).integral)
            }
        case .compact:
            placeCard(for: reminder)
        }
    }

    /// Fixed under the resting point rather than the swaying mascot, so a
    /// button never moves between a press and its release.
    private mutating func placeButtons(under scene: ReminderScene) {
        let width = 204.0, primaryHeight = 42.0, rowHeight = 34.0, gap = 8.0
        let height = scene.isPreview ? primaryHeight : primaryHeight + gap + rowHeight
        let anchor = scene.restingPoint
        let origin = Self.fit(CGSize(width: width, height: height),
                              at: CGPoint(x: anchor.x - width / 2, y: anchor.y + 58), in: scene.screen.visible)
        let primary = CGRect(x: origin.x, y: origin.y, width: width, height: primaryHeight)
        if scene.isPreview {
            buttons = [OverlayButton(action: .endPreview, frame: primary)]
            badge = CGRect(x: origin.x, y: max(scene.screen.visible.minY, origin.y - 25), width: 55, height: 20)
        } else {
            buttons = Self.answerButtons(primary: primary, rowHeight: rowHeight, gap: gap,
                                         isDrinking: scene.phase == .drinking)
        }
    }

    private mutating func placeCard(for reminder: Reminder) {
        let visible = reminder.scene.screen.visible
        let size = CGSize(width: min(276.0, max(220.0, visible.width - 20)),
                          height: min(204.0, max(174.0, visible.height - 20)))
        let left = visible.minX + 18, right = visible.maxX - size.width - 18
        let top = visible.minY + 18, bottom = visible.maxY - size.height - 18
        let wanted: CGPoint
        switch reminder.corner {
        case .random, .bottomRight: wanted = CGPoint(x: right, y: bottom)
        case .topLeft: wanted = CGPoint(x: left, y: top)
        case .topRight: wanted = CGPoint(x: right, y: top)
        case .bottomLeft: wanted = CGPoint(x: left, y: bottom)
        }
        let card = CGRect(origin: Self.fit(size, at: wanted, in: visible), size: size)
        let primary = Self.cardPrimaryFrame(in: card)
        self.card = card
        // The body without its stepped corners and offset shadow.
        solid = [CGRect(x: card.minX, y: card.minY + 4, width: card.width, height: card.height - 8),
                 CGRect(x: card.minX + 4, y: card.minY, width: card.width - 8, height: card.height)]
        painted = [card.insetBy(dx: -8, dy: -8)]
        buttons = reminder.isPreview
            ? [OverlayButton(action: .endPreview, frame: primary)]
            : Self.answerButtons(primary: primary, rowHeight: 32, gap: 8,
                                 isDrinking: reminder.scene.phase == .drinking)
    }

    /// Where the card's drink button sits, and its drink bar after a press.
    public static func cardPrimaryFrame(in card: CGRect) -> CGRect {
        CGRect(x: card.minX + 18, y: card.minY + card.height - 94, width: card.width - 36, height: 40)
    }

    /// "Drink" above two "later" buttons. Once the drink starts only the
    /// two stay, in their places, so a second click where the drink button
    /// was lands on nothing.
    private static func answerButtons(primary: CGRect, rowHeight: Double, gap: Double,
                                      isDrinking: Bool) -> [OverlayButton] {
        let width = (primary.width - gap) / 2
        let later = OverlayAction.snoozeChoices.enumerated().map { index, minutes in
            OverlayButton(action: .snooze(minutes),
                          frame: CGRect(x: primary.minX + Double(index) * (width + gap), y: primary.maxY + gap,
                                        width: width, height: rowHeight))
        }
        return isDrinking ? later : [OverlayButton(action: .drink, frame: primary)] + later
    }

    /// The origin nearest to `wanted` that keeps `size` 8 points inside `bounds`.
    private static func fit(_ size: CGSize, at wanted: CGPoint, in bounds: CGRect) -> CGPoint {
        let minX = bounds.minX + 8, minY = bounds.minY + 8
        return CGPoint(x: min(max(wanted.x, minX), max(minX, bounds.maxX - size.width - 8)),
                       y: min(max(wanted.y, minY), max(minY, bounds.maxY - size.height - 8)))
    }
}

// MARK: - Where the scene's parts are

extension ReminderScene {
    public static let bubbleSize = CGSize(width: 180, height: 64)

    /// The bubble is up while the mascot asks, drinks and cheers.
    public var bubbleOrigin: CGPoint? {
        guard phase == .asking || phase == .drinking || phase == .cheering else { return nil }
        let point = mascotPosition
        let bounds = screen.visible
        // It sits on the mascot's inward side, with room for its tail.
        let minX = bounds.minX + (facesLeft ? 8 : 20)
        let maxX = max(minX, bounds.maxX - (facesLeft ? 200 : 188))
        let minY = bounds.minY + 8
        return CGPoint(x: min(max(point.x + (facesLeft ? -260 : 80), minX), maxX),
                       y: min(max(point.y - 36, minY), max(minY, bounds.maxY - 72))).snapped(to: 2)
    }

    /// The bubble's body and tail, exactly as painted.
    public var bubbleArea: [CGRect] {
        guard let origin = bubbleOrigin else { return [] }
        let tailX = facesLeft ? origin.x + 180 : origin.x - 6
        let tipX = facesLeft ? origin.x + 186 : origin.x - 12
        return [CGRect(x: origin.x + 6, y: origin.y, width: 168, height: 64),
                CGRect(x: origin.x, y: origin.y + 6, width: 180, height: 52),
                CGRect(x: tailX, y: origin.y + 34, width: 6, height: 14),
                CGRect(x: tipX, y: origin.y + 38, width: 6, height: 6)]
            .compactMap { $0.clipped(to: screen.visible) }
    }

    /// The mascot's painted pixels on the display, cut off at the display's
    /// edge so a sprite sliding in never takes clicks from a neighbouring one.
    public var mascotArea: [CGRect] {
        let centre = mascotPosition.snapped(to: Sprite.scale)
        let y = centre.y + Sprite.bob(look.mascot, pose: pose)
        let bounds = CGRect(origin: .zero, size: screen.size).intersection(screen.visible)
        var plain = pose
        plain.isHovered = false
        return Sprite.solidArea(look.mascot, pose: plain).compactMap { area in
            CGRect(x: centre.x + (facesLeft ? -area.maxX : area.minX), y: y + area.minY,
                   width: area.width, height: area.height).clipped(to: bounds)
        }
    }

    /// Generous boxes around everything the painter draws for this frame.
    public var paintedArea: [CGRect] {
        guard phase != .gone else { return [] }
        let point = mascotPosition
        // The sprite with whatever it holds, mirrored with the art.
        var areas = [CGRect(x: point.x - (facesLeft ? 102 : 68), y: point.y - 78, width: 170, height: 150)]
        if usesRope {
            areas.append(CGRect(x: point.x + (facesLeft ? 40 : -56), y: screen.visible.minY, width: 16,
                                height: max(0, point.y + 45 - screen.visible.minY)))
        }
        if let origin = bubbleOrigin {
            areas.append(CGRect(x: origin.x - (facesLeft ? 0 : 12), y: origin.y, width: 192, height: 64))
        }
        for bottle in bottles {
            // Half the diagonal of the 18×32 bottle covers any rotation.
            let radius = 18.4 * bottle.drawnScale + 2
            areas.append(CGRect(x: bottle.position.x - radius, y: bottle.position.y - radius,
                                width: radius * 2, height: radius * 2))
        }
        for splash in splashes {
            areas.append(CGRect(x: splash.position.x - 2, y: splash.position.y - 2,
                                width: splash.size + 4, height: splash.size + 4))
        }
        return areas.map { $0.insetBy(dx: -4, dy: -4).integral }
    }
}

extension FlyingBottle {
    /// Sizes step by halves, like everything else on the pixel grid.
    public var drawnScale: Double { (scale * 2).rounded() / 2 }
}
