import Darwin
import Foundation

/// One reading of both clocks. Everything decided in one pass uses the same
/// reading, so nothing can slip across a boundary between two clock reads.
public struct Moment: Equatable, Sendable {
    /// Wall time: which day and which hours apply.
    public var date: Date
    /// Seconds on a clock that only moves forward and keeps running while
    /// the Mac sleeps. Elapsed time is always measured here, so changing the
    /// system time never changes the countdown.
    public var uptime: TimeInterval

    public init(date: Date, uptime: TimeInterval) {
        self.date = date
        self.uptime = uptime
    }

    public static func now() -> Moment {
        Moment(date: Date(), uptime: continuousUptime())
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func continuousUptime() -> TimeInterval {
        Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

/// A calendar day as the person sees it, comparable across time zone changes.
public struct LocalDay: Equatable, Sendable {
    public var era: Int
    public var year: Int
    public var month: Int
    public var day: Int

    public init(_ date: Date, calendar: Calendar) {
        self.init(calendar.dateComponents([.era, .year, .month, .day], from: date))
    }

    public init(_ components: DateComponents) {
        era = components.era ?? 0
        year = components.year ?? 0
        month = components.month ?? 0
        day = components.day ?? 0
    }
}
