import Foundation

/// Local record of explicit drink confirmations.
public struct HydrationHistory: Codable, Equatable {
    public private(set) var drinks: [Date]

    public init() {
        drinks = []
    }

    /// One unreadable entry must not discard the rest of the user's history.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        drinks = (values.lenientValue([ReadableDate].self, forKey: .drinks) ?? [])
            .compactMap(\.date).sorted()
    }

    private struct ReadableDate: Decodable {
        let date: Date?
        init(from decoder: Decoder) throws { date = try? decoder.singleValueContainer().decode(Date.self) }
    }

    /// Older confirmations are dropped; the app only shows recent days, and
    /// the whole history is rewritten with every checkpoint.
    public static let retentionDays = 90

    public mutating func recordDrink(at date: Date, calendar: Calendar = .autoupdatingCurrent) {
        drinks.insert(date, at: drinks.firstIndex { $0 > date } ?? drinks.endIndex)
        if let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays,
                                      to: calendar.startOfDay(for: date)) {
            drinks.removeAll { $0 < cutoff }
        }
    }

    /// Add an older confirmation without letting its date move the retention
    /// window backwards. The same-day upper bound keeps the current time
    /// authoritative when the system clock has changed.
    @discardableResult
    public mutating func addPastDrink(at date: Date, now: Date,
                                      calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard Self.isRetainedPastDate(date, now: now, calendar: calendar) else { return false }
        insertInOrder(date)
        prune(before: Self.retentionCutoff(now: now, calendar: calendar))
        return true
    }

    /// Correct one saved timestamp while preserving the number and order of
    /// all other confirmations. A clock-corrected future entry remains
    /// addressable as `from`, but its replacement must be a retained past time.
    @discardableResult
    public mutating func updateDrink(from oldDate: Date, to newDate: Date, now: Date,
                                     calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard let index = drinks.firstIndex(of: oldDate),
              Self.isRetainedPastDate(newDate, now: now, calendar: calendar) else { return false }
        drinks.remove(at: index)
        insertInOrder(newDate)
        return true
    }

    /// Remove exactly one confirmation, including histories saved by older builds.
    @discardableResult
    public mutating func removeDrink(at date: Date) -> Bool {
        guard let index = drinks.lastIndex(of: date) else { return false }
        drinks.remove(at: index)
        return true
    }

    public func count(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        drinks.reduce(into: 0) { count, drink in
            if calendar.isDate(drink, inSameDayAs: date) { count += 1 }
        }
    }

    public func drinks(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        drinks.filter { calendar.isDate($0, inSameDayAs: date) }.sorted()
    }

    private mutating func insertInOrder(_ date: Date) {
        drinks.insert(date, at: drinks.firstIndex { $0 > date } ?? drinks.endIndex)
    }

    private mutating func prune(before cutoff: Date) {
        drinks.removeAll { $0 < cutoff }
    }

    private static func retentionCutoff(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -retentionDays,
                      to: calendar.startOfDay(for: now)) ?? now
    }

    private static func isRetainedPastDate(_ date: Date, now: Date,
                                           calendar: Calendar) -> Bool {
        date <= now && date >= retentionCutoff(now: now, calendar: calendar)
    }
}
