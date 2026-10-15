import AppKit
import BigWaterCore

public enum WaterPalette {
    public static let cream = NSColor(srgbRed: 0.98, green: 0.96, blue: 0.92, alpha: 1)
    public static let ink = NSColor(srgbRed: 0.24, green: 0.19, blue: 0.16, alpha: 1)
    public static let clay = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    public static let clayLight = NSColor(srgbRed: 0.94, green: 0.61, blue: 0.45, alpha: 1)
    public static let clayShadow = NSColor(srgbRed: 0.68, green: 0.33, blue: 0.24, alpha: 1)
    public static let blue = NSColor(srgbRed: 0.26, green: 0.59, blue: 0.86, alpha: 1)
    public static let blueLight = NSColor(srgbRed: 0.58, green: 0.85, blue: 0.97, alpha: 1)
    public static let blueDark = NSColor(srgbRed: 0.13, green: 0.35, blue: 0.55, alpha: 1)
    public static let glint = NSColor(srgbRed: 0.86, green: 0.97, blue: 1, alpha: 1)
    public static let rope = NSColor(srgbRed: 0.48, green: 0.37, blue: 0.27, alpha: 1)
    public static let ropeLight = NSColor(srgbRed: 0.79, green: 0.65, blue: 0.46, alpha: 1)
}

/// Deliberately painted on a fixed pixel grid: no filtered textures or fuzzy
/// vector outlines. The same artwork is used in the menu, app and previews.
public enum PixelArt {
    public static func rect(_ context: CGContext, _ x: Double, _ y: Double,
                            _ width: Double, _ height: Double, _ color: NSColor) {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: x, y: y, width: width, height: height))
    }

    public static func bottle(in context: CGContext, at point: CGPoint,
                              scale: Double, angle: Double = 0, opacity: Double = 1) {
        context.saveGState()
        context.setShouldAntialias(false)
        context.setAlpha(opacity)
        context.translateBy(x: point.x.rounded(), y: point.y.rounded())
        context.rotate(by: (angle / (.pi / 12)).rounded() * (.pi / 12))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -9, y: -16)

        // Screw cap and narrow neck.
        rect(context, 6, 0, 6, 3, WaterPalette.blueDark)
        rect(context, 7, 0, 4, 1, WaterPalette.blue)
        rect(context, 7, 1, 1, 2, WaterPalette.blueLight)
        rect(context, 6, 3, 6, 3, WaterPalette.glint)
        rect(context, 10, 3, 2, 3, WaterPalette.blue)

        // Stepped shoulders, transparent plastic and blue water.
        rect(context, 5, 5, 8, 2, WaterPalette.blueDark)
        rect(context, 4, 7, 10, 2, WaterPalette.blueDark)
        rect(context, 3, 9, 12, 20, WaterPalette.blueDark)
        rect(context, 4, 29, 10, 2, WaterPalette.blueDark)
        rect(context, 6, 5, 6, 2, WaterPalette.glint)
        rect(context, 5, 7, 8, 2, WaterPalette.glint)
        rect(context, 4, 9, 10, 19, WaterPalette.blueLight)
        rect(context, 5, 10, 2, 17, WaterPalette.glint)
        rect(context, 11, 9, 3, 19, WaterPalette.blue)
        rect(context, 4, 12, 10, 1, WaterPalette.blue)
        rect(context, 4, 25, 10, 1, WaterPalette.blue)
        rect(context, 5, 28, 8, 2, WaterPalette.blue)
        rect(context, 6, 29, 5, 1, WaterPalette.blueLight)

        // A real label rather than a plain blue rectangle.
        rect(context, 4, 15, 10, 8, WaterPalette.cream)
        rect(context, 12, 15, 2, 8, NSColor(srgbRed: 0.82, green: 0.87, blue: 0.86, alpha: 1))
        microText("H2O", in: context, at: CGPoint(x: 4, y: 17), color: WaterPalette.blueDark)
        context.restoreGState()
    }

    public static func claude(in context: CGContext, at point: CGPoint,
                              phase: ReminderPhase, poseTime: Double, hovered: Bool = false) {
        context.saveGState()
        context.setShouldAntialias(false)
        context.translateBy(x: (point.x / 4).rounded() * 4 - 64,
                            y: (point.y / 4).rounded() * 4 - 64)
        context.scaleBy(x: 4, y: 4)
        for block in claudeBlocks(phase: phase, poseTime: poseTime, hovered: hovered) {
            rect(context, block.frame.minX, block.frame.minY, block.frame.width, block.frame.height, block.color)
        }
        let cycle = poseTime.truncatingRemainder(dividingBy: ReminderScene.throwPeriod)
        context.restoreGState()

        if phase == .reminding && cycle >= 0.18 && cycle < ReminderScene.releaseTime {
            let lift = min((cycle - 0.18) / 0.25, 1)
            bottle(in: context, at: CGPoint(x: point.x + 55, y: point.y - 30 - lift * 13),
                   scale: 1.5, angle: -0.25 - lift * 0.4)
        }
        if phase == .reminding && cycle >= ReminderScene.releaseTime && cycle < 0.72 {
            // Three short pixel streaks make the moment of release readable.
            for index in 0..<3 {
                rect(context, point.x + 75 + Double(index) * 9,
                     point.y + 8 + Double(index) * 7, 6, 3, WaterPalette.blueLight)
            }
        }
    }

    private struct PixelBlock {
        let frame: CGRect
        let color: NSColor
    }

    private static func claudeBlocks(phase: ReminderPhase, poseTime: Double, hovered: Bool) -> [PixelBlock] {
        var blocks: [PixelBlock] = []
        func paint(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ color: NSColor) {
            blocks.append(PixelBlock(frame: CGRect(x: x, y: y, width: width, height: height), color: color))
        }
        let clay = hovered ? WaterPalette.clayLight : WaterPalette.clay
        let climbing = phase == .ascending
        let happy = phase == .acknowledging || climbing
        let grip = Int(poseTime * 7) % 2
        let cycle = poseTime.truncatingRemainder(dividingBy: ReminderScene.throwPeriod)

        // Four little legs, alternating as he pulls himself up the rope.
        for (index, x) in [8.0, 12.0, 18.0, 22.0].enumerated() {
            let lifted = climbing && (index + grip) % 2 == 0
            paint(x, 22, 2, lifted ? 3 : 5, WaterPalette.clayShadow)
            paint(x, 22, 2, lifted ? 2 : 4, clay)
        }

        // Near arm always grips the rope; a second hand leapfrogs on ascent.
        let handY = climbing ? (grip == 0 ? 6.0 : 10.0) : 9.0
        paint(4, handY + 2, 2, 7, WaterPalette.clayShadow)
        paint(5, 15, 4, 3, clay)
        paint(3, handY, 4, 3, clay)
        paint(3, handY, 3, 1, WaterPalette.clayLight)
        if climbing {
            let secondY = grip == 0 ? 11.0 : 5.0
            paint(6, secondY + 2, 2, 8, clay)
            paint(3, secondY, 4, 3, WaterPalette.clayLight)
        }

        // Recognizable wide Clawd body and slit eyes.
        paint(8, 12, 16, 11, clay)
        paint(9, 12, 14, 1, WaterPalette.clayLight)
        paint(8, 21, 16, 2, WaterPalette.clayShadow)
        paint(9, 21, 14, 1, clay)
        let blinking = !happy && Int(poseTime * 10) % 43 == 37
        if happy || blinking {
            paint(11, 17, 3, 1, WaterPalette.ink)
            paint(19, 17, 3, 1, WaterPalette.ink)
        } else {
            paint(11, 15, 2, 4, WaterPalette.ink)
            paint(20, 15, 2, 4, WaterPalette.ink)
            paint(11, 15, 1, 1, WaterPalette.cream)
            paint(20, 15, 1, 1, WaterPalette.cream)
        }
        if happy { paint(15, 20, 3, 1, WaterPalette.ink) }

        // Far arm has four distinct silhouettes, including a wind-up and release.
        if phase == .reminding && cycle >= 0.18 && cycle < ReminderScene.releaseTime {
            paint(24, 12, 2, 7, clay)
            paint(24, 10, 4, 3, clay)
            paint(25, 10, 3, 1, WaterPalette.clayLight)
        } else if phase == .reminding && cycle >= ReminderScene.releaseTime && cycle < 0.87 {
            paint(24, 16, 5, 3, clay)
            paint(29, 15, 3, 3, WaterPalette.clayLight)
        } else if phase == .acknowledging {
            let wave = Int(poseTime * 12) % 2 == 0 ? 0.0 : 1.0
            paint(24, 12, 2, 7, clay)
            paint(24, 8 + wave, 4, 4, WaterPalette.clayLight)
        } else {
            paint(24, 15, 3, 3, clay)
            paint(26, 16, 2, 3, WaterPalette.clayShadow)
        }

        // Blue delivery cap, with a tiny water-drop badge.
        paint(10, 5, 12, 2, WaterPalette.blueDark)
        paint(8, 7, 16, 5, WaterPalette.blueDark)
        paint(10, 6, 12, 2, WaterPalette.blue)
        paint(9, 8, 14, 3, WaterPalette.blue)
        paint(11, 6, 9, 1, WaterPalette.blueLight)
        paint(9, 8, 2, 3, WaterPalette.blueLight)
        paint(8, 11, 21, 2, WaterPalette.blueDark)
        paint(9, 11, 19, 1, WaterPalette.blue)
        paint(18, 8, 1, 1, WaterPalette.glint)
        paint(17, 9, 3, 2, WaterPalette.glint)
        return blocks
    }

    /// Positive hit regions, derived from the painted sprite itself. Rope,
    /// carried bottles, flying bottles and transparent gaps are excluded.
    /// Coordinates are relative to Claude's center, in top-left view space.
    public static func claudeHitRegions(phase: ReminderPhase, poseTime: Double) -> [CGRect] {
        var mask = Array(repeating: Array(repeating: false, count: 32), count: 32)
        for block in claudeBlocks(phase: phase, poseTime: poseTime, hovered: false) {
            for y in max(0, Int(block.frame.minY))..<min(32, Int(block.frame.maxY)) {
                for x in max(0, Int(block.frame.minX))..<min(32, Int(block.frame.maxX)) {
                    mask[y][x] = true
                }
            }
        }
        var regions: [CGRect] = []
        var activeRuns: [String: Int] = [:]
        for y in 0..<32 {
            var nextRuns: [String: Int] = [:]
            var x = 0
            while x < 32 {
                guard mask[y][x] else { x += 1; continue }
                let start = x
                while x < 32 && mask[y][x] { x += 1 }
                let key = "\(start):\(x)"
                let index: Int
                if let previous = activeRuns[key] {
                    index = previous
                    regions[index].size.height += 4
                } else {
                    index = regions.count
                    regions.append(CGRect(x: start * 4 - 64, y: y * 4 - 64,
                                          width: (x - start) * 4, height: 4))
                }
                nextRuns[key] = index
            }
            activeRuns = nextRuns
        }
        return regions
    }

    /// Clip the sprite to its canvas before creating desktop input windows.
    /// During descent the un-clipped pixels are above this display; on a
    /// vertically arranged second display they must not become visible there.
    public static func claudeHitRegions(in scene: ReminderScene) -> [CGRect] {
        let point = scene.characterPosition
        let x = (point.x / 4).rounded() * 4
        let y = (point.y / 4).rounded() * 4
        let bounds = CGRect(origin: .zero, size: scene.viewport)
        return claudeHitRegions(phase: scene.phase, poseTime: scene.phaseTime).compactMap { region in
            let clipped = region.offsetBy(dx: x, dy: y).intersection(bounds)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
    }

    public static func rope(in context: CGContext, x: Double, from top: Double, to bottom: Double) {
        guard bottom > top else { return }
        let snappedX = (x / 4).rounded() * 4
        rect(context, snappedX - 2, top, 6, bottom - top, WaterPalette.rope)
        var y = top
        while y < bottom {
            let height = min(5, bottom - y)
            rect(context, snappedX - 2, y, 2, height, WaterPalette.ropeLight)
            if y + 5 < bottom {
                rect(context, snappedX, y + 5, 2, min(5, bottom - y - 5), WaterPalette.ropeLight)
            }
            y += 10
        }
    }

    public static func speech(in context: CGContext, at origin: CGPoint, acknowledged: Bool) {
        context.saveGState()
        context.translateBy(x: (origin.x / 2).rounded() * 2, y: (origin.y / 2).rounded() * 2)
        let border = WaterPalette.rope
        rect(context, 6, 0, 168, 64, border)
        rect(context, 0, 6, 180, 52, border)
        rect(context, 6, 2, 168, 60, WaterPalette.cream)
        rect(context, 2, 6, 176, 52, WaterPalette.cream)
        rect(context, 180, 34, 6, 14, border)
        rect(context, 186, 38, 6, 6, border)
        rect(context, 178, 36, 6, 10, WaterPalette.cream)
        rect(context, 184, 40, 6, 2, WaterPalette.cream)
        pixelText(acknowledged ? "GOOD JOB!" : "WATER TIME", in: context,
                  at: CGPoint(x: acknowledged ? 36 : 30, y: 12), scale: 2,
                  color: acknowledged ? WaterPalette.clay : WaterPalette.ink)
        let secondary = acknowledged ? "喝口水，下次见" : "点我，喝水去"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: WaterPalette.rope
        ]
        (secondary as NSString).draw(at: CGPoint(x: acknowledged ? 43 : 53, y: 37), withAttributes: attributes)
        context.restoreGState()
    }

    public static func pixelText(_ text: String, in context: CGContext, at origin: CGPoint,
                                 scale: Double, color: NSColor) {
        var x = origin.x
        for character in text {
            if let rows = font[character] {
                for (y, row) in rows.enumerated() {
                    for bit in 0..<5 where row & (1 << (4 - bit)) != 0 {
                        rect(context, x + Double(bit) * scale, origin.y + Double(y) * scale,
                             scale, scale, color)
                    }
                }
            }
            x += 6 * scale
        }
    }

    private static func microText(_ text: String, in context: CGContext, at origin: CGPoint, color: NSColor) {
        let glyphs: [Character: [Int]] = ["H": [5, 5, 7, 5, 5], "2": [6, 1, 2, 4, 7], "O": [2, 5, 5, 5, 2]]
        var x = origin.x
        for character in text {
            for (y, row) in (glyphs[character] ?? []).enumerated() {
                for bit in 0..<3 where row & (1 << (2 - bit)) != 0 {
                    rect(context, x + Double(bit), origin.y + Double(y), 1, 1, color)
                }
            }
            x += 3.5
        }
    }

    private static let font: [Character: [Int]] = [
        "A": [14,17,17,31,17,17,17], "B": [30,17,17,30,17,17,30],
        "C": [14,17,16,16,16,17,14], "D": [30,17,17,17,17,17,30],
        "E": [31,16,16,30,16,16,31], "F": [31,16,16,30,16,16,16],
        "G": [14,17,16,23,17,17,15], "H": [17,17,17,31,17,17,17],
        "I": [14,4,4,4,4,4,14], "J": [7,2,2,2,18,18,12],
        "K": [17,18,20,24,20,18,17], "L": [16,16,16,16,16,16,31],
        "M": [17,27,21,21,17,17,17], "N": [17,25,21,19,17,17,17],
        "O": [14,17,17,17,17,17,14], "P": [30,17,17,30,16,16,16],
        "Q": [14,17,17,17,21,18,13], "R": [30,17,17,30,20,18,17],
        "S": [15,16,16,14,1,1,30], "T": [31,4,4,4,4,4,4],
        "U": [17,17,17,17,17,17,14], "V": [17,17,17,17,17,10,4],
        "W": [17,17,17,21,21,21,10], "X": [17,17,10,4,10,17,17],
        "Y": [17,17,10,4,4,4,4], "Z": [31,1,2,4,8,16,31],
        "!": [4,4,4,4,4,0,4], " ": [0,0,0,0,0,0,0]
    ]

    public static func image(size: CGSize, backingScale: Double = 2,
                              draw: (CGContext) -> Void) -> NSImage {
        let width = Int(size.width * backingScale)
        let height = Int(size.height * backingScale)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        let context = graphics.cgContext
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: backingScale, y: -backingScale)
        context.setShouldAntialias(false)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let result = NSImage(size: size)
        result.addRepresentation(bitmap)
        result.isTemplate = false
        return result
    }

    public static func menuIcon() -> NSImage {
        image(size: CGSize(width: 18, height: 22)) { context in
            bottle(in: context, at: CGPoint(x: 9, y: 11), scale: 0.625)
        }
    }

    public static func settingsBottle() -> NSImage {
        image(size: CGSize(width: 36, height: 64)) { context in
            bottle(in: context, at: CGPoint(x: 18, y: 32), scale: 2)
        }
    }
}

public enum SceneRenderer {
    public static func draw(_ scene: ReminderScene, in context: CGContext) {
        guard scene.phase != .finished else { return }
        context.saveGState()
        context.setShouldAntialias(false)
        let point = scene.characterPosition
        PixelArt.rope(in: context, x: point.x - 48, from: scene.topInset, to: point.y + 43)
        if scene.phase == .reminding || scene.phase == .acknowledging {
            PixelArt.speech(in: context, at: CGPoint(x: max(12, point.x - 255), y: point.y - 36),
                            acknowledged: scene.hasAcknowledged)
        }
        PixelArt.claude(in: context, at: point, phase: scene.phase,
                        poseTime: scene.phaseTime, hovered: scene.isHovered)
        for bottle in scene.bottles {
            // Large bottles come toward the viewer and rotate in 15-degree steps.
            let scale = (bottle.scale * 2).rounded() / 2
            PixelArt.bottle(in: context, at: bottle.position, scale: scale, angle: bottle.angle)
        }
        for particle in scene.particles {
            let opacity = max(0, 1 - particle.age / particle.lifetime)
            PixelArt.rect(context, (particle.position.x / 2).rounded() * 2,
                          (particle.position.y / 2).rounded() * 2,
                          particle.size, particle.size,
                          WaterPalette.blueLight.withAlphaComponent(opacity))
        }
        context.restoreGState()
    }
}
