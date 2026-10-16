import Foundation
import BigWaterCore

struct HistoryCorrectionChecks {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 16,
                      _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    static let checks: [(String, () throws -> Void)] = [
        ("history corrections: sorted backfill across dates", {
            try HistoryCorrectionChecks().sortedBackfillAcrossDates()
        }),
        ("history corrections: retained boundary and future rejection", {
            try HistoryCorrectionChecks().retainedBoundaryAndFutureRejection()
        }),
        ("history corrections: edit across day and month", {
            try HistoryCorrectionChecks().editAcrossDayAndMonth()
        }),
        ("history corrections: edit only one duplicate", {
            try HistoryCorrectionChecks().editOnlyOneDuplicate()
        }),
        ("history corrections: missing and invalid edits preserve history", {
            try HistoryCorrectionChecks().missingAndInvalidEditsPreserveHistory()
        }),
        ("history corrections: clock-corrected future entry remains editable", {
            try HistoryCorrectionChecks().futureEntryRemainsEditable()
        }),
        ("history corrections: serialization keeps the date array format", {
            try HistoryCorrectionChecks().serializationKeepsDateArrayFormat()
        })
    ]

    func sortedBackfillAcrossDates() throws {
        let now = date()
        let first = date(2026, 10, 12, 8)
        let second = date(2026, 10, 14, 9)
        let third = date(2026, 10, 15, 10)
        var history = HydrationHistory()
        history.recordDrink(at: now, calendar: calendar)

        try expect(history.addPastDrink(at: third, now: now, calendar: calendar),
                   "A recent past confirmation was rejected")
        try expect(history.addPastDrink(at: first, now: now, calendar: calendar),
                   "An earlier confirmation was rejected")
        try expect(history.addPastDrink(at: second, now: now, calendar: calendar),
                   "A middle confirmation was rejected")
        try expect(history.drinks == [first, second, third, now],
                   "Backfilled confirmations were not sorted across dates")
    }

    func retainedBoundaryAndFutureRejection() throws {
        let now = date()
        let cutoff = calendar.date(byAdding: .day, value: -HydrationHistory.retentionDays,
                                   to: calendar.startOfDay(for: now))!
        var history = HydrationHistory()
        try expect(history.addPastDrink(at: cutoff, now: now, calendar: calendar),
                   "The inclusive retention boundary was rejected")
        let acceptedHistory = history

        try expect(!history.addPastDrink(at: cutoff.addingTimeInterval(-1), now: now,
                                         calendar: calendar),
                   "A confirmation older than the retention window was accepted")
        try expect(!history.addPastDrink(at: now.addingTimeInterval(1), now: now,
                                         calendar: calendar),
                   "A future confirmation was accepted")
        try expect(history == acceptedHistory,
                   "Rejected backfills changed the history")

        var pruneCheck = HydrationHistory()
        let stale = cutoff.addingTimeInterval(-20 * 86_400)
        pruneCheck.recordDrink(at: stale, calendar: calendar)
        try expect(pruneCheck.addPastDrink(at: cutoff, now: now, calendar: calendar),
                   "A valid backfill at the retained boundary was rejected")
        try expect(pruneCheck.drinks == [cutoff],
                   "A new backfill did not prune entries relative to now")
    }

    func editAcrossDayAndMonth() throws {
        let original = date(2026, 10, 1, 0, 5)
        let replacement = date(2026, 9, 30, 23, 55)
        let other = date(2026, 10, 2, 7)
        var history = HydrationHistory()
        history.recordDrink(at: original, calendar: calendar)
        history.recordDrink(at: other, calendar: calendar)

        try expect(history.updateDrink(from: original, to: replacement, now: date(), calendar: calendar),
                   "A valid cross-month edit was rejected")
        try expect(history.drinks == [replacement, other],
                   "The edit did not preserve sorted order and the other confirmation")
    }

    func editOnlyOneDuplicate() throws {
        let original = date(2026, 10, 8, 9)
        let replacement = date(2026, 10, 9, 10)
        var history = HydrationHistory()
        history.recordDrink(at: original, calendar: calendar)
        history.recordDrink(at: original, calendar: calendar)
        history.recordDrink(at: date(2026, 10, 10), calendar: calendar)

        try expect(history.updateDrink(from: original, to: replacement, now: date(), calendar: calendar),
                   "An existing duplicate could not be edited")
        try expect(history.drinks == [original, replacement, date(2026, 10, 10)],
                   "The edit changed more than one duplicate or lost another entry")
    }

    func missingAndInvalidEditsPreserveHistory() throws {
        let original = date(2026, 10, 7, 9)
        let missing = date(2026, 10, 7, 10)
        var history = HydrationHistory()
        history.recordDrink(at: original, calendar: calendar)
        let savedHistory = history
        let now = date()
        let cutoff = calendar.date(byAdding: .day, value: -HydrationHistory.retentionDays,
                                   to: calendar.startOfDay(for: now))!

        try expect(!history.updateDrink(from: missing, to: date(2026, 10, 8), now: now,
                                        calendar: calendar),
                   "An absent original entry was edited")
        try expect(!history.updateDrink(from: original, to: now.addingTimeInterval(1), now: now,
                                        calendar: calendar),
                   "An edit to a future time was accepted")
        try expect(!history.updateDrink(from: original, to: cutoff.addingTimeInterval(-1), now: now,
                                        calendar: calendar),
                   "An edit outside the retention window was accepted")
        try expect(history == savedHistory,
                   "A missing or invalid edit lost the original confirmation")
    }

    func futureEntryRemainsEditable() throws {
        let future = date(2026, 10, 18, 9)
        let corrected = date(2026, 10, 15, 8)
        var history = HydrationHistory()
        history.recordDrink(at: future, calendar: calendar)

        try expect(history.updateDrink(from: future, to: corrected, now: date(), calendar: calendar),
                   "A clock-corrected future timestamp could not be corrected")
        try expect(history.drinks == [corrected],
                   "Correcting a future timestamp changed the wrong entry")
    }

    func serializationKeepsDateArrayFormat() throws {
        var history = HydrationHistory()
        try expect(history.addPastDrink(at: date(2026, 10, 12, 8), now: date(), calendar: calendar),
                   "Serialization fixture backfill was rejected")
        try expect(history.addPastDrink(at: date(2026, 10, 15, 10), now: date(), calendar: calendar),
                   "Serialization fixture second backfill was rejected")
        let encoded = try JSONEncoder().encode(history)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        try expect(object?.keys.sorted() == ["drinks"] && object?["drinks"] is [Any],
                   "History serialization no longer uses the existing drinks date array")
        let restored = try JSONDecoder().decode(HydrationHistory.self, from: encoded)
        try expect(restored == history,
                   "Backfilled confirmations did not survive serialization and reload")
    }
}
