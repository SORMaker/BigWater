import Foundation
import BigWaterCore

// A test runner small enough to read in a minute.
//
//     swift run BigWaterTests            every test
//     swift run BigWaterTests schedule   tests whose suite or name contains "schedule"
//
// A test is a closure. `expect` records a failure and carries on, so one run
// shows everything that is wrong.

struct Test {
    let name: String
    let body: @MainActor () throws -> Void
}

struct Suite {
    let name: String
    let tests: [Test]
}

func test(_ name: String, _ body: @escaping @MainActor () throws -> Void) -> Test {
    Test(name: name, body: body)
}

@MainActor
enum Run {
    static var failures: [String] = []
    static var expectations = 0

    static func all(_ suites: [Suite], matching filter: String?) -> Int32 {
        var ran = 0
        let started = Date()
        for suite in suites {
            for test in suite.tests {
                let title = "\(suite.name): \(test.name)"
                if let filter, !title.localizedCaseInsensitiveContains(filter) { continue }
                ran += 1
                let before = failures.count
                do { try test.body() } catch { failures.append("threw \(error)") }
                for index in before..<failures.count {
                    failures[index] = "✗ \(title)\n    \(failures[index])"
                }
            }
        }
        failures.forEach { print($0) }
        let time = String(format: "%.1f", Date().timeIntervalSince(started))
        if ran == 0 {
            print("No test matches \"\(filter ?? "")\".")
            return 2
        }
        print(failures.isEmpty
            ? "✓ \(ran) tests, \(expectations) expectations, \(time)s"
            : "\(failures.count) failed expectations in \(ran) tests, \(time)s")
        return failures.isEmpty ? 0 : 1
    }
}

@MainActor
func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) {
    Run.expectations += 1
    let passed = (try? condition()) ?? false
    if !passed { Run.failures.append("\(file):\(line) \(message())") }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T,
                               _ message: @autoclosure () -> String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    Run.expectations += 1
    let value = try? actual()
    if value != expected {
        Run.failures.append("\(file):\(line) \(message()) got \(value.map { "\($0)" } ?? "an error"), expected \(expected)")
    }
}

// MARK: - A calendar and a clock to test with

/// China has no daylight saving time, so hours here are plain arithmetic.
let shanghai: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.locale = Locale(identifier: "zh_CN")
    return calendar
}()

/// A time in October 2026. The 15th is a Thursday, the 17th a Saturday.
func october(_ day: Int, _ hour: Int, _ minute: Int = 0, calendar: Calendar = shanghai) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

let minute: TimeInterval = 60
let hour: TimeInterval = 3_600

/// Both clocks, moved by hand.
struct TestClock {
    var date: Date
    var uptime: TimeInterval = 5_000

    var moment: Moment { Moment(date: date, uptime: uptime) }

    /// Time passes on both clocks.
    mutating func pass(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
        uptime += seconds
    }

    mutating func go(to next: Date) { pass(next.timeIntervalSince(date)) }

    /// Someone sets the system time; no real time passes.
    mutating func setWallClock(to next: Date) { date = next }
}
