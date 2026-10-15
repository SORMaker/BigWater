import Foundation

/// A reminder stays outstanding until Claude is clicked. The next interval
/// starts at that click, so overdue reminders never form a queue.
public struct ReminderSchedule {
    public static let defaultHours = 2.0
    public static let minimumHours = 0.5
    public static let maximumHours = 24.0

    public private(set) var intervalHours: Double
    public private(set) var nextReminderAt: Date?
    public private(set) var isAwaitingAcknowledgment = false

    public init(hours: Double = defaultHours, now: Date = Date()) {
        intervalHours = Self.validated(hours)
        nextReminderAt = now.addingTimeInterval(intervalHours * 3_600)
    }

    public static func validated(_ hours: Double) -> Double {
        guard hours.isFinite else { return defaultHours }
        return min(max(hours, minimumHours), maximumHours)
    }

    public func isDue(at now: Date) -> Bool {
        guard let nextReminderAt, !isAwaitingAcknowledgment else { return false }
        return now >= nextReminderAt
    }

    public mutating func reminderDidStart() {
        isAwaitingAcknowledgment = true
        nextReminderAt = nil
    }

    public mutating func acknowledge(at now: Date) {
        guard isAwaitingAcknowledgment else { return }
        isAwaitingAcknowledgment = false
        nextReminderAt = now.addingTimeInterval(intervalHours * 3_600)
    }

    public mutating func setInterval(hours: Double, now: Date) {
        intervalHours = Self.validated(hours)
        if !isAwaitingAcknowledgment {
            nextReminderAt = now.addingTimeInterval(intervalHours * 3_600)
        }
    }
}
