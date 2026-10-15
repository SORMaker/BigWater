import Foundation

/// Local record of explicit drink confirmations.
public struct HydrationHistory: Codable, Equatable {
    public private(set) var drinks: [Date]

    public init() {
        drinks = []
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
