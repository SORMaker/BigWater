import AppKit
import BigWaterCore
import BigWaterArt
@testable import BigWaterApp

/// Drives the production AppDelegate from the BigWaterApp library.
/// Notifications stay inside this process; the Mac never actually sleeps.
@MainActor
private final class SessionChecks {
    private var now: Date
    private var uptime: TimeInterval = 0
    private let calendar = Calendar.autoupdatingCurrent
    private var delegate: AppDelegate!
    private var advanceAfterNextDateRead: TimeInterval?

    init() {
        now = Calendar.autoupdatingCurrent.date(from: DateComponents(
            year: 2026, month: 10, day: 15, hour: 9))!
    }

    private var schedule: ReminderSchedule { delegate.schedule }
    private var overlay: OverlayController { delegate.overlay }

    private func readDate() -> Date {
        let result = now
        if let advance = advanceAfterNextDateRead {
            advanceAfterNextDateRead = nil
            now = now.addingTimeInterval(advance)
            uptime += advance
        }
        return result
    }

    private func move(to day: Int, _ hour: Int, _ minute: Int = 0) {
        let next = calendar.date(from: DateComponents(year: 2026, month: 10, day: day,
                                                     hour: hour, minute: minute))!
        uptime += next.timeIntervalSince(now)
        now = next
    }

    /// What the simulated session and displays report when the app asks.
    /// Posting a notification also updates it, as the real system would.
    private var system = AppDelegate.SystemState(isSessionActive: true, isScreenAwake: true)

    private func post(_ notification: Notification.Name, workspace: Bool = true) {
        switch notification {
        case NSWorkspace.screensDidSleepNotification: system.isScreenAwake = false
        case NSWorkspace.screensDidWakeNotification: system.isScreenAwake = true
        case NSWorkspace.sessionDidResignActiveNotification: system.isSessionActive = false
        case NSWorkspace.sessionDidBecomeActiveNotification: system.isSessionActive = true
        default: break
        }
        let center = workspace ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
        center.post(name: notification, object: nil)
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "BigWaterSessionChecks", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    /// One day-by-day story through sleep, reminders, settings and restarts.
    /// Steps build on each other, so the story stops at its first failure.
    func dailyStory(_ preferences: UserDefaults) throws {
        preferences.set(2.0, forKey: "reminderIntervalHours")
        launch(preferences)
        try expect(!delegate.updater.isAvailable && !delegate.updater.canCheckForUpdates,
                   "Command-line checks must not start the live updater")
        delegate.updater.setAutomaticallyChecksForUpdates(true)
        delegate.updater.checkForUpdates()
        try expect(!delegate.updater.automaticallyChecksForUpdates,
                   "An unbundled runner must keep updating disabled")
        pass("unbundled checks do not start Sparkle or enable automatic checks")
        try expect(schedule.intervalHours == 2, "Run session checks with the standard two-hour interval")
        try expect(schedule.isCounting, "Session checks require an awake display in the active user session")

        move(to: 15, 9, 45)
        post(NSWorkspace.screensDidSleepNotification)
        try expect(schedule.remainingTime == 4_500 && !schedule.isCounting, "Screen sleep did not pause at 75 minutes")
        move(to: 15, 10)
        post(NSWorkspace.willSleepNotification)
        move(to: 15, 14)
        post(NSWorkspace.didWakeNotification)
        try expect(!schedule.isCounting && schedule.remainingTime == 4_500, "System wake counted before screen wake")
        post(NSWorkspace.screensDidWakeNotification)
        post(NSWorkspace.screensDidWakeNotification)
        try expect(schedule.isCounting && schedule.nextReminderAt == now.addingTimeInterval(4_500),
                   "Screen wake did not preserve the remaining interval")
        pass("production sleep/screen notification wiring and duplicate wake")

        post(NSWorkspace.sessionDidResignActiveNotification)
        move(to: 15, 15)
        post(NSWorkspace.sessionDidBecomeActiveNotification)
        try expect(schedule.remainingTime == 4_500, "Inactive user session consumed time")
        pass("inactive user session pauses countdown")


        move(to: 15, 16, 15)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment && schedule.isAwaitingAcknowledgment, "Due reminder failed to start")
        post(NSWorkspace.screensDidSleepNotification)
        move(to: 16, 8)
        post(NSWorkspace.screensDidWakeNotification)
        try expect(!overlay.isActive && !schedule.isAwaitingAcknowledgment, "Yesterday's unclicked scene returned on wake")
        try expect(schedule.nextReminderAt == now.addingTimeInterval(7_200), "Morning did not start a full interval")
        pass("overnight wake discards yesterday's unclicked overlay")

        move(to: 16, 10)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Morning reminder failed to start")
        overlay.acknowledge()
        try expect(overlay.isActive && !overlay.isAwaitingAcknowledgment, "Ordinary click lost the exit animation")
        try expect(schedule.nextReminderAt == now.addingTimeInterval(7_200), "Ordinary click did not restart the interval")
        pass("ordinary click preserves exit animation and restarts countdown")

        // Complete that exit without waiting for wall time, then start the next
        // real reminder through the production clock-change handler.
        overlay.stop()
        move(to: 16, 12)
        post(.NSSystemClockDidChange, workspace: false)
        move(to: 16, 22)
        overlay.acknowledge()
        try expect(!overlay.isActive && !schedule.isCounting, "A cutoff-time click left the overlay on screen")
        pass("cutoff-time click immediately dismisses the overlay")

        move(to: 17, 8)
        post(.NSCalendarDayChanged, workspace: false)
        move(to: 17, 10)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Next-day reminder failed to start")
        move(to: 17, 22)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(!overlay.isActive && schedule.nextReminderAt == nil, "22:00 did not dismiss an outstanding overlay")
        pass("daily boundary dismisses outstanding overlay")

        move(to: 18, 8)
        post(.NSCalendarDayChanged, workspace: false)
        move(to: 18, 10)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Interval-edit fixture did not start its reminder")
        move(to: 18, 22)
        delegate.settings.hours = 2.5
        try expect(!overlay.isActive && !schedule.isCounting, "A cutoff-time setting edit left the overlay on screen")
        pass("cutoff-time interval edit immediately dismisses the overlay")

        move(to: 19, 8)
        post(.NSCalendarDayChanged, workspace: false)
        move(to: 19, 10, 30)
        post(.NSSystemClockDidChange, workspace: false)
        overlay.acknowledge()
        post(NSWorkspace.screensDidSleepNotification)
        move(to: 19, 11)
        post(NSWorkspace.screensDidWakeNotification)
        try expect(overlay.isActive && !overlay.isAwaitingAcknowledgment, "Same-day wake discarded the normal exit animation")
        post(NSWorkspace.screensDidSleepNotification)
        move(to: 20, 8)
        post(NSWorkspace.screensDidWakeNotification)
        try expect(!overlay.isActive, "Yesterday's paused exit animation returned in the morning")
        try expect(schedule.nextReminderAt == now.addingTimeInterval(9_000), "Exit cleanup changed the new day's interval")
        pass("exit animation resumes on the same day and is discarded across days")

        move(to: 20, 10, 30)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Drink-confirmation fixture did not start")
        overlay.confirmDrink()
        try expect(delegate.history.count(on: now) == 1,
                   "The drink button did not record immediately at click time")
        try expect(schedule.nextReminderAt == now.addingTimeInterval(9_000), "Drink click did not immediately restart the regular interval")
        overlay.confirmDrink()
        try expect(delegate.history.count(on: now) == 1, "Double click counted a drink twice")
        try expect(AppStorage(defaults: preferences).loadHistory().count(on: now) == 1, "Drink confirmation was not saved")
        let saved = AppStorage(defaults: preferences)
        try expect(saved.loadPreferences().intervalHours == 2.5
                   && saved.loadProgress()?.isAwaitingAcknowledgment == false
                   && saved.loadProgress()?.remainingTime == 9_000,
                   "Drink, settings and new countdown were not committed as one state")
        overlay.stop()
        pass("explicit drink confirms immediately, saves locally and ignores double click")

        let model: SettingsModel = delegate.settings
        model.change {
            $0.style = .compact
            $0.appearance = ReminderAppearance(theme: .mint, character: .droplet)
        }
        let originalDeadline = schedule.nextReminderAt
        model.onPreview?()
        try expect(overlay.isActive && delegate.isPreviewing, "Appearance preview did not start")
        overlay.confirmDrink()
        try expect(!overlay.isActive && !delegate.isPreviewing, "Preview action did not close the preview")
        try expect(schedule.nextReminderAt == originalDeadline, "Appearance preview changed the deadline")
        try expect(delegate.history.count(on: now) == 1, "Preview recorded a drink")
        pass("appearance preview leaves countdown and drink history unchanged")

        move(to: 20, 13)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isActive && overlay.isAwaitingAcknowledgment, "Compact reminder failed to start")
        overlay.snooze(minutes: 10)
        try expect(!overlay.isActive && schedule.isSnoozed && schedule.remainingTime == 600,
                   "Ten-minute action did not close and snooze")
        move(to: 20, 13, 10)
        post(.NSSystemClockDidChange, workspace: false)
        overlay.snooze(minutes: 20)
        try expect(!overlay.isActive && schedule.isSnoozed && schedule.remainingTime == 1_200,
                   "Twenty-minute action did not use the selected delay")
        try expect(delegate.history.count(on: now) == 1, "Snoozing recorded a drink")
        pass("compact reminder and both snooze actions preserve drink history")

        move(to: 20, 13, 15)
        model.onPause?(30)
        try expect(schedule.isManuallyPaused && schedule.remainingTime == 900, "Pause did not preserve the snoozed countdown")
        try expect(schedule.nextCheckAt == now.addingTimeInterval(1_800), "Pause did not schedule automatic resume")
        move(to: 20, 13, 20)
        relaunch(preferences)
        try expect(schedule.isManuallyPaused && schedule.remainingTime == 900, "Restart lost pause or counted offline time")
        try expect(delegate.configuration.style == .compact,
                   "Restart lost reminder preferences")
        try expect(delegate.history.count(on: now) == 1, "Restart lost explicit drink history")
        move(to: 20, 13, 45)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(!schedule.isManuallyPaused && schedule.nextReminderAt == now.addingTimeInterval(900),
                   "Pause expiry did not resume from the saved remaining time")
        pass("restart restores pause, snooze, settings and history without counting offline time")

        move(to: 20, 14)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Restored countdown did not become due")
        move(to: 20, 14, 5)
        relaunch(preferences)
        try expect(overlay.isActive && schedule.isAwaitingAcknowledgment, "Restart restored pending state without its visible reminder")
        overlay.acknowledge()
        try expect(delegate.history.count(on: now) == 2, "Character confirmation did not count the restored reminder")
        pass("outstanding reminder is re-presented after restart and character confirmation records a drink")

        move(to: 21, 8)
        post(.NSCalendarDayChanged, workspace: false)
        move(to: 21, 10, 30)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Cutoff confirmation fixture did not start")
        move(to: 21, 22)
        overlay.confirmDrink()
        try expect(delegate.history.count(on: now) == 1,
                   "Visible drink confirmation was lost at the closing boundary")
        try expect(!overlay.isActive && !schedule.isCounting, "Cutoff confirmation restarted night counting")
        pass("a visible real drink button records at cutoff without restarting night counting")

        move(to: 22, 8)
        post(.NSCalendarDayChanged, workspace: false)
        move(to: 22, 10, 30)
        post(.NSSystemClockDidChange, workspace: false)
        move(to: 22, 22)
        let cutoff = now
        now = cutoff.addingTimeInterval(-0.001)
        uptime -= 0.001
        advanceAfterNextDateRead = 0.001
        post(.NSSystemClockDidChange, workspace: false)
        try expect(schedule.nextCheckAt == cutoff, "Saving across the cutoff replaced the closing timer with tomorrow's opening")
        post(.NSSystemClockDidChange, workspace: false)
        try expect(!overlay.isActive && !schedule.isCounting, "A cutoff crossed during saving left the reminder visible")
        pass("saving across a clock boundary preserves the closing callback")

        let visible = CGRect(x: 0, y: 24, width: 900, height: 540)
        for character in ReminderCharacter.allCases {
            var scene = ReminderScene(viewport: CGSize(width: 900, height: 600),
                                      appearance: ReminderAppearance(character: character))
            scene.advance(by: 2)
            for preview in [false, true] {
                let animated = OverlayControls.animatedButtons(in: scene, visibleBounds: visible, isPreview: preview)
                let compact = OverlayControls.compactLayout(visibleBounds: visible, isPreview: preview)
                try expect(animated.buttons.allSatisfy { visible.contains($0.frame) }, "Animated controls escaped the visible display")
                try expect(visible.contains(compact.card) && compact.buttons.allSatisfy { compact.card.contains($0.frame) },
                           "Compact controls escaped their card")
                try expect(animated.buttons.count == (preview ? 1 : 3) && compact.buttons.count == (preview ? 1 : 3),
                           "Preview exposed a real drink or snooze action")
            }
        }
        try expect(!preferences.dictionaryRepresentation().keys.contains { $0.hasPrefix("appStateV1.unreadable.") },
                   "This build's own saved state was treated as unreadable")
        pass("reminder and preview button layouts stay inside the visible display")
    }

    /// Both confirmation entry points share one record per real reminder.
    func drinkConfirmationScenario(_ preferences: UserDefaults) throws {
        move(to: 27, 8)
        launch(preferences)
        var confirmed = 0
        var hour = 10

        for style in ReminderStyle.allCases {
            delegate.settings.change { $0.style = style }
            for characterFirst in [true, false] {
                move(to: 27, hour)
                hour += 2
                post(.NSSystemClockDidChange, workspace: false)
                try expect(overlay.isAwaitingAcknowledgment, "Confirmation fixture did not start")

                if characterFirst { overlay.acknowledge() }
                else { overlay.confirmDrink() }
                confirmed += 1
                try expect(delegate.history.count(on: now) == confirmed,
                           "The first confirmation did not record exactly one drink")
                try expect(delegate.history.drinks.last == now
                           && delegate.settings.todayDrinkTimes.count == confirmed,
                           "Confirmation time or displayed count was not updated immediately")
                let deadline = now.addingTimeInterval(7_200)
                try expect(!schedule.isAwaitingAcknowledgment && schedule.nextReminderAt == deadline,
                           "Confirmation did not restart the full interval")

                overlay.acknowledge()
                overlay.confirmDrink()
                delegate.settings.onDrink?()
                try expect(delegate.history.count(on: now) == confirmed && schedule.nextReminderAt == deadline,
                           "Repeated or mixed confirmation counted the same reminder twice")
                try expect(AppStorage(defaults: preferences).loadHistory().count(on: now) == confirmed,
                           "Confirmation was not persisted exactly once")

                relaunch(preferences)
                delegate.settings.onDrink?()
                try expect(delegate.history.count(on: now) == confirmed && !overlay.isActive,
                           "Restart lost a confirmation or allowed the same reminder to be counted again")
                pass("\(style.rawValue) \(characterFirst ? "character" : "button") first: one saved drink per reminder")
            }

            let deadline = schedule.nextReminderAt
            delegate.settings.onPreview?()
            try expect(overlay.isActive && delegate.isPreviewing, "Character preview fixture did not start")
            overlay.acknowledge()
            try expect(!overlay.isActive && !delegate.isPreviewing
                       && delegate.history.count(on: now) == confirmed && schedule.nextReminderAt == deadline,
                       "Clicking the preview character recorded a drink or changed the countdown")
            pass("\(style.rawValue) preview character leaves drink history and countdown unchanged")
        }
    }

    /// Saved state written by another build, or damaged.
    func storageScenario(_ preferences: UserDefaults) throws {
        // A state written by a different build: one key missing, one unknown value.
        let otherBuild = #"{"preferences":{"intervalHours":1.5,"style":"compact","weekdayHours":{"endMinutes":1320,"startMinutes":360},"appearance":{"character":"droplet","theme":"ocean"}},"history":{"drinks":[813717000,813720540]},"progress":{"remainingTime":"later"}}"#
        preferences.set(Data(otherBuild.utf8), forKey: "appStateV1")
        launch(preferences)
        try expect(delegate.history.drinks.count == 2,
                   "A schema mismatch hid the saved drink history")
        try expect(delegate.configuration.intervalHours == 1.5
                   && delegate.configuration.style == .compact,
                   "A schema mismatch discarded readable preferences")
        try expect(AppStorage(defaults: preferences).loadHistory().drinks.count == 2,
                   "Launch-time save overwrote the drink history")
        pass("a state from another build keeps its history and readable settings")

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let unreadable = Data(#"{"history":{"drinks":"#.utf8)
        preferences.set(unreadable, forKey: "appStateV1")
        launch(preferences)
        let backups = preferences.dictionaryRepresentation().filter { $0.key.hasPrefix("appStateV1.unreadable.") }
        try expect(backups.values.contains { $0 as? Data == unreadable },
                   "Unreadable saved state was overwritten without a backup")
        pass("unreadable saved state is backed up before the first save")

    }

    /// A due reminder that cannot be shown yet: the previous exit animation
    /// is still on screen. These steps run the real overlay timers.
    func overlayScenario(_ preferences: UserDefaults) throws {
        move(to: 23, 9)
        launch(preferences)
        move(to: 23, 11)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Overlay fixture did not start")
        overlay.acknowledge()
        move(to: 23, 13, 1)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(schedule.isDue && overlay.isActive, "Fixture did not overlap a due reminder with the exit animation")
        let retry = delegate.reminderTimer?.fireDate.timeIntervalSinceNow ?? 0
        try expect(retry > AppDelegate.presentationRetryDelay - 2,
                   "A reminder that could not be shown retried in a tight loop")
        pass("a due reminder that cannot be shown retries slowly")

        spin(ReminderScene.acknowledgmentDuration + ReminderScene.ascentDuration + 0.5)
        try expect(overlay.isAwaitingAcknowledgment, "The next reminder waited for the retry, not the exit animation")
        pass("the next reminder appears as soon as the exit animation ends")

        spin(ReminderScene.descentDuration + 0.3)
        let buttonFrames = { self.overlay.buttonPanels.map(\.frame) }
        let shownBlockers = { self.overlay.blockerPanels.filter(\.isVisible) }
        let firstFrames = buttonFrames()
        try expect(firstFrames.count == 3 && shownBlockers().count == 2, "Reminder controls or bubble blockers are missing")
        spin(ReminderScene.throwPeriod)
        try expect(buttonFrames() == firstFrames, "Reminder buttons moved while shown")
        pass("animated buttons hold still and the speech bubble catches clicks")

        delegate.settings.change { $0.style = .compact }
        overlay.snooze(minutes: 10)
        move(to: 23, 13, 11)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment && shownBlockers().count == 2, "The compact card lets clicks through")
        let layout = OverlayControls.compactLayout(visibleBounds: CGRect(x: 0, y: 24, width: 900, height: 540), isPreview: false)
        let card = PixelArt.image(size: CGSize(width: 900, height: 600), backingScale: 1) {
            OverlayControls.drawCompactCard(layout.card, in: $0, appearance: ReminderAppearance(), isPreview: false)
        }.representations.first as! NSBitmapImageRep
        for region in OverlayControls.compactCardRegions(layout.card) {
            for y in stride(from: Int(region.minY), to: Int(region.maxY), by: 3) {
                for x in stride(from: Int(region.minX), to: Int(region.maxX), by: 3) {
                    try expect(card.bitmapData![y * card.bytesPerRow + x * 4 + 3] == 255,
                               "Card blocker region is not painted at (\(x), \(y))")
                }
            }
        }
        overlay.stop()
        pass("the compact card catches clicks under fully painted pixels")

    }

    /// Missed notifications: the display slept without screensDidSleep, and
    /// later woke without screensDidWake. The app must read the real state.
    func systemScenario(_ preferences: UserDefaults) throws {
        move(to: 26, 9)
        launch(preferences)
        try expect(schedule.isCounting, "Missed-notification fixture did not start counting")
        post(NSWorkspace.willSleepNotification)
        system.isScreenAwake = false
        move(to: 26, 9, 30)
        post(NSWorkspace.didWakeNotification)
        move(to: 26, 9, 40)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(!schedule.isCounting && schedule.remainingTime == 7_200,
                   "Counted while the display was dark after a missed screen-sleep notification")
        system.isScreenAwake = true
        post(NSWorkspace.sessionDidBecomeActiveNotification)
        try expect(schedule.isCounting, "Stayed paused after a missed screen-wake notification")
        pass("wake events re-read the real display state")

        // The menu offers the reminder's actions while it is waiting.
        let menu: SettingsModel = delegate.settings
        move(to: 26, 11, 40)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment && menu.isAwaitingAcknowledgment, "Menu did not offer reminder actions")
        menu.onSnooze?(10)
        try expect(!overlay.isActive && schedule.isSnoozed && !menu.isAwaitingAcknowledgment, "Menu snooze did not close the reminder")
        move(to: 26, 11, 50)
        post(.NSSystemClockDidChange, workspace: false)
        menu.onDrink?()
        try expect(delegate.history.drinks.count == 1 && !schedule.isAwaitingAcknowledgment,
                   "Menu drink confirmation was not recorded")
        try expect(overlay.isActive && !overlay.isAwaitingAcknowledgment, "Menu confirmation skipped the exit animation")
        overlay.stop()
        pass("the menu can confirm a drink or snooze a waiting reminder")
    }


    private(set) var passed = 0
    private(set) var failures: [String] = []

    private func pass(_ name: String) {
        passed += 1
        print("PASS: \(name)")
    }

    private func launch(_ preferences: UserDefaults) {
        delegate = AppDelegate(dateNow: { self.readDate() }, uptimeNow: { self.uptime },
                               systemState: { self.system }, preferences: preferences)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    /// Quits normally (saving state) and launches a fresh app on the same storage.
    private func relaunch(_ preferences: UserDefaults) {
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        launch(preferences)
    }

    /// Runs a scenario against its own isolated preferences. A failure ends
    /// only that scenario; the others still run.
    func scenario(_ name: String, _ body: (UserDefaults) throws -> Void) {
        let suiteName = "com.oil.bigwater.sessionchecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.set(true, forKey: "launchAtLogin")
        defer {
            delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            delegate = nil
            system = AppDelegate.SystemState(isSessionActive: true, isScreenAwake: true)
            preferences.removePersistentDomain(forName: suiteName)
        }
        do {
            try body(preferences)
        } catch {
            failures.append(name)
            fputs("FAIL: \(name): \(error.localizedDescription)\n", stderr)
        }
    }

    /// Lets the overlay's real animation timers run.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

@main
private enum BigWaterSessionChecks {
    static func main() {
        _ = NSApplication.shared
        MainActor.assumeIsolated {
            let checks = SessionChecks()
            checks.scenario("daily story", checks.dailyStory)
            checks.scenario("saved state from other builds", checks.storageScenario)
            checks.scenario("overlay timing and input", checks.overlayScenario)
            checks.scenario("system state and menu actions", checks.systemScenario)
            checks.scenario("drink confirmation and deduplication", checks.drinkConfirmationScenario)
            if checks.failures.isEmpty {
                print("\(checks.passed) session checks passed")
            } else {
                print("\(checks.passed) session checks passed; failed scenarios: \(checks.failures.joined(separator: ", "))")
                exit(1)
            }
        }
    }
}
