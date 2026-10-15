import Foundation

/// A same-day local-time window. `endMinutes == 1_440` means midnight at the
/// end of the selected day.
public struct DailyHours: Codable, Equatable {
    public var startMinutes: Int
    public var endMinutes: Int

    public init(startMinutes: Int = 360, endMinutes: Int = 1320) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    public var isValid: Bool {
        startMinutes >= 0 && startMinutes < endMinutes && endMinutes <= 1_440
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DailyHours()
        startMinutes = values.lenientValue(Int.self, forKey: .startMinutes) ?? defaults.startMinutes
        endMinutes = values.lenientValue(Int.self, forKey: .endMinutes) ?? defaults.endMinutes
    }
}

public enum ReminderStyle: String, Codable, CaseIterable {
    case animated
    case compact
}

public enum ReminderCharacter: String, Codable, CaseIterable {
    case claude
    case droplet
}

public enum ReminderTheme: String, Codable, CaseIterable {
    case blue
    case mint
    case peach
}

public struct ReminderAppearance: Codable, Equatable {
    public var theme: ReminderTheme
    public var character: ReminderCharacter

    public init(theme: ReminderTheme = .blue, character: ReminderCharacter = .claude) {
        self.theme = theme
        self.character = character
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReminderAppearance()
        theme = values.lenientValue(ReminderTheme.self, forKey: .theme) ?? defaults.theme
        character = values.lenientValue(ReminderCharacter.self, forKey: .character) ?? defaults.character
    }
}

/// User-controlled settings shared by the app, settings UI, and reminder
/// scheduler. Values loaded from storage should pass through `validated()`.
public struct AppPreferences: Codable, Equatable {
    public var intervalHours: Double = 2
    public var weekdayHours: DailyHours = .init()
    public var weekendHours: DailyHours? = nil
    public var style: ReminderStyle = .animated
    public var soundEnabled: Bool = false
    public var appearance: ReminderAppearance = .init()

    public init() {}

    /// Settings saved by older or newer builds keep every value this build
    /// understands; missing, mistyped or unknown values fall back to defaults.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences()
        intervalHours = values.lenientValue(Double.self, forKey: .intervalHours) ?? defaults.intervalHours
        weekdayHours = values.lenientValue(DailyHours.self, forKey: .weekdayHours) ?? defaults.weekdayHours
        weekendHours = values.lenientValue(DailyHours.self, forKey: .weekendHours)
        style = values.lenientValue(ReminderStyle.self, forKey: .style) ?? defaults.style
        soundEnabled = values.lenientValue(Bool.self, forKey: .soundEnabled) ?? defaults.soundEnabled
        appearance = values.lenientValue(ReminderAppearance.self, forKey: .appearance) ?? defaults.appearance
    }

    public func validated() -> AppPreferences {
        var result = self
        result.intervalHours = ReminderSchedule.validated(intervalHours)
        if !result.weekdayHours.isValid { result.weekdayHours = .init() }
        if let weekendHours, !weekendHours.isValid { result.weekendHours = nil }
        return result
    }
}

extension KeyedDecodingContainer {
    /// A missing, mistyped or unknown value reads as nil instead of failing
    /// the surrounding value.
    func lenientValue<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

/// A crash-safe snapshot of the active-day scheduler state. Elapsed time is
/// intentionally not applied while restoring: the next active session starts
/// from `remainingTime`, excluding time when the app was not running.
public struct ReminderSnapshot: Codable, Equatable {
    public var capturedAt: Date
    public var capturedDay: DateComponents
    public var timeZoneIdentifier: String
    public var intervalHours: Double
    public var weekdayHours: DailyHours
    public var weekendHours: DailyHours?
    public var remainingTime: TimeInterval
    public var isAwaitingAcknowledgment: Bool
    public var pausedUntil: Date?
    public var isSnoozed: Bool

    public init(capturedAt: Date, capturedDay: DateComponents, timeZoneIdentifier: String,
                intervalHours: Double, weekdayHours: DailyHours, weekendHours: DailyHours?,
                remainingTime: TimeInterval, isAwaitingAcknowledgment: Bool,
                pausedUntil: Date?, isSnoozed: Bool) {
        self.capturedAt = capturedAt
        self.capturedDay = capturedDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.intervalHours = intervalHours
        self.weekdayHours = weekdayHours
        self.weekendHours = weekendHours
        self.remainingTime = remainingTime
        self.isAwaitingAcknowledgment = isAwaitingAcknowledgment
        self.pausedUntil = pausedUntil
        self.isSnoozed = isSnoozed
    }
}
