import Foundation

/// When the person drank, kept on this Mac only. It holds times, not amounts.
public struct DrinkLog: Codable, Equatable, Sendable {
    /// Oldest first.
    public private(set) var drinks: [Date]

    /// Older entries are dropped: the app shows recent months only, and the
    /// whole log is written with every save.
    public static let retentionDays = 90

    public init() { drinks = [] }

    /// One unreadable entry must not cost the rest of the log.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        drinks = (values.lenient([Entry].self, .drinks) ?? []).compactMap(\.date).sorted()
    }

    private struct Entry: Decodable {
        let date: Date?
        init(from decoder: Decoder) throws { date = try? decoder.singleValueContainer().decode(Date.self) }
    }

    /// A drink that just happened.
    public mutating func record(at date: Date, calendar: Calendar = .autoupdatingCurrent) {
        insert(date)
        prune(asOf: date, calendar: calendar)
    }

    /// A drink the person forgot to confirm. False when `date` is in the
    /// future or older than the log keeps.
    @discardableResult
    public mutating func addPast(at date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard Self.isKept(date, now: now, calendar: calendar) else { return false }
        insert(date)
        prune(asOf: now, calendar: calendar)
        return true
    }

    /// Corrects the time of one entry and leaves every other one alone.
    @discardableResult
    public mutating func move(from old: Date, to new: Date, now: Date,
                              calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard let index = drinks.firstIndex(of: old), Self.isKept(new, now: now, calendar: calendar)
        else { return false }
        drinks.remove(at: index)
        insert(new)
        return true
    }

    /// Removes exactly one entry at that time.
    @discardableResult
    public mutating func remove(at date: Date) -> Bool {
        guard let index = drinks.lastIndex(of: date) else { return false }
        drinks.remove(at: index)
        return true
    }

    public func drinks(on day: Date, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        drinks.filter { calendar.isDate($0, inSameDayAs: day) }
    }

    public func count(on day: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        drinks(on: day, calendar: calendar).count
    }

    public func count(in month: MonthGrid) -> Int {
        drinks.filter { $0 >= month.start && $0 < month.end }.count
    }

    /// The earliest time an entry may have, seen from `now`.
    public static func cutoff(from now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)) ?? now
    }

    private static func isKept(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        date <= now && date >= cutoff(from: now, calendar: calendar)
    }

    private mutating func prune(asOf now: Date, calendar: Calendar) {
        let cutoff = Self.cutoff(from: now, calendar: calendar)
        drinks.removeAll { $0 < cutoff }
    }

    private mutating func insert(_ date: Date) {
        drinks.insert(date, at: drinks.firstIndex { $0 > date } ?? drinks.endIndex)
    }
}

/// One month laid out for a heat map: weeks of seven days starting on Monday,
/// with nil where a week reaches outside the month.
public struct MonthGrid: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let weeks: [[Date?]]

    /// Days are found by calendar arithmetic, so a daylight saving change
    /// can neither skip nor repeat one.
    public init(containing date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let month = calendar.dateInterval(of: .month, for: date)!
        let first = month.start
        start = first
        end = month.end
        let leading = (calendar.component(.weekday, from: first) + 5) % 7
        let days = calendar.range(of: .day, in: .month, for: first)!.count
        var cells = [Date?](repeating: nil, count: leading)
        cells += (0..<days).map { calendar.date(byAdding: .day, value: $0, to: first)! }
        cells += [Date?](repeating: nil, count: (7 - cells.count % 7) % 7)
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// The latest month worth showing. A corrected system clock can leave
    /// entries after today; their months stay reachable so they can be fixed.
    public static func latest(for log: DrinkLog, today: Date,
                              calendar: Calendar = .autoupdatingCurrent) -> Date {
        let current = calendar.dateInterval(of: .month, for: today)!.start
        return log.drinks.compactMap { calendar.dateInterval(of: .month, for: $0)?.start }.reduce(current, max)
    }
}
