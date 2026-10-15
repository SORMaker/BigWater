import Foundation

/// Counts screen-awake use inside the configured local daily window. A reminder
/// remains outstanding until acknowledged, snoozed, paused, or the window ends.
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
    private var windowEnd: Date
    private var pauseDeadlineUptime: TimeInterval?

    public var isManuallyPaused: Bool { pausedUntil != nil }

    public var isCounting: Bool {
        isSessionActive && isWithinReminderHours && !isAwaitingAcknowledgment
            && !isManuallyPaused
    }

    public var isDue: Bool { isCounting && remainingTime <= 0 }

    public var nextReminderAt: Date? {
        guard isCounting else { return nil }
        let due = lastUpdateAt.addingTimeInterval(remainingTime)
        return due < windowEnd ? due : nil
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
        localDay = calendar.dateComponents([.era, .year, .month, .day], from: now)
        lastUpdateAt = now
        lastUptime = uptime
        windowEnd = now
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
            let bounds = Self.bounds(for: now, hours: currentHours, calendar: calendar)
            let insideWindow = now >= bounds.start && now < bounds.end
            isWithinReminderHours = insideWindow
            windowEnd = bounds.end
            if insideWindow {
                remainingTime = Self.validRemaining(snapshot.remainingTime, fallback: intervalHours * 3_600)
                isAwaitingAcknowledgment = snapshot.isAwaitingAcknowledgment
                isSnoozed = snapshot.isSnoozed && !isAwaitingAcknowledgment
            } else {
                // An overnight or post-window launch retires yesterday's UI and
                // gives the next active window a complete interval.
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
        let oldWithinWindow = isWithinReminderHours
        let newLocalDay = !Self.sameDay(today, localDay)

        if newLocalDay {
            // A new local day always starts with a complete interval.
            remainingTime = intervalHours * 3_600
            isAwaitingAcknowledgment = false
            isSnoozed = false
        } else if isCounting {
            // Monotonic elapsed time prevents clock adjustments from changing
            // the countdown. Clamp delayed callbacks at the previous cutoff.
            let elapsed = max(0, uptime - lastUptime)
            let beforeCutoff = max(0, windowEnd.timeIntervalSince(lastUpdateAt))
            remainingTime = max(0, remainingTime - min(elapsed, beforeCutoff))
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
        let bounds = Self.bounds(for: now, hours: hours, calendar: calendar)
        isWithinReminderHours = now >= bounds.start && now < bounds.end
        windowEnd = bounds.end

        // Opening a window that was previously closed begins from a full
        // interval; inactive or overnight time never consumes the countdown.
        if !newLocalDay && !oldWithinWindow && isWithinReminderHours {
            remainingTime = intervalHours * 3_600
            isAwaitingAcknowledgment = false
            isSnoozed = false
        }
        if !isWithinReminderHours {
            isAwaitingAcknowledgment = false
            isSnoozed = false
        }
        if let isSessionActive { self.isSessionActive = isSessionActive }

        if now < bounds.start {
            nextBoundaryAt = bounds.start
        } else if now < bounds.end {
            nextBoundaryAt = bounds.end
        } else {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let nextHours = Self.hours(for: tomorrow, weekday: weekdayHours,
                                       weekend: weekendHours, calendar: calendar)
            nextBoundaryAt = Self.bounds(for: tomorrow, hours: nextHours, calendar: calendar).start
        }

        localDay = today
        lastUpdateAt = now
        lastUptime = uptime
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

    private static func bounds(for date: Date, hours: DailyHours, calendar: Calendar) -> (start: Date, end: Date) {
        let start = localTime(hours.startMinutes, on: date, calendar: calendar)
        let end: Date
        if hours.endMinutes == 1_440 {
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        } else {
            end = localTime(hours.endMinutes, on: date, calendar: calendar)
        }
        return (start, end)
    }

    private static func localTime(_ minute: Int, on date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
    }
}
