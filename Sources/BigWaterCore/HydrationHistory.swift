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

    public mutating func recordDrink(at date: Date) {
        drinks.append(date)
        drinks.sort()
    }

    public func count(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        drinks.reduce(into: 0) { count, drink in
            if calendar.isDate(drink, inSameDayAs: date) { count += 1 }
        }
    }

    public func drinks(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        drinks.filter { calendar.isDate($0, inSameDayAs: date) }.sorted()
    }
}
