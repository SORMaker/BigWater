import Foundation
import BigWaterCore

enum AwayChecks {
    static let checks: [(String, () throws -> Void)] = [
        ("away: idle past the threshold stops counting until input returns", pausesUntilReturn),
        ("away: short idle and a missing threshold count normally", shortIdleCounts),
        ("away: a check without a reading keeps the away state", missingReadingKeepsAway),
        ("away: no reminder becomes due while away", noReminderWhileAway),
        ("away: turning detection off resumes at once", turningOffResumes),
        ("away: menu and countdown card say why counting stopped", statusTexts),
        ("away: preferences default on and tolerate bad saves", lenientPreferences)
    ]

    private static func fixture() -> (Calendar, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return (calendar, calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))!)
    }

    private static func schedule(threshold: TimeInterval? = 300) -> (ReminderSchedule, Calendar, Date) {
        let (calendar, now) = fixture()
        return (ReminderSchedule(now: now, uptime: 0, calendar: calendar, awayThreshold: threshold),
                calendar, now)
    }

    /// Last input at 9:30, checks at 9:31 and 10:00, input again at 10:20.
    /// Only 9:00–9:35 and 10:20 onward are use.
    private static func pausesUntilReturn() throws {
        var (schedule, calendar, now) = schedule()
        schedule.update(at: now.addingTimeInterval(1_860), uptime: 1_860, idleTime: 60, calendar: calendar)
        try expect(!schedule.isAway && schedule.remainingTime == 7_200 - 1_860,
                   "One idle minute already stopped the countdown")
        schedule.update(at: now.addingTimeInterval(3_600), uptime: 3_600, idleTime: 1_800, calendar: calendar)
        try expect(schedule.isAway && !schedule.isCounting && schedule.remainingTime == 7_200 - 2_100,
                   "Away time after the threshold was counted, or the threshold minutes were lost")
        schedule.update(at: now.addingTimeInterval(4_800), uptime: 4_800, idleTime: 3_000, calendar: calendar)
        try expect(schedule.remainingTime == 7_200 - 2_100, "A second away reading counted time")
        schedule.update(at: now.addingTimeInterval(4_830), uptime: 4_830, idleTime: 30, calendar: calendar)
        try expect(!schedule.isAway && schedule.isCounting && schedule.remainingTime == 7_200 - 2_130,
                   "Returning did not resume counting from the input that ended the absence")
    }

    private static func shortIdleCounts() throws {
        var (away, calendar, now) = schedule()
        away.update(at: now.addingTimeInterval(1_800), uptime: 1_800, idleTime: 299, calendar: calendar)
        try expect(!away.isAway && away.remainingTime == 5_400, "Idle under the threshold stopped counting")
        var (off, _, _) = schedule(threshold: nil)
        off.update(at: now.addingTimeInterval(1_800), uptime: 1_800, idleTime: 1_800, calendar: calendar)
        try expect(!off.isAway && off.remainingTime == 5_400, "Detection that is off still paused")
    }

    private static func missingReadingKeepsAway() throws {
        var (schedule, calendar, now) = schedule()
        schedule.update(at: now.addingTimeInterval(600), uptime: 600, idleTime: 600, calendar: calendar)
        try expect(schedule.isAway && schedule.remainingTime == 6_900, "The fixture did not go away")
        schedule.update(at: now.addingTimeInterval(1_200), uptime: 1_200, calendar: calendar)
        try expect(schedule.isAway && schedule.remainingTime == 6_900,
                   "An update without an idle reading counted away time")
    }

    private static func noReminderWhileAway() throws {
        var (schedule, calendar, now) = schedule()
        schedule.update(at: now.addingTimeInterval(7_000), uptime: 7_000, idleTime: 600, calendar: calendar)
        schedule.update(at: now.addingTimeInterval(7_300), uptime: 7_300, idleTime: 900, calendar: calendar)
        try expect(schedule.isAway && !schedule.isDue && schedule.nextReminderAt == nil
                   && schedule.remainingTime == 500, "A reminder became due while nobody was there")
        let back = now.addingTimeInterval(9_000)
        schedule.update(at: back, uptime: 9_000, idleTime: 0, calendar: calendar)
        try expect(schedule.nextReminderAt == back.addingTimeInterval(500),
                   "The reminder was not rescheduled from the return")
    }

    private static func turningOffResumes() throws {
        var (schedule, calendar, now) = schedule()
        schedule.update(at: now.addingTimeInterval(600), uptime: 600, idleTime: 600, calendar: calendar)
        schedule.setAwayThreshold(nil, at: now.addingTimeInterval(900), uptime: 900, calendar: calendar)
        try expect(!schedule.isAway && schedule.isCounting && schedule.remainingTime == 6_900,
                   "Turning detection off did not resume, or counted the earlier absence")
        schedule.update(at: now.addingTimeInterval(1_500), uptime: 1_500, idleTime: 1_500, calendar: calendar)
        try expect(schedule.remainingTime == 6_300, "Detection turned off still ignored idle time")
    }

    private static func statusTexts() throws {
        var (schedule, calendar, now) = schedule()
        let later = now.addingTimeInterval(600)
        schedule.update(at: later, uptime: 600, idleTime: 600, calendar: calendar)
        let menu = MenuBarStatus(schedule: schedule, canPresentReminder: true)
        try expect(menu.phase == .away && menu.remainingMinutes == nil && menu.title(showMinutes: true) == "离开",
                   "The menu bar did not show the away pause")
        let card = CountdownStatus(schedule: schedule, canPresentReminder: true, now: later, calendar: calendar)
        try expect(card.title == "离开暂停", "The countdown card said \(card.title) while away")
        schedule.reminderDidStart()
        try expect(!schedule.isAwaitingAcknowledgment, "A reminder started while away")
    }

    private static func lenientPreferences() throws {
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"intervalHours":1}"#.utf8))
        try expect(old.pauseWhenAway && old.awayMinutes == 5 && old.awayThreshold == 300,
                   "A save from before away detection did not get the defaults")
        let odd = try JSONDecoder().decode(AppPreferences.self,
                                           from: Data(#"{"pauseWhenAway":"yes","awayMinutes":7}"#.utf8))
        try expect(odd.pauseWhenAway && odd.validated().awayMinutes == 5,
                   "Unreadable or unlisted away settings were kept")
        var off = AppPreferences()
        off.pauseWhenAway = false
        let saved = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(off))
        try expect(!saved.pauseWhenAway && saved.awayThreshold == nil, "Turning detection off was not saved")
    }
}
