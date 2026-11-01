import Foundation

/// The settings panel's countdown card: a title, a word shown in place of the
/// digits when there is nothing to count, and one line about what comes next.
public struct CountdownStatus: Equatable {
    public let title: String
    public let replacement: String?
    public let detail: String

    public init(schedule: ReminderSchedule, canPresentReminder: Bool, now: Date,
                calendar: Calendar = .autoupdatingCurrent) {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        func time(_ date: Date?) -> String { date?.formatted(style) ?? "" }

        if !schedule.isWithinReminderHours {
            title = "休息时间"
            replacement = "休息中"
            let opening = time(schedule.nextBoundaryAt)
            detail = calendar.isDate(now, inSameDayAs: schedule.nextBoundaryAt)
                ? "\(opening) 后接着剩余时间继续计时"
                : "本地 \(opening) 后使用电脑，开始新的计时"
        } else if schedule.isManuallyPaused {
            title = "计时已暂停"
            replacement = nil
            detail = "\(time(schedule.pausedUntil)) 自动恢复，保留当前剩余时间"
        } else if !canPresentReminder {
            title = "休眠暂停"
            replacement = nil
            detail = "亮屏后接着剩余时间继续计时"
        } else if schedule.isAwaitingAcknowledgment {
            title = "等待你的确认"
            replacement = "喝口水吧"
            detail = "喝水后点提醒里或下面的按钮，也可以稍后再提醒"
        } else if let next = schedule.nextReminderAt {
            title = schedule.isSnoozed ? "稍后提醒" : "距离下次提醒"
            replacement = nil
            detail = "下次提醒 \(time(next)) · 休眠时暂停"
        } else {
            title = "今天不再提醒"
            replacement = "明天见"
            detail = "剩余作息不足一个间隔，明天使用时重新计时"
        }
    }
}
