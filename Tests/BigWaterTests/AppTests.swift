import AppKit
import BigWaterCore
@testable import BigWaterApp

@MainActor
let appSuite = Suite(name: "app", tests: [
    // MARK: The reminder and the drink-along

    test("a reminder comes up when due, and a drink counts only once it is drunk") {
        let world = World()
        world.use(2 * hour - 1)
        expectEqual(world.stage, nil)
        world.use(1)
        expectEqual(world.stage, .asking)
        expectEqual(world.schedule.stage, .waiting)
        expectEqual(world.model.drinkTitle, "去喝水")

        world.press(.drink)
        expectEqual(world.stage, .drinking)
        expectEqual(world.drinksToday, 0, "pressing the button records nothing")
        expectEqual(world.model.drinkTitle, "喝水中…")
        expect(!world.model.canDrink)

        world.use(15)
        world.finishDrinking()
        expectEqual(world.drinksToday, 1)
        expectEqual(world.stage, .leaving, "the mascot takes its bow")
        expectEqual(world.schedule.remaining, 2 * hour, "the interval restarts when the drink ends")
        world.finishLeaving()
        expectEqual(world.stage, nil)
        expect(!world.surface.isOpen)
        expectEqual(world.drinksToday, 1, "one reminder, one drink")
    },

    test("the mascot is a drink button too, and the sound plays only when wanted") {
        let world = World { $0.soundEnabled = true }
        world.workUntilReminded()
        expectEqual(world.sounds, 1)
        // A click on the mascot arrives as the same action.
        world.press(.drink)
        world.press(.drink)
        world.finishDrinking()
        expectEqual(world.drinksToday, 1)

        let quiet = World()
        quiet.workUntilReminded()
        expectEqual(quiet.sounds, 0)
    },

    test("the menu is no way round the drink-along") {
        let world = World()
        world.workUntilReminded()
        world.model.drink()
        expectEqual(world.stage, .drinking)
        expectEqual(world.drinksToday, 0)
        world.model.drink()
        expectEqual(world.drinksToday, 0, "asking again in the menu does not hurry it")
        world.finishDrinking()
        expectEqual(world.drinksToday, 1)
        world.model.drink()
        expectEqual(world.drinksToday, 1, "nor does it record a second drink while the mascot leaves")
    },

    test("later takes the reminder down and brings it back") {
        let world = World()
        world.workUntilReminded()
        world.press(.snooze(10))
        expectEqual(world.stage, nil)
        expectEqual(world.schedule.status, .snoozed)
        world.use(10 * minute - 1)
        expectEqual(world.stage, nil)
        world.use(1)
        expectEqual(world.stage, .asking)
        expectEqual(world.drinksToday, 0)
    },

    test("later during the drink-along records nothing") {
        let world = World()
        world.workUntilReminded()
        world.press(.drink)
        world.animate(8)
        world.model.snooze(minutes: 20)
        expectEqual(world.stage, nil)
        world.animate(30)
        expectEqual(world.drinksToday, 0)
        expectEqual(world.schedule.remaining, 20 * minute)
    },

    test("the card records when its bar is full and closes at once") {
        let world = World { $0.style = .compact }
        world.workUntilReminded()
        expectEqual(world.surface.layout?.buttons.count, 3)
        expect(!world.ticker.isRunning, "a card that only waits needs no frames")
        world.press(.drink)
        expect(world.ticker.isRunning)
        expectEqual(world.surface.layout?.buttons.map(\.action), [.snooze(10), .snooze(20)])
        world.animate(19)
        expectEqual(world.drinksToday, 0)
        world.animate(2)
        expectEqual(world.drinksToday, 1)
        expectEqual(world.stage, nil)
        expect(!world.ticker.isRunning)
    },

    // MARK: Drinking without a reminder, and undo

    test("a drink without a reminder is recorded at once") {
        let world = World()
        world.use(50 * minute)
        expectEqual(world.model.drinkTitle, "我刚喝过水")
        world.model.drink()
        expectEqual(world.drinksToday, 1)
        expectEqual(world.schedule.remaining, 2 * hour)
        // A double click is one drink.
        world.clock.pass(0.3)
        world.model.drink()
        expectEqual(world.drinksToday, 1)
        world.use(2)
        world.model.drink()
        expectEqual(world.drinksToday, 2)
    },

    test("undo removes the drink and puts the countdown back") {
        let world = World()
        world.use(50 * minute)
        world.model.drink()
        expect(world.model.canUndo)
        world.use(10 * minute)
        world.model.undoLastDrink()
        expectEqual(world.drinksToday, 0)
        expectEqual(world.schedule.remaining, 60 * minute, "the ten minutes since still count")
        expect(!world.model.canUndo)
    },

    test("undoing an answered reminder brings the reminder back") {
        let world = World()
        world.workUntilReminded()
        world.press(.drink)
        world.finishDrinking()
        world.finishLeaving()
        world.model.undoLastDrink()
        expectEqual(world.drinksToday, 0)
        expectEqual(world.stage, .asking)
        expectEqual(world.schedule.stage, .waiting)
    },

    test("after a later choice, undo only removes the drink") {
        let world = World()
        world.use(50 * minute)
        world.model.drink()
        world.model.pause(minutes: 30)
        world.model.undoLastDrink()
        expectEqual(world.drinksToday, 0)
        expect(world.schedule.isPaused, "the pause stays")
        expectEqual(world.schedule.remaining, 2 * hour)

        let renamer = World()
        renamer.use(50 * minute)
        renamer.model.drink()
        renamer.model.update { $0.weekdayHours.periods[0].name = "白天" }
        renamer.model.undoLastDrink()
        expectEqual(renamer.schedule.remaining, 70 * minute, "a new name changes nothing that undo relies on")

        let retimer = World()
        retimer.use(50 * minute)
        retimer.model.drink()
        retimer.model.update { $0.intervalHours = 1 }
        retimer.model.undoLastDrink()
        expectEqual(retimer.schedule.remaining, hour, "a new interval does")
    },

    // MARK: The log

    test("corrections to the log leave the reminder and the countdown alone") {
        let world = World()
        world.workUntilReminded()
        expect(world.model.addPastDrink(at: october(15, 10)))
        expectEqual(world.drinksToday, 1)
        expectEqual(world.stage, .asking, "the reminder still waits")
        expect(!world.model.canUndo, "there is no countdown to go back to")
        expect(world.model.moveDrink(from: october(15, 10), to: october(15, 10, 30)))
        expectEqual(world.model.log.drinks, [october(15, 10, 30)])
        expect(!world.model.addPastDrink(at: october(15, 23)), "not in the future")
        world.model.removeDrink(at: october(15, 10, 30))
        expectEqual(world.drinksToday, 0)
        expectEqual(world.schedule.stage, .waiting)
    },

    test("deleting the last drink from the log is an undo") {
        let world = World()
        world.use(50 * minute)
        world.model.drink()
        let entry = world.model.log.drinks[0]
        world.model.removeDrink(at: entry)
        expectEqual(world.schedule.remaining, 70 * minute)

        world.model.drink()
        let second = world.model.log.drinks[0]
        expect(world.model.moveDrink(from: second, to: october(15, 9, 5)))
        expect(!world.model.canUndo, "a retimed entry is no longer 'the drink just now'")
    },

    // MARK: Pause

    test("a pause takes the reminder down and it returns when the pause ends") {
        let world = World()
        world.workUntilReminded()
        world.model.pause(minutes: 30)
        expectEqual(world.stage, nil)
        expectEqual(world.model.status.title, "计时已暂停")
        expectEqual(world.timer.delay, 30 * minute, "wake up when the pause ends")
        world.use(30 * minute)
        expectEqual(world.stage, .asking)

        world.model.pause(minutes: 60)
        world.model.resume()
        expectEqual(world.stage, .asking, "resuming early works the same")
    },

    // MARK: Sleep, hours and days

    test("a dark display holds the reminder, a drink included") {
        let world = World()
        world.workUntilReminded()
        world.press(.drink)
        world.animate(5)
        world.setAwake(false)
        expect(world.surface.isHidden && world.presenter.isSuspended)
        expect(!world.ticker.isRunning)
        expectEqual(world.timer.delay, nil, "asleep, nothing to wake up for")
        world.clock.pass(40 * minute)
        world.setAwake(true)
        expect(!world.surface.isHidden)
        expectEqual(world.stage, .drinking)
        expect(world.ticker.isRunning)
        world.finishDrinking()
        expectEqual(world.drinksToday, 1)
    },

    test("no countdown runs while the display is dark") {
        let world = World()
        world.use(45 * minute)
        world.setAwake(false)
        world.clock.pass(3 * hour)
        world.setAwake(true)
        expectEqual(world.schedule.remaining, 75 * minute)
        expectEqual(world.model.status.detail, "下次提醒 14:00 · 休眠时暂停")
    },

    test("the end of the day takes an unanswered reminder with it") {
        let world = World(at: october(15, 19, 30))
        world.workUntilReminded()
        world.press(.drink)
        world.animate(5)
        world.use(until: october(15, 22))
        expectEqual(world.stage, nil, "22:00: hours are over")
        expectEqual(world.drinksToday, 0, "half a drink is not a drink")
        world.use(until: october(16, 6))
        expectEqual(world.stage, nil)
        expectEqual(world.schedule.remaining, 2 * hour, "the next day starts whole")
    },

    test("a reminder left overnight is gone in the morning") {
        let world = World(at: october(15, 19, 30))
        world.workUntilReminded()
        world.setAwake(false)
        world.clock.go(to: october(16, 8))
        world.setAwake(true)
        expectEqual(world.stage, nil)
        expectEqual(world.schedule.fireDate, october(16, 10))
    },

    test("a reminder waits out a rest between periods") {
        let world = World { $0.weekdayHours = DayHours([Period(start: 540, end: 720), Period(start: 840, end: 1_320)]) }
        world.workUntilReminded()
        world.use(until: october(15, 12))
        expectEqual(world.stage, nil, "taken down for lunch")
        expectEqual(world.model.status.title, "休息时间")
        world.use(until: october(15, 14))
        expectEqual(world.stage, .asking, "and back when the afternoon starts")
    },

    test("a drink that ends as the hours close still counts") {
        let world = World(at: october(15, 19, 30))
        world.workUntilReminded()
        world.press(.drink)
        // The clock passes 22:00 without the app having looked yet.
        world.clock.go(to: october(15, 22, 0))
        world.finishDrinking()
        expectEqual(world.model.log.drinks.count, 1)
    },

    // MARK: Away

    test("being away stops the countdown, and coming back is noticed quickly") {
        let world = World()
        world.use(10 * minute)
        world.system.idle = 20 * minute
        world.use(20 * minute)
        expectEqual(world.model.status.title, "离开暂停")
        expectEqual(world.schedule.remaining, 105 * minute, "five idle minutes count, the rest do not")
        expectEqual(world.timer.delay, AppModel.awayPollInterval)
        world.system.idle = 2
        world.use(5)
        expect(!world.schedule.isAway)
        expectEqual(world.schedule.remaining, 105 * minute - 2)
        expectEqual(world.timer.delay, AppModel.checkpointInterval)

        world.model.update { $0.pauseWhenAway = false }
        world.system.idle = hour
        world.use(hour)
        expectEqual(world.schedule.remaining, 45 * minute - 2, "switched off, idle time counts like any other")
    },

    // MARK: Preview

    test("a preview shows the reminder and changes nothing") {
        let world = World { $0.soundEnabled = true }
        world.use(30 * minute)
        expect(world.model.canPreview)
        world.model.preview()
        expectEqual(world.stage, .preview)
        expect(!world.model.canPreview)
        expectEqual(world.schedule.stage, .counting)
        expectEqual(world.sounds, 0)
        world.press(.drink)
        expectEqual(world.stage, nil, "any click ends it")
        expectEqual(world.drinksToday, 0)
        expectEqual(world.schedule.remaining, 90 * minute)

        world.model.preview()
        world.model.drink()
        expectEqual(world.stage, nil)
        expectEqual(world.drinksToday, 1, "the panel's own drink button still records")
    },

    test("a preview gives way to the real reminder") {
        let world = World()
        world.use(2 * hour - 5)
        world.model.preview()
        world.use(5)
        expectEqual(world.stage, .asking)
        expectEqual(world.schedule.stage, .waiting)
    },

    // MARK: When a reminder cannot be shown

    test("with no display to show it on, the reminder is tried again") {
        let world = World()
        world.surface.screen = nil
        world.use(2 * hour)
        expectEqual(world.stage, nil)
        expect(world.schedule.isDue)
        expectEqual(world.timer.delay, AppModel.retryDelay, "not a busy loop")
        world.surface.screen = ScreenSpace(size: CGSize(width: 1_440, height: 900))
        world.timer.fireNow()
        expectEqual(world.stage, .asking)
    },

    test("the next reminder waits for the last mascot to leave") {
        let world = World { $0.intervalHours = 5.0 / 60 }
        world.workUntilReminded()
        world.press(.drink)
        world.finishDrinking()
        expectEqual(world.stage, .leaving)
        world.use(5 * minute)
        expectEqual(world.stage, .leaving)
        expect(world.schedule.isDue)
        world.finishLeaving()
        expectEqual(world.stage, .asking, "shown the moment the screen is free")
        expectEqual(world.surface.opens, 2)
    },

    test("displays coming and going move or hold the reminder") {
        let world = World()
        world.workUntilReminded()
        world.surface.screen = ScreenSpace(size: CGSize(width: 800, height: 600))
        world.system.onChange?(true)
        expectEqual(world.presenter.reminder?.scene.screen.size, CGSize(width: 800, height: 600))
        world.surface.screen = nil
        world.system.onChange?(true)
        expect(world.presenter.isSuspended, "no display left: wait")
        world.surface.screen = ScreenSpace(size: CGSize(width: 800, height: 600))
        world.system.onChange?(true)
        expect(!world.presenter.isSuspended)
        expectEqual(world.stage, .asking)
    },

    // MARK: Settings

    test("settings apply at once and survive a restart") {
        let world = World()
        world.use(50 * minute)
        world.model.update {
            $0.intervalHours = 3
            $0.look = Look(theme: .peach, mascot: .droplet)
            $0.placement.corner = .topLeft
        }
        expectEqual(world.schedule.remaining, 130 * minute)
        world.model.drink()
        world.quitAndRelaunch(after: 20 * minute)
        expectEqual(world.model.preferences.look.mascot, .droplet)
        expectEqual(world.model.preferences.intervalHours, 3)
        expectEqual(world.drinksToday, 1)
        expectEqual(world.schedule.remaining, 3 * hour, "closed for twenty minutes: nothing counted")
        world.workUntilReminded()
        expectEqual(world.surface.shown?.scene.look.mascot, .droplet)
        expectEqual(world.surface.shown?.scene.entrance, Entrance(edge: .top, position: 0))
    },

    test("hours that make no sense are refused") {
        let world = World()
        expect(!world.model.update { $0.weekdayHours = DayHours([Period(start: 900, end: 600)]) })
        expectEqual(world.model.preferences, Preferences())
        expect(world.model.update { $0.awayMinutes = 99 })
        expectEqual(world.model.preferences.awayMinutes, 5, "an unknown choice falls back")
    },

    test("a restart with a reminder waiting shows it again") {
        let world = World()
        world.workUntilReminded()
        world.quitAndRelaunch(after: 5 * minute)
        expectEqual(world.stage, .asking)
        expectEqual(world.drinksToday, 0)
    },

    test("the countdown is saved as it runs") {
        let world = World()
        expectEqual(world.timer.delay, AppModel.checkpointInterval)
        world.use(30)
        let saved = StateStore(defaults: world.defaults).load()
        expectEqual(saved.progress?.remainingTime, 2 * hour - 30)
    },

    // MARK: Menu bar

    test("the right-click menu follows the state") {
        let world = World()
        @MainActor func titles() -> [[String]] { world.model.quickActions(openPanel: {}, quit: {}).map { $0.map(\.title) } }
        @MainActor func action(_ title: String) -> QuickAction? {
            world.model.quickActions(openPanel: {}, quit: {}).flatMap { $0 }.first { $0.title == title }
        }
        expectEqual(titles(), [["我刚喝过水", "撤销刚才的喝水记录"], ["暂停 30 分钟", "暂停 60 分钟"],
                               ["打开设置…", "退出 Big Water"]])
        expectEqual(action("撤销刚才的喝水记录")?.isEnabled, false)
        action("我刚喝过水")?.run()
        expectEqual(world.drinksToday, 1)
        expectEqual(action("撤销刚才的喝水记录")?.isEnabled, true)
        action("暂停 30 分钟")?.run()
        expectEqual(titles()[1], ["暂停 30 分钟", "暂停 60 分钟", "恢复计时"])
        action("恢复计时")?.run()
        expect(!world.schedule.isPaused)

        world.workUntilReminded()
        expectEqual(titles()[0][0], "去喝水")
        action("去喝水")?.run()
        expectEqual(titles()[0][0], "喝水中…")
        expectEqual(action("喝水中…")?.isEnabled, false)
    },

    test("the menu bar text follows the countdown") {
        let world = World()
        world.use(29 * minute + 30)
        expectEqual(world.model.status.menuTitle, "91分")
        expectEqual(world.model.countdown(at: world.model.now), "01:30:30")
        expectEqual(world.model.countdown(at: world.model.now.addingTimeInterval(30)), "01:30:00",
                    "the panel ticks between passes")
        world.model.pause(minutes: 10)
        expectEqual(world.model.countdown(at: world.model.now.addingTimeInterval(30)), "01:30:30",
                    "and stands still when nothing is counted")
        expectEqual(world.model.status.menuTitle, "暂停")
    },

    // MARK: The system monitor

    test("sleep and wake are believed going down and checked coming up") {
        let workspace = NotificationCenter()
        let general = NotificationCenter()
        var real = SystemMonitor.Reading(isSessionActive: true, isScreenAwake: true)
        let monitor = SystemMonitor(workspace: workspace, general: general) { real }
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        expect(monitor.isAwake)

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        expect(!monitor.isAwake)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        expect(monitor.isAwake)

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        expect(!monitor.isAwake)
        // The Mac wakes with its display still dark.
        real.isScreenAwake = false
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        expect(!monitor.isAwake, "awake again, but nothing to see yet")
        real.isScreenAwake = true
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        expect(monitor.isAwake)

        // A missed "screen woke" is made good by the next event that looks.
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        expect(monitor.isAwake)

        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        expect(!monitor.isAwake, "another user has the screen")
        real.isSessionActive = true
        general.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        expect(monitor.isAwake)
        general.post(name: .NSSystemClockDidChange, object: nil)
        expectEqual(changes, 10, "every event is passed on")
        monitor.stop()
    }
])
