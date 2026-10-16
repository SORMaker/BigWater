import Foundation
import CoreGraphics

public enum ReminderPhase: String {
    case descending, reminding, acknowledging, ascending, finished
}

public enum ReminderEdge: String, CaseIterable {
    case top, bottom, left, right
}

/// Picked once per reminder, so resizing or resuming never rerolls its path.
public struct ReminderEntrance: Equatable {
    public let edge: ReminderEdge
    /// Position along the usable part of the edge, from left/top to right/bottom.
    public let position: Double

    public init(edge: ReminderEdge = .top, position: Double = 0.72) {
        self.edge = edge
        self.position = position.isFinite ? min(max(position, 0), 1) : 0.5
    }

    public static func random() -> Self {
        Self(edge: ReminderEdge.allCases.randomElement() ?? .top,
             position: Double.random(in: 0...1))
    }
}

public struct FlyingBottle {
    public var position: CGPoint
    public var velocity: CGVector
    public var angle: Double
    public let spin: Double
    public var age: Double = 0
    public var scale: Double { min(2.0 + age * 1.35, 4.3) }
}

public struct WaterParticle {
    public var position: CGPoint
    public var velocity: CGVector
    public var age: Double = 0
    public let lifetime: Double
    public let size: Double
}

/// All coordinates are in points, with the origin at the top left.
/// Keeping the animation independent of windows lets previews and tests use
/// the same poses, trajectories and state transitions as the desktop app.
public struct ReminderScene {
    public static let descentDuration = 1.85
    public static let acknowledgmentDuration = 0.55
    public static let ascentDuration = 2.05
    public static let throwPeriod = 1.35
    public static let releaseTime = 0.58

    public private(set) var viewport: CGSize
    public private(set) var topInset: Double
    public private(set) var visibleBounds: CGRect
    public let entrance: ReminderEntrance
    public private(set) var phase: ReminderPhase = .descending
    public let appearance: ReminderAppearance
    /// A settings-page preview: it looks the same but records nothing.
    public let isPreview: Bool
    public private(set) var phaseTime = 0.0
    public private(set) var time = 0.0
    public private(set) var bottles: [FlyingBottle] = []
    public private(set) var particles: [WaterParticle] = []
    public private(set) var throwCount = 0
    public var isHovered = false
    private var retirementStart = CGPoint.zero

    public init(viewport: CGSize, topInset: Double = 24,
                appearance: ReminderAppearance = .init(), isPreview: Bool = false,
                entrance: ReminderEntrance = .init(), visibleBounds: CGRect? = nil) {
        self.viewport = viewport
        self.topInset = topInset
        self.appearance = appearance
        self.isPreview = isPreview
        self.entrance = entrance
        self.visibleBounds = visibleBounds ?? CGRect(x: 0, y: topInset, width: viewport.width,
                                                     height: max(0, viewport.height - topInset))
    }

    public var target: CGPoint {
        // Leave room for the sprite, the bubble to its inward side and the
        // fixed buttons below it, including a Dock on any screen edge.
        let bounds = visibleBounds
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
        return CGPoint(x: (point.x / 4).rounded() * 4, y: (point.y / 4).rounded() * 4)
    }

    public var usesRope: Bool { entrance.edge == .top }
    public var facesLeft: Bool {
        switch entrance.edge {
        case .left: return false
        case .right: return true
        case .top, .bottom: return entrance.position > 0.5
        }
    }

    public var throwCycle: Double {
        phase == .reminding ? phaseTime.truncatingRemainder(dividingBy: Self.throwPeriod) : 0
    }

    public var characterPosition: CGPoint {
        switch phase {
        case .descending:
            let t = min(phaseTime / Self.descentDuration, 1)
            let ease = 1 - pow(1 - t, 3)
            let start = offscreenPoint(alignedWith: target)
            let sway = sin(t * .pi * 2) * 8
            let horizontal = entrance.edge == .left || entrance.edge == .right
            return CGPoint(x: start.x + (target.x - start.x) * ease + (horizontal ? 0 : sway),
                           y: start.y + (target.y - start.y) * ease + (horizontal ? sway : 0))
        case .reminding:
            // Only Claude throws, so only Claude recoils.
            let recoil = appearance.character == .claude
                && throwCycle > Self.releaseTime && throwCycle < 0.84
                ? sin((throwCycle - Self.releaseTime) / 0.26 * .pi) * 6 : 0
            return CGPoint(x: target.x + (facesLeft ? recoil : -recoil) + sin(phaseTime * 2.1) * 3,
                           y: target.y + sin(phaseTime * 3.2) * 3)
        case .acknowledging:
            return CGPoint(x: retirementStart.x, y: retirementStart.y - sin(phaseTime * .pi / 0.55) * 5)
        case .ascending:
            let t = min(phaseTime / Self.ascentDuration, 1)
            // Each climbing cycle has a short pull and a longer grip change.
            let step = floor(t * 7)
            let part = t * 7 - step
            let pull = min(part / 0.64, 1)
            let progress = usesRope ? min((step + pull * pull * (3 - 2 * pull)) / 7, 1)
                : t * t * (3 - 2 * t)
            let end = offscreenPoint(alignedWith: retirementStart)
            let horizontal = entrance.edge == .left || entrance.edge == .right
            let sway = sin(t * .pi * 14) * 3
            return CGPoint(x: retirementStart.x + (end.x - retirementStart.x) * progress + (horizontal ? 0 : sway),
                           y: retirementStart.y + (end.y - retirementStart.y) * progress + (horizontal ? sway : 0))
        case .finished:
            return offscreenPoint(alignedWith: target)
        }
    }

    private func offscreenPoint(alignedWith point: CGPoint) -> CGPoint {
        switch entrance.edge {
        case .top: return CGPoint(x: point.x, y: -100)
        case .bottom: return CGPoint(x: point.x, y: viewport.height + 100)
        case .left: return CGPoint(x: -110, y: point.y)
        case .right: return CGPoint(x: viewport.width + 110, y: point.y)
        }
    }

    public var isInteractive: Bool { phase == .descending || phase == .reminding }
    public var isClimbing: Bool { phase == .ascending && usesRope }
    public var hasAcknowledged: Bool { phase == .acknowledging || phase == .ascending || phase == .finished }

    @discardableResult
    public mutating func acknowledge() -> Bool {
        guard isInteractive else { return false }
        retirementStart = characterPosition
        phase = .acknowledging
        phaseTime = 0
        isHovered = false
        return true
    }

    public mutating func resize(to size: CGSize, topInset: Double, visibleBounds: CGRect? = nil) {
        let oldTarget = target
        viewport = size
        self.topInset = topInset
        self.visibleBounds = visibleBounds ?? CGRect(x: 0, y: topInset, width: size.width,
                                                     height: max(0, size.height - topInset))
        retirementStart.x += target.x - oldTarget.x
        retirementStart.y += target.y - oldTarget.y
    }

    public mutating func advance(by elapsed: Double) {
        guard elapsed.isFinite, elapsed > 0, phase != .finished else { return }
        // Small integration steps prevent throws being skipped during a slow frame.
        var remaining = elapsed
        while remaining > 0.000_001, phase != .finished {
            let dt = min(remaining, 1.0 / 60)
            step(dt)
            remaining -= dt
        }
    }

    private mutating func step(_ dt: Double) {
        time += dt
        let previousPhaseTime = phaseTime
        phaseTime += dt

        switch phase {
        case .descending where phaseTime >= Self.descentDuration:
            phase = .reminding
            phaseTime -= Self.descentDuration
        case .reminding:
            let previousCycle = floor((previousPhaseTime - Self.releaseTime) / Self.throwPeriod)
            let currentCycle = floor((phaseTime - Self.releaseTime) / Self.throwPeriod)
            if currentCycle > previousCycle { throwBottle() }
        case .acknowledging where phaseTime >= Self.acknowledgmentDuration:
            phase = .ascending
            phaseTime -= Self.acknowledgmentDuration
        case .ascending where phaseTime >= Self.ascentDuration:
            phase = .finished
            bottles.removeAll()
            particles.removeAll()
        default:
            break
        }

        for index in bottles.indices {
            bottles[index].age += dt
            bottles[index].velocity.dy += 690 * dt
            bottles[index].position.x += bottles[index].velocity.dx * dt
            bottles[index].position.y += bottles[index].velocity.dy * dt
            bottles[index].angle += bottles[index].spin * dt
        }

        let floor = min(viewport.height, visibleBounds.maxY)
        for bottle in bottles where bottle.position.y > floor - 25 {
            splash(at: CGPoint(x: min(max(bottle.position.x, visibleBounds.minX + 20), visibleBounds.maxX - 20),
                               y: floor - 18))
        }
        bottles.removeAll { $0.position.y > floor - 25 || $0.age > 5 }

        for index in particles.indices {
            particles[index].age += dt
            particles[index].velocity.dy += 540 * dt
            particles[index].position.x += particles[index].velocity.dx * dt
            particles[index].position.y += particles[index].velocity.dy * dt
        }
        particles.removeAll { $0.age > $0.lifetime }
    }

    private mutating func throwBottle() {
        guard appearance.character == .claude else { return }
        let variation = throwCount % 4
        let velocities = [245.0, 90.0, 145.0, 155.0]
        let spins = [-2.8, 2.1, -1.6, 2.9]
        let point = characterPosition
        let direction = facesLeft ? -1.0 : 1.0
        bottles.append(FlyingBottle(
            position: CGPoint(x: point.x + direction * 54, y: point.y + 12),
            velocity: CGVector(dx: direction * velocities[variation], dy: -130 - Double(variation) * 12),
            angle: direction * -0.4,
            spin: direction * spins[variation]
        ))
        throwCount += 1
    }

    private mutating func splash(at point: CGPoint) {
        for index in 0..<9 {
            let angle = .pi + Double(index) / 8 * .pi
            let speed = 90 + Double(index % 3) * 55
            particles.append(WaterParticle(
                position: point,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - 70),
                lifetime: 0.38 + Double(index % 3) * 0.08,
                size: Double(3 + index % 3) * 2
            ))
        }
    }
}
