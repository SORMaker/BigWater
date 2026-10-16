import Foundation

/// The menu shows active-use time, so lunch breaks do not inflate its minutes.
public struct MenuBarStatus: Equatable {
    public enum Phase: Equatable {
        case counting, snoozed, paused, waiting, resting, finishedForToday
    }

    public let phase: Phase
    public let remainingFraction: Double
    public let remainingMinutes: Int?

    public init(schedule: ReminderSchedule, canPresentReminder: Bool) {
        remainingFraction = min(1, max(0, schedule.remainingTime / (schedule.intervalHours * 3_600)))
        if !schedule.isWithinReminderHours {
            phase = .resting
        } else if schedule.isManuallyPaused || !canPresentReminder {
            phase = .paused
        } else if schedule.isAwaitingAcknowledgment {
            phase = .waiting
        } else if schedule.nextReminderAt == nil {
            phase = .finishedForToday
        } else {
            phase = schedule.isSnoozed ? .snoozed : .counting
        }
        remainingMinutes = phase == .counting || phase == .snoozed
            ? Int(ceil(max(0, schedule.remainingTime) / 60)) : nil
    }

    public var label: String {
        switch phase {
        case .counting: return "计时中"
        case .snoozed: return "稍后提醒"
        case .paused: return "已暂停"
        case .waiting: return "等待喝水确认"
        case .resting: return "休息中"
        case .finishedForToday: return "今天不再提醒"
        }
    }

    public func title(showMinutes: Bool) -> String {
        guard showMinutes else { return "" }
        if let remainingMinutes { return "\(remainingMinutes)分" }
        switch phase {
        case .paused: return "暂停"
        case .waiting: return "喝水"
        case .resting: return "休息"
        case .finishedForToday: return "明天见"
        default: return ""
        }
    }
}
