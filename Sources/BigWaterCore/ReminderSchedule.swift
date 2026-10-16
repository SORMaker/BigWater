import Foundation

/// Counts screen-awake use inside the configured local daily periods. A reminder
/// remains outstanding until acknowledged, snoozed, paused, or the day ends.
public struct ReminderSchedule {
    public static let defaultHours = 2.0
    public static let minimumHours = 0.5
    public static let maximumHours = 24.0

    public private(set) var intervalHours: Double
    public private(set) var remainingTime: TimeInterval
    public private(set) var isAwaitingAcknowledgment = false
    public private(set) var isWithinReminderHours = false
    public private(set) var isSessionActive: Bool
    public private(set) var nextBoundaryAt: Date
    public private(set) var localDay: DateComponents
    public private(set) var weekdayHours: DailyHours
    public private(set) var weekendHours: DailyHours?
    public private(set) var pausedUntil: Date?
    public private(set) var isSnoozed = false

    private var lastUpdateAt: Date
    private var lastUptime: TimeInterval
    private var pauseDeadlineUptime: TimeInterval?
    private var calendar: Calendar

    public var isManuallyPaused: Bool { pausedUntil != nil }

    public var isCounting: Bool {
        isSessionActive && isWithinReminderHours && !isAwaitingAcknowledgment
            && !isManuallyPaused
    }

    public var isDue: Bool { isCounting && remainingTime <= 0 }

    public var nextReminderAt: Date? {
        guard isCounting else { return nil }
        let hours = Self.hours(for: lastUpdateAt, weekday: weekdayHours,
                               weekend: weekendHours, calendar: calendar)
        let periods = Self.periodBounds(for: lastUpdateAt, hours: hours, calendar: calendar)
        var remaining = remainingTime

        for index in periods.indices where periods[index].end > lastUpdateAt {
            let period = periods[index]
            let activeStart = max(lastUpdateAt, period.start)
            let available = period.end.timeIntervalSince(activeStart)
            if remaining < available {
                return activeStart.addingTimeInterval(remaining)
            }
            if remaining == available {
                // A due time at a rest-gap edge is delivered when use resumes.
                return periods.dropFirst(index + 1).first?.start
            }
            remaining -= available
        }
        return nil
    }

    /// Always includes the daily boundary, even while a reminder is on screen.
    /// A manual pause adds its expiry as a wake-up so the countdown can resume.
    public var nextCheckAt: Date? {
        guard isSessionActive else { return nil }
        return [nextReminderAt ?? nextBoundaryAt, nextBoundaryAt,
                pausedUntil ?? nextBoundaryAt].min()
    }

    public init(hours: Double = defaultHours, now: Date = Date(),
                uptime: TimeInterval = ReminderClock.uptime,
                isSessionActive: Bool = true, calendar: Calendar = .autoupdatingCurrent,
                weekdayHours: DailyHours = .init(), weekendHours: DailyHours? = nil,
                snapshot: ReminderSnapshot? = nil) {
        intervalHours = Self.validated(hours)
        remainingTime = intervalHours * 3_600
        self.isSessionActive = isSessionActive
        self.weekdayHours = Self.validHours(weekdayHours)
        self.weekendHours = weekendHours.map(Self.validHours)
        self.calendar = calendar
        localDay = calendar.dateComponents([.era, .year, .month, .day], from: now)
        lastUpdateAt = now
        lastUptime = uptime
        nextBoundaryAt = now
        pauseDeadlineUptime = nil

        if let snapshot,
           snapshot.capturedAt.timeIntervalSince1970.isFinite,
           snapshot.capturedAt <= now,
           let savedPause = snapshot.pausedUntil,
           savedPause.timeIntervalSince1970.isFinite,
           savedPause > now {
            pausedUntil = savedPause
            pauseDeadlineUptime = uptime + savedPause.timeIntervalSince(now)
        }

        if let snapshot,
           Self.canRestore(snapshot, at: now, hours: intervalHours,
                           weekdayHours: self.weekdayHours, weekendHours: self.weekendHours,
                           calendar: calendar) {
            let currentHours = Self.hours(for: now, weekday: self.weekdayHours,
                                          weekend: self.weekendHours, calendar: calendar)
            let insidePeriod = Self.periodContaining(now, hours: currentHours, calendar: calendar)
            let insideWindow = insidePeriod != nil
            let inRestGap = Self.isRestGap(now, hours: currentHours, calendar: calendar)
            isWithinReminderHours = insideWindow
            if insideWindow || inRestGap {
                remainingTime = Self.validRemaining(snapshot.remainingTime, fallback: intervalHours * 3_600)
                let crossedGap = insideWindow && Self.hasRestGapCrossed(
                    after: snapshot.capturedAt, through: now,
                    weekdayHours: self.weekdayHours, weekendHours: self.weekendHours,
                    calendar: calendar
                )
                if snapshot.isAwaitingAcknowledgment && (inRestGap || crossedGap) {
                    // The overlay itself is not restored. Re-offer its reminder
                    // at the next active period instead of treating it as seen.
                    remainingTime = 0
                } else {
                    isAwaitingAcknowledgment = insideWindow && snapshot.isAwaitingAcknowledgment
                }
                isSnoozed = snapshot.isSnoozed && !isAwaitingAcknowledgment
            } else {
                // Before the first period or after the last, retire the saved
                // reminder. Only a same-day rest gap preserves its progress.
                remainingTime = intervalHours * 3_600
            }
        }
        update(at: now, uptime: uptime, calendar: calendar)
    }

    public static func validated(_ hours: Double) -> Double {
        guard hours.isFinite else { return defaultHours }
        return min(max(hours, minimumHours), maximumHours)
    }

    public mutating func update(at now: Date, uptime: TimeInterval = ReminderClock.uptime,
                                isSessionActive: Bool? = nil, calendar: Calendar = .autoupdatingCurrent) {
        let today = calendar.dateComponents([.era, .year, .month, .day], from: now)
        let newLocalDay = !Self.sameDay(today, localDay)
        let elapsed = max(0, uptime - lastUptime)
        let projectedEnd = lastUpdateAt.addingTimeInterval(elapsed)
        let countingStart: Date
        if let pauseDeadlineUptime {
            let pausedFor = max(0, pauseDeadlineUptime - lastUptime)
            countingStart = lastUpdateAt.addingTimeInterval(pausedFor)
        } else {
            countingStart = lastUpdateAt
        }
        // Local time governs whether an old pending scene crossed a rest
        // boundary; clock corrections must not keep it in the wrong period.
        // Only the monotonic projection below consumes active-use time.
        let crossedRestGap = !newLocalDay && Self.hasRestGapCrossed(
            after: lastUpdateAt, through: max(now, projectedEnd),
            weekdayHours: weekdayHours, weekendHours: weekendHours, calendar: self.calendar
        )

        if newLocalDay {
            // A new local day always starts with a complete interval.
            remainingTime = intervalHours * 3_600
            isAwaitingAcknowledgment = false
            isSnoozed = false
        } else if self.isSessionActive && !isAwaitingAcknowledgment {
            // Use monotonic elapsed time projected from the prior wall-clock
            // anchor, beginning at a pause's monotonic expiry when necessary.
            // Count only active-period overlaps so gaps and wall-clock jumps do
            // not consume active-use time.
            let activeElapsed = Self.activeSeconds(
                from: countingStart, through: projectedEnd,
                weekdayHours: weekdayHours, weekendHours: weekendHours,
                calendar: self.calendar
            )
            remainingTime = max(0, remainingTime - activeElapsed)
        }

        if let pauseDeadlineUptime {
            let pauseRemaining = pauseDeadlineUptime - uptime
            if pauseRemaining <= 0 {
                self.pauseDeadlineUptime = nil
                pausedUntil = nil
            } else {
                pausedUntil = now.addingTimeInterval(pauseRemaining)
            }
        }

        let hours = Self.hours(for: now, weekday: weekdayHours,
                               weekend: weekendHours, calendar: calendar)
        let currentPeriod = Self.periodContaining(now, hours: hours, calendar: calendar)
        isWithinReminderHours = currentPeriod != nil
        // If a delayed callback crossed a rest gap and returned during a later
        // period, dismiss the stale UI and re-offer the same due reminder.
        if crossedRestGap && isWithinReminderHours && isAwaitingAcknowledgment {
            isAwaitingAcknowledgment = false
            remainingTime = 0
            isSnoozed = false
        }
        if !isWithinReminderHours {
            if isAwaitingAcknowledgment {
                // A pending reminder is re-offered at the next period opening.
                remainingTime = Self.isRestGap(now, hours: hours, calendar: calendar)
                    ? 0 : intervalHours * 3_600
                isAwaitingAcknowledgment = false
            }
            if !Self.isRestGap(now, hours: hours, calendar: calendar) {
                isSnoozed = false
            }
        }
        if let isSessionActive { self.isSessionActive = isSessionActive }

        nextBoundaryAt = Self.nextBoundary(after: now, weekdayHours: weekdayHours,
                                            weekendHours: weekendHours, calendar: calendar)

        localDay = today
        lastUpdateAt = now
        lastUptime = uptime
        self.calendar = calendar
    }

    /// Mark the currently due reminder as visible. This remains permissive for
    /// the app's explicit developer-preview path, which can start before due.
    public mutating func reminderDidStart() {
        guard isCounting else { return }
        isAwaitingAcknowledgment = true
        isSnoozed = false
        remainingTime = intervalHours * 3_600
    }

    public mutating func acknowledge(at now: Date,
                                     uptime: TimeInterval = ReminderClock.uptime,
                                     calendar: Calendar = .autoupdatingCurrent) {
        update(at: now, uptime: uptime, calendar: calendar)
        guard isAwaitingAcknowledgment else { return }
        isAwaitingAcknowledgment = false
        isSnoozed = false
        remainingTime = intervalHours * 3_600
    }

    /// A drink can happen before a reminder. Keep an intentional pause, but
    /// replace either the ordinary countdown or a snooze with a full interval.
    public mutating func recordDrink(at now: Date,
                                     uptime: TimeInterval = ReminderClock.uptime,
                                     calendar: Calendar = .autoupdatingCurrent) {
        update(at: now, uptime: uptime, calendar: calendar)
        isAwaitingAcknowledgment = false
        isSnoozed = false
        remainingTime = intervalHours * 3_600
    }

    public mutating func setInterval(hours: Double, now: Date,
                                     uptime: TimeInterval = ReminderClock.uptime,
                                     calendar: Calendar = .autoupdatingCurrent) {
        update(at: now, uptime: uptime, calendar: calendar)
        let elapsed = max(0, intervalHours * 3_600 - remainingTime)
        intervalHours = Self.validated(hours)
        if !isAwaitingAcknowledgment && !isManuallyPaused && !isSnoozed {
            // Keep the use already counted, so + then − changes nothing.
            remainingTime = max(0, intervalHours * 3_600 - elapsed)
        }
    }

    public mutating func pause(for minutes: Int, at now: Date,
                               uptime: TimeInterval = ReminderClock.uptime,
                               calendar: Calendar = .autoupdatingCurrent) {
        update(at: now, uptime: uptime, calendar: calendar)
        guard minutes > 0 else { return }
        if isAwaitingAcknowledgment {
            // Re-offer immediately after resume rather than losing the reminder.
            isAwaitingAcknowledgment = false
            remainingTime = 0
            isSnoozed = false
        }
        let duration = TimeInterval(minutes) * 60
        pauseDeadlineUptime = uptime + duration
        pausedUntil = now.addingTimeInterval(duration)
    }

    public mutating func resume(at now: Date,
                                uptime: TimeInterval = ReminderClock.uptime,
                                calendar: Calendar = .autoupdatingCurrent) {
        update(at: now, uptime: uptime, calendar: calendar)
        pausedUntil = nil
        pauseDeadlineUptime = nil
    }

    public mutating func snooze(minutes: Int, at now: Date,
                                uptime: TimeInterval = ReminderClock.uptime,
                                calendar: Calendar = .autoupdatingCurrent) {
        update(at: now, uptime: uptime, calendar: calendar)
        guard isAwaitingAcknowledgment, minutes > 0 else { return }
        isAwaitingAcknowledgment = false
        remainingTime = TimeInterval(minutes) * 60
        isSnoozed = true
    }

    public mutating func setHours(weekday: DailyHours, weekend: DailyHours?, at now: Date,
                                  uptime: TimeInterval = ReminderClock.uptime,
                                  calendar: Calendar = .autoupdatingCurrent) {
        update(at: now, uptime: uptime, calendar: calendar)
        weekdayHours = Self.validHours(weekday)
        weekendHours = weekend.map(Self.validHours)
        update(at: now, uptime: uptime, calendar: calendar)
    }

    /// Captures the latest active-use countdown for persistence. Call this
    /// periodically while the app is running so a crash loses at most one save
    /// interval; restoration never subtracts offline time.
    public mutating func snapshot(at now: Date,
                                  uptime: TimeInterval = ReminderClock.uptime,
                                  calendar: Calendar = .autoupdatingCurrent) -> ReminderSnapshot {
        update(at: now, uptime: uptime, calendar: calendar)
        return ReminderSnapshot(
            capturedAt: now,
            capturedDay: calendar.dateComponents([.era, .year, .month, .day], from: now),
            timeZoneIdentifier: calendar.timeZone.identifier,
            intervalHours: intervalHours,
            weekdayHours: weekdayHours,
            weekendHours: weekendHours,
            remainingTime: remainingTime,
            isAwaitingAcknowledgment: isAwaitingAcknowledgment,
            pausedUntil: pausedUntil,
            isSnoozed: isSnoozed
        )
    }

    private static func canRestore(_ snapshot: ReminderSnapshot, at now: Date,
                                   hours: Double, weekdayHours: DailyHours,
                                   weekendHours: DailyHours?, calendar: Calendar) -> Bool {
        guard snapshot.capturedAt.timeIntervalSince1970.isFinite,
              snapshot.capturedAt <= now,
              snapshot.timeZoneIdentifier == calendar.timeZone.identifier,
              snapshot.intervalHours == hours,
              snapshot.weekdayHours == weekdayHours,
              snapshot.weekendHours == weekendHours,
              Self.sameDay(snapshot.capturedDay,
                           calendar.dateComponents([.era, .year, .month, .day], from: now)),
              Self.sameDay(snapshot.capturedDay,
                           calendar.dateComponents([.era, .year, .month, .day], from: snapshot.capturedAt))
        else { return false }
        return true
    }

    private static func validRemaining(_ remaining: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        guard remaining.isFinite else { return fallback }
        return min(max(remaining, 0), maximumHours * 3_600)
    }

    private static func validHours(_ hours: DailyHours) -> DailyHours {
        hours.isValid ? hours : DailyHours()
    }

    private static func sameDay(_ lhs: DateComponents, _ rhs: DateComponents) -> Bool {
        lhs.era == rhs.era && lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day
    }

    private static func hours(for date: Date, weekday: DailyHours, weekend: DailyHours?,
                              calendar: Calendar) -> DailyHours {
        guard let weekend, calendar.isDateInWeekend(date) else { return weekday }
        return weekend
    }

    private struct PeriodBounds {
        var start: Date
        var end: Date
    }

    private static func periodBounds(for date: Date, hours: DailyHours,
                                     calendar: Calendar) -> [PeriodBounds] {
        let dayStart = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        return hours.periods.map { period in
            let start = localTime(period.startMinutes, on: dayStart, calendar: calendar)
            let end = period.endMinutes == 1_440
                ? nextDay
                : localTime(period.endMinutes, on: dayStart, calendar: calendar)
            return PeriodBounds(start: start, end: end)
        }
    }

    private static func periodContaining(_ date: Date, hours: DailyHours,
                                         calendar: Calendar) -> PeriodBounds? {
        periodBounds(for: date, hours: hours, calendar: calendar)
            .first { date >= $0.start && date < $0.end }
    }

    private static func isRestGap(_ date: Date, hours: DailyHours,
                                  calendar: Calendar) -> Bool {
        let periods = periodBounds(for: date, hours: hours, calendar: calendar)
        guard periods.count > 1 else { return false }
        for index in 0..<(periods.count - 1) {
            let previous = periods[index]
            let next = periods[index + 1]
            if previous.end < next.start && date >= previous.end && date < next.start {
                return true
            }
        }
        return false
    }

    private static func nextBoundary(after date: Date, weekdayHours: DailyHours,
                                     weekendHours: DailyHours?, calendar: Calendar) -> Date {
        let todayHours = hours(for: date, weekday: weekdayHours,
                               weekend: weekendHours, calendar: calendar)
        if let boundary = periodBounds(for: date, hours: todayHours, calendar: calendar)
            .flatMap({ [$0.start, $0.end] })
            .filter({ $0 > date })
            .min() {
            return boundary
        }

        let tomorrow = calendar.date(byAdding: .day, value: 1,
                                     to: calendar.startOfDay(for: date))!
        let tomorrowHours = hours(for: tomorrow, weekday: weekdayHours,
                                  weekend: weekendHours, calendar: calendar)
        return periodBounds(for: tomorrow, hours: tomorrowHours, calendar: calendar)
            .first!.start
    }

    /// Counts only the parts of a monotonic elapsed interval that intersect
    /// configured periods, walking local days so delayed callbacks can cross
    /// several same-day gaps safely.
    private static func activeSeconds(from start: Date, through end: Date,
                                      weekdayHours: DailyHours, weekendHours: DailyHours?,
                                      calendar: Calendar) -> TimeInterval {
        guard end > start else { return 0 }
        var dayStart = calendar.startOfDay(for: start)
        var counted: TimeInterval = 0

        while dayStart < end {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let dayHours = hours(for: dayStart, weekday: weekdayHours,
                                 weekend: weekendHours, calendar: calendar)
            for period in periodBounds(for: dayStart, hours: dayHours, calendar: calendar) {
                let overlapStart = max(start, period.start)
                let overlapEnd = min(end, period.end)
                if overlapEnd > overlapStart {
                    counted += overlapEnd.timeIntervalSince(overlapStart)
                }
            }
            dayStart = nextDay
        }
        return counted
    }

    private static func hasRestGapCrossed(after start: Date, through end: Date,
                                          weekdayHours: DailyHours, weekendHours: DailyHours?,
                                          calendar: Calendar) -> Bool {
        guard end > start else { return false }
        var dayStart = calendar.startOfDay(for: start)

        while dayStart < end {
            let dayHours = hours(for: dayStart, weekday: weekdayHours,
                                 weekend: weekendHours, calendar: calendar)
            let periods = periodBounds(for: dayStart, hours: dayHours, calendar: calendar)
            if periods.count > 1 {
                for index in 0..<(periods.count - 1) {
                    let current = periods[index]
                    let next = periods[index + 1]
                    if current.end < next.start && current.end > start && current.end <= end {
                        return true
                    }
                }
            }
            dayStart = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        }
        return false
    }

    private static func localTime(_ minute: Int, on date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
    }
}
