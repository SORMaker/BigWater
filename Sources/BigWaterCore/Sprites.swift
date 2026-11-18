import CoreGraphics
import Foundation

/// A colour by its role. The painter decides what each one looks like for a
/// theme; the shapes here never mention real colours.
public enum Ink: Sendable {
    case cream, ink, clay, clayLight, clayShadow
    case accent, accentLight, accentDark
    case glint, rope, ropeLight, labelShade
}

/// One filled rectangle of pixel art.
public struct Block: Equatable, Sendable {
    public var rect: CGRect
    public var ink: Ink

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ ink: Ink) {
        rect = CGRect(x: x, y: y, width: width, height: height)
        self.ink = ink
    }
}

/// What the mascot is doing at one instant.
public struct Pose: Equatable, Sendable {
    public var phase: ReminderScene.Phase
    /// Seconds into the phase.
    public var time: Double
    public var isHovered: Bool
    public var usesRope: Bool

    public init(phase: ReminderScene.Phase, time: Double, isHovered: Bool = false, usesRope: Bool = true) {
        self.phase = phase
        self.time = time
        self.isHovered = isHovered
        self.usesRope = usesRope
    }

    /// Each sip tips the bottle up for a moment, then lowers it for a breath.
    public var isSipping: Bool { phase == .drinking && time.truncatingRemainder(dividingBy: 2.4) < 1.6 }
    var throwCycle: Double { time.truncatingRemainder(dividingBy: ReminderScene.throwPeriod) }
    var isWindingUp: Bool { phase == .asking && throwCycle >= 0.18 && throwCycle < ReminderScene.releaseTime }
}

extension ReminderScene {
    public var pose: Pose {
        Pose(phase: phase, time: phaseTime, isHovered: isHovered, usesRope: usesRope)
    }
}

/// Something the mascot holds or leaves in the air, placed in points from
/// its centre. It faces right; the painter mirrors it with the mascot.
public enum Prop: Equatable, Sendable {
    case bottle(at: CGPoint, scale: Double, angle: Double)
    case block(Block)
}

/// The pixel art as data: 32×32 mascots at four points per pixel, an 18×32
/// bottle, and a 5×7 alphabet.
public enum Sprite {
    public static let side = 32
    public static let scale = 4.0
    static let half = Double(side) * scale / 2

    public static func mascot(_ mascot: Mascot, pose: Pose) -> [Block] {
        switch mascot {
        case .claude: return claude(pose)
        case .droplet: return droplet(pose)
        }
    }

    /// The droplet hops in place while it asks. Points, downwards.
    public static func bob(_ mascot: Mascot, pose: Pose) -> Double {
        mascot == .droplet && pose.phase == .asking ? sin(pose.time * 2.8).rounded() * scale : 0
    }

    public static func props(_ mascot: Mascot, pose: Pose) -> [Prop] {
        let hand: Ink
        switch mascot {
        case .claude: hand = pose.isHovered ? .clayLight : .clay
        case .droplet: hand = pose.isHovered ? .accentLight : .accent
        }
        if pose.phase == .drinking {
            // Held to the mouth, with the hand painted over the bottle.
            let reach = mascot == .droplet ? 8.0 : 0
            return pose.isSipping
                ? [.bottle(at: CGPoint(x: reach + 50, y: -2), scale: 1.5, angle: -2 * .pi / 3),
                   .block(Block(reach + 44, -4, 16, 12, hand))]
                : [.bottle(at: CGPoint(x: reach + 56, y: 8), scale: 1.5, angle: -5 * .pi / 12),
                   .block(Block(reach + 48, 4, 16, 12, hand))]
        }
        guard mascot == .claude, pose.phase == .asking else { return [] }
        let cycle = pose.throwCycle
        if pose.isWindingUp {
            let lift = min((cycle - 0.18) / 0.25, 1)
            return [.bottle(at: CGPoint(x: 55, y: -30 - lift * 13), scale: 1.5, angle: -0.25 - lift * 0.4)]
        }
        if cycle >= ReminderScene.releaseTime && cycle < 0.72 {
            // Three short streaks make the moment of release readable.
            return (0..<3).map { .block(Block(75 + Double($0) * 9, 8 + Double($0) * 7, 6, 3, .accentLight)) }
        }
        return []
    }

    // MARK: Claude

    private static func claude(_ pose: Pose) -> [Block] {
        var blocks: [Block] = []
        func paint(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ ink: Ink) {
            blocks.append(Block(x, y, width, height, ink))
        }
        let clay: Ink = pose.isHovered ? .clayLight : .clay
        let climbing = pose.phase == .leaving && pose.usesRope
        let walking = !pose.usesRope && (pose.phase == .entering || pose.phase == .leaving)
        let moving = climbing || walking
        let happy = pose.phase == .cheering || pose.phase == .leaving
        let grip = Int(pose.time * 7) % 2
        let cycle = pose.throwCycle

        // Four little legs, alternating as he climbs or walks.
        for (index, x) in [8.0, 12.0, 18.0, 22.0].enumerated() {
            let lifted = moving && (index + grip) % 2 == 0
            paint(x, 22, 2, lifted ? 3 : 5, .clayShadow)
            paint(x, 22, 2, lifted ? 2 : 4, clay)
        }

        if pose.usesRope {
            // The near arm holds the rope; on the way up a second hand leapfrogs it.
            let handY = climbing ? (grip == 0 ? 6.0 : 10.0) : 9.0
            paint(4, handY + 2, 2, 7, .clayShadow)
            paint(5, 15, 4, 3, clay)
            paint(3, handY, 4, 3, clay)
            paint(3, handY, 3, 1, .clayLight)
            if climbing {
                let secondY = grip == 0 ? 11.0 : 5.0
                paint(6, secondY + 2, 2, 8, clay)
                paint(3, secondY, 4, 3, .clayLight)
            }
        } else {
            paint(5, 15, 4, 3, clay)
            paint(5, 17, 2, moving && grip == 0 ? 3 : 5, .clayShadow)
            paint(5, 17, 2, moving && grip == 0 ? 2 : 4, clay)
        }

        // The wide body and slit eyes.
        paint(8, 12, 16, 11, clay)
        paint(9, 12, 14, 1, .clayLight)
        paint(8, 21, 16, 2, .clayShadow)
        paint(9, 21, 14, 1, clay)
        let blinking = !happy && Int(pose.time * 10) % 43 == 37
        if happy || blinking || pose.isSipping {
            paint(11, 17, 3, 1, .ink)
            paint(19, 17, 3, 1, .ink)
        } else {
            paint(11, 15, 2, 4, .ink)
            paint(20, 15, 2, 4, .ink)
            paint(11, 15, 1, 1, .cream)
            paint(20, 15, 1, 1, .cream)
        }
        if happy { paint(15, 20, 3, 1, .ink) }

        // The far arm: wind-up, release, holding a bottle, waving, or at rest.
        if pose.isWindingUp {
            paint(24, 12, 2, 7, clay)
            paint(24, 10, 4, 3, clay)
            paint(25, 10, 3, 1, .clayLight)
        } else if pose.phase == .asking && cycle >= ReminderScene.releaseTime && cycle < 0.87 {
            paint(24, 16, 5, 3, clay)
            paint(29, 15, 3, 3, .clayLight)
        } else if pose.phase == .drinking {
            paint(24, pose.isSipping ? 15 : 17, 4, 3, clay)
        } else if pose.phase == .cheering {
            let wave = Int(pose.time * 12) % 2 == 0 ? 0.0 : 1.0
            paint(24, 12, 2, 7, clay)
            paint(24, 8 + wave, 4, 4, .clayLight)
        } else {
            paint(24, 15, 3, 3, clay)
            paint(26, 16, 2, 3, .clayShadow)
        }

        // The delivery cap, with a tiny water-drop badge.
        paint(10, 5, 12, 2, .accentDark)
        paint(8, 7, 16, 5, .accentDark)
        paint(10, 6, 12, 2, .accent)
        paint(9, 8, 14, 3, .accent)
        paint(11, 6, 9, 1, .accentLight)
        paint(9, 8, 2, 3, .accentLight)
        paint(8, 11, 21, 2, .accentDark)
        paint(9, 11, 19, 1, .accent)
        paint(18, 8, 1, 1, .glint)
        paint(17, 9, 3, 2, .glint)
        return blocks
    }

    // MARK: Droplet

    private static func droplet(_ pose: Pose) -> [Block] {
        let body: Ink = pose.isHovered ? .accentLight : .accent
        let closed = pose.isSipping
        return [
            // A pointed crown that broadens into a round base.
            Block(14, 3, 4, 2, .accentDark), Block(12, 5, 8, 2, .accentDark), Block(10, 7, 12, 2, .accentDark),
            Block(8, 9, 16, 2, .accentDark), Block(6, 11, 20, 10, .accentDark), Block(7, 21, 18, 3, .accentDark),
            Block(9, 24, 14, 2, .accentDark), Block(13, 26, 6, 1, .accentDark),
            Block(12, 5, 8, 2, body), Block(10, 7, 12, 2, body), Block(8, 9, 16, 2, body),
            Block(7, 11, 18, 10, body), Block(8, 21, 16, 3, body), Block(10, 24, 12, 1, body),
            Block(10, 10, 3, 10, .accentLight), Block(9, 11, 2, 7, .glint),
            // Two stubby arms.
            Block(23, 13, 2, 6, .accentDark), Block(24, 12, 3, 3, body),
            Block(5, 13, 2, 6, .accentDark), Block(4, 12, 3, 3, body),
            // Eyes, blush and a small smile.
            Block(12, closed ? 17 : 16, 2, closed ? 1 : 3, .ink), Block(20, closed ? 17 : 16, 2, closed ? 1 : 3, .ink),
            Block(10, 19, 2, 1, .clayLight), Block(22, 19, 2, 1, .clayLight),
            Block(16, 20, 2, 1, .ink), Block(15, 19, 1, 1, .ink), Block(18, 19, 1, 1, .ink)
        ]
    }

    // MARK: Bottle

    /// An 18×32 mineral-water bottle, drawn around its centre at (9, 16).
    public static let bottle: [Block] = {
        var blocks = [
            // Screw cap and narrow neck.
            Block(6, 0, 6, 3, .accentDark), Block(7, 0, 4, 1, .accent), Block(7, 1, 1, 2, .accentLight),
            Block(6, 3, 6, 3, .glint), Block(10, 3, 2, 3, .accent),
            // Stepped shoulders, clear plastic and the water inside.
            Block(5, 5, 8, 2, .accentDark), Block(4, 7, 10, 2, .accentDark), Block(3, 9, 12, 20, .accentDark),
            Block(4, 29, 10, 2, .accentDark), Block(6, 5, 6, 2, .glint), Block(5, 7, 8, 2, .glint),
            Block(4, 9, 10, 19, .accentLight), Block(5, 10, 2, 17, .glint), Block(11, 9, 3, 19, .accent),
            Block(4, 12, 10, 1, .accent), Block(4, 25, 10, 1, .accent), Block(5, 28, 8, 2, .accent),
            Block(6, 29, 5, 1, .accentLight),
            // A paper label.
            Block(4, 15, 10, 8, .cream), Block(12, 15, 2, 8, .labelShade)
        ]
        // "H2O" in a 3×5 face, half a pixel apart.
        let glyphs = [[5, 5, 7, 5, 5], [6, 1, 2, 4, 7], [2, 5, 5, 5, 2]]
        for (index, rows) in glyphs.enumerated() {
            for (y, row) in rows.enumerated() {
                for bit in 0..<3 where row & (1 << (2 - bit)) != 0 {
                    blocks.append(Block(4 + Double(index) * 3.5 + Double(bit), 17 + Double(y), 1, 1, .accentDark))
                }
            }
        }
        return blocks
    }()

    public static let bottleCentre = CGPoint(x: 9, y: 16)

    // MARK: Lettering

    /// Capital letters in a 5×7 face. Each pixel is `scale` points and each
    /// character advances six pixels. Unknown characters leave a space.
    public static func text(_ string: String, scale: Double, ink: Ink) -> [Block] {
        var blocks: [Block] = []
        for (index, character) in string.enumerated() {
            for (y, row) in (alphabet[character] ?? []).enumerated() {
                for bit in 0..<5 where row & (1 << (4 - bit)) != 0 {
                    blocks.append(Block((Double(index) * 6 + Double(bit)) * scale, Double(y) * scale,
                                        scale, scale, ink))
                }
            }
        }
        return blocks
    }

    public static func textWidth(_ string: String, scale: Double) -> Double {
        Double(string.count) * 6 * scale
    }

    private static let alphabet: [Character: [Int]] = [
        "A": [14, 17, 17, 31, 17, 17, 17], "B": [30, 17, 17, 30, 17, 17, 30],
        "C": [14, 17, 16, 16, 16, 17, 14], "D": [30, 17, 17, 17, 17, 17, 30],
        "E": [31, 16, 16, 30, 16, 16, 31], "F": [31, 16, 16, 30, 16, 16, 16],
        "G": [14, 17, 16, 23, 17, 17, 15], "H": [17, 17, 17, 31, 17, 17, 17],
        "I": [14, 4, 4, 4, 4, 4, 14], "J": [7, 2, 2, 2, 18, 18, 12],
        "K": [17, 18, 20, 24, 20, 18, 17], "L": [16, 16, 16, 16, 16, 16, 31],
        "M": [17, 27, 21, 21, 17, 17, 17], "N": [17, 25, 21, 19, 17, 17, 17],
        "O": [14, 17, 17, 17, 17, 17, 14], "P": [30, 17, 17, 30, 16, 16, 16],
        "Q": [14, 17, 17, 17, 21, 18, 13], "R": [30, 17, 17, 30, 20, 18, 17],
        "S": [15, 16, 16, 14, 1, 1, 30], "T": [31, 4, 4, 4, 4, 4, 4],
        "U": [17, 17, 17, 17, 17, 17, 14], "V": [17, 17, 17, 17, 17, 10, 4],
        "W": [17, 17, 17, 21, 21, 21, 10], "X": [17, 17, 10, 4, 10, 17, 17],
        "Y": [17, 17, 10, 4, 4, 4, 4], "Z": [31, 1, 2, 4, 8, 16, 31],
        "!": [4, 4, 4, 4, 4, 0, 4]
    ]

    // MARK: Solid area

    /// The mascot's painted pixels as rectangles in points from its centre,
    /// facing right. Rows that cover the same columns are joined, so the
    /// see-through gaps between limbs stay out.
    public static func solidArea(_ mascot: Mascot, pose: Pose) -> [CGRect] {
        var filled = [[Bool]](repeating: [Bool](repeating: false, count: side), count: side)
        for block in Sprite.mascot(mascot, pose: pose) {
            for y in max(0, Int(block.rect.minY))..<min(side, Int(block.rect.maxY)) {
                for x in max(0, Int(block.rect.minX))..<min(side, Int(block.rect.maxX)) { filled[y][x] = true }
            }
        }
        var areas: [CGRect] = []
        var open: [Range<Int>: Int] = [:]
        for y in 0..<side {
            var next: [Range<Int>: Int] = [:]
            var x = 0
            while x < side {
                guard filled[y][x] else { x += 1; continue }
                let start = x
                while x < side && filled[y][x] { x += 1 }
                if let index = open[start..<x] {
                    areas[index].size.height += scale
                    next[start..<x] = index
                } else {
                    next[start..<x] = areas.count
                    areas.append(CGRect(x: Double(start) * scale - half, y: Double(y) * scale - half,
                                        width: Double(x - start) * scale, height: scale))
                }
            }
            open = next
        }
        return areas
    }
}
