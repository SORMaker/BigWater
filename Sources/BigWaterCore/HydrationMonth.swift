import Foundation

/// Monday-first weeks for a contribution-style month view. Dates are built
/// with calendar arithmetic so daylight saving changes cannot skip a day.
public struct HydrationMonth {
    public let start: Date
    public let end: Date
    public let weeks: [[Date?]]

    /// Clock corrections can leave saved confirmations after `today`. Keep
    /// their months reachable so the user can inspect and remove mistakes.
    public static func latestAvailableMonth(history: HydrationHistory, today: Date,
                                            calendar: Calendar = .autoupdatingCurrent) -> Date {
        let current = calendar.dateInterval(of: .month, for: today)!.start
        return history.drinks.compactMap { calendar.dateInterval(of: .month, for: $0)?.start }
            .reduce(current, max)
    }

    public init(containing date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let interval = calendar.dateInterval(of: .month, for: date)!
        start = interval.start
        end = interval.end
        let leading = (calendar.component(.weekday, from: start) + 5) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: start)!.count
        var cells = [Date?](repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: start)!)
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        weeks = stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<($0 + 7)])
        }
    }
}
