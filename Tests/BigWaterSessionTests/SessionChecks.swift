import AppKit
import BigWaterCore

/// Compiled together with the production AppDelegate by Tools/check-session.sh.
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

    private func property<T>(_ label: String, as type: T.Type) -> T {
        Mirror(reflecting: delegate!).children.first { $0.label == label }!.value as! T
    }

    private var schedule: ReminderSchedule { property("schedule", as: ReminderSchedule.self) }
    private var overlay: OverlayController { property("overlay", as: OverlayController.self) }

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

    private func post(_ notification: Notification.Name, workspace: Bool = true) {
        let center = workspace ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
        center.post(name: notification, object: nil)
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "BigWaterSessionChecks", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    func run() throws {
        let suiteName = "com.oil.bigwater.sessionchecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.set(2.0, forKey: "reminderIntervalHours")
        preferences.set(true, forKey: "launchAtLogin")
        defer { preferences.removePersistentDomain(forName: suiteName) }
        delegate = AppDelegate(dateNow: { self.readDate() }, uptimeNow: { self.uptime }, preferences: preferences)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
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
        print("PASS: production sleep/screen notification wiring and duplicate wake")

        post(NSWorkspace.sessionDidResignActiveNotification)
        move(to: 15, 15)
        post(NSWorkspace.sessionDidBecomeActiveNotification)
        try expect(schedule.remainingTime == 4_500, "Inactive user session consumed time")
        print("PASS: inactive user session pauses countdown")

        move(to: 15, 16, 15)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment && schedule.isAwaitingAcknowledgment, "Due reminder failed to start")
        post(NSWorkspace.screensDidSleepNotification)
        move(to: 16, 8)
        post(NSWorkspace.screensDidWakeNotification)
        try expect(!overlay.isActive && !schedule.isAwaitingAcknowledgment, "Yesterday's unclicked scene returned on wake")
        try expect(schedule.nextReminderAt == now.addingTimeInterval(7_200), "Morning did not start a full interval")
        print("PASS: overnight wake discards yesterday's unclicked overlay")

        move(to: 16, 10)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Morning reminder failed to start")
        overlay.acknowledge()
        try expect(overlay.isActive && !overlay.isAwaitingAcknowledgment, "Ordinary click lost the exit animation")
        try expect(schedule.nextReminderAt == now.addingTimeInterval(7_200), "Ordinary click did not restart the interval")
        print("PASS: ordinary click preserves exit animation and restarts countdown")

        // Complete that exit without waiting for wall time, then start the next
        // real reminder through the production clock-change handler.
        overlay.stop()
        move(to: 16, 12)
        post(.NSSystemClockDidChange, workspace: false)
        move(to: 16, 22)
        overlay.acknowledge()
        try expect(!overlay.isActive && !schedule.isCounting, "A cutoff-time click left the overlay on screen")
        print("PASS: cutoff-time click immediately dismisses the overlay")

        move(to: 17, 8)
        post(.NSCalendarDayChanged, workspace: false)
        move(to: 17, 10)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Next-day reminder failed to start")
        move(to: 17, 22)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(!overlay.isActive && schedule.nextReminderAt == nil, "22:00 did not dismiss an outstanding overlay")
        print("PASS: daily boundary dismisses outstanding overlay")

        move(to: 18, 8)
        post(.NSCalendarDayChanged, workspace: false)
        move(to: 18, 10)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Interval-edit fixture did not start its reminder")
        move(to: 18, 22)
        property("settings", as: SettingsModel.self).hours = 2.5
        try expect(!overlay.isActive && !schedule.isCounting, "A cutoff-time setting edit left the overlay on screen")
        print("PASS: cutoff-time interval edit immediately dismisses the overlay")

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
        print("PASS: exit animation resumes on the same day and is discarded across days")

        move(to: 20, 10, 30)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Drink-confirmation fixture did not start")
        overlay.confirmDrink()
        try expect(property("history", as: HydrationHistory.self).count(on: now) == 1,
                   "The drink button did not record immediately at click time")
        try expect(schedule.nextReminderAt == now.addingTimeInterval(9_000), "Drink click did not immediately restart the regular interval")
        overlay.confirmDrink()
        try expect(property("history", as: HydrationHistory.self).count(on: now) == 1, "Double click counted a drink twice")
        try expect(AppStorage(defaults: preferences).loadHistory().count(on: now) == 1, "Drink confirmation was not saved")
        let saved = AppStorage(defaults: preferences)
        try expect(saved.loadPreferences().intervalHours == 2.5
                   && saved.loadProgress()?.isAwaitingAcknowledgment == false
                   && saved.loadProgress()?.remainingTime == 9_000,
                   "Drink, settings and new countdown were not committed as one state")
        overlay.stop()
        print("PASS: explicit drink confirms immediately, saves locally and ignores double click")

        let model = property("settings", as: SettingsModel.self)
        model.change {
            $0.style = .compact
            $0.appearance = ReminderAppearance(theme: .mint, character: .droplet)
        }
        let originalDeadline = schedule.nextReminderAt
        model.onPreview?()
        try expect(overlay.isActive && property("isPreviewing", as: Bool.self), "Appearance preview did not start")
        overlay.confirmDrink()
        try expect(!overlay.isActive && !property("isPreviewing", as: Bool.self), "Preview action did not close the preview")
        try expect(schedule.nextReminderAt == originalDeadline, "Appearance preview changed the deadline")
        try expect(property("history", as: HydrationHistory.self).count(on: now) == 1, "Preview recorded a drink")
        print("PASS: appearance preview leaves countdown and drink history unchanged")

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
        try expect(property("history", as: HydrationHistory.self).count(on: now) == 1, "Snoozing recorded a drink")
        print("PASS: compact reminder and both snooze actions preserve drink history")

        move(to: 20, 13, 15)
        model.onPause?(30)
        try expect(schedule.isManuallyPaused && schedule.remainingTime == 900, "Pause did not preserve the snoozed countdown")
        try expect(schedule.nextCheckAt == now.addingTimeInterval(1_800), "Pause did not schedule automatic resume")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        move(to: 20, 13, 20)
        delegate = AppDelegate(dateNow: { self.readDate() }, uptimeNow: { self.uptime }, preferences: preferences)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try expect(schedule.isManuallyPaused && schedule.remainingTime == 900, "Restart lost pause or counted offline time")
        try expect(property("configuration", as: AppPreferences.self).style == .compact,
                   "Restart lost reminder preferences")
        try expect(property("history", as: HydrationHistory.self).count(on: now) == 1, "Restart lost explicit drink history")
        move(to: 20, 13, 45)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(!schedule.isManuallyPaused && schedule.nextReminderAt == now.addingTimeInterval(900),
                   "Pause expiry did not resume from the saved remaining time")
        print("PASS: restart restores pause, snooze, settings and history without counting offline time")

        move(to: 20, 14)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Restored countdown did not become due")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        move(to: 20, 14, 5)
        delegate = AppDelegate(dateNow: { self.readDate() }, uptimeNow: { self.uptime }, preferences: preferences)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try expect(overlay.isActive && schedule.isAwaitingAcknowledgment, "Restart restored pending state without its visible reminder")
        overlay.acknowledge()
        try expect(property("history", as: HydrationHistory.self).count(on: now) == 1, "Character dismissal counted a drink")
        print("PASS: outstanding reminder is re-presented after restart and dismiss does not record")

        move(to: 21, 8)
        post(.NSCalendarDayChanged, workspace: false)
        move(to: 21, 10, 30)
        post(.NSSystemClockDidChange, workspace: false)
        try expect(overlay.isAwaitingAcknowledgment, "Cutoff confirmation fixture did not start")
        move(to: 21, 22)
        overlay.confirmDrink()
        try expect(property("history", as: HydrationHistory.self).count(on: now) == 1,
                   "Visible drink confirmation was lost at the closing boundary")
        try expect(!overlay.isActive && !schedule.isCounting, "Cutoff confirmation restarted night counting")
        print("PASS: a visible real drink button records at cutoff without restarting night counting")

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
        print("PASS: saving across a clock boundary preserves the closing callback")

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
        print("PASS: reminder and preview button layouts stay inside the visible display")

        // A state written by a different build: one key missing, one unknown value.
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try expect(!preferences.dictionaryRepresentation().keys.contains { $0.hasPrefix("appStateV1.unreadable.") },
                   "This build's own saved state was treated as unreadable")
        let otherBuild = #"{"preferences":{"intervalHours":1.5,"style":"compact","weekdayHours":{"endMinutes":1320,"startMinutes":360},"appearance":{"character":"droplet","theme":"ocean"}},"history":{"drinks":[813717000,813720540]},"progress":{"remainingTime":"later"}}"#
        preferences.set(Data(otherBuild.utf8), forKey: "appStateV1")
        delegate = AppDelegate(dateNow: { self.readDate() }, uptimeNow: { self.uptime }, preferences: preferences)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try expect(property("history", as: HydrationHistory.self).drinks.count == 2,
                   "A schema mismatch hid the saved drink history")
        try expect(property("configuration", as: AppPreferences.self).intervalHours == 1.5
                   && property("configuration", as: AppPreferences.self).style == .compact,
                   "A schema mismatch discarded readable preferences")
        try expect(AppStorage(defaults: preferences).loadHistory().drinks.count == 2,
                   "Launch-time save overwrote the drink history")
        print("PASS: a state from another build keeps its history and readable settings")

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let unreadable = Data(#"{"history":{"drinks":"#.utf8)
        preferences.set(unreadable, forKey: "appStateV1")
        delegate = AppDelegate(dateNow: { self.readDate() }, uptimeNow: { self.uptime }, preferences: preferences)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let backups = preferences.dictionaryRepresentation().filter { $0.key.hasPrefix("appStateV1.unreadable.") }
        try expect(backups.values.contains { $0 as? Data == unreadable },
                   "Unreadable saved state was overwritten without a backup")
        print("PASS: unreadable saved state is backed up before the first save")
    }
}

@main
private enum BigWaterSessionChecks {
    static func main() {
        _ = NSApplication.shared
        do {
            try MainActor.assumeIsolated { try SessionChecks().run() }
            print("18/18 session checks passed")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
