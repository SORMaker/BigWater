import Foundation
import BigWaterCore

enum MenuBarStatusChecks {
    static let checks: [(String, () throws -> Void)] = [
        ("menu status: active minutes and fill", activeMinutes),
        ("menu status: pause, waiting and snooze", pausedAndWaiting),
        ("menu status: rest and hidden countdown", resting)
    ]

    private static func fixture() -> (Calendar, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return (calendar, calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))!)
    }

    private static func activeMinutes() throws {
        let (calendar, now) = fixture()
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.update(at: now.addingTimeInterval(3_601), uptime: 3_601, calendar: calendar)
        let status = MenuBarStatus(schedule: schedule, canPresentReminder: true)
        try expect(status.phase == .counting && status.remainingMinutes == 60,
                   "The menu did not round remaining active minutes up")
        try expect(abs(status.remainingFraction - 3_599.0 / 7_200) < 0.0001,
                   "Bottle fill no longer represents remaining active-use time")
        try expect(status.title(showMinutes: true) == "60分" && status.title(showMinutes: false).isEmpty,
                   "The optional menu countdown ignored its preference")
    }

    private static func pausedAndWaiting() throws {
        let (calendar, now) = fixture()
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.pause(for: 30, at: now, uptime: 0, calendar: calendar)
        var status = MenuBarStatus(schedule: schedule, canPresentReminder: true)
        try expect(status.phase == .paused && status.remainingMinutes == nil
                   && status.title(showMinutes: true) == "暂停", "Paused state looks like an active countdown")
        schedule.resume(at: now, uptime: 0, calendar: calendar)
        schedule.reminderDidStart()
        status = MenuBarStatus(schedule: schedule, canPresentReminder: true)
        try expect(status.phase == .waiting && status.title(showMinutes: true) == "喝水",
                   "A pending reminder did not become the confirmation state")
        schedule.snooze(minutes: 10, at: now, uptime: 0, calendar: calendar)
        status = MenuBarStatus(schedule: schedule, canPresentReminder: true)
        try expect(status.phase == .snoozed && status.remainingMinutes == 10,
                   "The snoozed menu lost its short active interval")
        status = MenuBarStatus(schedule: schedule, canPresentReminder: false)
        try expect(status.phase == .paused, "Inactive displays look like a running countdown")
    }

    private static func resting() throws {
        let (calendar, morning) = fixture()
        let schedule = ReminderSchedule(now: morning.addingTimeInterval(14 * 3_600), uptime: 0, calendar: calendar)
        let status = MenuBarStatus(schedule: schedule, canPresentReminder: true)
        try expect(status.phase == .resting && status.remainingMinutes == nil
                   && status.title(showMinutes: false).isEmpty, "Closed hours did not produce the quiet menu state")
        let insufficient = ReminderSchedule(now: morning.addingTimeInterval(12 * 3_600), uptime: 0, calendar: calendar)
        let finished = MenuBarStatus(schedule: insufficient, canPresentReminder: true)
        try expect(insufficient.isCounting && finished.phase == .finishedForToday
                   && finished.label == "今天不再提醒" && finished.title(showMinutes: true) == "明天见",
                   "Insufficient remaining work time was confused with a rest gap")
    }
}
