import CoreGraphics
import Foundation

public enum Edge: String, CaseIterable, Sendable {
    case top, bottom, left, right
}

/// Where the mascot comes in. Chosen once per reminder, so a resize or a
/// resume never sends it along a different path.
public struct Entrance: Equatable, Sendable {
    public let edge: Edge
    /// Along the usable part of the edge: 0 is left or top, 1 is right or bottom.
    public let position: Double

    public init(edge: Edge = .top, position: Double = 0.72) {
        self.edge = edge
        self.position = position.isFinite ? min(max(position, 0), 1) : 0.5
    }

    public static func random() -> Entrance {
        Entrance(edge: Edge.allCases.randomElement() ?? .top, position: .random(in: 0...1))
    }

    /// A fixed corner has its own entrance; `.random` keeps `fallback`.
    public init(corner: Corner, otherwise fallback: Entrance) {
        switch corner {
        case .random: self = fallback
        case .topLeft: self.init(edge: .top, position: 0)
        case .topRight: self.init(edge: .top, position: 1)
        case .bottomLeft: self.init(edge: .bottom, position: 0)
        case .bottomRight: self.init(edge: .bottom, position: 1)
        }
    }
}

/// One display as the reminder sees it. Points, origin at the top left.
public struct ScreenSpace: Equatable, Sendable {
    public var size: CGSize
    /// The part not covered by the menu bar or the Dock.
    public var visible: CGRect

    public init(size: CGSize, visible: CGRect) {
        self.size = size
        self.visible = visible
    }

    /// A display with only a menu bar of `topInset` points.
    public init(size: CGSize, topInset: Double = 24) {
        self.init(size: size, visible: CGRect(x: 0, y: topInset, width: size.width,
                                              height: max(0, size.height - topInset)))
    }
}

public struct FlyingBottle: Equatable, Sendable {
    public var position: CGPoint
    public var velocity: CGVector
    public var angle: Double
    public let spin: Double
    public var age = 0.0
    /// Bottles grow as they fly, as if coming towards the viewer.
    public var scale: Double { min(2.0 + age * 1.35, 4.3) }
}

public struct Splash: Equatable, Sendable {
    public var position: CGPoint
    public var velocity: CGVector
    public var age = 0.0
    public let lifetime: Double
    public let size: Double
}

/// The animated reminder as numbers: where the mascot is, what it is doing,
/// which bottles are in the air. It knows nothing about windows, so the app,
/// the artwork and the tests all run the very same motion.
public struct ReminderScene: Equatable, Sendable {
    public enum Phase: String, Sendable {
        /// Coming in from the edge.
        case entering
        /// In place, throwing bottles until the person answers.
        case asking
        /// Drinking along with the person.
        case drinking
        /// A short wave once the drink is done.
        case cheering
        /// Going back the way it came.
        case leaving
        case gone
    }

    public static let entranceTime = 1.85
    /// Long enough to pick up a glass and take a few sips. A drink counts
    /// only when this has run out, so a reflex click dismisses nothing.
    public static let standardDrinkTime = 20.0
    public static let cheerTime = 0.55
    public static let exitTime = 2.05
    public static let throwPeriod = 1.35
    /// Into each throw, when the bottle leaves the hand.
    public static let releaseTime = 0.58

    public private(set) var screen: ScreenSpace
    public let entrance: Entrance
    public let look: Look
    /// A preview from the settings: it looks the same and records nothing.
    public let isPreview: Bool
    /// Shorter only where artwork has to fit a drink into a few seconds.
    public let drinkTime: Double
    public private(set) var phase = Phase.entering
    public private(set) var phaseTime = 0.0
    public private(set) var bottles: [FlyingBottle] = []
    public private(set) var splashes: [Splash] = []
    public private(set) var throwCount = 0
    public var isHovered = false
    /// Where the mascot stood when it turned to leave.
    private var exitStart = CGPoint.zero
    /// Where each throw lands. Seeded, so a given reminder always throws the
    /// same way, which keeps the documentation animations stable.
    private var dice: Dice
    /// A click during the entrance starts the drink on arrival.
    public private(set) var willDrinkOnArrival = false

    public init(screen: ScreenSpace, look: Look = .init(), entrance: Entrance = .init(),
                isPreview: Bool = false, drinkTime: Double = standardDrinkTime,
                seed: UInt64 = .random(in: .min ... .max)) {
        dice = Dice(seed: seed)
        self.screen = screen
        self.look = look
        self.entrance = entrance
        self.isPreview = isPreview
        self.drinkTime = drinkTime
    }

    // MARK: Where things are

    /// Where the mascot comes to rest. It leaves room for the bubble on its
    /// inward side and the buttons below, clear of the menu bar and the Dock.
    public var restingPoint: CGPoint {
        let bounds = screen.visible
        let minX = bounds.minX + min(120, bounds.width / 2)
        let maxX = max(minX, bounds.maxX - 120)
        let minY = bounds.minY + min(100, bounds.height / 2)
        let maxY = max(minY, bounds.maxY - 164)
        let alongX = minX + (maxX - minX) * entrance.position
        let alongY = minY + (maxY - minY) * entrance.position
        let point: CGPoint
        switch entrance.edge {
        case .top: point = CGPoint(x: alongX, y: min(max(bounds.minY + 180, minY), maxY))
        case .bottom: point = CGPoint(x: alongX, y: maxY)
        case .left: point = CGPoint(x: minX, y: alongY)
        case .right: point = CGPoint(x: maxX, y: alongY)
        }
        return point.snapped(to: 4)
    }

    /// Only an entrance from the top comes down a rope.
    public var usesRope: Bool { entrance.edge == .top }

    /// The mascot faces into the screen; its bubble and bottles go that way.
    public var facesLeft: Bool {
        switch entrance.edge {
        case .left: return false
        case .right: return true
        case .top, .bottom: return entrance.position > 0.5
        }
    }

    /// Seconds into the current throw.
    public var throwCycle: Double {
        phase == .asking ? phaseTime.truncatingRemainder(dividingBy: Self.throwPeriod) : 0
    }

    public var mascotPosition: CGPoint {
        let sideways = entrance.edge == .left || entrance.edge == .right
        func travel(from start: CGPoint, to end: CGPoint, progress: Double, sway: Double) -> CGPoint {
            CGPoint(x: start.x + (end.x - start.x) * progress + (sideways ? 0 : sway),
                    y: start.y + (end.y - start.y) * progress + (sideways ? sway : 0))
        }
        let target = restingPoint
        switch phase {
        case .entering:
            let t = min(phaseTime / Self.entranceTime, 1)
            return travel(from: offscreen(beside: target), to: target, progress: 1 - pow(1 - t, 3),
                          sway: sin(t * .pi * 2) * 8)
        case .asking:
            // Only Claude throws by hand, so only Claude recoils.
            let recoiling = look.mascot == .claude && throwCycle > Self.releaseTime && throwCycle < 0.84
            let recoil = recoiling ? sin((throwCycle - Self.releaseTime) / 0.26 * .pi) * 6 : 0
            return CGPoint(x: target.x + (facesLeft ? recoil : -recoil) + sin(phaseTime * 2.1) * 3,
                           y: target.y + sin(phaseTime * 3.2) * 3)
        case .drinking:
            return target
        case .cheering:
            return CGPoint(x: exitStart.x, y: exitStart.y - sin(phaseTime * .pi / 0.55) * 5)
        case .leaving:
            let t = min(phaseTime / Self.exitTime, 1)
            // Up a rope in seven pulls, each a short heave and a longer change
            // of grip; along the ground in one smooth slide.
            let pull = floor(t * 7)
            let heave = min((t * 7 - pull) / 0.64, 1)
            let progress = usesRope ? min((pull + heave * heave * (3 - 2 * heave)) / 7, 1) : t * t * (3 - 2 * t)
            return travel(from: exitStart, to: offscreen(beside: exitStart), progress: progress,
                          sway: sin(t * .pi * 14) * 3)
        case .gone:
            return offscreen(beside: target)
        }
    }

    private func offscreen(beside point: CGPoint) -> CGPoint {
        switch entrance.edge {
        case .top: return CGPoint(x: point.x, y: -100)
        case .bottom: return CGPoint(x: point.x, y: screen.size.height + 100)
        case .left: return CGPoint(x: -110, y: point.y)
        case .right: return CGPoint(x: screen.size.width + 110, y: point.y)
        }
    }

    // MARK: What it is doing

    /// The mascot itself can still be clicked to start a drink.
    public var isClickable: Bool { (phase == .entering && !willDrinkOnArrival) || phase == .asking }
    public var isClimbing: Bool { phase == .leaving && usesRope }
    /// The drink-along ran to its end.
    public var hasFinishedDrink: Bool { phase == .cheering || phase == .leaving || phase == .gone }
    /// From 0 to 1 over the drink; 0 in every other phase.
    public var drinkProgress: Double { phase == .drinking ? min(phaseTime / drinkTime, 1) : 0 }

    /// The person says they will drink. The mascot stops throwing and drinks
    /// along. False when a drink is already under way or over.
    @discardableResult
    public mutating func beginDrinking() -> Bool {
        switch phase {
        case .entering where !willDrinkOnArrival:
            willDrinkOnArrival = true
        case .asking:
            phase = .drinking
            phaseTime = 0
        default:
            return false
        }
        isHovered = false
        return true
    }

    /// The display changed size, or its menu bar or Dock moved.
    public mutating func fit(_ next: ScreenSpace) {
        let before = restingPoint
        screen = next
        exitStart.x += restingPoint.x - before.x
        exitStart.y += restingPoint.y - before.y
    }

    public mutating func advance(by elapsed: Double) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        // Small fixed steps, so a slow frame never skips a throw.
        var left = elapsed
        while left > 0.000_001, phase != .gone {
            let step = min(left, 1.0 / 60)
            self.step(step)
            left -= step
        }
    }

    private mutating func step(_ dt: Double) {
        let before = phaseTime
        phaseTime += dt

        switch phase {
        case .entering where phaseTime >= Self.entranceTime:
            phase = willDrinkOnArrival ? .drinking : .asking
            phaseTime -= Self.entranceTime
        case .asking:
            func throwsDone(by time: Double) -> Double { floor((time - Self.releaseTime) / Self.throwPeriod) }
            if throwsDone(by: phaseTime) > throwsDone(by: before) { throwBottle() }
        case .drinking where phaseTime >= drinkTime:
            exitStart = mascotPosition
            phase = .cheering
            phaseTime -= drinkTime
        case .cheering where phaseTime >= Self.cheerTime:
            phase = .leaving
            phaseTime -= Self.cheerTime
        case .leaving where phaseTime >= Self.exitTime:
            phase = .gone
            bottles.removeAll()
            splashes.removeAll()
        default:
            break
        }

        for index in bottles.indices {
            bottles[index].age += dt
            bottles[index].velocity.dy += Self.gravity * dt
            bottles[index].position.x += bottles[index].velocity.dx * dt
            bottles[index].position.y += bottles[index].velocity.dy * dt
            bottles[index].angle += bottles[index].spin * dt
        }
        // A bottle bursts wherever it meets an edge of the usable screen.
        let walls = self.walls
        for bottle in bottles {
            guard let normal = Self.edgeNormal(of: bottle.position, inside: walls) else { continue }
            let point = CGPoint(x: min(max(bottle.position.x, walls.minX), walls.maxX),
                                y: min(max(bottle.position.y, walls.minY), walls.maxY))
            splash(at: CGPoint(x: point.x - normal.dx * 7, y: point.y - normal.dy * 7), away: normal)
        }
        bottles.removeAll { Self.edgeNormal(of: $0.position, inside: walls) != nil || $0.age > 5 }

        for index in splashes.indices {
            splashes[index].age += dt
            splashes[index].velocity.dy += 540 * dt
            splashes[index].position.x += splashes[index].velocity.dx * dt
            splashes[index].position.y += splashes[index].velocity.dy * dt
        }
        splashes.removeAll { $0.age > $0.lifetime }
    }

    static let gravity = 690.0

    /// Where bottles burst: just inside every edge of the usable screen.
    private var walls: CGRect { screen.visible.insetBy(dx: 25, dy: 25) }

    /// Which way back into the screen from an edge `point` has crossed, or
    /// nil while it is still inside.
    static func edgeNormal(of point: CGPoint, inside walls: CGRect) -> CGVector? {
        if point.y > walls.maxY { return CGVector(dx: 0, dy: -1) }
        if point.y < walls.minY { return CGVector(dx: 0, dy: 1) }
        if point.x > walls.maxX { return CGVector(dx: -1, dy: 0) }
        if point.x < walls.minX { return CGVector(dx: 1, dy: 0) }
        return nil
    }

    private mutating func throwBottle() {
        guard look.mascot.throwsBottles else { return }
        let from = mascotPosition
        let direction = facesLeft ? -1.0 : 1.0
        // Claude throws from the hand; the wizard's bottles appear at the orb.
        let hand = look.mascot == .wizard ? CGPoint(x: Sprite.orb.x + 8, y: Sprite.orb.y) : CGPoint(x: 54, y: 12)
        let start = CGPoint(x: from.x + direction * hand.x, y: from.y + hand.y)

        // Each throw aims at a random point on an edge in front of the mascot:
        // the floor, the far wall or the ceiling. Never the wall behind it.
        let walls = self.walls
        let farWall = facesLeft ? walls.minX : walls.maxX
        let ahead = start.x + direction * 30
        let along = (farWall - ahead) * direction > 0 ? ahead + (farWall - ahead) * dice.next() : farWall
        let edge = dice.next()
        let target: CGPoint
        if edge < 0.45 {
            target = CGPoint(x: along, y: walls.maxY)
        } else if edge < 0.8 {
            target = CGPoint(x: farWall, y: walls.minY + walls.height * dice.next())
        } else {
            target = CGPoint(x: along, y: walls.minY)
        }
        // A quick throw flies flat; a slow one arcs high to get there.
        let distance = (pow(target.x - start.x, 2) + pow(target.y - start.y, 2)).squareRoot()
        let flight = min(max(distance / (420 + 580 * dice.next()), 0.45), 1.8)
        let velocity = CGVector(dx: (target.x - start.x) / flight,
                                dy: (target.y - start.y - Self.gravity * flight * flight / 2) / flight)
        let spin = (1.5 + 1.8 * dice.next()) * (dice.next() < 0.5 ? -1 : 1)
        bottles.append(FlyingBottle(position: start, velocity: velocity,
                                    angle: direction * -0.4, spin: direction * spin))
        throwCount += 1
    }

    /// Nine drops fanned out from the edge, back into the screen.
    private mutating func splash(at point: CGPoint, away normal: CGVector) {
        let facing = atan2(normal.dy, normal.dx)
        for index in 0..<9 {
            let angle = facing - .pi / 2 + Double(index) / 8 * .pi
            let speed = 90 + Double(index % 3) * 55
            splashes.append(Splash(position: point,
                                   velocity: CGVector(dx: cos(angle) * speed + normal.dx * 70,
                                                      dy: sin(angle) * speed + normal.dy * 70),
                                   lifetime: 0.38 + Double(index % 3) * 0.08,
                                   size: Double(3 + index % 3) * 2))
        }
    }
}

extension CGPoint {
    /// The art sits on a pixel grid; positions snap to it before drawing.
    public func snapped(to grid: Double) -> CGPoint {
        CGPoint(x: (x / grid).rounded() * grid, y: (y / grid).rounded() * grid)
    }
}

extension CGRect {
    /// The part inside `bounds`, or nil when nothing is.
    func clipped(to bounds: CGRect) -> CGRect? {
        let result = intersection(bounds)
        return result.isNull || result.isEmpty ? nil : result
    }
}

/// A small seeded random source (SplitMix64): the same seed gives the same
/// numbers, on every Mac and every run.
struct Dice: Equatable, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// From 0 up to, not including, 1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
