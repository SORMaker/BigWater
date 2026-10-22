import Foundation
import BigWaterCore

struct SegmentedScheduleChecks {
    private static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    private static func date(_ day: Int = 15, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day,
                                           hour: hour, minute: minute))!
    }

    private static let periods = DailyHours(periods: [
        ReminderPeriod(startMinutes: 6 * 60, endMinutes: 12 * 60),
        ReminderPeriod(startMinutes: 13 * 60, endMinutes: 18 * 60)
    ])

    static let checks: [(String, () throws -> Void)] = [
        ("segmented: legacy API and Codable migration", legacyAPIAndCodableMigration),
        ("segmented: custom period names survive saving", namedPeriodsSurviveSaving),
        ("segmented: validate ordered non-overlapping periods", validatePeriods),
        ("segmented: count use and project reminders across gaps", countAndProjectAcrossGaps),
        ("segmented: re-offer pending reminders after gaps", reofferAfterGap),
        ("segmented: clock jumps retire pending reminders across gaps", pendingClockJump),
        ("segmented: preserve pause and snooze through gaps", pauseAndSnoozeAcrossGap),
        ("segmented: sleep through a rest gap", sleepAtGap),
        ("segmented: restore same-day gap progress and old snapshots", restoreGapAndLegacySnapshot),
        ("segmented: delayed callbacks and new-day reset", delayedCallbacksAndNewDay),
        ("segmented: delayed callback resumes from a gap", delayedCallbackFromGap),
        ("segmented: delayed callback counts after pause expiry", delayedPauseExpiry),
        ("segmented: lenient menu countdown preference", lenientCountdownPreference)
    ]

    private static func legacyAPIAndCodableMigration() throws {
        let legacy = DailyHours(startMinutes: 8 * 60, endMinutes: 20 * 60)
        try expect(legacy.periods == [ReminderPeriod(startMinutes: 480, endMinutes: 1_200)],
                   "Legacy initializer did not create one period")
        var editable = DailyHours(periods: [
            ReminderPeriod(startMinutes: 360, endMinutes: 600),
            ReminderPeriod(startMinutes: 720, endMinutes: 1_080)
        ])
        try expect(editable.startMinutes == 360 && editable.endMinutes == 1_080,
                   "Legacy accessors do not expose the outer bounds")
        editable.startMinutes = 420
        editable.endMinutes = 1_140
        try expect(editable.periods[0].startMinutes == 420
                   && editable.periods[1].endMinutes == 1_140,
                   "Legacy accessors did not update the outer periods")

        let data = #"{"startMinutes":480,"endMinutes":1200}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DailyHours.self, from: data)
        try expect(decoded == legacy, "Legacy start/end JSON did not migrate")
        let encoded = try JSONEncoder().encode(periods)
        let roundTrip = try JSONDecoder().decode(DailyHours.self, from: encoded)
        try expect(roundTrip == periods && roundTrip.startMinutes == 360 && roundTrip.endMinutes == 1_080,
                   "Segmented periods did not survive Codable round-trip")
    }

    private static func validatePeriods() throws {
        try expect(periods.isValid, "Valid separated periods were rejected")
        try expect(DailyHours(periods: []).isValid == false, "Empty schedule was accepted")
        try expect(DailyHours(periods: [ReminderPeriod(startMinutes: -1, endMinutes: 60)]).isValid == false,
                   "Negative period start was accepted")
        try expect(DailyHours(periods: [ReminderPeriod(startMinutes: 60, endMinutes: 60)]).isValid == false,
                   "Zero-length period was accepted")
        try expect(DailyHours(periods: [ReminderPeriod(startMinutes: 60, endMinutes: 80),
                                        ReminderPeriod(startMinutes: 79, endMinutes: 100)]).isValid == false,
                   "Overlapping periods were accepted")
        try expect(DailyHours(periods: [ReminderPeriod(startMinutes: 120, endMinutes: 180),
                                        ReminderPeriod(startMinutes: 60, endMinutes: 90)]).isValid == false,
                   "Unordered periods were accepted")
        try expect(DailyHours(periods: [ReminderPeriod(startMinutes: 1_380, endMinutes: 1_440)]).isValid,
                   "A period ending at midnight was rejected")
    }

    private static func namedPeriodsSurviveSaving() throws {
        let morning = ReminderPeriod(startMinutes: 360, endMinutes: 720, name: "上午学习")
        let afternoon = ReminderPeriod(startMinutes: 780, endMinutes: 1_080, name: "下午工作")
        for namedHours in [DailyHours(periods: [morning]), DailyHours(periods: [morning, afternoon])] {
            var preferences = AppPreferences()
            preferences.weekdayHours = namedHours
            preferences.weekendHours = DailyHours(periods: [
                ReminderPeriod(startMinutes: 600, endMinutes: 1_200, name: "周末")
            ])
            let data = try JSONEncoder().encode(preferences)
            let restored = try JSONDecoder().decode(AppPreferences.self, from: data).validated()
            try expect(restored == preferences, "Saving discarded period names or changed their times")
        }

        let oldData = #"{"periods":[{"startMinutes":360,"endMinutes":720},{"startMinutes":780,"endMinutes":1080}],"startMinutes":360,"endMinutes":1080}"#.data(using: .utf8)!
        let oldHours = try JSONDecoder().decode(DailyHours.self, from: oldData)
        try expect(oldHours == periods, "Existing unnamed periods did not remain readable")
    }

    private static func countAndProjectAcrossGaps() throws {
        var schedule = ReminderSchedule(hours: 2, now: date(15, 11, 30), uptime: 0,
                                        calendar: calendar, weekdayHours: periods)
        try expect(schedule.nextBoundaryAt == date(15, 12), "First closing boundary was skipped")
        try expect(schedule.nextReminderAt == date(15, 14, 30),
                   "Projected deadline did not skip the rest gap")

        schedule.update(at: date(15, 12), uptime: 1_800, calendar: calendar)
        try expect(!schedule.isWithinReminderHours && schedule.remainingTime == 5_400,
                   "Closing the first period consumed rest-gap time")
        try expect(schedule.nextBoundaryAt == date(15, 13), "Gap boundary did not point to reopening")
        try expect(schedule.nextReminderAt == nil, "A closed-period reminder was scheduled")

        schedule.update(at: date(15, 13), uptime: 5_400, calendar: calendar)
        try expect(schedule.isCounting && schedule.remainingTime == 5_400,
                   "Opening the next period reset or consumed progress")
        try expect(schedule.nextReminderAt == date(15, 14, 30),
                   "Countdown did not resume after the gap")
        schedule.update(at: date(15, 14, 30), uptime: 10_800, calendar: calendar)
        try expect(schedule.isDue, "Reminder did not become due after resumed active use")

        let closesAtFinalBoundary = ReminderSchedule(
            hours: 2, now: date(15, 16), uptime: 0, calendar: calendar, weekdayHours: periods
        )
        try expect(closesAtFinalBoundary.nextReminderAt == nil,
                   "A reminder was scheduled exactly at the final close")
    }

    private static func reofferAfterGap() throws {
        var schedule = ReminderSchedule(now: date(15, 11, 30), uptime: 0,
                                        calendar: calendar, weekdayHours: periods)
        schedule.reminderDidStart()
        try expect(schedule.isAwaitingAcknowledgment, "Reminder did not become pending")
        schedule.update(at: date(15, 12), uptime: 1_800, calendar: calendar)
        try expect(!schedule.isWithinReminderHours && !schedule.isAwaitingAcknowledgment
                   && schedule.remainingTime == 0,
                   "Pending reminder was not suspended at the gap")
        schedule.update(at: date(15, 13), uptime: 5_400, calendar: calendar)
        try expect(schedule.isDue && !schedule.isAwaitingAcknowledgment,
                   "Pending reminder was not re-offered at the next opening")

        var delayed = ReminderSchedule(now: date(15, 11, 30), uptime: 0,
                                       calendar: calendar, weekdayHours: periods)
        delayed.reminderDidStart()
        delayed.update(at: date(15, 13, 10), uptime: 6_000, calendar: calendar)
        try expect(delayed.isDue && !delayed.isAwaitingAcknowledgment,
                   "A delayed callback carried a stale reminder overlay through the gap")
    }

    private static func pendingClockJump() throws {
        var pending = ReminderSchedule(now: date(15, 11, 50), uptime: 0,
                                       calendar: calendar, weekdayHours: periods)
        pending.reminderDidStart()
        pending.update(at: date(15, 13, 10), uptime: 0, calendar: calendar)
        try expect(pending.isDue && !pending.isAwaitingAcknowledgment,
                   "A wall-clock jump carried a pending reminder across the rest gap")

        var samePeriod = ReminderSchedule(now: date(15, 9), uptime: 0,
                                          calendar: calendar, weekdayHours: periods)
        samePeriod.reminderDidStart()
        samePeriod.update(at: date(15, 11), uptime: 60, calendar: calendar)
        try expect(samePeriod.isAwaitingAcknowledgment,
                   "A clock correction within one period retired a valid pending reminder")
    }

    private static func pauseAndSnoozeAcrossGap() throws {
        var paused = ReminderSchedule(now: date(15, 11, 30), uptime: 0,
                                      calendar: calendar, weekdayHours: periods)
        paused.update(at: date(15, 11, 30), uptime: 1_800, calendar: calendar)
        paused.pause(for: 60, at: date(15, 11, 30), uptime: 1_800, calendar: calendar)
        paused.update(at: date(15, 12, 30), uptime: 5_400, calendar: calendar)
        try expect(!paused.isManuallyPaused && paused.remainingTime == 5_400,
                   "Pause expiry during a gap consumed active time")
        paused.update(at: date(15, 13), uptime: 7_200, calendar: calendar)
        try expect(paused.nextReminderAt == date(15, 14, 30),
                   "Countdown did not resume after a pause expired in the gap")

        var snoozed = ReminderSchedule(now: date(15, 11, 30), uptime: 0,
                                       calendar: calendar, weekdayHours: periods)
        snoozed.reminderDidStart()
        snoozed.snooze(minutes: 45, at: date(15, 11, 30), uptime: 0, calendar: calendar)
        snoozed.update(at: date(15, 12), uptime: 1_800, calendar: calendar)
        try expect(snoozed.isSnoozed && snoozed.remainingTime == 900,
                   "Snooze did not retain its active-time remainder at the gap")
        snoozed.update(at: date(15, 13, 10), uptime: 6_000, calendar: calendar)
        try expect(snoozed.isSnoozed && snoozed.nextReminderAt == date(15, 13, 15),
                   "Snooze countdown did not resume in the next period")
    }

    private static func sleepAtGap() throws {
        var schedule = ReminderSchedule(now: date(15, 11, 30), uptime: 0,
                                        calendar: calendar, weekdayHours: periods)
        schedule.update(at: date(15, 11, 45), uptime: 900, calendar: calendar)
        schedule.update(at: date(15, 12), uptime: 1_800,
                        isSessionActive: false, calendar: calendar)
        schedule.update(at: date(15, 12, 30), uptime: 3_600,
                        isSessionActive: false, calendar: calendar)
        schedule.update(at: date(15, 13), uptime: 5_400,
                        isSessionActive: true, calendar: calendar)
        try expect(schedule.remainingTime == 5_400
                   && schedule.nextReminderAt == date(15, 14, 30),
                   "Sleep or the rest gap consumed saved active-period progress")
    }

    private static func restoreGapAndLegacySnapshot() throws {
        var active = ReminderSchedule(now: date(15, 11, 30), uptime: 0,
                                      calendar: calendar, weekdayHours: periods)
        active.update(at: date(15, 11, 45), uptime: 900, calendar: calendar)
        let saved = active.snapshot(at: date(15, 11, 45), uptime: 900, calendar: calendar)
        let restoredInGap = ReminderSchedule(now: date(15, 12, 30), uptime: 50_000,
                                             calendar: calendar, weekdayHours: periods,
                                             snapshot: saved)
        try expect(!restoredInGap.isWithinReminderHours && restoredInGap.remainingTime == 6_300,
                   "Same-day gap restore lost saved progress")
        try expect(restoredInGap.nextBoundaryAt == date(15, 13),
                   "Restored gap did not retain the next opening")

        let restoredAtOpen = ReminderSchedule(now: date(15, 13), uptime: 60_000,
                                              calendar: calendar, weekdayHours: periods,
                                              snapshot: saved)
        try expect(restoredAtOpen.remainingTime == 6_300
                   && restoredAtOpen.nextReminderAt == date(15, 14, 45),
                   "Offline gap time consumed restored progress")

        let capturedDay = calendar.dateComponents([.era, .year, .month, .day], from: date())
        let legacySnapshot: [String: Any] = [
            "capturedAt": date().timeIntervalSinceReferenceDate,
            "capturedDay": ["era": capturedDay.era!, "year": capturedDay.year!,
                            "month": capturedDay.month!, "day": capturedDay.day!],
            "timeZoneIdentifier": "Asia/Shanghai",
            "intervalHours": 2,
            "weekdayHours": ["startMinutes": 360, "endMinutes": 1_320],
            "remainingTime": 4_500,
            "isAwaitingAcknowledgment": false,
            "isSnoozed": false
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacySnapshot)
        let decoded = try JSONDecoder().decode(ReminderSnapshot.self, from: legacyData)
        try expect(decoded.weekdayHours == DailyHours() && decoded.remainingTime == 4_500,
                   "Legacy single-window snapshot did not migrate")
    }

    private static func delayedCallbacksAndNewDay() throws {
        let threePeriods = DailyHours(periods: [
            ReminderPeriod(startMinutes: 6 * 60, endMinutes: 9 * 60),
            ReminderPeriod(startMinutes: 10 * 60, endMinutes: 12 * 60),
            ReminderPeriod(startMinutes: 14 * 60, endMinutes: 18 * 60)
        ])
        var delayed = ReminderSchedule(hours: 2, now: date(15, 8, 30), uptime: 0,
                                       calendar: calendar, weekdayHours: threePeriods)
        delayed.update(at: date(15, 14, 30), uptime: 21_600, calendar: calendar)
        try expect(delayed.remainingTime == 0 && delayed.isDue,
                   "Delayed callback failed to account across multiple periods")

        var nextDay = ReminderSchedule(now: date(15, 17, 30), uptime: 0,
                                       calendar: calendar, weekdayHours: periods)
        nextDay.update(at: date(16, 6), uptime: 45_000, calendar: calendar)
        try expect(nextDay.remainingTime == 7_200 && nextDay.nextReminderAt == date(16, 8),
                   "New local day did not reset the full interval")

        var clockChange = ReminderSchedule(hours: 2, now: date(15, 11, 30), uptime: 0,
                                           calendar: calendar, weekdayHours: periods)
        clockChange.update(at: date(15, 16), uptime: 600, calendar: calendar)
        try expect(clockChange.remainingTime == 6_600,
                   "A wall-clock jump consumed the rest gap as active use")
    }

    private static func delayedCallbackFromGap() throws {
        var schedule = ReminderSchedule(hours: 2, now: date(15, 12), uptime: 0,
                                        calendar: calendar, weekdayHours: periods)
        try expect(!schedule.isWithinReminderHours && schedule.nextBoundaryAt == date(15, 13),
                   "Schedule did not begin in the configured rest gap")
        schedule.update(at: date(15, 14), uptime: 7_200, calendar: calendar)
        try expect(schedule.remainingTime == 3_600 && schedule.nextReminderAt == date(15, 15),
                   "A delayed callback skipped active use after the next opening")
    }

    private static func delayedPauseExpiry() throws {
        var acrossGap = ReminderSchedule(now: date(15, 11), uptime: 0,
                                         calendar: calendar, weekdayHours: periods)
        acrossGap.update(at: date(15, 11, 30), uptime: 1_800, calendar: calendar)
        acrossGap.pause(for: 60, at: date(15, 11, 30), uptime: 1_800, calendar: calendar)
        acrossGap.update(at: date(15, 13, 30), uptime: 9_000, calendar: calendar)
        try expect(!acrossGap.isManuallyPaused && acrossGap.remainingTime == 3_600
                   && acrossGap.nextReminderAt == date(15, 14, 30),
                   "A delayed callback did not count active use after pause expiry and reopening")

        let allDay = DailyHours(startMinutes: 6 * 60, endMinutes: 18 * 60)
        var withinPeriod = ReminderSchedule(now: date(15, 9), uptime: 0,
                                            calendar: calendar, weekdayHours: allDay)
        withinPeriod.update(at: date(15, 9, 30), uptime: 1_800, calendar: calendar)
        withinPeriod.pause(for: 30, at: date(15, 9, 30), uptime: 1_800, calendar: calendar)
        withinPeriod.update(at: date(15, 11), uptime: 7_200, calendar: calendar)
        try expect(withinPeriod.remainingTime == 1_800
                   && withinPeriod.nextReminderAt == date(15, 11, 30),
                   "A delayed callback did not count active use after same-period pause expiry")

        var screenWentDark = ReminderSchedule(now: date(15, 11), uptime: 0,
                                              calendar: calendar, weekdayHours: periods)
        screenWentDark.update(at: date(15, 11, 30), uptime: 1_800, calendar: calendar)
        screenWentDark.pause(for: 60, at: date(15, 11, 30), uptime: 1_800, calendar: calendar)
        screenWentDark.update(at: date(15, 12), uptime: 3_600,
                              isSessionActive: false, calendar: calendar)
        screenWentDark.update(at: date(15, 13, 30), uptime: 9_000,
                              isSessionActive: true, calendar: calendar)
        try expect(screenWentDark.remainingTime == 5_400
                   && screenWentDark.nextReminderAt == date(15, 15),
                   "Inactive-screen time after pause expiry was counted")
    }

    private static func lenientCountdownPreference() throws {
        let enabled = #"{"showMenuBarCountdown":true}"#.data(using: .utf8)!
        let disabled = #"{"showMenuBarCountdown":"yes"}"#.data(using: .utf8)!
        let enabledPreferences = try JSONDecoder().decode(AppPreferences.self, from: enabled)
        let disabledPreferences = try JSONDecoder().decode(AppPreferences.self, from: disabled)
        try expect(enabledPreferences.showMenuBarCountdown,
                   "Menu countdown preference was not decoded")
        try expect(!disabledPreferences.showMenuBarCountdown,
                   "Mistyped menu countdown preference did not use the false default")
        try expect(!AppPreferences().showMenuBarCountdown,
                   "Menu countdown preference default changed")
    }
}
