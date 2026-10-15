import Foundation
import BigWaterCore
import BigWaterArt

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String,
            file: String = #filePath, line: Int = #line) throws {
    if !condition() { throw CheckFailure(description: "\(file):\(line): \(message)") }
}

struct ReminderChecks {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    private func date(_ day: Int = 15, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date() }

    func twoHourDefault() throws {
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.update(at: now.addingTimeInterval(7_199), uptime: 7_199, calendar: calendar)
        try expect(!schedule.isDue, "Reminder fired early")
        schedule.update(at: now.addingTimeInterval(7_200), uptime: 7_200, calendar: calendar)
        try expect(schedule.isDue, "Default is not two hours")
    }

    func sleepPreservesRemainingTime() throws {
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.update(at: date(15, 9, 45), uptime: 2_700, isSessionActive: false, calendar: calendar)
        try expect(schedule.remainingTime == 4_500, "Sleep did not save the remaining 75 minutes")
        try expect(schedule.nextReminderAt == nil && schedule.nextCheckAt == nil, "Sleep left an armed countdown")
        schedule.update(at: date(15, 10), uptime: 3_600, isSessionActive: false, calendar: calendar)
        schedule.update(at: date(15, 14), uptime: 18_000, isSessionActive: true, calendar: calendar)
        schedule.update(at: date(15, 14), uptime: 18_000, isSessionActive: true, calendar: calendar)
        try expect(!schedule.isDue && schedule.remainingTime == 4_500, "Sleep or duplicate notifications consumed time")
        try expect(schedule.nextReminderAt == date(15, 15, 15), "Wake did not resume the saved countdown")
        schedule.update(at: date(15, 15, 15), uptime: 22_500, calendar: calendar)
        try expect(schedule.isDue, "Resumed countdown never became due")
    }

    func overnightStartsAtFirstMorningUse() throws {
        var schedule = ReminderSchedule(now: date(15, 21), uptime: 0, calendar: calendar)
        schedule.update(at: date(15, 21, 30), uptime: 1_800, isSessionActive: false, calendar: calendar)
        schedule.update(at: date(16, 5), uptime: 28_800, isSessionActive: true, calendar: calendar)
        try expect(!schedule.isCounting && schedule.nextCheckAt == date(16, 6), "Counted before 06:00")
        schedule.update(at: date(16, 5, 10), uptime: 29_400, isSessionActive: false, calendar: calendar)
        schedule.update(at: date(16, 8, 15), uptime: 40_500, isSessionActive: true, calendar: calendar)
        try expect(schedule.remainingTime == 7_200, "Morning inherited yesterday's partial interval")
        try expect(schedule.nextReminderAt == date(16, 10, 15), "Counted from 06:00 while the computer slept")
    }

    func dailyBoundariesAndOutstandingReminder() throws {
        var schedule = ReminderSchedule(now: date(15, 5, 59), uptime: 0, calendar: calendar)
        try expect(!schedule.isCounting && schedule.nextCheckAt == date(15, 6), "Early launch ignored morning boundary")
        schedule.update(at: date(15, 6), uptime: 60, calendar: calendar)
        try expect(schedule.nextReminderAt == date(15, 8), "06:00 did not start a full interval")
        schedule.update(at: date(15, 8), uptime: 7_260, calendar: calendar)
        schedule.reminderDidStart()
        try expect(schedule.isAwaitingAcknowledgment, "Due reminder did not become outstanding")
        try expect(schedule.nextCheckAt == date(15, 22), "Outstanding reminder lost its 22:00 stop timer")
        schedule.update(at: date(15, 22), uptime: 57_660, calendar: calendar)
        try expect(!schedule.isAwaitingAcknowledgment && !schedule.isDue, "22:00 kept a reminder outstanding")
        try expect(schedule.nextReminderAt == nil && schedule.nextCheckAt == date(16, 6), "Night scheduled a reminder")
        schedule.reminderDidStart()
        try expect(!schedule.isAwaitingAcknowledgment, "Preview bypassed quiet hours")
    }

    func cutoffWinsOverSimultaneousDeadline() throws {
        var schedule = ReminderSchedule(hours: 0.5, now: date(15, 21, 30), uptime: 0, calendar: calendar)
        try expect(schedule.nextReminderAt == nil && schedule.nextCheckAt == date(15, 22), "A reminder was scheduled at 22:00")
        schedule.update(at: date(15, 23), uptime: 5_400, calendar: calendar)
        try expect(!schedule.isDue && !schedule.isCounting, "Delayed callback fired after 22:00")
        try expect(schedule.remainingTime == 0, "Delayed callback did not stop counting at the cutoff")
        schedule.update(at: date(16, 7), uptime: 34_200, calendar: calendar)
        try expect(schedule.nextReminderAt == date(16, 7, 30), "Yesterday's overdue reminder leaked into morning")
    }

    func clockAndTimeZoneChanges() throws {
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.update(at: date(15, 8), uptime: 600, calendar: calendar)
        try expect(schedule.remainingTime == 6_600, "Backward clock change altered elapsed use")
        schedule.update(at: date(15, 14), uptime: 1_200, calendar: calendar)
        try expect(schedule.remainingTime == 6_000 && !schedule.isDue, "Forward clock change consumed extra hours")
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        schedule = ReminderSchedule(now: date(15, 21, 30), uptime: 0, calendar: calendar)
        schedule.update(at: date(15, 21, 30), uptime: 0, calendar: tokyo)
        try expect(!schedule.isCounting && schedule.nextReminderAt == nil, "Time zone change ignored the new local cutoff")
    }

    func dstAndInactiveStartup() throws {
        var newYork = calendar
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let morning = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
        var schedule = ReminderSchedule(now: morning, uptime: 0, isSessionActive: false, calendar: newYork)
        schedule.update(at: morning.addingTimeInterval(3_600), uptime: 3_600, calendar: newYork)
        try expect(schedule.remainingTime == 7_200 && schedule.nextCheckAt == nil, "Dark login launch counted screen-off time")
        schedule.update(at: morning.addingTimeInterval(3_600), uptime: 3_600, isSessionActive: true, calendar: newYork)
        try expect(schedule.nextReminderAt == morning.addingTimeInterval(10_800), "DST morning did not use the first screen wake")
        let cutoff = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 22))!
        try expect(schedule.nextBoundaryAt == cutoff, "DST cutoff used a fixed UTC offset")
    }

    func nextIntervalStartsAtClickAndDoesNotQueue() throws {
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.reminderDidStart()
        try expect(schedule.nextReminderAt == nil, "Outstanding reminder left another deadline")
        try expect(!schedule.isDue, "Outstanding reminder queued another")
        schedule.acknowledge(at: now.addingTimeInterval(10_000), uptime: 10_000, calendar: calendar)
        try expect(schedule.nextReminderAt == now.addingTimeInterval(17_200), "Interval did not start at click")
        schedule.acknowledge(at: now.addingTimeInterval(11_000), uptime: 11_000, calendar: calendar)
        try expect(schedule.nextReminderAt == now.addingTimeInterval(17_200), "Duplicate click postponed reminder")
    }

    func intervalChangeDuringReminderWaitsForClick() throws {
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.reminderDidStart()
        schedule.setInterval(hours: 3.5, now: now.addingTimeInterval(100), uptime: 100, calendar: calendar)
        try expect(schedule.nextReminderAt == nil, "Changing interval scheduled over an active reminder")
        schedule.acknowledge(at: now.addingTimeInterval(500), uptime: 500, calendar: calendar)
        try expect(schedule.nextReminderAt == now.addingTimeInterval(13_100), "New interval was not applied at click")
    }

    func invalidPreferencesAndIntervalChange() throws {
        try expect(ReminderSchedule.validated(.nan) == 2, "NaN preference was accepted")
        try expect(ReminderSchedule.validated(.infinity) == 2, "Infinite preference was accepted")
        try expect(ReminderSchedule.validated(-10) == 0.5, "Minimum interval is not enforced")
        try expect(ReminderSchedule.validated(30) == 24, "Maximum interval is not enforced")
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.setInterval(hours: 1, now: now.addingTimeInterval(400), uptime: 400, calendar: calendar)
        try expect(schedule.nextReminderAt == now.addingTimeInterval(4_000), "Idle interval change did not reset deadline")
        schedule.update(at: now.addingTimeInterval(500), uptime: 500, isSessionActive: false, calendar: calendar)
        schedule.setInterval(hours: 0.5, now: now.addingTimeInterval(600), uptime: 600, calendar: calendar)
        try expect(schedule.nextReminderAt == nil && schedule.remainingTime == 1_800, "Setting interval restarted a sleeping countdown")
        schedule.update(at: now.addingTimeInterval(1_000), uptime: 1_000, isSessionActive: true, calendar: calendar)
        try expect(schedule.nextReminderAt == now.addingTimeInterval(2_800), "Sleeping interval edit did not apply at wake")
    }

    func slideThrowClickAndClimb() throws {
        var scene = ReminderScene(viewport: CGSize(width: 1_440, height: 900))
        try expect(scene.characterPosition.y < 0, "Claude did not start above screen")
        scene.advance(by: 2)
        try expect(scene.phase == .reminding, "Descent never reached reminding phase")
        scene.advance(by: 5)
        try expect(scene.throwCount >= 3, "Claude did not keep throwing bottles")
        let previousThrowCount = scene.throwCount
        try expect(scene.acknowledge(), "First click was ignored")
        try expect(!scene.acknowledge(), "Repeated click changed animation state")
        scene.advance(by: 0.6)
        try expect(scene.phase == .ascending, "Click did not start climbing")
        scene.advance(by: 2.1)
        try expect(scene.phase == .finished, "Climb did not finish")
        try expect(scene.throwCount == previousThrowCount, "Claude kept throwing after click")
        try expect(scene.bottles.isEmpty && scene.particles.isEmpty, "Animation objects leaked after departure")
    }

    func earlyClickDuringDescent() throws {
        var scene = ReminderScene(viewport: CGSize(width: 900, height: 600))
        scene.advance(by: 0.3)
        try expect(scene.acknowledge(), "Click during descent was ignored")
        scene.advance(by: 3)
        try expect(scene.phase == .finished, "Early click did not produce a full departure")
        try expect(scene.throwCount == 0, "Early click still threw water")
    }

    func persistentReminderHasBoundedParticles() throws {
        var scene = ReminderScene(viewport: CGSize(width: 1_440, height: 900))
        scene.advance(by: 120)
        try expect(scene.phase == .reminding, "Reminder stopped without a click")
        try expect(scene.throwCount > 80, "Throwing stalled during long reminder")
        try expect(scene.bottles.count < 5, "Bottles accumulated off-screen")
        try expect(scene.particles.count < 30, "Water particles accumulated indefinitely")
    }

    func hitRegionsExcludeRopeWaterAndTransparentGaps() throws {
        for poseTime in [0.0, 0.3, 0.43, 0.64, 1.0] {
            let regions = PixelArt.claudeHitRegions(phase: .reminding, poseTime: poseTime)
            try expect(regions.contains { $0.contains(CGPoint(x: 0, y: 8)) }, "Claude's body is not clickable")
            try expect(!regions.contains { $0.contains(CGPoint(x: -48, y: -40)) }, "Exposed rope intercepts clicks")
            try expect(!regions.contains { $0.contains(CGPoint(x: 63, y: -38)) }, "Carried bottle intercepts clicks")
            try expect(!regions.contains { $0.contains(CGPoint(x: 0, y: 42)) }, "Gap between legs intercepts clicks")
            try expect(regions.count < 25, "Hit regions created excessive windows")
        }
    }

    func descendingHitRegionsStayOnTheirDisplay() throws {
        var scene = ReminderScene(viewport: CGSize(width: 1_440, height: 900))
        try expect(PixelArt.claudeHitRegions(in: scene).isEmpty, "Off-screen Claude created visible input windows")
        scene.advance(by: 0.15)
        let bounds = CGRect(origin: .zero, size: scene.viewport)
        let regions = PixelArt.claudeHitRegions(in: scene)
        try expect(!regions.isEmpty, "Entering Claude has no visible hit regions")
        try expect(regions.allSatisfy { bounds.contains($0) }, "Input region escaped onto another display")
    }
}

@main
enum BigWaterChecks {
    static func main() {
        let suite = ReminderChecks()
        let checks: [(String, () throws -> Void)] = [
            ("two-hour default", suite.twoHourDefault),
            ("sleep and duplicate notifications preserve remaining time", suite.sleepPreservesRemainingTime),
            ("overnight reset starts at first morning use", suite.overnightStartsAtFirstMorningUse),
            ("06:00 start and 22:00 dismiss outstanding reminders", suite.dailyBoundariesAndOutstandingReminder),
            ("22:00 cutoff wins over simultaneous and late deadlines", suite.cutoffWinsOverSimultaneousDeadline),
            ("clock and local time zone changes", suite.clockAndTimeZoneChanges),
            ("DST and screen-off login startup", suite.dstAndInactiveStartup),
            ("click resets interval without queued reminders", suite.nextIntervalStartsAtClickAndDoesNotQueue),
            ("interval changes during reminders", suite.intervalChangeDuringReminderWaitsForClick),
            ("invalid preferences and idle interval changes", suite.invalidPreferencesAndIntervalChange),
            ("descent, continuous throwing, click and climb", suite.slideThrowClickAndClimb),
            ("early click during descent", suite.earlyClickDuringDescent),
            ("bounded objects over a long reminder", suite.persistentReminderHasBoundedParticles),
            ("only Claude's visible pixels intercept clicks", suite.hitRegionsExcludeRopeWaterAndTransparentGaps),
            ("descent cannot leak input windows onto another display", suite.descendingHitRegionsStayOnTheirDisplay)
        ]
        var failures = 0
        for (name, run) in checks {
            do { try run(); print("PASS: \(name)") }
            catch { failures += 1; fputs("FAIL: \(name): \(error)\n", stderr) }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { exit(1) }
    }
}
