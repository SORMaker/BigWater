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
    private let now = Date(timeIntervalSince1970: 10_000)

    func twoHourDefaultAndWakeOverdue() throws {
        let schedule = ReminderSchedule(now: now)
        try expect(!schedule.isDue(at: now.addingTimeInterval(7_199)), "Reminder fired early")
        try expect(schedule.isDue(at: now.addingTimeInterval(7_200)), "Default is not two hours")
        try expect(schedule.isDue(at: now.addingTimeInterval(86_400)), "Overdue reminder lost after sleep")
    }

    func nextIntervalStartsAtClickAndDoesNotQueue() throws {
        var schedule = ReminderSchedule(now: now)
        schedule.reminderDidStart()
        try expect(schedule.nextReminderAt == nil, "Outstanding reminder left another deadline")
        try expect(!schedule.isDue(at: now.addingTimeInterval(86_400)), "Outstanding reminder queued another")
        schedule.acknowledge(at: now.addingTimeInterval(10_000))
        try expect(schedule.nextReminderAt == now.addingTimeInterval(17_200), "Interval did not start at click")
        schedule.acknowledge(at: now.addingTimeInterval(20_000))
        try expect(schedule.nextReminderAt == now.addingTimeInterval(17_200), "Duplicate click postponed reminder")
    }

    func intervalChangeDuringReminderWaitsForClick() throws {
        var schedule = ReminderSchedule(now: now)
        schedule.reminderDidStart()
        schedule.setInterval(hours: 3.5, now: now.addingTimeInterval(100))
        try expect(schedule.nextReminderAt == nil, "Changing interval scheduled over an active reminder")
        schedule.acknowledge(at: now.addingTimeInterval(500))
        try expect(schedule.nextReminderAt == now.addingTimeInterval(13_100), "New interval was not applied at click")
    }

    func invalidPreferencesAndIntervalChange() throws {
        try expect(ReminderSchedule.validated(.nan) == 2, "NaN preference was accepted")
        try expect(ReminderSchedule.validated(.infinity) == 2, "Infinite preference was accepted")
        try expect(ReminderSchedule.validated(-10) == 0.5, "Minimum interval is not enforced")
        try expect(ReminderSchedule.validated(30) == 24, "Maximum interval is not enforced")
        var schedule = ReminderSchedule(now: now)
        schedule.setInterval(hours: 1, now: now.addingTimeInterval(400))
        try expect(schedule.nextReminderAt == now.addingTimeInterval(4_000), "Idle interval change did not reset deadline")
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
            ("two-hour default and overdue wake", suite.twoHourDefaultAndWakeOverdue),
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
