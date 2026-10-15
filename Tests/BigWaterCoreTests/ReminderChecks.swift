import AppKit
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
        try expect(schedule.nextReminderAt == now.addingTimeInterval(3_600), "Idle interval change discarded counted use")
        schedule.update(at: now.addingTimeInterval(500), uptime: 500, isSessionActive: false, calendar: calendar)
        schedule.setInterval(hours: 0.5, now: now.addingTimeInterval(600), uptime: 600, calendar: calendar)
        try expect(schedule.nextReminderAt == nil && schedule.remainingTime == 1_300, "Setting interval restarted a sleeping countdown")
        schedule.update(at: now.addingTimeInterval(1_000), uptime: 1_000, isSessionActive: true, calendar: calendar)
        try expect(schedule.nextReminderAt == now.addingTimeInterval(2_300), "Sleeping interval edit did not apply at wake")
    }

    func invalidDecodedPreferencesAreSanitized() throws {
        let json = #"{"intervalHours":99,"weekdayHours":{"startMinutes":800,"endMinutes":700},"weekendHours":{"startMinutes":0,"endMinutes":1500},"style":"animated","soundEnabled":false,"appearance":{"theme":"blue","character":"claude"}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: json)
        let preferences = decoded.validated()
        try expect(preferences.intervalHours == ReminderSchedule.maximumHours, "Decoded interval was not clamped")
        try expect(preferences.weekdayHours == DailyHours(), "Invalid weekday window did not use defaults")
        try expect(preferences.weekendHours == nil, "Invalid weekend window was retained")
    }

    func weekdayAndWeekendWindows() throws {
        let weekdayHours = DailyHours(startMinutes: 8 * 60, endMinutes: 20 * 60)
        let weekendHours = DailyHours(startMinutes: 10 * 60, endMinutes: 18 * 60)
        var schedule = ReminderSchedule(now: date(15, 7), uptime: 0, calendar: calendar,
                                        weekdayHours: weekdayHours, weekendHours: weekendHours)
        try expect(!schedule.isWithinReminderHours && schedule.nextBoundaryAt == date(15, 8),
                   "Weekday schedule ignored its custom start")
        schedule.update(at: date(17, 9), uptime: 0, calendar: calendar)
        try expect(!schedule.isWithinReminderHours && schedule.nextBoundaryAt == date(17, 10),
                   "Weekend schedule did not use its separate start")
        schedule.update(at: date(17, 18), uptime: 0, calendar: calendar)
        try expect(!schedule.isWithinReminderHours && schedule.nextBoundaryAt == date(18, 10),
                   "Weekend cutoff did not advance to the next weekend window")
    }

    func snapshotRestoresSameDayWithoutOfflineTime() throws {
        var active = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        active.update(at: date(15, 9, 30), uptime: 1_800, calendar: calendar)
        let saved = active.snapshot(at: date(15, 9, 30), uptime: 1_800, calendar: calendar)
        let encoded = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(ReminderSnapshot.self, from: encoded)
        let restored = ReminderSchedule(now: date(15, 13), uptime: 50_000, calendar: calendar,
                                        snapshot: decoded)
        try expect(restored.remainingTime == 5_400, "Offline time consumed the saved countdown")
        try expect(restored.nextReminderAt == date(15, 14, 30), "Restored countdown used the old deadline")
        let changedSettings = ReminderSchedule(now: date(15, 13), uptime: 50_000, calendar: calendar,
                                              weekdayHours: DailyHours(startMinutes: 7 * 60, endMinutes: 22 * 60),
                                              snapshot: decoded)
        try expect(changedSettings.remainingTime == 7_200,
                   "Snapshot from different schedule settings was restored")
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let changedZone = ReminderSchedule(now: date(15, 13), uptime: 50_000, calendar: tokyo,
                                           snapshot: decoded)
        try expect(changedZone.remainingTime == 7_200,
                   "Snapshot from a different timezone was restored")

        var awaiting = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        awaiting.reminderDidStart()
        let awaitingSnapshot = awaiting.snapshot(at: now, uptime: 0, calendar: calendar)
        let awaitingRestore = ReminderSchedule(now: date(15, 11), uptime: 7_200, calendar: calendar,
                                               snapshot: awaitingSnapshot)
        try expect(awaitingRestore.isAwaitingAcknowledgment && awaitingRestore.nextReminderAt == nil,
                   "Same-day restore lost the outstanding reminder")
    }

    func staleReminderIsDiscardedOutsideWindow() throws {
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.reminderDidStart()
        let saved = schedule.snapshot(at: now, uptime: 0, calendar: calendar)
        let afterHours = ReminderSchedule(now: date(15, 22, 30), uptime: 0, calendar: calendar,
                                          snapshot: saved)
        try expect(!afterHours.isAwaitingAcknowledgment && afterHours.remainingTime == 7_200,
                   "Nighttime restore retained a stale reminder")
        let nextDay = ReminderSchedule(now: date(16, 8), uptime: 10, calendar: calendar,
                                       snapshot: saved)
        try expect(!nextDay.isAwaitingAcknowledgment && nextDay.remainingTime == 7_200,
                   "New-day restore inherited stale reminder state")
    }

    func pauseResumesCountdownAndReoffersOutstandingReminder() throws {
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.update(at: date(15, 9, 20), uptime: 1_200, calendar: calendar)
        schedule.pause(for: 30, at: date(15, 9, 20), uptime: 1_200, calendar: calendar)
        try expect(schedule.isManuallyPaused && schedule.remainingTime == 6_000,
                   "Pause changed the existing countdown")
        try expect(schedule.nextCheckAt == date(15, 9, 50), "Pause did not arm its expiry")
        schedule.resume(at: date(15, 10), uptime: 1_200, calendar: calendar)
        try expect(!schedule.isManuallyPaused && schedule.remainingTime == 6_000,
                   "Time spent paused consumed the countdown")
        schedule.update(at: date(15, 10, 1), uptime: 1_260, calendar: calendar)
        try expect(schedule.remainingTime == 5_940, "Countdown did not resume after pause")

        var outstanding = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        outstanding.reminderDidStart()
        outstanding.pause(for: 30, at: now, uptime: 0, calendar: calendar)
        try expect(!outstanding.isAwaitingAcknowledgment && !outstanding.isDue,
                   "Pause did not hide the outstanding reminder")
        outstanding.resume(at: date(15, 9, 20), uptime: 0, calendar: calendar)
        try expect(outstanding.isDue, "Resume did not re-offer the hidden reminder")
    }

    func pauseExpiryIgnoresWallClockCorrections() throws {
        var forward = ReminderSchedule(now: now, uptime: 100, calendar: calendar)
        forward.pause(for: 30, at: now, uptime: 100, calendar: calendar)
        let jumpedForward = now.addingTimeInterval(3_600)
        forward.update(at: jumpedForward, uptime: 160, calendar: calendar)
        try expect(forward.isManuallyPaused, "Forward clock correction canceled the pause")
        try expect(forward.pausedUntil == jumpedForward.addingTimeInterval(29 * 60),
                   "Forward correction did not rebase the visible pause deadline")
        forward.update(at: jumpedForward.addingTimeInterval(29 * 60), uptime: 1_900, calendar: calendar)
        try expect(!forward.isManuallyPaused, "Monotonic pause did not expire after 30 active minutes")

        var backward = ReminderSchedule(now: now, uptime: 100, calendar: calendar)
        backward.pause(for: 30, at: now, uptime: 100, calendar: calendar)
        let jumpedBackward = now.addingTimeInterval(-3_600)
        backward.update(at: jumpedBackward, uptime: 160, calendar: calendar)
        try expect(backward.isManuallyPaused, "Backward clock correction canceled the pause")
        try expect(backward.pausedUntil == jumpedBackward.addingTimeInterval(29 * 60),
                   "Backward correction did not rebase the visible pause deadline")
        backward.update(at: jumpedBackward.addingTimeInterval(29 * 60), uptime: 1_900, calendar: calendar)
        try expect(!backward.isManuallyPaused, "Backward-adjusted pause did not expire monotonically")
    }

    func futurePauseRestoresAcrossLocalDayBoundary() throws {
        let allDay = DailyHours(startMinutes: 0, endMinutes: 1_440)
        var schedule = ReminderSchedule(now: date(15, 23, 45), uptime: 0, calendar: calendar,
                                        weekdayHours: allDay)
        schedule.pause(for: 60, at: date(15, 23, 45), uptime: 0, calendar: calendar)
        let saved = schedule.snapshot(at: date(15, 23, 50), uptime: 300, calendar: calendar)
        var restored = ReminderSchedule(now: date(16, 0, 5), uptime: 100, calendar: calendar,
                                        weekdayHours: allDay, snapshot: saved)
        try expect(restored.isManuallyPaused && restored.pausedUntil == date(16, 0, 45),
                   "Cross-day restart discarded the remaining manual pause")
        try expect(restored.remainingTime == 7_200 && !restored.isAwaitingAcknowledgment
                   && !restored.isSnoozed,
                   "Cross-day pause restore retained stale reminder state")
        restored.update(at: date(16, 0, 45), uptime: 2_500, calendar: calendar)
        try expect(!restored.isManuallyPaused && restored.remainingTime == 7_200,
                   "Cross-day pause did not expire with a fresh daily interval")
    }

    func snoozeUsesShortActiveIntervalAndKeepsNormalInterval() throws {
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.reminderDidStart()
        schedule.snooze(minutes: 10, at: now, uptime: 0, calendar: calendar)
        try expect(!schedule.isAwaitingAcknowledgment && schedule.isSnoozed,
                   "Snooze did not hide the outstanding reminder")
        try expect(schedule.intervalHours == 2 && schedule.remainingTime == 600,
                   "Snooze changed the normal interval")
        try expect(schedule.nextReminderAt == date(15, 9, 10), "Snooze deadline was not ten minutes")
        schedule.update(at: date(15, 9, 10), uptime: 600, calendar: calendar)
        try expect(schedule.isDue && schedule.isSnoozed, "Snoozed reminder did not become due")
        schedule.reminderDidStart()
        try expect(!schedule.isSnoozed && schedule.remainingTime == 7_200,
                   "Next reminder did not return to the configured interval")

        schedule.snooze(minutes: 20, at: date(15, 9, 10), uptime: 600, calendar: calendar)
        let saved = schedule.snapshot(at: date(15, 9, 10), uptime: 600, calendar: calendar)
        let restored = ReminderSchedule(now: date(15, 9, 15), uptime: 5_000, calendar: calendar,
                                        snapshot: saved)
        try expect(restored.isSnoozed && restored.remainingTime == 1_200,
                   "Snapshot did not preserve snooze state or exclude offline time")
    }

    func hydrationHistoryCountsExplicitDrinksByLocalDay() throws {
        var history = HydrationHistory()
        history.recordDrink(at: date(15, 10))
        history.recordDrink(at: date(15, 8))
        history.recordDrink(at: date(16, 9))
        try expect(history.count(on: date(15, 12), calendar: calendar) == 2,
                   "Drink history mixed adjacent local days")
        try expect(history.drinks(on: date(15, 12), calendar: calendar) == [date(15, 8), date(15, 10)],
                   "Drink history was not returned in chronological order")
    }

    /// Saved exactly as 0.3.0 wrote it, so later model changes keep reading it.
    static let version030State = #"{"preferences":{"intervalHours":2,"style":"compact","weekdayHours":{"endMinutes":1320,"startMinutes":360},"weekendHours":{"startMinutes":600,"endMinutes":1080},"soundEnabled":false,"appearance":{"character":"droplet","theme":"mint"}},"history":{"drinks":[813717000,813720540]},"progress":{"weekdayHours":{"endMinutes":1320,"startMinutes":360},"weekendHours":{"endMinutes":1080,"startMinutes":600},"capturedDay":{"isLeapMonth":false,"year":2026,"day":15,"month":10,"era":1},"remainingTime":7200,"isAwaitingAcknowledgment":false,"isSnoozed":false,"timeZoneIdentifier":"Asia\/Shanghai","intervalHours":2,"capturedAt":813720600}}"#

    func version030StateStillDecodes() throws {
        let root = try JSONSerialization.jsonObject(with: Data(Self.version030State.utf8)) as! [String: Any]
        func section(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: root[key]!) }
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: section("preferences"))
        try expect(preferences.style == .compact && preferences.weekendHours?.startMinutes == 600
                   && preferences.appearance == ReminderAppearance(theme: .mint, character: .droplet),
                   "0.3.0 preferences changed meaning")
        let history = try JSONDecoder().decode(HydrationHistory.self, from: section("history"))
        try expect(history.drinks.count == 2, "0.3.0 drink history was not restored")
        let progress = try JSONDecoder().decode(ReminderSnapshot.self, from: section("progress"))
        try expect(progress.remainingTime == 7_200 && progress.timeZoneIdentifier == "Asia/Shanghai",
                   "0.3.0 progress was not restored")
    }

    func storedPreferencesTolerateMissingAndUnknownValues() throws {
        // An older build lacks newer keys; a newer build may store values this build doesn't know.
        let json = #"{"intervalHours":3,"style":"bubbles","weekdayHours":{"startMinutes":420},"appearance":{"theme":"ocean","character":"droplet"},"futureOption":true}"#
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8)).validated()
        try expect(preferences.intervalHours == 3, "Known interval was discarded with unknown neighbours")
        try expect(preferences.style == .animated && !preferences.soundEnabled, "Unknown or missing options did not use defaults")
        try expect(preferences.weekdayHours == DailyHours(startMinutes: 420, endMinutes: 1_320),
                   "A partial window did not keep its known start")
        try expect(preferences.appearance == ReminderAppearance(theme: .blue, character: .droplet),
                   "Unknown theme discarded the known character")
        let empty = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        try expect(empty == AppPreferences(), "Empty preferences did not use defaults")
    }

    func storedHistoryKeepsReadableDrinks() throws {
        let json = #"{"drinks":[813717000,"not a date",null,813720540]}"#
        let history = try JSONDecoder().decode(HydrationHistory.self, from: Data(json.utf8))
        try expect(history.drinks.count == 2, "One unreadable entry discarded the whole drink history")
        let missing = try JSONDecoder().decode(HydrationHistory.self, from: Data("{}".utf8))
        try expect(missing.drinks.isEmpty, "Missing history did not decode as empty")
    }

    /// Renders a frame at 1× and calls `visit` with each pixel's alpha, in the
    /// scene's top-left coordinates.
    private func eachPixel(of scene: ReminderScene, _ visit: (Int, Int, UInt8) throws -> Void) rethrows {
        let image = PixelArt.image(size: scene.viewport, backingScale: 1) { SceneRenderer.draw(scene, in: $0) }
        let bitmap = image.representations.first as! NSBitmapImageRep
        let data = bitmap.bitmapData!
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                try visit(x, y, data[y * bitmap.bytesPerRow + x * 4 + 3])
            }
        }
    }

    func paintedRegionsCoverEveryDrawnPixel() throws {
        for character in ReminderCharacter.allCases {
            var scene = ReminderScene(viewport: CGSize(width: 640, height: 420),
                                      appearance: ReminderAppearance(character: character))
            var steps = [0.2, 0.9, 0.95, 0.6, 0.35, 0.45, 0.7, 1.1, 0.3, 0.5, 0.25, 0.8]
            var frame = 0
            while scene.phase != .finished, !steps.isEmpty {
                scene.advance(by: steps.removeFirst())
                frame += 1
                if frame == 9 { scene.acknowledge() }
                let regions = SceneRenderer.paintedRegions(of: scene)
                try eachPixel(of: scene) { x, y, alpha in
                    let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    if alpha > 0 && !regions.contains(where: { $0.contains(point) }) {
                        throw CheckFailure(description: "\(character) \(scene.phase) painted (\(x), \(y)) outside its redraw bounds")
                    }
                }
            }
        }
        var idle = ReminderScene(viewport: CGSize(width: 1_440, height: 900))
        idle.advance(by: 30)
        let area = SceneRenderer.paintedRegions(of: idle).reduce(0) { $0 + $1.width * $1.height }
        try expect(area < 1_440 * 900 * 0.15, "Redraw regions cover much of the screen")
    }

    func speechBubbleClickRegionsAreFullyPainted() throws {
        var scene = ReminderScene(viewport: CGSize(width: 900, height: 600))
        try expect(SceneRenderer.speechRegions(for: scene).isEmpty, "Hidden bubble blocks clicks")
        scene.advance(by: 2.3)
        let regions = SceneRenderer.speechRegions(for: scene)
        try expect(regions.count == 2, "Visible bubble has no click regions")
        try eachPixel(of: scene) { x, y, alpha in
            let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
            if alpha < 255 && regions.contains(where: { $0.contains(point) }) {
                throw CheckFailure(description: "Bubble click region is not painted at (\(x), \(y))")
            }
        }
    }

    func intervalEditsKeepCountedUse() throws {
        var schedule = ReminderSchedule(now: now, uptime: 0, calendar: calendar)
        schedule.update(at: date(15, 10, 50), uptime: 6_600, calendar: calendar)
        schedule.setInterval(hours: 2.5, now: date(15, 10, 50), uptime: 6_600, calendar: calendar)
        schedule.setInterval(hours: 2, now: date(15, 10, 50), uptime: 6_600, calendar: calendar)
        try expect(schedule.remainingTime == 600, "Changing the interval and back restarted the countdown")
        schedule.setInterval(hours: 1.5, now: date(15, 10, 50), uptime: 6_600, calendar: calendar)
        try expect(schedule.isDue, "A shorter interval than the time already used did not become due")
    }

    func historyKeepsRecentDaysInOrder() throws {
        var history = HydrationHistory()
        history.recordDrink(at: date(15, 10), calendar: calendar)
        history.recordDrink(at: date(15, 8), calendar: calendar)
        history.recordDrink(at: date(15, 9), calendar: calendar)
        try expect(history.drinks == [date(15, 8), date(15, 9), date(15, 10)], "Drinks were not kept in order")
        let later = calendar.date(byAdding: .day, value: HydrationHistory.retentionDays + 1, to: date(15, 12))!
        history.recordDrink(at: later, calendar: calendar)
        try expect(history.drinks == [later], "Confirmations older than the retention window were kept")
    }

    func onlyClaudeRecoils() throws {
        for character in ReminderCharacter.allCases {
            var scene = ReminderScene(viewport: CGSize(width: 1_440, height: 900),
                                      appearance: ReminderAppearance(character: character))
            scene.advance(by: 2)
            var xs: [Double] = []
            for _ in 0..<90 { scene.advance(by: 1.0 / 30); xs.append(scene.characterPosition.x) }
            let sway = xs.max()! - xs.min()!
            try expect(character == .claude ? sway > 8 : sway <= 6.01,
                       "\(character) sway \(sway)pt does not match whether it throws")
        }
    }

    func weekendFollowsTheLocale() throws {
        var israel = calendar
        israel.locale = Locale(identifier: "he_IL")
        let weekend = DailyHours(startMinutes: 10 * 60, endMinutes: 18 * 60)
        // 2026-10-16 is a Friday, a weekend day in Israel but not in China.
        let friday = date(16, 9)
        let local = ReminderSchedule(now: friday, uptime: 0, calendar: israel, weekendHours: weekend)
        try expect(!local.isWithinReminderHours && local.nextBoundaryAt == date(16, 10),
                   "Friday did not use the weekend window in a Friday–Saturday locale")
        var china = calendar
        china.locale = Locale(identifier: "zh_CN")
        let weekday = ReminderSchedule(now: friday, uptime: 0, calendar: china, weekendHours: weekend)
        try expect(weekday.isWithinReminderHours, "Friday used the weekend window in a Saturday–Sunday locale")
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
        try expect(PixelArt.characterHitRegions(in: scene).isEmpty, "Off-screen Claude created visible input windows")
        scene.advance(by: 0.15)
        let bounds = CGRect(origin: .zero, size: scene.viewport)
        let regions = PixelArt.characterHitRegions(in: scene)
        try expect(!regions.isEmpty, "Entering Claude has no visible hit regions")
        try expect(regions.allSatisfy { bounds.contains($0) }, "Input region escaped onto another display")
    }

    func dropletThemesKeepInputAndAnimationBounded() throws {
        for theme in ReminderTheme.allCases {
            var scene = ReminderScene(viewport: CGSize(width: 900, height: 600),
                                      appearance: ReminderAppearance(theme: theme, character: .droplet))
            try expect(PixelArt.characterHitRegions(in: scene).isEmpty, "Off-screen droplet intercepted input")
            scene.advance(by: 15)
            try expect(scene.phase == .reminding && scene.throwCount == 0 && scene.bottles.isEmpty,
                       "Droplet did not stay in its own reminder animation")
            let bounds = CGRect(origin: .zero, size: scene.viewport)
            let regions = PixelArt.characterHitRegions(in: scene)
            try expect(!regions.isEmpty && regions.allSatisfy { bounds.contains($0) }, "Droplet input escaped its display")
            try expect(regions.contains { $0.contains(scene.characterPosition) }, "Droplet's center could not be clicked")
            try expect(scene.acknowledge(), "Droplet click failed")
            scene.advance(by: 3)
            try expect(scene.phase == .finished, "Droplet exit never finished")
        }
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
            ("decoded preferences are sanitized", suite.invalidDecodedPreferencesAreSanitized),
            ("weekday and weekend reminder windows", suite.weekdayAndWeekendWindows),
            ("same-day snapshot restore excludes offline time", suite.snapshotRestoresSameDayWithoutOfflineTime),
            ("stale reminders are discarded at night and on a new day", suite.staleReminderIsDiscardedOutsideWindow),
            ("pause preserves and resumes the countdown", suite.pauseResumesCountdownAndReoffersOutstandingReminder),
            ("manual pause ignores wall-clock corrections", suite.pauseExpiryIgnoresWallClockCorrections),
            ("future manual pause survives a cross-day restart", suite.futurePauseRestoresAcrossLocalDayBoundary),
            ("snooze uses a short interval and keeps the normal interval", suite.snoozeUsesShortActiveIntervalAndKeepsNormalInterval),
            ("drink history counts explicit confirmations by local day", suite.hydrationHistoryCountsExplicitDrinksByLocalDay),
            ("state saved by 0.3.0 still decodes", suite.version030StateStillDecodes),
            ("stored preferences tolerate missing and unknown values", suite.storedPreferencesTolerateMissingAndUnknownValues),
            ("stored history keeps readable drinks", suite.storedHistoryKeepsReadableDrinks),
            ("interval edits keep counted use", suite.intervalEditsKeepCountedUse),
            ("history keeps recent days in order", suite.historyKeepsRecentDaysInOrder),
            ("only Claude recoils", suite.onlyClaudeRecoils),
            ("weekend follows the locale", suite.weekendFollowsTheLocale),
            ("redraw regions cover every drawn pixel", suite.paintedRegionsCoverEveryDrawnPixel),
            ("speech bubble click regions are fully painted", suite.speechBubbleClickRegionsAreFullyPainted),
            ("descent, continuous throwing, click and climb", suite.slideThrowClickAndClimb),
            ("early click during descent", suite.earlyClickDuringDescent),
            ("bounded objects over a long reminder", suite.persistentReminderHasBoundedParticles),
            ("only Claude's visible pixels intercept clicks", suite.hitRegionsExcludeRopeWaterAndTransparentGaps),
            ("descent cannot leak input windows onto another display", suite.descendingHitRegionsStayOnTheirDisplay),
            ("all droplet themes keep animation and input bounded", suite.dropletThemesKeepInputAndAnimationBounded)
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
