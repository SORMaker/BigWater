import Foundation
import BigWaterCore
@testable import BigWaterApp

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(data: try! encoder.encode(value), encoding: .utf8)!
}

/// User defaults that live in memory, so a test run leaves nothing on disk.
final class MemoryDefaults: KeyValueStore {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func dictionaryRepresentation() -> [String: Any] { values }
}

func scratchDefaults() -> MemoryDefaults { MemoryDefaults() }

/// What 0.5.2 wrote: the last build before the rewrite. If this stops
/// loading, every installed copy loses its settings and history on update.
private let saveFrom052 = """
{"preferences":{"intervalHours":1.5,"weekdayHours":{"periods":[{"startMinutes":540,"endMinutes":720,"name":"上午"},\
{"startMinutes":840,"endMinutes":1320}],"startMinutes":540,"endMinutes":1320},\
"weekendHours":{"startMinutes":600,"endMinutes":1200},"style":"compact","soundEnabled":true,\
"appearance":{"theme":"mint","character":"droplet"},\
"placement":{"position":"topLeft","screen":"selected","displayID":"37D8832A-2D66-02CA-B9F7-8F30A301B230"},\
"showMenuBarCountdown":true},\
"progress":{"capturedAt":815100000,"capturedDay":{"era":1,"year":2026,"month":10,"day":31,"isLeapMonth":false},\
"timeZoneIdentifier":"Asia/Shanghai","intervalHours":1.5,\
"weekdayHours":{"periods":[{"startMinutes":540,"endMinutes":720,"name":"上午"},{"startMinutes":840,"endMinutes":1320}],\
"startMinutes":540,"endMinutes":1320},"weekendHours":{"startMinutes":600,"endMinutes":1200},\
"remainingTime":1234.5,"isAwaitingAcknowledgment":false,"pausedUntil":815103600,"isSnoozed":true},\
"history":{"drinks":[815000000,815050000]}}
"""

@MainActor
let dataSuite = Suite(name: "data", tests: [
    // MARK: Hours

    test("periods must be in order, inside the day and apart") {
        expect(DayHours.standard.isValid)
        expect(DayHours([Period(start: 0, end: 1_440)]).isValid)
        expect(DayHours([Period(start: 480, end: 600), Period(start: 600, end: 720)]).isValid, "touching is fine")
        expect(!DayHours([]).isValid)
        expect(!DayHours([Period(start: 600, end: 600)]).isValid)
        expect(!DayHours([Period(start: 480, end: 700), Period(start: 600, end: 720)]).isValid, "overlap")
        expect(!DayHours([Period(start: 840, end: 900), Period(start: 480, end: 600)]).isValid, "out of order")
        expect(!DayHours([Period(start: -10, end: 60)]).isValid)
        expect(!DayHours([Period(start: 600, end: 1_500)]).isValid)
    },

    test("a new period goes into free time after the last one") {
        let morning = DayHours([Period(start: 540, end: 720)])
        expectEqual(morning.addingPeriod()?.periods.last, Period(start: 750, end: 870), "half an hour of rest first")
        let untilLate = DayHours([Period(start: 540, end: 1_400)])
        expectEqual(untilLate.addingPeriod()?.periods.last, Period(start: 1_400, end: 1_440), "what is left of the evening")
        let evening = DayHours([Period(start: 600, end: 1_440)])
        expectEqual(evening.addingPeriod()?.periods.last, Period(start: 0, end: 120), "otherwise the first free stretch")
        expectEqual(DayHours([Period(start: 0, end: 1_440)]).addingPeriod(), nil, "a full day has no room")
    },

    test("hours are saved in the shape every build can read") {
        expectEqual(json(DayHours.standard), #"{"endMinutes":1320,"startMinutes":360}"#)
        let split = DayHours([Period(start: 540, end: 720, name: "上午"), Period(start: 840, end: 1_320)])
        expectEqual(json(split), #"{"endMinutes":1320,"periods":[{"endMinutes":720,"name":"上午","startMinutes":540},"#
            + #"{"endMinutes":1320,"startMinutes":840}],"startMinutes":540}"#)
        expectEqual(try decode(DayHours.self, json(split)), split)
        expectEqual(try decode(DayHours.self, #"{"startMinutes":480,"endMinutes":1200}"#),
                    DayHours([Period(start: 480, end: 1_200)]), "the single window of builds before 0.4")
    },

    // MARK: Preferences

    test("settings keep what they understand and default the rest") {
        expectEqual(try decode(Preferences.self, "{}"), Preferences())
        let odd = try decode(Preferences.self, """
            {"intervalHours":"abc","style":"hologram","soundEnabled":3,"appearance":{"theme":"purple","character":"droplet"},
             "placement":{"position":"center","screen":"main"},"awayMinutes":"5","somethingNew":[1,2]}
            """)
        var expected = Preferences()
        expected.look.mascot = .droplet
        expected.placement.screen = .main
        expectEqual(odd, expected, "one unknown value must not cost its neighbours")
    },

    test("settings out of range are put back in range") {
        var preferences = Preferences()
        preferences.intervalHours = 999
        preferences.weekdayHours = DayHours([Period(start: 900, end: 600)])
        preferences.weekendHours = DayHours([])
        preferences.awayMinutes = 7
        let valid = preferences.validated()
        expectEqual(valid.intervalHours, 24)
        expectEqual(valid.weekdayHours, .standard)
        expectEqual(valid.weekendHours, nil)
        expectEqual(valid.awayMinutes, 5)
        expectEqual(valid.plan.awayAfter, 300)
        preferences.pauseWhenAway = false
        expectEqual(preferences.plan.awayAfter, nil)
    },

    test("renaming a period does not change how time is counted") {
        var renamed = Preferences()
        renamed.weekdayHours.periods[0].name = "白天"
        expect(renamed.countsLike(Preferences()))
        expect(renamed != Preferences())
        renamed.weekdayHours.periods[0].end = 1_200
        expect(!renamed.countsLike(Preferences()))
    },

    // MARK: Drink log

    test("the log stays in order and forgets after ninety days") {
        var log = DrinkLog()
        log.record(at: october(15, 12), calendar: shanghai)
        log.record(at: october(15, 9), calendar: shanghai)
        expectEqual(log.drinks, [october(15, 9), october(15, 12)])
        let muchLater = shanghai.date(byAdding: .day, value: 90, to: october(15, 8))!
        log.record(at: muchLater, calendar: shanghai)
        expectEqual(log.drinks.count, 3, "day 90 still shows day 0")
        log.record(at: muchLater.addingTimeInterval(24 * hour), calendar: shanghai)
        expectEqual(log.drinks.count, 2, "on day 91 the first day is gone")
    },

    test("a forgotten drink can be added, but not in the future or too far back") {
        var log = DrinkLog()
        let now = october(15, 12)
        expect(log.addPast(at: october(14, 20), now: now, calendar: shanghai))
        expect(log.addPast(at: now, now: now, calendar: shanghai))
        expect(!log.addPast(at: now.addingTimeInterval(1), now: now, calendar: shanghai))
        expect(!log.addPast(at: now.addingTimeInterval(-100 * 24 * hour), now: now, calendar: shanghai))
        expectEqual(log.count(on: now, calendar: shanghai), 1)
        expectEqual(log.count(on: october(14, 1), calendar: shanghai), 1)
    },

    test("an entry can be retimed or removed without touching the others") {
        var log = DrinkLog()
        let now = october(15, 18)
        for hour in [9, 12, 12, 15] { log.record(at: october(15, hour), calendar: shanghai) }
        expect(log.remove(at: october(15, 12)), "removes one of two identical entries")
        expectEqual(log.drinks, [october(15, 9), october(15, 12), october(15, 15)])
        expect(!log.remove(at: october(15, 13)))
        expect(log.move(from: october(15, 9), to: october(15, 16), now: now, calendar: shanghai))
        expectEqual(log.drinks, [october(15, 12), october(15, 15), october(15, 16)])
        expect(!log.move(from: october(15, 12), to: october(15, 19), now: now, calendar: shanghai), "not into the future")
        expect(!log.move(from: october(15, 11), to: october(15, 10), now: now, calendar: shanghai), "no such entry")
        expectEqual(log.drinks.count, 3)
    },

    test("one unreadable entry does not cost the rest of the log") {
        let log = try decode(DrinkLog.self, #"{"drinks":[815050000,"oops",null,815000000]}"#)
        expectEqual(log.drinks.map(\.timeIntervalSinceReferenceDate), [815_000_000, 815_050_000])
        expectEqual(try decode(DrinkLog.self, #"{"drinks":"none"}"#).drinks, [])
    },

    test("a month is laid out in weeks from Monday") {
        let grid = MonthGrid(containing: october(15, 12), calendar: shanghai)
        // 1 October 2026 is a Thursday.
        expectEqual(grid.weeks.count, 5)
        expectEqual(grid.weeks[0].map { $0 != nil }, [false, false, false, true, true, true, true])
        expectEqual(grid.weeks[0][3], october(1, 0))
        expectEqual(grid.weeks.flatMap { $0 }.compactMap { $0 }.count, 31)
        expectEqual(grid.weeks[4][5], october(31, 0))

        var log = DrinkLog()
        log.record(at: october(3, 9), calendar: shanghai)
        expectEqual(log.count(in: grid), 1)
        expectEqual(MonthGrid.latest(for: log, today: october(15, 12), calendar: shanghai), grid.start)
    },

    test("a month with a daylight saving change still has every day once") {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        for month in [3, 11] {
            let grid = MonthGrid(containing: newYork.date(from: DateComponents(year: 2026, month: month, day: 10))!,
                                 calendar: newYork)
            let days = grid.weeks.flatMap { $0 }.compactMap { $0 }.map { newYork.component(.day, from: $0) }
            expectEqual(days, Array(1...(month == 3 ? 31 : 30)))
        }
    },

    // MARK: Saved state

    test("a save from 0.5.2 loads whole") {
        let reading = SavedState.read(Data(saveFrom052.utf8))
        expect(reading.isComplete, "nothing in it would be lost by saving again")
        let state = reading.state
        expectEqual(state?.preferences?.intervalHours, 1.5)
        expectEqual(state?.preferences?.weekdayHours.periods.first?.name, "上午")
        expectEqual(state?.preferences?.weekendHours, DayHours([Period(start: 600, end: 1_200)]))
        expectEqual(state?.preferences?.style, .compact)
        expectEqual(state?.preferences?.look, Look(theme: .mint, mascot: .droplet))
        expectEqual(state?.preferences?.placement.corner, .topLeft)
        expectEqual(state?.preferences?.placement.displayID, "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        expectEqual(state?.preferences?.pauseWhenAway, true, "a setting newer than the save takes its default")
        expectEqual(state?.progress?.remainingTime, 1234.5)
        expectEqual(state?.progress?.isSnoozed, true)
        expectEqual(state?.history?.drinks.count, 2)
    },

    test("each part of a save is read on its own") {
        let reading = SavedState.read(Data(#"{"preferences":7,"progress":"broken","history":{"drinks":[815000000]}}"#.utf8))
        expectEqual(reading.state?.preferences, nil)
        expectEqual(reading.state?.progress, nil)
        expectEqual(reading.state?.history?.drinks.count, 1)
        expect(!reading.isComplete)
        expectEqual(SavedState.read(Data("not json".utf8)), .init(state: nil, isComplete: false))
    },

    test("a save that would lose something is set aside before it is overwritten") {
        let defaults = scratchDefaults()
        let fromTheFuture = #"{"preferences":{"intervalHours":1,"style":"hologram"},"history":{"drinks":[815000000]}}"#
        defaults.set(Data(fromTheFuture.utf8), forKey: StateStore.key)
        func copies() -> [Data] {
            defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(StateStore.key + ".unreadable.") }
                .compactMap { $0.value as? Data }
        }
        let loaded = StateStore(defaults: defaults).load()
        expectEqual(loaded.preferences.intervalHours, 1)
        expectEqual(loaded.preferences.style, .animated)
        expectEqual(copies(), [Data(fromTheFuture.utf8)])
        _ = StateStore(defaults: defaults).load()
        expectEqual(copies().count, 1, "the same data is kept once")

        let clean = scratchDefaults()
        clean.set(Data(saveFrom052.utf8), forKey: StateStore.key)
        _ = StateStore(defaults: clean).load()
        expect(clean.dictionaryRepresentation().keys.allSatisfy { !$0.contains("unreadable") },
               "a save that loads whole needs no copy")
    },

    test("what is saved is what loads") {
        let defaults = scratchDefaults()
        var preferences = Preferences()
        preferences.intervalHours = 0.5
        preferences.weekendHours = DayHours([Period(start: 600, end: 720, name: "周末")])
        preferences.look = Look(theme: .peach, mascot: .droplet)
        var log = DrinkLog()
        log.record(at: october(15, 9), calendar: shanghai)
        var schedule = Schedule(plan: preferences.plan, now: Moment(date: october(15, 9), uptime: 1), calendar: shanghai)
        let progress = schedule.progress(at: Moment(date: october(15, 9, 10), uptime: 601), calendar: shanghai)
        StateStore(defaults: defaults).save(preferences: preferences, progress: progress, log: log)

        let loaded = StateStore(defaults: defaults).load()
        expectEqual(loaded.preferences, preferences)
        expectEqual(loaded.progress, progress)
        expectEqual(loaded.log, log)
        expectEqual(loaded.progress?.remainingTime, 20 * minute)
    },

    test("the interval of a build before 0.4 is carried over") {
        let defaults = scratchDefaults()
        defaults.set(0.75, forKey: StateStore.legacyIntervalKey)
        expectEqual(StateStore(defaults: defaults).load().preferences.intervalHours, 0.75)
        expectEqual(StateStore(defaults: scratchDefaults()).load().preferences, Preferences())
    }
])
