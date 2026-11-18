import Foundation
import BigWaterCore

/// A countdown and the clock it is driven by.
@MainActor
private struct Timeline {
    var clock: TestClock
    var schedule: Schedule

    /// Two-hour interval, 06:00–22:00, starting on Thursday the 15th.
    init(at start: Date = october(15, 9), plan: Schedule.Plan = .init()) {
        clock = TestClock(date: start)
        schedule = Schedule(plan: plan, now: clock.moment, calendar: shanghai)
    }

    /// The person uses the Mac for a while.
    mutating func use(_ seconds: TimeInterval, idle: TimeInterval? = 0) {
        clock.pass(seconds)
        schedule.advance(to: clock.moment, idle: idle, calendar: shanghai)
    }

    mutating func use(until date: Date) { use(date.timeIntervalSince(clock.date)) }

    /// The display goes dark, time passes, and it comes back.
    mutating func sleep(_ seconds: TimeInterval) {
        schedule.advance(to: clock.moment, awake: false, calendar: shanghai)
        clock.pass(seconds)
        schedule.advance(to: clock.moment, awake: true, calendar: shanghai)
    }

    /// Runs the countdown out and puts the reminder up.
    mutating func remind() {
        use(schedule.remaining)
        expect(schedule.isDue, "the countdown should be due")
        schedule.reminderShown()
    }

    /// Quits and starts again after `offline` seconds.
    mutating func relaunch(after offline: TimeInterval = 0, plan: Schedule.Plan? = nil) {
        let saved = schedule.progress(at: clock.moment, calendar: shanghai)
        clock.date = clock.date.addingTimeInterval(offline)
        // A restart may come with a reboot: the monotonic clock starts over.
        clock.uptime = 40
        schedule = Schedule(plan: plan ?? schedule.plan, now: clock.moment, calendar: shanghai, saved: saved)
    }
}

private let splitDay = WeekHours(weekday: DayHours([Period(start: 540, end: 720), Period(start: 840, end: 1_320)]))

@MainActor
let scheduleSuite = Suite(name: "schedule", tests: [
    test("counts use of the Mac, not time on the wall") {
        var t = Timeline()
        t.use(45 * minute)
        t.sleep(3 * hour)
        expectEqual(t.schedule.remaining, 75 * minute, "three hours asleep must not count")
        expectEqual(t.schedule.fireDate, october(15, 14), "45 minutes used, 3 hours asleep, 75 minutes to go")
    },

    test("is due after one interval of use and waits for an answer") {
        var t = Timeline()
        t.use(2 * hour - 1)
        expect(!t.schedule.isDue)
        t.use(1)
        expect(t.schedule.isDue)
        t.schedule.reminderShown()
        expectEqual(t.schedule.stage, .waiting)
        expectEqual(t.schedule.status, .waiting)
        // An unanswered reminder does not start the next countdown.
        t.use(5 * hour)
        expectEqual(t.schedule.stage, .waiting)
        expect(!t.schedule.isDue)
        t.schedule.recordDrink(at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.stage, .counting)
        expectEqual(t.schedule.remaining, 2 * hour, "a drink starts a whole interval")
    },

    test("a drink without a reminder restarts the interval") {
        var t = Timeline()
        t.use(90 * minute)
        t.schedule.recordDrink(at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.fireDate, october(15, 12, 30))
    },

    test("does not remind when today's hours end first") {
        var t = Timeline(at: october(15, 20, 30))
        expectEqual(t.schedule.status, .doneForToday)
        expectEqual(t.schedule.fireDate, nil)
        // Exactly enough room is not enough: it would land on closing time.
        t = Timeline(at: october(15, 20))
        expectEqual(t.schedule.fireDate, nil)
        t = Timeline(at: october(15, 19, 59))
        expectEqual(t.schedule.fireDate, october(15, 21, 59))
    },

    test("rests outside the hours and starts each day with a whole interval") {
        var t = Timeline(at: october(15, 21))
        t.use(30 * minute)
        expectEqual(t.schedule.remaining, 90 * minute)
        t.use(until: october(15, 23))
        expectEqual(t.schedule.status, .resting)
        expectEqual(t.schedule.remaining, 60 * minute, "counted up to 22:00 and no further")
        expectEqual(t.schedule.nextBoundary, october(16, 6))
        t.use(until: october(16, 6))
        expectEqual(t.schedule.remaining, 2 * hour, "a new day starts with a whole interval")
        expectEqual(t.schedule.fireDate, october(16, 8))
    },

    test("a rest between two periods pauses the countdown and keeps it") {
        var t = Timeline(at: october(15, 11), plan: .init(hours: splitDay))
        expectEqual(t.schedule.fireDate, october(15, 15), "one hour before the rest, one after")
        t.use(until: october(15, 13))
        expectEqual(t.schedule.window, .gap)
        expectEqual(t.schedule.status, .resting)
        expectEqual(t.schedule.remaining, hour)
        t.use(until: october(15, 14, 30))
        expectEqual(t.schedule.remaining, 30 * minute)
    },

    test("due exactly as a period closes comes when the next one opens") {
        let t = Timeline(at: october(15, 10), plan: .init(hours: splitDay))
        expectEqual(t.schedule.fireDate, october(15, 14))
    },

    test("an unanswered reminder returns after a rest and is dropped overnight") {
        var t = Timeline(at: october(15, 9), plan: .init(hours: splitDay))
        t.remind()
        t.use(until: october(15, 12, 30))
        expectEqual(t.schedule.stage, .counting, "the reminder is taken down for the rest")
        expectEqual(t.schedule.remaining, 0)
        t.use(until: october(15, 14))
        expect(t.schedule.isDue, "and offered again when the next period opens")

        t.schedule.reminderShown()
        t.use(until: october(15, 22, 30))
        expectEqual(t.schedule.stage, .counting)
        expectEqual(t.schedule.remaining, 2 * hour, "after the last period it is simply dropped")
    },

    test("a reminder that sat through a rest unseen is offered again") {
        var t = Timeline(at: october(15, 9), plan: .init(hours: splitDay))
        t.remind()
        // The Mac slept from before the rest until after it.
        t.sleep(october(15, 15).timeIntervalSince(t.clock.date))
        expect(t.schedule.isDue)
    },

    test("later puts a waiting reminder off without changing the interval") {
        var t = Timeline()
        t.schedule.snooze(minutes: 10, at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.stage, .counting, "nothing to put off yet")
        t.remind()
        t.schedule.snooze(minutes: 10, at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.status, .snoozed)
        t.use(10 * minute)
        expect(t.schedule.isDue)
        t.schedule.reminderShown()
        t.schedule.recordDrink(at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.remaining, 2 * hour)
    },

    test("a pause holds the countdown and ends on its own") {
        var t = Timeline()
        t.use(30 * minute)
        t.schedule.pause(minutes: 30, at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.status, .paused)
        expectEqual(t.schedule.pausedUntil, october(15, 10))
        expectEqual(t.schedule.nextWake, october(15, 10), "wake up to end the pause")
        t.use(20 * minute)
        expectEqual(t.schedule.remaining, 90 * minute)
        t.use(20 * minute)
        expect(!t.schedule.isPaused)
        expectEqual(t.schedule.remaining, 80 * minute, "only the ten minutes after the pause count")
    },

    test("a pause does not care what the wall clock is set to") {
        var t = Timeline()
        t.schedule.pause(minutes: 30, at: t.clock.moment, calendar: shanghai)
        t.clock.setWallClock(to: october(15, 13))
        t.use(10 * minute)
        expect(t.schedule.isPaused, "ten real minutes in, whatever the clock says")
        expectEqual(t.schedule.pausedUntil, october(15, 13, 30))
        t.use(20 * minute)
        expect(!t.schedule.isPaused)
    },

    test("pausing under a reminder brings it straight back afterwards") {
        var t = Timeline()
        t.remind()
        t.schedule.pause(minutes: 30, at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.stage, .counting)
        t.schedule.resume(at: t.clock.moment, calendar: shanghai)
        expect(t.schedule.isDue)
    },

    test("setting the system time does not move the countdown") {
        var t = Timeline()
        t.use(30 * minute)
        t.clock.setWallClock(to: october(15, 12))
        t.use(30 * minute)
        expectEqual(t.schedule.remaining, hour, "an hour of real use, whatever the clock jumped to")
        t.clock.setWallClock(to: october(15, 10))
        t.use(30 * minute)
        expectEqual(t.schedule.remaining, 30 * minute)
    },

    test("stops counting once the person has been away for the threshold") {
        var t = Timeline(plan: .init(awayAfter: 5 * minute))
        t.use(10 * minute)
        // Twenty minutes with no input: the first five still count.
        t.use(20 * minute, idle: 20 * minute)
        expect(t.schedule.isAway)
        expectEqual(t.schedule.status, .away)
        expectEqual(t.schedule.remaining, 105 * minute)
        t.use(hour, idle: 80 * minute)
        expectEqual(t.schedule.remaining, 105 * minute, "nothing counts while away")
        // A key is pressed just as the app looks again.
        t.use(10 * minute, idle: 0)
        expect(!t.schedule.isAway)
        expectEqual(t.schedule.remaining, 105 * minute, "the absence ended at that key press")
        t.use(10 * minute)
        expectEqual(t.schedule.remaining, 95 * minute)
    },

    test("counts from the input that ended the absence, not from when it was noticed") {
        var t = Timeline(plan: .init(awayAfter: 5 * minute))
        t.use(30 * minute, idle: 30 * minute)
        expectEqual(t.schedule.remaining, 115 * minute)
        // The app looks again a minute later; the person came back 20 seconds ago.
        t.use(60, idle: 20)
        expectEqual(t.schedule.remaining, 115 * minute - 20, "only the time since the returning input")
    },

    test("someone away stays away until a reading shows input") {
        var t = Timeline(plan: .init(awayAfter: 5 * minute))
        t.use(30 * minute, idle: 30 * minute)
        t.use(10 * minute, idle: nil)
        expect(t.schedule.isAway)
        expectEqual(t.schedule.remaining, 115 * minute)
        expect(!t.schedule.isDue)
    },

    test("no reminder appears while the person is away") {
        var t = Timeline(plan: .init(intervalHours: 5.0 / 60, awayAfter: 3 * minute))
        t.use(4 * minute)
        t.use(10 * minute, idle: 10 * minute)
        expectEqual(t.schedule.remaining, 0, "the interval ran out before the threshold")
        expect(!t.schedule.isDue, "but nobody is there to see a reminder")
        t.use(5, idle: 0)
        expect(t.schedule.isDue)
    },

    test("turning away detection off ends an absence") {
        var t = Timeline(plan: .init(awayAfter: 5 * minute))
        t.use(30 * minute, idle: 30 * minute)
        t.schedule.adopt(.init(awayAfter: nil), at: t.clock.moment, calendar: shanghai)
        expect(!t.schedule.isAway)
        expect(t.schedule.isRunning)
    },

    test("a new interval keeps the use already counted") {
        var t = Timeline()
        t.use(50 * minute)
        t.schedule.adopt(.init(intervalHours: 3), at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.remaining, 130 * minute)
        t.schedule.adopt(.init(intervalHours: 2), at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.remaining, 70 * minute, "longer then shorter changes nothing")
        t.schedule.adopt(.init(intervalHours: 0.5), at: t.clock.moment, calendar: shanghai)
        expect(t.schedule.isDue, "already past the shorter interval")
    },

    test("a paused countdown never outlasts a shortened interval") {
        var t = Timeline()
        t.use(10 * minute)
        t.schedule.pause(minutes: 30, at: t.clock.moment, calendar: shanghai)
        t.schedule.adopt(.init(intervalHours: 0.5), at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.remaining, 30 * minute, "not the 110 minutes of the old interval")
        // A reminder waiting behind a pause still comes back at once.
        t = Timeline()
        t.remind()
        t.schedule.pause(minutes: 30, at: t.clock.moment, calendar: shanghai)
        t.schedule.adopt(.init(intervalHours: 3), at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.remaining, 0)
    },

    test("out-of-range plans are put back in range") {
        let t = Timeline(plan: .init(intervalHours: 99, hours: WeekHours(weekday: DayHours([])), awayAfter: 5))
        expectEqual(t.schedule.plan.intervalHours, 24)
        expectEqual(t.schedule.plan.hours.weekday, .standard)
        expectEqual(t.schedule.plan.awayAfter, 60, "a threshold under a minute would flicker")
        expectEqual(Schedule.Plan.validHours(.nan), 2)
        expectEqual(Schedule.Plan.validHours(0), 5.0 / 60)
    },

    test("new hours apply at once") {
        var t = Timeline(at: october(15, 13))
        expect(t.schedule.isRunning)
        t.schedule.adopt(.init(hours: splitDay), at: t.clock.moment, calendar: shanghai)
        expectEqual(t.schedule.window, .gap)
        expect(!t.schedule.isRunning)
    },

    test("weekends can have their own hours, by the calendar's idea of a weekend") {
        let hours = WeekHours(weekday: .standard, weekend: DayHours([Period(start: 600, end: 720)]))
        var t = Timeline(at: october(16, 9), plan: .init(hours: hours))
        expect(t.schedule.isRunning, "Friday morning is a weekday")
        t.use(until: october(17, 9))
        expectEqual(t.schedule.status, .resting, "Saturday starts at ten")
        expectEqual(t.schedule.nextBoundary, october(17, 10))
    },

    test("a restart the same day carries on and never counts time spent closed") {
        var t = Timeline()
        t.use(45 * minute)
        t.relaunch(after: 2 * hour)
        expectEqual(t.schedule.remaining, 75 * minute)
        expectEqual(t.schedule.fireDate, october(15, 13))
    },

    test("a restart keeps a reminder, a later and a pause") {
        var t = Timeline()
        t.remind()
        t.relaunch(after: 10 * minute)
        expectEqual(t.schedule.stage, .waiting, "the reminder is still owed")

        t.schedule.snooze(minutes: 20, at: t.clock.moment, calendar: shanghai)
        t.use(5 * minute)
        t.relaunch()
        expectEqual(t.schedule.status, .snoozed)
        expectEqual(t.schedule.remaining, 15 * minute)

        t.schedule.pause(minutes: 60, at: t.clock.moment, calendar: shanghai)
        let until = t.schedule.pausedUntil
        t.relaunch(after: 20 * minute)
        expect(abs(t.schedule.pausedUntil!.timeIntervalSince(until!)) < 0.001, "the pause ends when it was going to")
        t.use(41 * minute)
        expect(!t.schedule.isPaused)
    },

    test("a save from another day, zone or plan starts a whole interval") {
        var t = Timeline()
        t.use(45 * minute)
        t.relaunch(after: 24 * hour)
        expectEqual(t.schedule.remaining, 2 * hour, "yesterday's countdown")

        t.use(45 * minute)
        t.relaunch(plan: .init(intervalHours: 1))
        expectEqual(t.schedule.remaining, hour, "a different interval")

        t.use(15 * minute)
        let saved = t.schedule.progress(at: t.clock.moment, calendar: shanghai)
        var tokyo = shanghai
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let moved = Schedule(plan: t.schedule.plan, now: t.clock.moment, calendar: tokyo, saved: saved)
        expectEqual(moved.remaining, hour, "a different time zone")
    },

    test("a save cannot come from the future or carry nonsense") {
        var t = Timeline()
        t.use(45 * minute)
        var saved = t.schedule.progress(at: t.clock.moment, calendar: shanghai)
        let earlier = Moment(date: october(15, 9, 30), uptime: 1)
        expectEqual(Schedule(now: earlier, calendar: shanghai, saved: saved).remaining, 2 * hour)
        saved.remainingTime = .infinity
        expectEqual(Schedule(now: t.clock.moment, calendar: shanghai, saved: saved).remaining, 2 * hour)
        saved.remainingTime = -5
        expectEqual(Schedule(now: t.clock.moment, calendar: shanghai, saved: saved).remaining, 0)
    },

    test("a reminder saved before a rest is offered again after it") {
        var t = Timeline(at: october(15, 9), plan: .init(hours: splitDay))
        t.remind()
        t.relaunch(after: october(15, 13).timeIntervalSince(t.clock.date))
        expectEqual(t.schedule.stage, .counting)
        expectEqual(t.schedule.remaining, 0)
        t.use(until: october(15, 14))
        expect(t.schedule.isDue)
    },

    test("asleep, there is nothing to wake up for") {
        var t = Timeline()
        expectEqual(t.schedule.nextWake, october(15, 11))
        t.schedule.advance(to: t.clock.moment, awake: false, calendar: shanghai)
        expectEqual(t.schedule.nextWake, nil)
        expectEqual(t.schedule.status, .asleep)
    },

    test("follows the time zone it is given") {
        var t = Timeline(at: october(15, 21))
        var newYork = shanghai
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // 21:00 in Shanghai is 09:00 the same day in New York.
        t.schedule.advance(to: t.clock.moment, calendar: newYork)
        expectEqual(t.schedule.fireDate, t.clock.date.addingTimeInterval(2 * hour))
    },

    test("says what is going on in words") {
        var t = Timeline()
        var text = StatusText(t.schedule, now: t.clock.date, calendar: shanghai)
        expectEqual(text.title, "距离下次提醒")
        expectEqual(text.menuTitle, "120分")
        expectEqual(text.countdown(t.schedule.remaining), "02:00:00")
        expectEqual(text.countdown(59.2), "00:01:00", "rounds up, so it never shows zero early")
        t.remind()
        text = StatusText(t.schedule, now: t.clock.date, calendar: shanghai)
        expectEqual(text.replacement, "喝口水吧")
        expectEqual(text.menuTitle, "喝水")
        expectEqual(text.remainingMinutes, nil)
        t.use(until: october(15, 23))
        text = StatusText(t.schedule, now: t.clock.date, calendar: shanghai)
        expectEqual(text.label, "休息中")
        expect(text.detail.hasPrefix("本地"), "tomorrow's opening is named as such: \(text.detail)")
    }
])
