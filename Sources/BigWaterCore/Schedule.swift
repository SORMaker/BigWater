import Foundation

/// The countdown to the next reminder.
///
/// It counts only time the person spends at an awake Mac inside their hours:
/// sleep, a dark display, a manual pause, time away from the keyboard and the
/// gaps between periods all stop it, and it carries on where it left off. A
/// new day always starts with a whole interval.
///
/// Nothing here reads a clock. Callers pass one `Moment` per pass.
public struct Schedule: Equatable, Sendable {
    /// What the person chose: how often, during which hours, and how long
    /// without input counts as being away.
    public struct Plan: Equatable, Sendable {
        public var intervalHours: Double
        public var hours: WeekHours
        /// Nil turns away detection off.
        public var awayAfter: TimeInterval?

        public static let defaultHours = 2.0
        public static let hourRange = (5.0 / 60)...24.0

        public init(intervalHours: Double = defaultHours, hours: WeekHours = .init(),
                    awayAfter: TimeInterval? = nil) {
            self.intervalHours = intervalHours
            self.hours = hours
            self.awayAfter = awayAfter
        }

        public static func validHours(_ hours: Double) -> Double {
            hours.isFinite ? min(max(hours, hourRange.lowerBound), hourRange.upperBound) : defaultHours
        }

        var usable: Plan {
            Plan(intervalHours: Self.validHours(intervalHours), hours: hours.usable,
                 awayAfter: awayAfter.map { $0.isFinite ? max(60, $0) : 300 })
        }
    }

    public enum Stage: Equatable, Sendable {
        /// Counting down a whole interval.
        case counting
        /// Counting down the few minutes of a "later".
        case snoozed
        /// A reminder is up and waits for the person.
        case waiting
    }

    /// Where a moment falls in its day.
    public enum Window: Equatable, Sendable {
        /// Inside a period.
        case open
        /// Between two periods of the same day: the countdown waits and
        /// carries on in the next period.
        case gap
        /// Before the first period or after the last.
        case closed
    }

    /// The one thing to tell the person about the countdown right now.
    public enum Status: Equatable, Sendable {
        case resting, paused, asleep, waiting, away, doneForToday, snoozed, counting
    }

    public private(set) var plan: Plan
    public private(set) var stage = Stage.counting
    public private(set) var remaining: TimeInterval
    public private(set) var window = Window.closed
    /// Awake display in the person's own session.
    public private(set) var isAwake: Bool
    public private(set) var isAway = false
    public private(set) var pausedUntil: Date?
    /// The next time a period opens or closes.
    public private(set) var nextBoundary: Date
    public private(set) var day: LocalDay

    private var anchor: Moment
    /// A pause ends on the monotonic clock, so setting the system time
    /// neither shortens nor stretches it.
    private var pauseDeadline: TimeInterval?
    private var calendar: Calendar

    /// The wall time this state is true for: the last pass.
    public var asOf: Date { anchor.date }
    public var interval: TimeInterval { plan.intervalHours * 3_600 }
    public var isPaused: Bool { pausedUntil != nil }

    /// True while use of the Mac is being counted.
    public var isRunning: Bool {
        isAwake && window == .open && stage != .waiting && !isPaused && !isAway
    }

    public var isDue: Bool { isRunning && remaining <= 0 }

    /// When the reminder will come if the person keeps using the Mac. Nil
    /// while nothing is counted, and when today's hours end first.
    public var fireDate: Date? {
        guard isRunning else { return nil }
        let spans = timetable.spans(on: anchor.date)
        var left = remaining
        for (index, span) in spans.enumerated() where span.end > anchor.date {
            let from = max(anchor.date, span.start)
            let room = span.end.timeIntervalSince(from)
            if left < room { return from.addingTimeInterval(left) }
            // Due exactly as a period closes: it comes when the next one opens.
            if left == room { return spans.dropFirst(index + 1).first?.start }
            left -= room
        }
        return nil
    }

    /// When to look again without any event: the reminder, a period opening
    /// or closing, or a pause running out. Nil while asleep.
    public var nextWake: Date? {
        guard isAwake else { return nil }
        return [fireDate, nextBoundary, pausedUntil].compactMap { $0 }.min()
    }

    public var status: Status {
        if window != .open { return .resting }
        if isPaused { return .paused }
        if !isAwake { return .asleep }
        if stage == .waiting { return .waiting }
        if isAway { return .away }
        if fireDate == nil { return .doneForToday }
        return stage == .snoozed ? .snoozed : .counting
    }

    /// Starts a countdown, picking up a saved one when it still applies:
    /// same day, same time zone and same plan. Time the app was not running
    /// is never counted.
    public init(plan: Plan = .init(), now: Moment = .now(), isAwake: Bool = true,
                calendar: Calendar = .autoupdatingCurrent, saved: SavedProgress? = nil) {
        self.plan = plan.usable
        self.isAwake = isAwake
        self.calendar = calendar
        remaining = self.plan.intervalHours * 3_600
        anchor = now
        nextBoundary = now.date
        day = LocalDay(now.date, calendar: calendar)

        guard let saved, saved.capturedAt.timeIntervalSince1970.isFinite, saved.capturedAt <= now.date else {
            advance(to: now, calendar: calendar)
            return
        }
        // A pause outlives everything else in a save, even a changed plan.
        if let until = saved.pausedUntil, until.timeIntervalSince1970.isFinite, until > now.date {
            pausedUntil = until
            pauseDeadline = now.uptime + until.timeIntervalSince(now.date)
        }
        if saved.applies(to: self.plan, on: day, calendar: calendar) {
            let place = timetable.place(of: now.date)
            if place != .closed {
                remaining = saved.remainingTime.isFinite
                    ? min(max(saved.remainingTime, 0), Plan.hourRange.upperBound * 3_600) : interval
                let restedSince = place == .gap
                    || timetable.crossesGap(after: saved.capturedAt, through: now.date)
                if saved.isAwaitingAcknowledgment && restedSince {
                    // The reminder itself was not saved. Offer it again when
                    // the next period opens rather than treat it as seen.
                    remaining = 0
                } else if saved.isAwaitingAcknowledgment {
                    stage = .waiting
                }
                if saved.isSnoozed && stage != .waiting { stage = .snoozed }
            }
        }
        advance(to: now, calendar: calendar)
    }

    /// Moves the countdown to `now`.
    ///
    /// - `awake`: whether the display is awake in the person's session from
    ///   now on. Nil keeps what was last reported.
    /// - `idle`: seconds since the last keyboard or pointer input, read with
    ///   the same `now`. Nil means no new reading: someone away stays away
    ///   and nothing is counted until a reading shows input again.
    public mutating func advance(to now: Moment, awake: Bool? = nil, idle: TimeInterval? = nil,
                                 calendar: Calendar = .autoupdatingCurrent) {
        let today = LocalDay(now.date, calendar: calendar)
        let before = timetable
        let anchor = self.anchor
        let elapsed = max(0, now.uptime - anchor.uptime)
        func date(atUptime uptime: TimeInterval) -> Date {
            anchor.date.addingTimeInterval(uptime - anchor.uptime)
        }

        // The stretch since the last pass that may count, on the wall clock
        // as it stood then: it starts once a pause has run out.
        var from = date(atUptime: max(anchor.uptime, pauseDeadline ?? anchor.uptime))
        var to = date(atUptime: anchor.uptime + elapsed)
        // Presence is only known from the last input, so it is applied after
        // the fact: away begins once idle time passes the threshold and ends
        // at the input that brought the person back.
        var away = false
        if let threshold = plan.awayAfter {
            if let idle {
                let lastInput = now.uptime - max(0, idle)
                away = idle >= threshold
                if isAway { from = max(from, date(atUptime: lastInput)) }
                if away { to = min(to, date(atUptime: lastInput + threshold)) }
            } else if isAway {
                away = true
                to = from
            }
        }

        if today != day {
            remaining = interval
            stage = .counting
        } else if isAwake && stage != .waiting {
            remaining = max(0, remaining - before.openSeconds(from: from, to: to))
        }
        // Whether an open reminder sat through a rest is judged on the wall
        // clock, including a clock that was set forward meanwhile.
        let rested = today == day
            && before.crossesGap(after: anchor.date, through: max(now.date, date(atUptime: anchor.uptime + elapsed)))

        if let deadline = pauseDeadline {
            if deadline <= now.uptime {
                pauseDeadline = nil
                pausedUntil = nil
            } else {
                pausedUntil = now.date.addingTimeInterval(deadline - now.uptime)
            }
        }

        self.calendar = calendar
        window = timetable.place(of: now.date)
        if stage == .waiting && (window != .open || rested) {
            // Hours ended under an open reminder. After a rest it comes back
            // when the next period opens; at the end of the day it is dropped.
            stage = .counting
            remaining = window == .closed ? interval : 0
        }
        if stage == .snoozed && window == .closed { stage = .counting }

        if let awake { isAwake = awake }
        isAway = away
        nextBoundary = timetable.nextBoundary(after: now.date)
        day = today
        self.anchor = now
    }

    /// A reminder went up. The countdown stops until the person answers it.
    public mutating func reminderShown() {
        guard isRunning else { return }
        stage = .waiting
        remaining = interval
    }

    /// The person drank, answering a reminder or on their own. A manual
    /// pause stays in force.
    public mutating func recordDrink(at now: Moment, calendar: Calendar = .autoupdatingCurrent) {
        advance(to: now, calendar: calendar)
        stage = .counting
        remaining = interval
    }

    /// Puts an open reminder off for a few minutes.
    public mutating func snooze(minutes: Int, at now: Moment, calendar: Calendar = .autoupdatingCurrent) {
        advance(to: now, calendar: calendar)
        guard stage == .waiting, minutes > 0 else { return }
        stage = .snoozed
        remaining = TimeInterval(minutes) * 60
    }

    /// Stops everything for a while. An open reminder comes straight back
    /// when the pause ends.
    public mutating func pause(minutes: Int, at now: Moment, calendar: Calendar = .autoupdatingCurrent) {
        advance(to: now, calendar: calendar)
        guard minutes > 0 else { return }
        if stage == .waiting {
            stage = .counting
            remaining = 0
        }
        let length = TimeInterval(minutes) * 60
        pauseDeadline = now.uptime + length
        pausedUntil = now.date.addingTimeInterval(length)
    }

    public mutating func resume(at now: Moment, calendar: Calendar = .autoupdatingCurrent) {
        advance(to: now, calendar: calendar)
        pauseDeadline = nil
        pausedUntil = nil
    }

    /// Switches to a new plan from this moment on.
    public mutating func adopt(_ next: Plan, at now: Moment, calendar: Calendar = .autoupdatingCurrent) {
        advance(to: now, calendar: calendar)
        let next = next.usable
        if next.intervalHours != plan.intervalHours {
            // Keep the use already counted, so longer-then-shorter changes nothing.
            // A pause holds its countdown as it is (a reminder may be waiting
            // behind it), but never for longer than the new interval.
            let used = max(0, interval - remaining)
            plan.intervalHours = next.intervalHours
            if stage == .counting { remaining = isPaused ? min(remaining, interval) : max(0, interval - used) }
        }
        if next.hours != plan.hours {
            plan.hours = next.hours
            advance(to: now, calendar: calendar)
        }
        if next.awayAfter != plan.awayAfter {
            plan.awayAfter = next.awayAfter
            if next.awayAfter == nil { isAway = false }
        }
    }

    /// What to save so the countdown survives a restart.
    public mutating func progress(at now: Moment, calendar: Calendar = .autoupdatingCurrent) -> SavedProgress {
        advance(to: now, calendar: calendar)
        return SavedProgress(capturedAt: now.date,
                             capturedDay: calendar.dateComponents([.era, .year, .month, .day], from: now.date),
                             timeZoneIdentifier: calendar.timeZone.identifier,
                             intervalHours: plan.intervalHours,
                             weekdayHours: plan.hours.weekday, weekendHours: plan.hours.weekend,
                             remainingTime: remaining, isAwaitingAcknowledgment: stage == .waiting,
                             pausedUntil: pausedUntil, isSnoozed: stage == .snoozed)
    }

    private var timetable: Timetable { Timetable(hours: plan.hours, calendar: calendar) }
}

/// The countdown as it is written to disk. The field names are the saved
/// format of every installed copy, so they stay as they are.
public struct SavedProgress: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var capturedDay: DateComponents
    public var timeZoneIdentifier: String
    public var intervalHours: Double
    public var weekdayHours: DayHours
    public var weekendHours: DayHours?
    public var remainingTime: TimeInterval
    public var isAwaitingAcknowledgment: Bool
    public var pausedUntil: Date?
    public var isSnoozed: Bool

    /// A save continues only on the day it was made, in the same time zone
    /// and under the same plan. Anything else starts a whole interval.
    func applies(to plan: Schedule.Plan, on today: LocalDay, calendar: Calendar) -> Bool {
        let savedDay = LocalDay(capturedDay)
        return timeZoneIdentifier == calendar.timeZone.identifier
            && intervalHours == plan.intervalHours
            && WeekHours(weekday: weekdayHours, weekend: weekendHours).hasSameTiming(as: plan.hours)
            && savedDay == today
            && savedDay == LocalDay(capturedAt, calendar: calendar)
    }
}
