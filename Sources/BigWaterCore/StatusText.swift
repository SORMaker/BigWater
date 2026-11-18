import Foundation

/// The countdown in words, for the menu bar and the panel's countdown card.
public struct StatusText: Equatable, Sendable {
    public let status: Schedule.Status
    /// Share of the interval still to go, from 0 to 1.
    public let remainingFraction: Double
    /// Minutes of use left, while a countdown is running.
    public let remainingMinutes: Int?
    /// Above the countdown.
    public let title: String
    /// Shown instead of the digits when there is nothing to count.
    public let replacement: String?
    /// What happens next.
    public let detail: String

    public init(_ schedule: Schedule, now: Date, calendar: Calendar = .autoupdatingCurrent) {
        func time(_ date: Date?) -> String {
            date?.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)) ?? ""
        }
        status = schedule.status
        remainingFraction = min(1, max(0, schedule.remaining / schedule.interval))
        remainingMinutes = status == .counting || status == .snoozed
            ? Int((max(0, schedule.remaining) / 60).rounded(.up)) : nil

        switch status {
        case .resting:
            title = "休息时间"
            replacement = "休息中"
            let opening = time(schedule.nextBoundary)
            detail = calendar.isDate(now, inSameDayAs: schedule.nextBoundary)
                ? "\(opening) 后接着剩余时间继续计时"
                : "本地 \(opening) 后使用电脑，开始新的计时"
        case .paused:
            title = "计时已暂停"
            replacement = nil
            detail = "\(time(schedule.pausedUntil)) 自动恢复，保留当前剩余时间"
        case .asleep:
            title = "休眠暂停"
            replacement = nil
            detail = "亮屏后接着剩余时间继续计时"
        case .waiting:
            title = "等待你的确认"
            replacement = "喝口水吧"
            detail = "点“去喝水”，喝完自动记录；也可以稍后再提醒"
        case .away:
            title = "离开暂停"
            replacement = nil
            detail = "回来使用键盘或鼠标后接着剩余时间继续计时"
        case .doneForToday:
            title = "今天不再提醒"
            replacement = "明天见"
            detail = "剩余作息不足一个间隔，明天使用时重新计时"
        case .snoozed, .counting:
            title = status == .snoozed ? "稍后提醒" : "距离下次提醒"
            replacement = nil
            detail = "下次提醒 \(time(schedule.fireDate)) · 休眠时暂停"
        }
    }

    /// For VoiceOver on the menu bar item.
    public var label: String {
        switch status {
        case .counting: return "计时中"
        case .snoozed: return "稍后提醒"
        case .paused, .asleep: return "已暂停"
        case .away: return "离开时暂停"
        case .waiting: return "等待喝水确认"
        case .resting: return "休息中"
        case .doneForToday: return "今天不再提醒"
        }
    }

    /// The few characters beside the menu bar bottle, when that is switched on.
    public var menuTitle: String {
        if let remainingMinutes { return "\(remainingMinutes)分" }
        switch status {
        case .paused, .asleep: return "暂停"
        case .away: return "离开"
        case .waiting: return "喝水"
        case .resting: return "休息"
        case .doneForToday: return "明天见"
        case .counting, .snoozed: return ""
        }
    }

    /// `HH:MM:SS` until the reminder, or the word that replaces it.
    public func countdown(_ seconds: TimeInterval) -> String {
        if let replacement { return replacement }
        let whole = Int(max(0, seconds).rounded(.up))
        return String(format: "%02d:%02d:%02d", whole / 3_600, whole % 3_600 / 60, whole % 60)
    }
}
