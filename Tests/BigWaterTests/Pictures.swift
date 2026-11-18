import AppKit
import SwiftUI
import BigWaterCore
import BigWaterArt
@testable import BigWaterApp

/// Renders the panel's pages and the reminder to PNG files, for looking at
/// the interface where the screen itself cannot be seen:
///
///     swift run BigWaterTests --pictures /some/folder
@MainActor
enum Pictures {
    static func save(to directory: URL) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let updater = AppUpdater()
        let login = LoginItem()

        // An ordinary morning, with some history behind it.
        let world = World(at: october(15, 9)) {
            $0.weekdayHours = DayHours([Period(start: 540, end: 720, name: "上午"), Period(start: 840, end: 1_320)])
            $0.weekendHours = DayHours([Period(start: 600, end: 1_200)])
            $0.showMenuBarCountdown = true
        }
        for (day, hours) in [(2, [9, 11, 15]), (5, [10]), (9, [9, 10, 14, 16, 19]), (13, [11, 20]), (14, [9, 13, 17, 21])] {
            for hour in hours { world.model.addPastDrink(at: october(day, hour, 7 * hour % 60)) }
        }
        world.use(25 * minute)
        world.model.drink()
        world.use(40 * minute)
        let page = Binding.constant(PanelView.Page.home)
        try save(HomePage(model: world.model, updater: updater, login: login, page: page), "panel-home", to: directory)
        try save(MorePage(model: world.model, page: page), "panel-more", to: directory)
        try save(HoursPage(model: world.model, page: page), "panel-hours", to: directory)
        try save(HistoryPage(model: world.model, page: page), "panel-history", to: directory)

        // A reminder is up.
        world.workUntilReminded()
        try save(HomePage(model: world.model, updater: updater, login: login, page: page), "panel-home-waiting",
                 to: directory)
        world.model.pause(minutes: 30)
        try save(MorePage(model: world.model, page: page), "panel-more-paused", to: directory)

        // The reminder itself, as the overlay paints it.
        for (name, style, drinking) in [("reminder-asking", ReminderStyle.animated, false),
                                        ("reminder-drinking", .animated, true),
                                        ("card-asking", .compact, false), ("card-drinking", .compact, true)] {
            var reminder = Reminder(style: style, look: world.model.preferences.look,
                                    screen: ScreenSpace(size: CGSize(width: 720, height: 450), topInset: 25),
                                    entrance: Entrance(edge: .top, position: 0.3))
            _ = reminder.advance(by: ReminderScene.entranceTime + 1)
            if drinking {
                reminder.drink()
                _ = reminder.advance(by: 7)
            }
            try savePNG(picture(of: reminder), "\(name).png", to: directory)
        }
        // Every mascot from the top, a few throws in.
        for mascot in Mascot.allCases {
            var reminder = Reminder(style: .animated, look: Look(theme: .blue, mascot: mascot),
                                    screen: ScreenSpace(size: CGSize(width: 720, height: 450), topInset: 25),
                                    entrance: Entrance(edge: .top, position: 0.3))
            _ = reminder.advance(by: ReminderScene.entranceTime + 3.4)
            try savePNG(picture(of: reminder), "mascot-\(mascot.rawValue).png", to: directory)
        }
        // Where 25 seconds of bottles fly and land, as dotted paths.
        for (name, entrance) in [("throws-top", Entrance(edge: .top, position: 0.25)),
                                 ("throws-right", Entrance(edge: .right, position: 0.4))] {
            let screen = ScreenSpace(size: CGSize(width: 1_440, height: 900), topInset: 25)
            var reminder = Reminder(style: .animated, look: Look(), screen: screen, entrance: entrance, seed: 7)
            let accent = Palette.accent(.blue)
            let image = Painter.image(size: screen.size, scale: 1) { context in
                Painter.fill(CGRect(origin: .zero, size: screen.size), NSColor(white: 0.9, alpha: 1), in: context)
                for _ in 0..<(30 * 25) {
                    _ = reminder.advance(by: 1.0 / 30)
                    for bottle in reminder.scene.bottles {
                        Painter.fill(CGRect(x: bottle.position.x - 2, y: bottle.position.y - 2, width: 4, height: 4),
                                     accent.base, in: context)
                    }
                    for drop in reminder.scene.splashes where drop.age <= 1.0 / 30 + 0.001 {
                        Painter.fill(CGRect(x: drop.position.x - 6, y: drop.position.y - 6, width: 12, height: 12),
                                     accent.dark, in: context)
                    }
                }
                Painter.scene(reminder.scene, in: context)
            }
            try savePNG(image, "\(name).png", to: directory)
        }
        print("Pictures: \(directory.path)")
    }

    /// A reminder with its buttons, on a plain desktop.
    private static func picture(of reminder: Reminder) -> NSImage {
        let layout = reminder.layout
        let scene = reminder.scene
        return Painter.image(size: scene.screen.size) { context in
            Painter.fill(CGRect(origin: .zero, size: scene.screen.size), NSColor(white: 0.82, alpha: 1), in: context)
            if let card = layout.card {
                Painter.card(card, look: scene.look, isPreview: reminder.isPreview,
                             drinkProgress: scene.phase == .drinking ? scene.drinkProgress : nil, in: context)
            } else {
                Painter.scene(scene, in: context)
            }
            for button in layout.buttons {
                context.saveGState()
                context.translateBy(x: button.frame.minX, y: button.frame.minY)
                Painter.button(button.title, isPrimary: button.isPrimary, size: button.frame.size,
                               theme: scene.look.theme, in: context)
                context.restoreGState()
            }
        }
    }

    private static func save<Page: View>(_ page: Page, _ name: String, to directory: URL) throws {
        let content = page
            .font(.system(size: 13))
            .frame(width: PanelView.size.width - 40, alignment: .leading)
            .padding(20)
            .background(PanelStyle.cream)
            .foregroundStyle(PanelStyle.ink)
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        // Let `onAppear` and layout settle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        try savePNG(image, "\(name).png", to: directory)
    }

    private static func savePNG(_ image: NSImage, _ name: String, to directory: URL) throws {
        guard let bitmap = image.representations.first as? NSBitmapImageRep,
              let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: directory.appendingPathComponent(name))
    }
}
