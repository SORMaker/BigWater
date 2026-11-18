import Foundation

/// One stretch of a day in local time, in minutes after midnight. An `end`
/// of 1 440 is the midnight that closes the day.
public struct Period: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    /// A label the person gave it. It never changes what is counted.
    public var name: String

    public init(start: Int, end: Int, name: String = "") {
        self.start = start
        self.end = end
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case start = "startMinutes", end = "endMinutes", name
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decode(Int.self, forKey: .start)
        end = try values.decode(Int.self, forKey: .end)
        name = values.lenient(String.self, .name) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        if !name.isEmpty { try values.encode(name, forKey: .name) }
    }
}

/// The periods of one day during which reminders may appear.
public struct DayHours: Codable, Equatable, Sendable {
    public var periods: [Period]

    public static let standard = DayHours([Period(start: 360, end: 1_320)])

    public init(_ periods: [Period]) { self.periods = periods }

    /// In order, inside the day, and not overlapping. Periods may touch.
    public var isValid: Bool {
        guard !periods.isEmpty else { return false }
        var previousEnd = -1
        for period in periods {
            guard period.start >= 0, period.start < period.end, period.end <= 1_440,
                  period.start >= previousEnd else { return false }
            previousEnd = period.end
        }
        return true
    }

    public var sorted: DayHours { DayHours(periods.sorted { $0.start < $1.start }) }

    public func hasSameTiming(as other: DayHours) -> Bool {
        periods.count == other.periods.count
            && zip(periods, other.periods).allSatisfy { $0.start == $1.start && $0.end == $1.end }
    }

    /// A new period in free time, after the last one when there is room.
    /// Nil when the day has no free half hour left.
    public func addingPeriod() -> DayHours? {
        let taken = sorted.periods
        let gaps = zip([0] + taken.map(\.end), taken.map(\.start) + [1_440]).filter { $1 - $0 >= 30 }
        let lastEnd = taken.last?.end ?? 0
        guard let gap = gaps.last(where: { $0.0 >= lastEnd }) ?? gaps.first else { return nil }
        // Leave half an hour of rest before it when there is space to.
        let start = gap.0 + (gap.1 - gap.0 >= 60 && gap.0 != 0 ? 30 : 0)
        return DayHours(periods + [Period(start: start, end: min(start + 120, gap.1))])
    }

    // Builds before 0.4 saved one window as `startMinutes`/`endMinutes`.
    // Both shapes are read, and both are written so any build can read it back.
    private enum CodingKeys: String, CodingKey { case periods, startMinutes, endMinutes }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let periods = values.lenient([Period].self, .periods) {
            self.periods = periods
        } else {
            let fallback = DayHours.standard.periods[0]
            periods = [Period(start: values.lenient(Int.self, .startMinutes) ?? fallback.start,
                              end: values.lenient(Int.self, .endMinutes) ?? fallback.end)]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if periods.count != 1 || !periods[0].name.isEmpty {
            try values.encode(periods, forKey: .periods)
        }
        try values.encode(periods.first?.start ?? 0, forKey: .startMinutes)
        try values.encode(periods.last?.end ?? 0, forKey: .endMinutes)
    }
}

/// Hours for the week: one set for every day, or a separate one for weekends.
public struct WeekHours: Equatable, Sendable {
    public var weekday: DayHours
    public var weekend: DayHours?

    public init(weekday: DayHours = .standard, weekend: DayHours? = nil) {
        self.weekday = weekday
        self.weekend = weekend
    }

    public func hours(on date: Date, calendar: Calendar) -> DayHours {
        guard let weekend, calendar.isDateInWeekend(date) else { return weekday }
        return weekend
    }

    public func hasSameTiming(as other: WeekHours) -> Bool {
        guard weekday.hasSameTiming(as: other.weekday) else { return false }
        switch (weekend, other.weekend) {
        case (nil, nil): return true
        case let (mine?, theirs?): return mine.hasSameTiming(as: theirs)
        default: return false
        }
    }

    /// Unusable hours fall back rather than leaving a day with no periods.
    var usable: WeekHours {
        WeekHours(weekday: weekday.isValid ? weekday : .standard,
                  weekend: weekend.map { $0.isValid ? $0 : .standard })
    }
}

/// Week hours laid onto real dates.
struct Timetable {
    let hours: WeekHours
    let calendar: Calendar

    struct Span {
        var start: Date
        var end: Date
    }

    /// The periods of the day that contains `date`.
    func spans(on date: Date) -> [Span] {
        let dayStart = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        func time(_ minutes: Int) -> Date {
            minutes == 1_440 ? nextDay
                : calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: dayStart) ?? dayStart
        }
        return hours.hours(on: date, calendar: calendar).periods.map { Span(start: time($0.start), end: time($0.end)) }
    }

    /// Where a moment falls in its day.
    func place(of date: Date) -> Schedule.Window {
        let spans = spans(on: date)
        if spans.contains(where: { date >= $0.start && date < $0.end }) { return .open }
        let inGap = zip(spans, spans.dropFirst()).contains { $0.end < $1.start && date >= $0.end && date < $1.start }
        return inGap ? .gap : .closed
    }

    /// The next time a period opens or closes.
    func nextBoundary(after date: Date) -> Date {
        if let today = spans(on: date).flatMap({ [$0.start, $0.end] }).filter({ $0 > date }).min() {
            return today
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        return spans(on: tomorrow).first!.start
    }

    /// How much of `start..<end` lies inside periods.
    func openSeconds(from start: Date, to end: Date) -> TimeInterval {
        guard end > start else { return 0 }
        var total: TimeInterval = 0
        var day = calendar.startOfDay(for: start)
        while day < end {
            for span in spans(on: day) {
                let from = max(start, span.start)
                let to = min(end, span.end)
                if to > from { total += to.timeIntervalSince(from) }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return total
    }

    /// True when a period ended into a same-day gap after `start` and no
    /// later than `end`.
    func crossesGap(after start: Date, through end: Date) -> Bool {
        guard end > start else { return false }
        var day = calendar.startOfDay(for: start)
        while day < end {
            let spans = spans(on: day)
            if zip(spans, spans.dropFirst()).contains(where: {
                $0.end < $1.start && $0.end > start && $0.end <= end
            }) { return true }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return false
    }
}

extension KeyedDecodingContainer {
    /// A missing, mistyped or unknown value reads as nil instead of failing
    /// everything around it, so one bad field never costs the rest of a save.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}
