import Foundation

/// Counts screen-awake use within the local daily window. A reminder remains
/// outstanding until clicked or until the daily window closes.
public struct ReminderSchedule {
    public static let defaultHours = 2.0
    public static let minimumHours = 0.5
    public static let maximumHours = 24.0
    public static let startHour = 6
    public static let stopHour = 22

    public private(set) var intervalHours: Double
    public private(set) var remainingTime: TimeInterval
    public private(set) var isAwaitingAcknowledgment = false
    public private(set) var isWithinReminderHours = false
    public private(set) var isSessionActive: Bool
    public private(set) var nextBoundaryAt: Date
    public private(set) var localDay: DateComponents

    private var lastUpdateAt: Date
    private var lastUptime: TimeInterval
    private var windowEnd: Date

    public var isCounting: Bool {
        isSessionActive && isWithinReminderHours && !isAwaitingAcknowledgment
    }

    public var isDue: Bool { isCounting && remainingTime <= 0 }

    public var nextReminderAt: Date? {
        guard isCounting else { return nil }
        let due = lastUpdateAt.addingTimeInterval(remainingTime)
        return due < windowEnd ? due : nil
    }

    /// Always includes the daily boundary, even while a reminder is on screen.
    public var nextCheckAt: Date? {
        guard isSessionActive else { return nil }
        return min(nextReminderAt ?? nextBoundaryAt, nextBoundaryAt)
    }

    public init(hours: Double = defaultHours, now: Date = Date(),
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                isSessionActive: Bool = true, calendar: Calendar = .autoupdatingCurrent) {
        intervalHours = Self.validated(hours)
        remainingTime = intervalHours * 3_600
        self.isSessionActive = isSessionActive
        localDay = calendar.dateComponents([.era, .year, .month, .day], from: now)
        lastUpdateAt = now
        lastUptime = uptime
        windowEnd = now
        nextBoundaryAt = now
        update(at: now, uptime: uptime, calendar: calendar)
    }

    public static func validated(_ hours: Double) -> Double {
        guard hours.isFinite else { return defaultHours }
        return min(max(hours, minimumHours), maximumHours)
    }

    public mutating func update(at now: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                isSessionActive: Bool? = nil, calendar: Calendar = .autoupdatingCurrent) {
        let today = calendar.dateComponents([.era, .year, .month, .day], from: now)
        if today != localDay {
            // The first use of a new local day starts a complete interval.
            remainingTime = intervalHours * 3_600
            isAwaitingAcknowledgment = false
        } else if isCounting {
            // Monotonic elapsed time prevents clock adjustments from changing
            // the countdown. Clamp delayed callbacks at the previous cutoff.
            let elapsed = max(0, uptime - lastUptime)
            let beforeCutoff = max(0, windowEnd.timeIntervalSince(lastUpdateAt))
            remainingTime = max(0, remainingTime - min(elapsed, beforeCutoff))
        }

        let start = calendar.date(bySettingHour: Self.startHour, minute: 0, second: 0, of: now)!
        windowEnd = calendar.date(bySettingHour: Self.stopHour, minute: 0, second: 0, of: now)!
        isWithinReminderHours = now >= start && now < windowEnd
        if !isWithinReminderHours { isAwaitingAcknowledgment = false }
        if let isSessionActive { self.isSessionActive = isSessionActive }
        nextBoundaryAt = now < start ? start : (now < windowEnd ? windowEnd
            : calendar.date(byAdding: .day, value: 1, to: start)!)
        localDay = today
        lastUpdateAt = now
        lastUptime = uptime
    }

    public mutating func reminderDidStart() {
        guard isCounting else { return }
        isAwaitingAcknowledgment = true
        remainingTime = intervalHours * 3_600
    }

    public mutating func acknowledge(at now: Date,
                                     uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                     calendar: Calendar = .autoupdatingCurrent) {
        update(at: now, uptime: uptime, calendar: calendar)
        guard isAwaitingAcknowledgment else { return }
        isAwaitingAcknowledgment = false
        remainingTime = intervalHours * 3_600
    }

    public mutating func setInterval(hours: Double, now: Date,
                                    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                    calendar: Calendar = .autoupdatingCurrent) {
        update(at: now, uptime: uptime, calendar: calendar)
        intervalHours = Self.validated(hours)
        if !isAwaitingAcknowledgment { remainingTime = intervalHours * 3_600 }
    }
}
