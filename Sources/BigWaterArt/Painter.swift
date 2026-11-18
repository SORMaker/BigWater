import AppKit
import BigWaterCore

/// Paints what the core describes. Everything lands on a fixed pixel grid
/// with antialiasing off: no filtered textures, no soft vector edges.
///
/// Coordinates are points with the origin at the top left. Text needs a
/// flipped `NSGraphicsContext` to be current, as in a flipped view or inside
/// `Painter.image`.
public enum Painter {
    public static func fill(_ rect: CGRect, _ color: NSColor, in context: CGContext) {
        context.setFillColor(color.cgColor)
        context.fill(rect)
    }

    private static func fill(_ x: Double, _ y: Double, _ width: Double, _ height: Double,
                             _ color: NSColor, in context: CGContext) {
        fill(CGRect(x: x, y: y, width: width, height: height), color, in: context)
    }

    public static func blocks(_ blocks: [Block], theme: Theme, in context: CGContext) {
        for block in blocks { fill(block.rect, Palette.color(block.ink, theme: theme), in: context) }
    }

    // MARK: Bottle and mascots

    /// A bottle around `point`. Rotation snaps to 15° steps.
    public static func bottle(at point: CGPoint, scale: Double, angle: Double = 0,
                              theme: Theme = .blue, in context: CGContext) {
        context.saveGState()
        context.setShouldAntialias(false)
        context.translateBy(x: point.x.rounded(), y: point.y.rounded())
        context.rotate(by: (angle / (.pi / 12)).rounded() * (.pi / 12))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -Sprite.bottleCentre.x, y: -Sprite.bottleCentre.y)
        blocks(Sprite.bottle, theme: theme, in: context)
        context.restoreGState()
    }

    /// A mascot around `point`, facing right, with whatever it is holding.
    public static func mascot(_ mascot: Mascot, pose: Pose, at point: CGPoint,
                              theme: Theme = .blue, in context: CGContext) {
        // The bob lifts the sprite and whatever it holds together.
        let centre = point.snapped(to: Sprite.scale).applying(.init(translationX: 0, y: Sprite.bob(mascot, pose: pose)))
        let half = Double(Sprite.side) * Sprite.scale / 2
        context.saveGState()
        context.setShouldAntialias(false)
        context.translateBy(x: centre.x - half, y: centre.y - half)
        context.scaleBy(x: Sprite.scale, y: Sprite.scale)
        blocks(Sprite.mascot(mascot, pose: pose), theme: theme, in: context)
        context.restoreGState()

        for prop in Sprite.props(mascot, pose: pose) {
            switch prop {
            case let .bottle(offset, scale, angle):
                bottle(at: CGPoint(x: centre.x + offset.x, y: centre.y + offset.y), scale: scale, angle: angle,
                       theme: theme, in: context)
            case let .block(block):
                fill(block.rect.offsetBy(dx: centre.x, dy: centre.y), Palette.color(block.ink, theme: theme),
                     in: context)
            }
        }
    }

    public static func rope(x: Double, from top: Double, to bottom: Double, in context: CGContext) {
        guard bottom > top else { return }
        let left = (x / 4).rounded() * 4 - 2
        fill(left, top, 6, bottom - top, Palette.rope, in: context)
        // Two offset columns of highlights read as a twist.
        for y in stride(from: top, to: bottom, by: 10) {
            fill(left, y, 2, min(5, bottom - y), Palette.ropeLight, in: context)
            if y + 5 < bottom { fill(left + 2, y + 5, 2, min(5, bottom - y - 5), Palette.ropeLight, in: context) }
        }
    }

    // MARK: Speech bubble

    public enum BubbleMessage: Equatable {
        case ask
        case preview
        /// With how far the drink has come, from 0 to 1.
        case drinking(Double)
        case done

        var title: String {
            switch self {
            case .ask, .preview: return "WATER TIME"
            case .drinking: return "CHEERS!"
            case .done: return "GOOD JOB!"
            }
        }

        var line: String {
            switch self {
            case .ask: return "点我，一起喝水"
            case .preview: return "这是预览效果"
            case .drinking: return "慢慢喝，我陪你"
            case .done: return "喝好了，下次见"
            }
        }
    }

    /// A 180×64 bubble at `origin` with its tail pointing at the mascot.
    public static func bubble(_ message: BubbleMessage, at origin: CGPoint, tailOnLeft: Bool,
                              theme: Theme = .blue, in context: CGContext) {
        let width = ReminderScene.bubbleSize.width
        context.saveGState()
        context.translateBy(x: (origin.x / 2).rounded() * 2, y: (origin.y / 2).rounded() * 2)
        fill(6, 0, 168, 64, Palette.rope, in: context)
        fill(0, 6, 180, 52, Palette.rope, in: context)
        fill(6, 2, 168, 60, Palette.cream, in: context)
        fill(2, 6, 176, 52, Palette.cream, in: context)
        context.saveGState()
        if tailOnLeft {
            context.translateBy(x: width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        fill(180, 34, 6, 14, Palette.rope, in: context)
        fill(186, 38, 6, 6, Palette.rope, in: context)
        fill(178, 36, 6, 10, Palette.cream, in: context)
        fill(184, 40, 6, 2, Palette.cream, in: context)
        context.restoreGState()

        var progress: Double?
        if case let .drinking(value) = message { progress = value }
        context.saveGState()
        context.translateBy(x: (width - Sprite.textWidth(message.title, scale: 2)) / 2, y: progress == nil ? 12 : 8)
        blocks(Sprite.text(message.title, scale: 2, ink: message == .done ? .clay : .ink), theme: theme, in: context)
        context.restoreGState()

        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                         .foregroundColor: Palette.rope]
        let line = message.line as NSString
        line.draw(at: CGPoint(x: ((width - line.size(withAttributes: attributes).width) / 2).rounded(),
                              y: progress == nil ? 37 : 27), withAttributes: attributes)
        if let progress {
            fill(28, 46, 124, 10, Palette.rope, in: context)
            fill(30, 48, 120, 6, Palette.glint, in: context)
            // The bar fills a whole 4-point pixel at a time, like the rest of the art.
            fill(30, 48, (min(max(progress, 0), 1) * 30).rounded(.down) * 4, 6, Palette.accent(theme).base, in: context)
        }
        context.restoreGState()
    }

    // MARK: Whole scene

    public static func scene(_ scene: ReminderScene, in context: CGContext) {
        guard scene.phase != .gone else { return }
        let theme = scene.look.theme
        context.saveGState()
        context.setShouldAntialias(false)
        context.clip(to: scene.screen.visible)
        let point = scene.mascotPosition
        if scene.usesRope {
            rope(x: point.x + (scene.facesLeft ? 48 : -48), from: scene.screen.visible.minY, to: point.y + 43,
                 in: context)
        }
        if let origin = scene.bubbleOrigin {
            let message: BubbleMessage
            if scene.hasFinishedDrink { message = .done }
            else if scene.phase == .drinking { message = .drinking(scene.drinkProgress) }
            else { message = scene.isPreview ? .preview : .ask }
            bubble(message, at: origin, tailOnLeft: !scene.facesLeft, theme: theme, in: context)
        }

        let centre = point.snapped(to: Sprite.scale)
        context.saveGState()
        if scene.facesLeft {
            context.translateBy(x: centre.x * 2, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        mascot(scene.look.mascot, pose: scene.pose, at: centre, theme: theme, in: context)
        context.restoreGState()

        for bottle in scene.bottles {
            Painter.bottle(at: bottle.position, scale: bottle.drawnScale, angle: bottle.angle, theme: theme,
                           in: context)
        }
        // Water is always blue, whatever the theme.
        let water = Palette.accent(.blue).light
        for splash in scene.splashes {
            fill((splash.position.x / 2).rounded() * 2, (splash.position.y / 2).rounded() * 2, splash.size, splash.size,
                 water.withAlphaComponent(max(0, 1 - splash.age / splash.lifetime)), in: context)
        }
        context.restoreGState()
    }

    // MARK: Card, badge and buttons

    /// The compact reminder. `drinkProgress` swaps the drink button for a
    /// filling bar while the person drinks.
    public static func card(_ frame: CGRect, look: Look, isPreview: Bool, drinkProgress: Double?,
                            in context: CGContext) {
        let accent = Palette.accent(look.theme)
        fill(frame.minX + 4, frame.minY + 5, frame.width, frame.height, accent.dark, in: context)
        fill(frame.minX + 2, frame.minY + 2, frame.width - 4, frame.height - 4, Palette.cream, in: context)
        fill(frame.minX, frame.minY + 4, frame.width, frame.height - 8, accent.dark, in: context)
        fill(frame.minX + 4, frame.minY, frame.width - 8, frame.height, accent.dark, in: context)
        fill(frame.minX + 4, frame.minY + 4, frame.width - 8, frame.height - 8, Palette.cream, in: context)

        let icon = CGPoint(x: frame.minX + 43, y: frame.minY + 48)
        if look.mascot == .claude {
            bottle(at: icon, scale: 1.35, theme: look.theme, in: context)
        } else {
            context.saveGState()
            context.translateBy(x: icon.x, y: icon.y)
            context.scaleBy(x: 0.5, y: 0.5)
            mascot(look.mascot, pose: Pose(phase: .asking, time: 0, usesRope: false), at: .zero, theme: look.theme,
                   in: context)
            context.restoreGState()
        }

        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                      .foregroundColor: Palette.ink]
        let detail: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                     .foregroundColor: Palette.rope]
        let title = isPreview ? "喝水提醒预览" : (drinkProgress == nil ? "该喝水啦" : "慢慢喝几口")
        let line = isPreview ? "这是一次预览，不会记录喝水"
            : (drinkProgress == nil ? "休息一下，喝几口水" : "进度走完后自动记录")
        (title as NSString).draw(at: CGPoint(x: frame.minX + 76, y: frame.minY + 20), withAttributes: heading)
        (line as NSString).draw(at: CGPoint(x: frame.minX + 76, y: frame.minY + 45), withAttributes: detail)

        if let drinkProgress {
            let bar = OverlayLayout.cardPrimaryFrame(in: frame)
            fill(bar, accent.dark, in: context)
            fill(bar.insetBy(dx: 3, dy: 3), Palette.glint, in: context)
            let steps = Double(((bar.width - 6) / 4).rounded(.down))
            let filled = (min(max(drinkProgress, 0), 1) * steps).rounded(.down) * 4
            fill(bar.minX + 3, bar.minY + 3, filled, bar.height - 6, accent.light, in: context)
            let label = "喝水中…" as NSString
            let size = label.size(withAttributes: heading)
            label.draw(at: CGPoint(x: bar.midX - size.width / 2, y: bar.midY - size.height / 2 - 1),
                       withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                        .foregroundColor: Palette.ink])
        }
        if isPreview {
            badge(CGRect(x: frame.maxX - 58, y: frame.minY + 76, width: 44, height: 18), theme: look.theme, in: context)
        }
    }

    /// The small "preview" tag, with a 2-point shadow.
    public static func badge(_ frame: CGRect, theme: Theme, in context: CGContext) {
        let accent = Palette.accent(theme)
        fill(frame.minX + 2, frame.minY + 2, frame.width, frame.height, accent.dark, in: context)
        fill(frame.minX, frame.minY, frame.width - 2, frame.height - 2, accent.light, in: context)
        ("预览" as NSString).draw(at: CGPoint(x: frame.minX + 9, y: frame.minY + 2),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                                   .foregroundColor: accent.dark])
    }

    public struct ButtonState: Equatable {
        public var isHovered = false
        public var isPressed = false
        public init(isHovered: Bool = false, isPressed: Bool = false) {
            self.isHovered = isHovered
            self.isPressed = isPressed
        }
    }

    /// A reminder button filling `size` from the origin.
    public static func button(_ title: String, isPrimary: Bool, state: ButtonState = .init(), size: CGSize,
                              theme: Theme, in context: CGContext) {
        let accent = Palette.accent(theme)
        let face: NSColor
        if isPrimary {
            face = state.isPressed ? accent.dark : (state.isHovered ? accent.light : accent.base)
        } else {
            face = state.isPressed ? accent.light : (state.isHovered ? .white : Palette.cream)
        }
        fill(0, 0, size.width, size.height, accent.dark, in: context)
        fill(3, 3, size.width - 6, size.height - 6, face, in: context)
        if state.isHovered { fill(5, 5, 3, 3, accent.light, in: context) }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isPrimary ? 13 : 12, weight: .semibold),
            .foregroundColor: state.isPressed && isPrimary ? Palette.cream : Palette.ink
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2 - 1),
                  withAttributes: attributes)
    }

    // MARK: Images

    /// Renders into a bitmap with a flipped, top-left coordinate space.
    public static func image(size: CGSize, scale: Double = 2, draw: (CGContext) -> Void) -> NSImage {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        let context = graphics.cgContext
        NSGraphicsContext.saveGraphicsState()
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setShouldAntialias(false)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        withExtendedLifetime(graphics) { draw(context) }
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    /// A mascot standing still, for the picker in the settings.
    public static func portrait(_ mascot: Mascot, theme: Theme, size: Double = 48) -> NSImage {
        image(size: CGSize(width: size, height: size)) { context in
            // 3 of 8: each art pixel is 1.5 points, a whole 3 pixels on a Retina display.
            let scale = size / 128
            context.scaleBy(x: scale, y: scale)
            Painter.mascot(mascot, pose: Pose(phase: .asking, time: 0, usesRope: false), at: CGPoint(x: 64, y: 64),
                           theme: theme, in: context)
        }
    }

    public static func menuIcon() -> NSImage {
        image(size: CGSize(width: 18, height: 22)) { bottle(at: CGPoint(x: 9, y: 11), scale: 0.625, in: $0) }
    }

    public static func panelBottle() -> NSImage {
        image(size: CGSize(width: 36, height: 64)) { bottle(at: CGPoint(x: 18, y: 32), scale: 2, in: $0) }
    }
}
