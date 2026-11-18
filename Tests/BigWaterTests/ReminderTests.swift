import AppKit
import BigWaterCore
import BigWaterArt

private let desktop = ScreenSpace(size: CGSize(width: 1_440, height: 900), topInset: 25)
private let arrival = ReminderScene.entranceTime + 0.1

@MainActor
private func animated(_ mascot: Mascot = .claude, edge: Edge = .top, position: Double = 0.5,
                      screen: ScreenSpace = desktop, isPreview: Bool = false) -> Reminder {
    Reminder(style: .animated, look: Look(mascot: mascot), screen: screen, isPreview: isPreview,
             entrance: Entrance(edge: edge, position: position))
}

/// Steps a reminder at 30 frames a second and collects what happens.
@MainActor
private func run(_ reminder: inout Reminder, for seconds: Double) -> [Reminder.Event] {
    var events: [Reminder.Event] = []
    for _ in 0..<Int((seconds * 30).rounded()) { events += reminder.advance(by: 1.0 / 30) }
    return events
}

@MainActor
let reminderSuite = Suite(name: "reminder", tests: [
    test("a click starts a drink-along instead of dismissing the reminder") {
        var reminder = animated()
        _ = run(&reminder, for: arrival)
        expectEqual(reminder.stage, .asking)
        expect(reminder.drink())
        expectEqual(reminder.stage, .drinking)
        expect(!reminder.drink(), "clicking again changes nothing")

        let early = run(&reminder, for: ReminderScene.standardDrinkTime - 0.5)
        expectEqual(early, [], "nothing counts until the drink has run its length")
        expectEqual(reminder.stage, .drinking)
        expect(reminder.scene.drinkProgress > 0.95)

        expectEqual(run(&reminder, for: 1), [.drinkFinished], "the drink counts exactly once")
        expectEqual(reminder.stage, .leaving)
        expect(!reminder.drink() && !reminder.putOff(), "an answered reminder takes no more answers")
        expectEqual(run(&reminder, for: 3), [.gone])
        expectEqual(reminder.scene.phase, .gone)
    },

    test("clicking faster does not make the drink shorter") {
        var patient = animated()
        var frantic = animated()
        _ = run(&patient, for: arrival)
        _ = run(&frantic, for: arrival)
        patient.drink()
        frantic.drink()
        for _ in 0..<300 {
            _ = patient.advance(by: 1.0 / 30)
            frantic.drink()
            _ = frantic.advance(by: 1.0 / 30)
        }
        expectEqual(frantic.scene.drinkProgress, patient.scene.drinkProgress)
    },

    test("a click during the entrance starts the drink on arrival") {
        var reminder = animated()
        _ = run(&reminder, for: 0.5)
        expect(reminder.drink())
        expectEqual(reminder.scene.phase, .entering, "it still finishes coming in")
        expectEqual(reminder.stage, .drinking, "but the answer is already given")
        expect(reminder.layout.mascot.isEmpty && !reminder.drink(), "so the mascot is no longer a button")
        _ = run(&reminder, for: ReminderScene.entranceTime)
        expectEqual(reminder.scene.phase, .drinking)
        expectEqual(reminder.scene.bottles.count, 0, "it never started throwing")
    },

    test("later during the drink means no drink") {
        var reminder = animated()
        _ = run(&reminder, for: arrival)
        reminder.drink()
        _ = run(&reminder, for: 10)
        expect(reminder.putOff())
        expectEqual(reminder.stage, .leaving)
        expect(!run(&reminder, for: 15).contains(.drinkFinished))
    },

    test("Claude keeps throwing until answered; the droplet only hops") {
        var claude = animated(.claude)
        var droplet = animated(.droplet)
        _ = run(&claude, for: arrival + 6)
        _ = run(&droplet, for: arrival + 6)
        expectEqual(claude.scene.throwCount, 5, "one bottle every 1.35 seconds, the first after 0.58")
        expect(!claude.scene.bottles.isEmpty)
        expectEqual(droplet.scene.throwCount, 0)
        // Only the thrower recoils.
        let reach: (Reminder) -> Double = { abs($0.scene.mascotPosition.x - $0.scene.restingPoint.x) }
        var widest = (claude: 0.0, droplet: 0.0)
        for _ in 0..<90 {
            _ = claude.advance(by: 1.0 / 30)
            _ = droplet.advance(by: 1.0 / 30)
            widest = (max(widest.claude, reach(claude)), max(widest.droplet, reach(droplet)))
        }
        expect(widest.claude > 6 && widest.droplet <= 3, "\(widest)")
    },

    test("a slow frame does not skip a throw") {
        var smooth = animated()
        var choppy = animated()
        _ = run(&smooth, for: arrival + 8)
        for _ in 0..<4 { _ = choppy.advance(by: (arrival + 8) / 4) }
        expectEqual(choppy.scene.throwCount, smooth.scene.throwCount)
    },

    test("a preview loops until it is ended and never counts a drink") {
        var preview = animated(isPreview: true)
        expectEqual(preview.stage, .preview)
        expectEqual(run(&preview, for: 60), [])
        expect(!preview.drink() && !preview.putOff())
        expectEqual(preview.layout.buttons.map(\.action), [.endPreview])
        expect(preview.layout.badge != nil)
    },

    test("the card needs no entrance and only moves while its bar fills") {
        var card = Reminder(style: .compact, look: Look(), screen: desktop)
        expectEqual(card.stage, .asking)
        expect(!card.isAnimating)
        expectEqual(card.layout.buttons.map(\.action), [.drink, .snooze(10), .snooze(20)])
        card.drink()
        expect(card.isAnimating)
        expectEqual(card.layout.buttons.map(\.action), [.snooze(10), .snooze(20)])
        expectEqual(run(&card, for: 19), [])
        expectEqual(run(&card, for: 1.5), [.drinkFinished, .gone], "it records and closes in the same moment")
    },

    test("buttons stay put while the mascot sways") {
        var reminder = animated()
        _ = run(&reminder, for: arrival)
        let buttons = reminder.layout.buttons
        expectEqual(buttons.map(\.title), ["去喝水", "10 分钟后", "20 分钟后"])
        var positions = Set<Double>()
        for _ in 0..<60 {
            _ = reminder.advance(by: 1.0 / 30)
            positions.insert(reminder.scene.mascotPosition.x)
            expectEqual(reminder.layout.buttons, buttons)
        }
        expect(positions.count > 10, "the mascot itself does move")
    },

    test("once the drink starts, nothing sits where the drink button was") {
        var reminder = animated()
        _ = run(&reminder, for: arrival)
        let before = reminder.layout.buttons
        reminder.drink()
        let after = reminder.layout.buttons
        expectEqual(after, Array(before.dropFirst()), "both later buttons keep their places")
        expect(after.allSatisfy { !$0.frame.intersects(before[0].frame) })
    },

    test("everything clickable stays on the usable part of the screen") {
        let screens = [desktop,
                       ScreenSpace(size: CGSize(width: 1_280, height: 800),
                                   visible: CGRect(x: 90, y: 25, width: 1_190, height: 775)),
                       ScreenSpace(size: CGSize(width: 640, height: 360), topInset: 24)]
        for screen in screens {
            for edge in Edge.allCases {
                for position in [0.0, 0.5, 1.0] {
                    var reminder = animated(edge: edge, position: position, screen: screen)
                    _ = run(&reminder, for: arrival)
                    let layout = reminder.layout
                    let inside = (layout.buttons.map(\.frame) + layout.solid + layout.mascot)
                        .allSatisfy { screen.visible.contains($0) }
                    expect(inside, "\(edge) at \(position) on \(screen.size)")
                    expect(layout.buttons.count == 3 && !layout.mascot.isEmpty && !layout.solid.isEmpty)
                }
            }
        }
        for corner in Corner.allCases {
            let card = Reminder(style: .compact, look: Look(), corner: corner, screen: screens[1]).layout
            expect((card.buttons.map(\.frame) + card.solid).allSatisfy { screens[1].visible.contains($0) }, "\(corner)")
        }
    },

    test("the mascot faces into the screen and a fixed corner picks its entrance") {
        expect(animated(edge: .right).scene.facesLeft)
        expect(!animated(edge: .left).scene.facesLeft)
        expect(animated(edge: .top, position: 0.9).scene.facesLeft)
        expect(animated(edge: .top).scene.usesRope && !animated(edge: .bottom).scene.usesRope)
        let fallback = Entrance(edge: .left, position: 0.3)
        expectEqual(Entrance(corner: .random, otherwise: fallback), fallback)
        expectEqual(Entrance(corner: .bottomRight, otherwise: fallback), Entrance(edge: .bottom, position: 1))
        expectEqual(Entrance(edge: .top, position: .nan).position, 0.5)
    },

    test("only the mascot's own pixels take a click") {
        var reminder = animated()
        _ = run(&reminder, for: arrival)
        let scene = reminder.scene
        let centre = scene.mascotPosition.snapped(to: 4)
        expect(scene.mascotArea.contains { $0.contains(centre) }, "the body")
        // Between the legs, and in the corner of its 128-point box.
        expect(!scene.mascotArea.contains { $0.contains(CGPoint(x: centre.x + 2, y: centre.y + 36)) })
        expect(!scene.mascotArea.contains { $0.contains(CGPoint(x: centre.x + 60, y: centre.y - 60)) })

        reminder.hover(at: centre)
        expect(reminder.scene.isHovered)
        reminder.hover(at: CGPoint(x: centre.x + 60, y: centre.y - 60))
        expect(!reminder.scene.isHovered)
        reminder.drink()
        reminder.hover(at: centre)
        expect(!reminder.scene.isHovered && reminder.layout.mascot.isEmpty, "a drinking mascot is not a button")
    },

    test("a mascot sliding in from the side is not clickable beyond the screen") {
        var reminder = animated(edge: .left)
        expectEqual(reminder.layout.mascot, [], "still off screen")
        _ = run(&reminder, for: 0.4)
        let bounds = CGRect(origin: .zero, size: desktop.size)
        expect(!reminder.layout.mascot.isEmpty)
        expect(reminder.layout.mascot.allSatisfy { bounds.contains($0) })
    },

    test("a display that changes size keeps the reminder in view") {
        var reminder = animated(edge: .bottom, position: 1)
        _ = run(&reminder, for: arrival)
        let small = ScreenSpace(size: CGSize(width: 800, height: 600), topInset: 25)
        reminder.fit(small)
        _ = reminder.advance(by: 1.0 / 30)
        expect(small.visible.contains(reminder.scene.restingPoint))
        expect(reminder.layout.buttons.allSatisfy { small.visible.contains($0.frame) })
    },

    test("every painted pixel lies inside the area reported for repainting") {
        // The overlay repaints only `layout.painted`, so anything drawn
        // outside it would be left behind on screen.
        let screen = ScreenSpace(size: CGSize(width: 480, height: 320), topInset: 22)
        for mascot in Mascot.allCases {
            for edge in Edge.allCases {
                var reminder = Reminder(style: .animated, look: Look(mascot: mascot), screen: screen,
                                        entrance: Entrance(edge: edge, position: 0.6), drinkTime: 1.5)
                var strays = 0
                for frame in 0..<110 {
                    if frame == 50 { reminder.drink() }
                    if frame % 3 == 0 { strays += strayPixels(of: reminder.scene, outside: reminder.layout.painted) }
                    _ = reminder.advance(by: 1.0 / 12)
                }
                expectEqual(strays, 0, "\(mascot) from the \(edge)")
            }
        }
    }
])

/// How many pixels the painter touched outside `areas`.
@MainActor
private func strayPixels(of scene: ReminderScene, outside areas: [CGRect]) -> Int {
    let image = Painter.image(size: scene.screen.size, scale: 1) { Painter.scene(scene, in: $0) }
    guard let bitmap = image.representations.first as? NSBitmapImageRep, let data = bitmap.bitmapData else { return -1 }
    let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
    var covered = [Bool](repeating: false, count: width * height)
    for area in areas {
        let clipped = area.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull else { continue }
        for y in Int(clipped.minY)..<Int(clipped.maxY) {
            for x in Int(clipped.minX)..<Int(clipped.maxX) { covered[y * width + x] = true }
        }
    }
    var strays = 0
    for y in 0..<height {
        let row = data + y * bitmap.bytesPerRow
        for x in 0..<width where row[x * 4 + 3] != 0 && !covered[y * width + x] { strays += 1 }
    }
    return strays
}
