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

        for visible in [CGRect(x: 0, y: 24, width: 900, height: 540),
                        CGRect(x: 80, y: 38, width: 560, height: 318),
                        CGRect(x: 0, y: 38, width: 560, height: 318)] {
            for character in ReminderCharacter.allCases {
                for edge in ReminderEdge.allCases {
                    for position in [0.0, 0.5, 1.0] {
                        var scene = ReminderScene(viewport: CGSize(width: 900, height: 600),
                                                  appearance: ReminderAppearance(character: character),
                                                  entrance: ReminderEntrance(edge: edge, position: position),
                                                  visibleBounds: visible)
                        scene.advance(by: 2)
                        for preview in [false, true] {
                            let animated = OverlayControls.animatedButtons(in: scene, visibleBounds: visible, isPreview: preview)
                            let compact = OverlayControls.compactLayout(visibleBounds: visible, isPreview: preview)
                            try expect(animated.buttons.allSatisfy { visible.contains($0.frame) }, "Animated controls escaped the visible display")
                            let characterRegions = PixelArt.characterHitRegions(in: scene)
                            let bubble = SceneRenderer.speechRegions(for: scene)
                            try expect(animated.buttons.allSatisfy { button in
                                !characterRegions.contains { $0.intersects(button.frame) }
                                    && !bubble.contains { $0.intersects(button.frame) }
                            }, "Directional buttons overlap the character or bubble")
                            try expect(bubble.allSatisfy { visible.contains($0) }, "Directional bubble escaped the visible display")
                            let frames = animated.buttons.map(\.frame)
                            scene.advance(by: 0.45)
                            try expect(OverlayControls.animatedButtons(in: scene, visibleBounds: visible,
                                                                       isPreview: preview).buttons.map(\.frame) == frames,
                                       "Directional buttons swayed with the character")
                            try expect(visible.contains(compact.card) && compact.buttons.allSatisfy { compact.card.contains($0.frame) },
                                       "Compact controls escaped their card")
                            try expect(animated.buttons.count == (preview ? 1 : 3) && compact.buttons.count == (preview ? 1 : 3),
                                       "Preview exposed a real drink or snooze action")
                        }
                    }
                }
            }
        }
        try expect(!preferences.dictionaryRepresentation().keys.contains { $0.hasPrefix("appStateV1.unreadable.") },
                   "This build's own saved state was treated as unreadable")
        pass("all entrance layouts avoid the Dock, stay clickable and hold buttons still")
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
                try expect(delegate.history.count(on: now) == confirmed && !overlay.isActive,
                           "Restart lost a confirmation or re-presented an acknowledged reminder")
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

    func spontaneousDrinkAndUndoScenario(_ preferences: UserDefaults) throws {
        move(to: 28, 9)
        launch(preferences)
        move(to: 28, 9, 30)
        post(.NSSystemClockDidChange, workspace: false)
        delegate.settings.onDrink?()
        delegate.settings.onDrink?()
        try expect(delegate.history.drinks.count == 1 && schedule.remainingTime == 7_200,
                   "An early drink was not recorded once with a full interval")
        move(to: 28, 9, 40)
        post(.NSSystemClockDidChange, workspace: false)
        delegate.settings.onUndoDrink?()
        try expect(delegate.history.drinks.isEmpty && schedule.remainingTime == 4_800,
                   "Undo did not restore the earlier countdown including elapsed use")
        delegate.settings.onUndoDrink?()
        try expect(schedule.remainingTime == 4_800, "A repeated undo changed the countdown")
        pass("spontaneous drinks and double-click-safe undo restore the old countdown")

        delegate.settings.onDrink?()
        move(to: 28, 9, 50)
        post(NSWorkspace.screensDidSleepNotification)
        move(to: 28, 12)
        post(NSWorkspace.screensDidWakeNotification)
        move(to: 28, 12, 10)
        delegate.settings.onUndoDrink?()
        try expect(schedule.remainingTime == 3_600 && delegate.history.drinks.isEmpty,
                   "Undo counted screen-off time against the earlier countdown")
        pass("undo follows the old countdown through screen sleep and wake")

        delegate.settings.onDrink?()
        delegate.settings.onPause?(30)
        let paused = schedule.pausedUntil
        delegate.settings.onUndoDrink?()
        try expect(delegate.history.drinks.isEmpty && schedule.isManuallyPaused
                   && schedule.pausedUntil == paused && schedule.remainingTime == 7_200,
                   "Undo overwrote a later intentional pause")
        delegate.settings.onResume?()
        move(to: 28, 12, 15)
        delegate.settings.onDrink?()
        delegate.settings.hours = 1.5
        let changed = schedule.remainingTime
        delegate.settings.onUndoDrink?()
        try expect(delegate.history.drinks.isEmpty && schedule.intervalHours == 1.5
                   && schedule.remainingTime == changed,
                   "Undo overwrote a later interval choice")
        pass("undo removes a mistake while respecting later pause and interval choices")

        move(to: 28, 12, 20)
        delegate.settings.onDrink?()
        let recorded = delegate.history.drinks[0]
        relaunch(preferences)
        try expect(delegate.history.drinks == [recorded] && !delegate.settings.canUndoDrink,
                   "Restart did not preserve the drink or retained an unsafe countdown undo")
        delegate.settings.onRemoveDrink?(recorded)
        relaunch(preferences)
        try expect(delegate.history.drinks.isEmpty, "Deleting a saved mistake did not survive restart")
        pass("saved records can be deleted after restart without losing other state")

        move(to: 28, 23)
        delegate.settings.onDrink?()
        try expect(delegate.history.count(on: now) == 1 && !schedule.isCounting && !overlay.isActive,
                   "A quiet-hours drink did not record safely")
        delegate.settings.onUndoDrink?()
        try expect(delegate.history.count(on: now) == 0 && !schedule.isCounting,
                   "Undo outside reminder hours started counting")
        move(to: 29, 8)
        post(.NSCalendarDayChanged, workspace: false)
        move(to: 29, 9, 30)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Undo reminder fixture did not become due")
        overlay.acknowledge()
        delegate.settings.onUndoDrink?()
        try expect(delegate.history.count(on: now) == 0 && schedule.isAwaitingAcknowledgment
                   && overlay.isAwaitingAcknowledgment,
                   "Undoing a character confirmation did not restore the waiting reminder")
        overlay.confirmDrink()
        try expect(delegate.history.count(on: now) == 1, "A restored reminder could not be confirmed again")
        pass("quiet-hours records and undone character confirmations preserve reminder behavior")
    }

    func quickMenuScenario(_ preferences: UserDefaults) throws {
        move(to: 30, 9)
        launch(preferences)
        func perform(_ title: String) throws {
            let menu = delegate.makeQuickMenu()
            let index = menu.indexOfItem(withTitle: title)
            try expect(index >= 0 && menu.item(at: index)?.isEnabled == true,
                       "Quick-menu action is missing or stale: \(title)")
            menu.performActionForItem(at: index)
        }
        try perform("我刚喝过水")
        try expect(delegate.history.drinks.count == 1, "Quick record did not reach the shared drink action")
        try perform("撤销刚才的喝水记录")
        try expect(delegate.history.drinks.isEmpty, "Quick undo did not remove the drink")
        let undoneMenu = delegate.makeQuickMenu()
        try expect(undoneMenu.item(withTitle: "撤销刚才的喝水记录")?.isEnabled == false,
                   "Quick undo stayed enabled after the record was undone")
        try perform("暂停 30 分钟")
        try expect(schedule.isManuallyPaused && schedule.pausedUntil == now.addingTimeInterval(1_800),
                   "Quick thirty-minute pause used a different duration")
        try perform("恢复计时")
        try expect(!schedule.isManuallyPaused, "Quick resume stayed paused")
        try perform("暂停 60 分钟")
        try expect(schedule.pausedUntil == now.addingTimeInterval(3_600), "Quick sixty-minute pause used a different duration")
        pass("native right-click menu dispatches record, undo, pause and resume with live enabled state")
    }

    func placementScenario(_ preferences: UserDefaults) throws {
        try runPlacementChecks()
        pass("placement preferences, corner geometry and real display selection")
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
        try expect(firstFrames.count == 3 && shownBlockers().count == 4, "Reminder controls or bubble blockers are missing")
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

    /// Exercise all four paths with real windows/timers, using settings-style
    /// previews first so the test never records an artificial drink.
    func directionalOverlayScenario(_ preferences: UserDefaults) throws {
        let desktop = OverlayController()
        defer { desktop.stop() }
        var previewEnds = 0
        var confirmations = 0
        var finishes = 0
        desktop.onPreviewEnd = { previewEnds += 1 }
        desktop.onDrink = { confirmations += 1 }
        desktop.onFinished = { finishes += 1 }
        for edge in ReminderEdge.allCases {
            var scene = ReminderScene(viewport: CGSize(width: 640, height: 420), isPreview: true,
                                      entrance: ReminderEntrance(edge: edge, position: 0.5))
            scene.advance(by: 2)
            let layout = OverlayControls.animatedButtons(in: scene, visibleBounds: scene.visibleBounds, isPreview: true)
            let regions = OverlayControls.animatedPaintedRegions(in: scene, previewBadge: layout.badge)
            let badgeImage = PixelArt.image(size: scene.viewport, backingScale: 1) { context in
                if let badge = layout.badge {
                    OverlayControls.drawPreviewBadge(badge, in: context, theme: scene.appearance.theme)
                }
            }.representations.first as! NSBitmapImageRep
            for y in 0..<badgeImage.pixelsHigh {
                for x in 0..<badgeImage.pixelsWide where badgeImage.bitmapData![y * badgeImage.bytesPerRow + x * 4 + 3] > 0 {
                    try expect(regions.contains { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) },
                               "\(edge) preview badge or shadow was omitted from animation redraws")
                }
            }
            let entrance = ReminderEntrance(edge: edge, position: 0.35)
            try expect(desktop.start(isPreview: true, entrance: entrance), "\(edge) preview could not open")
            spin(ReminderScene.descentDuration + 0.15)
            try expect(desktop.buttonPanels.count == 1 && desktop.buttonPanels[0].isVisible,
                       "\(edge) preview did not show its end button")
            let frames = desktop.buttonPanels.map(\.frame)
            desktop.suspend()
            try expect(desktop.buttonPanels.allSatisfy { !$0.isVisible }, "\(edge) stayed visible during suspension")
            desktop.resume()
            spin(0.1)
            try expect(desktop.buttonPanels.map(\.frame) == frames && desktop.buttonPanels[0].isVisible,
                       "\(edge) resume changed its entrance or lost controls")
            desktop.acknowledge()
            try expect(!desktop.isActive && confirmations == 0, "Directional preview confirmed a drink")
        }
        try expect(previewEnds == ReminderEdge.allCases.count, "A directional preview never ended")
        pass("all preview badge pixels and shadows are included in animation redraws")
        pass("four real preview paths resume in place and close without recording drinks")

        for edge in ReminderEdge.allCases {
            try expect(desktop.start(entrance: ReminderEntrance(edge: edge, position: 0.65)),
                       "\(edge) reminder could not open")
            spin(ReminderScene.descentDuration + 0.15)
            try expect(desktop.buttonPanels.count == 3 && desktop.blockerPanels.filter(\.isVisible).count == 4,
                       "\(edge) reminder controls or bubble blockers are missing")
            let previous = confirmations
            desktop.confirmDrink()
            desktop.confirmDrink()
            desktop.acknowledge()
            try expect(confirmations == previous + 1 && desktop.isActive && !desktop.isAwaitingAcknowledgment,
                       "\(edge) confirmation was duplicated or skipped the exit animation")
            spin(ReminderScene.acknowledgmentDuration + ReminderScene.ascentDuration + 0.2)
            try expect(!desktop.isActive, "\(edge) exit left desktop windows active")
        }
        try expect(finishes == ReminderEdge.allCases.count, "A directional exit never called completion")
        pass("four real reminder paths confirm once and close after their exit animation")
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


    func featureCorrectionsScenario(_ preferences: UserDefaults) throws {
        move(to: 16, 9)
        launch(preferences)
        move(to: 16, 9, 15)
        post(.NSSystemClockDidChange, workspace: false)
        let deadline = schedule.nextReminderAt
        let remaining = schedule.remainingTime
        let original = now.addingTimeInterval(-1_800)
        try expect(delegate.settings.onAddDrink?(original) == true,
                   "The backfill entry did not reach the history store")
        try expect(schedule.nextReminderAt == deadline && schedule.remainingTime == remaining,
                   "Backfilling acknowledged or restarted the live countdown")
        let replacement = now.addingTimeInterval(-86_400)
        try expect(delegate.settings.onEditDrink?(original, replacement) == true,
                   "The timestamp editor did not update its record")
        try expect(delegate.history.drinks == [replacement] && schedule.nextReminderAt == deadline,
                   "Editing a timestamp lost the record or changed the reminder")
        let recorded = delegate.history
        try expect(delegate.settings.onAddDrink?(now.addingTimeInterval(60)) == false
                   && delegate.history == recorded, "A future backfill mutated history")
        delegate.settings.onDrink?()
        try expect(delegate.settings.canUndoDrink, "The ordinary record did not offer undo")
        try expect(delegate.settings.onEditDrink?(now, original) == true && !delegate.settings.canUndoDrink,
                   "Editing the undo target left an unsafe old countdown undo")
        let correctedHistory = delegate.history
        let correctedProgress = schedule.remainingTime
        relaunch(preferences)
        try expect(delegate.history == correctedHistory && schedule.remainingTime == correctedProgress,
                   "Corrected times or live progress were lost on reload")
        pass("feature corrections: backfill and edits save without changing the live clock")
    }

    func featureSegmentsScenario(_ preferences: UserDefaults) throws {
        move(to: 17, 11)
        var configuration = AppPreferences()
        configuration.weekdayHours = DailyHours(periods: [
            ReminderPeriod(startMinutes: 9 * 60, endMinutes: 12 * 60),
            ReminderPeriod(startMinutes: 14 * 60, endMinutes: 18 * 60)
        ])
        var initial = ReminderSchedule(now: now, uptime: uptime,
                                       weekdayHours: configuration.weekdayHours)
        AppStorage(defaults: preferences).save(preferences: configuration,
            progress: initial.snapshot(at: now, uptime: uptime), history: HydrationHistory())
        launch(preferences)
        move(to: 17, 11, 30)
        post(.NSSystemClockDidChange, workspace: false)
        // The remaining 90 active minutes are 30 before lunch and 60 after it.
        try expect(schedule.nextReminderAt == calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now)
                   && delegate.settings.countdown(at: now) == "01:30:00",
                   "The active-time countdown incorrectly included the lunch gap")
        move(to: 17, 12)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(!schedule.isCounting && schedule.remainingTime == 3_600
                   && !overlay.isActive && delegate.settings.menuBarStatus.phase == .resting,
                   "The lunch boundary did not freeze progress and update menu state")
        move(to: 17, 12, 30)
        relaunch(preferences)
        try expect(schedule.remainingTime == 3_600 && !schedule.isCounting,
                   "Restart during lunch discarded the saved progress")
        let lastModelDate = delegate.settings.currentDate
        move(to: 17, 13)
        try expect(delegate.settings.currentDate == lastModelDate
                   && delegate.settings.onHistoryReferenceDate?() == now,
                   "Opening a history editor during rest did not receive the current time")
        move(to: 17, 14)
        post(.NSSystemClockDidChange, workspace: false)
        delegate.settings.change { $0.showMenuBarCountdown = true }
        try expect(schedule.remainingTime == 3_600 && schedule.isCounting
                   && delegate.settings.menuBarStatus.title(showMinutes: true) == "60分",
                   "The afternoon start did not resume progress or menu minutes")
        try expect(AppStorage(defaults: preferences).loadPreferences().showMenuBarCountdown
                   && delegate.configuration.weekdayHours.periods.count == 2,
                   "Segmented periods or the countdown setting were not stored")
        pass("feature segments: lunch, reload and menu minutes follow the same saved state")
    }

    func featurePendingAcrossGapScenario(_ preferences: UserDefaults) throws {
        try pendingAcrossGap(preferences, clockJump: false)
    }

    func featurePendingClockJumpScenario(_ preferences: UserDefaults) throws {
        try pendingAcrossGap(preferences, clockJump: true)
    }

    func featurePendingSettingsFirstScenario(_ preferences: UserDefaults) throws {
        try pendingAcrossGap(preferences, clockJump: true, settingsFirst: true)
    }

    private func pendingAcrossGap(_ preferences: UserDefaults, clockJump: Bool,
                                  settingsFirst: Bool = false) throws {
        move(to: 18, 10, 30)
        var configuration = AppPreferences()
        configuration.intervalHours = settingsFirst ? 1 : 0.5
        configuration.style = .compact
        configuration.weekdayHours = DailyHours(periods: [
            ReminderPeriod(startMinutes: 9 * 60, endMinutes: 12 * 60),
            ReminderPeriod(startMinutes: 13 * 60, endMinutes: 18 * 60)
        ])
        var initial = ReminderSchedule(hours: configuration.intervalHours, now: now, uptime: uptime,
                                       weekdayHours: configuration.weekdayHours)
        AppStorage(defaults: preferences).save(preferences: configuration,
            progress: initial.snapshot(at: now, uptime: uptime), history: HydrationHistory())
        launch(preferences)
        move(to: 18, 11, settingsFirst ? 30 : 0)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(schedule.isAwaitingAcknowledgment && overlay.isAwaitingAcknowledgment,
                   "The pre-lunch reminder fixture did not start")
        let oldPanel = overlay.buttonPanels.first
        try expect(oldPanel != nil, "The reminder fixture had no action panel")
        move(to: 18, 11, 50)
        if clockJump {
            let oldUptime = uptime
            move(to: 18, 13, 10)
            uptime = oldUptime + 60
            if settingsFirst { delegate.settings.hours = 0.5 }
            else { post(.NSSystemClockDidChange, workspace: false) }
        } else {
            post(NSWorkspace.willSleepNotification)
            move(to: 18, 13, 10)
            post(NSWorkspace.didWakeNotification)
        }
        try expect(schedule.isAwaitingAcknowledgment && overlay.isAwaitingAcknowledgment
                   && delegate.settings.menuBarStatus.phase == .waiting,
                   "Skipping the lunch boundary left the old scene detached from the schedule")
        try expect(overlay.buttonPanels.first !== oldPanel,
                   "The prior period's action panel survived instead of being re-offered")
        overlay.confirmDrink()
        try expect(delegate.history.count(on: now) == 1 && !schedule.isAwaitingAcknowledgment,
                   "The re-offered reminder did not accept exactly one drink confirmation")
        overlay.stop()
        let trigger = settingsFirst ? "a settings action before the clock notification"
            : (clockJump ? "a clock correction" : "waking")
        pass("feature segments: a pending reminder re-offers after \(trigger) across a rest gap")
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
            if CommandLine.arguments.contains("--ui-preview")
                || Bundle.main.bundleIdentifier == "com.oil.bigwater.uipreview" {
                runHistoryPreview()
                return
            }
            let checks = SessionChecks()
            if CommandLine.arguments.contains("--features") {
                let scenarios: [(String, (UserDefaults) throws -> Void)] = [
                    ("feature history corrections", checks.featureCorrectionsScenario),
                    ("feature segmented timing and menu", checks.featureSegmentsScenario),
                    ("feature pending reminder across rest", checks.featurePendingAcrossGapScenario),
                    ("feature pending reminder after clock correction", checks.featurePendingClockJumpScenario),
                    ("feature pending reminder with settings first", checks.featurePendingSettingsFirstScenario)
                ]
                let arguments = CommandLine.arguments
                let filter: String
                if let index = arguments.firstIndex(of: "--filter") {
                    guard arguments.indices.contains(index + 1) else { exit(2) }
                    filter = arguments[index + 1]
                } else { filter = "" }
                let selected = scenarios.filter { $0.0.localizedCaseInsensitiveContains(filter) }
                guard !selected.isEmpty else { exit(2) }
                for (name, body) in selected { checks.scenario(name, body) }
                if !checks.failures.isEmpty { exit(1) }
                print("\(checks.passed) feature session checks passed (no animation scenarios)")
                return
            }
            checks.scenario("daily story", checks.dailyStory)
            checks.scenario("saved state from other builds", checks.storageScenario)
            checks.scenario("overlay timing and input", checks.overlayScenario)
            checks.scenario("four screen-edge entrances", checks.directionalOverlayScenario)
            checks.scenario("system state and menu actions", checks.systemScenario)
            checks.scenario("drink confirmation and deduplication", checks.drinkConfirmationScenario)
            checks.scenario("spontaneous records and undo", checks.spontaneousDrinkAndUndoScenario)
            checks.scenario("right-click quick menu", checks.quickMenuScenario)
            checks.scenario("configured placement", checks.placementScenario)
            if checks.failures.isEmpty {
                print("\(checks.passed) session checks passed")
            } else {
                print("\(checks.passed) session checks passed; failed scenarios: \(checks.failures.joined(separator: ", "))")
                exit(1)
            }
        }
    }
}
