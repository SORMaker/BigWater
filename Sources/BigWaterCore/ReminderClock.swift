import Darwin
import Foundation

/// A monotonic clock that continues advancing while the Mac sleeps.
public enum ReminderClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static var uptime: TimeInterval {
        let conversion = timebase
        return Double(mach_continuous_time()) * Double(conversion.numer)
            / Double(conversion.denom) / 1_000_000_000
    }
}
