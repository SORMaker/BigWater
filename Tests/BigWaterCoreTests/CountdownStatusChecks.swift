import Foundation
import BigWaterCore

enum CountdownStatusChecks {
    static let checks: [(String, () throws -> Void)] = [
        ("countdown status: counting, snoozed and finished", countingAndFinished),
        ("countdown status: rest, pause and sleep", restPauseAndSleep),
        ("countdown status: waiting for confirmation", waiting)
    ]

    private static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    private static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
    }

    private static func status(_ schedule: ReminderSchedule, at now: Date,
                               canPresentReminder: Bool = true) -> CountdownStatus {
        CountdownStatus(schedule: schedule, canPresentReminder: canPresentReminder, now: now, calendar: calendar)
    }

    private static func countingAndFinished() throws {
        var schedule = ReminderSchedule(now: date(15, 9), uptime: 0, calendar: calendar)
        var current = status(schedule, at: date(15, 9))
        try expect(current.title == "距离下次提醒" && current.replacement == nil
                   && current.detail == "下次提醒 \(time(date(15, 11))) · 休眠时暂停",
                   "A running countdown did not name its next reminder")

        schedule.reminderDidStart()
        schedule.snooze(minutes: 10, at: date(15, 9), uptime: 0, calendar: calendar)
        current = status(schedule, at: date(15, 9))
        try expect(current.title == "稍后提醒" && current.detail.contains(time(date(15, 9, 10))),
                   "A snooze did not read as a later reminder")

        let late = ReminderSchedule(now: date(15, 21), uptime: 0, calendar: calendar)
        current = status(late, at: date(15, 21))
        try expect(current.title == "今天不再提醒" && current.replacement == "明天见",
                   "Too little remaining time today did not end the day")
    }

    private static func restPauseAndSleep() throws {
        let night = ReminderSchedule(now: date(15, 23), uptime: 0, calendar: calendar)
        var current = status(night, at: date(15, 23))
        try expect(current.title == "休息时间" && current.replacement == "休息中"
                   && current.detail == "本地 \(time(date(16, 6))) 后使用电脑，开始新的计时",
                   "Night hours did not point to tomorrow's first period")

        let lunch = ReminderSchedule(now: date(15, 12, 30), uptime: 0, calendar: calendar,
                                     weekdayHours: DailyHours(periods: [
                                         ReminderPeriod(startMinutes: 540, endMinutes: 720),
                                         ReminderPeriod(startMinutes: 780, endMinutes: 1_080)
                                     ]))
        current = status(lunch, at: date(15, 12, 30))
        try expect(current.detail == "\(time(date(15, 13))) 后接着剩余时间继续计时",
                   "A same-day rest gap did not promise to continue")

        var paused = ReminderSchedule(now: date(15, 9), uptime: 0, calendar: calendar)
        paused.pause(for: 30, at: date(15, 9), uptime: 0, calendar: calendar)
        current = status(paused, at: date(15, 9))
        try expect(current.title == "计时已暂停" && current.replacement == nil
                   && current.detail == "\(time(date(15, 9, 30))) 自动恢复，保留当前剩余时间",
                   "A manual pause did not show when it ends")

        let asleep = ReminderSchedule(now: date(15, 9), uptime: 0, isSessionActive: false, calendar: calendar)
        current = status(asleep, at: date(15, 9), canPresentReminder: false)
        try expect(current.title == "休眠暂停", "A dark screen did not read as a sleep pause")
    }

    private static func waiting() throws {
        var schedule = ReminderSchedule(now: date(15, 9), uptime: 0, calendar: calendar)
        schedule.reminderDidStart()
        let current = status(schedule, at: date(15, 9))
        try expect(current.title == "等待你的确认" && current.replacement == "喝口水吧",
                   "A waiting reminder did not ask for confirmation")
    }
}
