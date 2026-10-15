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

    init() {
        now = Calendar.autoupdatingCurrent.date(from: DateComponents(
            year: 2026, month: 10, day: 15, hour: 9))!
    }

    private func property<T>(_ label: String, as type: T.Type) -> T {
        Mirror(reflecting: delegate!).children.first { $0.label == label }!.value as! T
    }

    private var schedule: ReminderSchedule { property("schedule", as: ReminderSchedule.self) }
    private var overlay: OverlayController { property("overlay", as: OverlayController.self) }

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
        delegate = AppDelegate(dateNow: { self.now }, uptimeNow: { self.uptime }, preferences: preferences)
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
    }
}

@main
private enum BigWaterSessionChecks {
    static func main() {
        _ = NSApplication.shared
        do {
            try MainActor.assumeIsolated { try SessionChecks().run() }
            print("8/8 session checks passed")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
