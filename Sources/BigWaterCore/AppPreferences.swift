import Foundation

/// One same-day local-time period. `endMinutes == 1_440` means midnight at
/// the end of the selected day.
public struct ReminderPeriod: Codable, Equatable {
    public var startMinutes: Int
    public var endMinutes: Int
    public var name: String

    private enum CodingKeys: String, CodingKey {
        case startMinutes, endMinutes, name
    }

    public init(startMinutes: Int, endMinutes: Int, name: String = "") {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startMinutes = try values.decode(Int.self, forKey: .startMinutes)
        endMinutes = try values.decode(Int.self, forKey: .endMinutes)
        name = values.lenientValue(String.self, forKey: .name) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(startMinutes, forKey: .startMinutes)
        try values.encode(endMinutes, forKey: .endMinutes)
        if !name.isEmpty { try values.encode(name, forKey: .name) }
    }
}

/// Ordered same-day local-time periods. The old single-window initializer and
/// outer-bound accessors remain available to existing callers.
public struct DailyHours: Codable, Equatable {
    public var periods: [ReminderPeriod]

    private enum CodingKeys: String, CodingKey {
        case periods
        case startMinutes
        case endMinutes
    }

    public init(startMinutes: Int = 360, endMinutes: Int = 1320) {
        periods = [ReminderPeriod(startMinutes: startMinutes, endMinutes: endMinutes)]
    }

    public init(periods: [ReminderPeriod]) {
        self.periods = periods
    }

    /// The first period's start, retained for callers that edit a single window.
    public var startMinutes: Int {
        get { periods.first?.startMinutes ?? 0 }
        set {
            guard !periods.isEmpty else {
                periods = [ReminderPeriod(startMinutes: newValue, endMinutes: 1_440)]
                return
            }
            periods[0].startMinutes = newValue
        }
    }

    /// The last period's end, retained for callers that edit a single window.
    public var endMinutes: Int {
        get { periods.last?.endMinutes ?? 0 }
        set {
            guard !periods.isEmpty else {
                periods = [ReminderPeriod(startMinutes: 0, endMinutes: newValue)]
                return
            }
            periods[periods.count - 1].endMinutes = newValue
        }
    }

    public var isValid: Bool {
        guard !periods.isEmpty else { return false }
        var previousEnd = -1
        for period in periods {
            guard period.startMinutes >= 0,
                  period.startMinutes < period.endMinutes,
                  period.endMinutes <= 1_440,
                  period.startMinutes >= previousEnd
            else { return false }
            previousEnd = period.endMinutes
        }
        return true
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let periods = values.lenientValue([ReminderPeriod].self, forKey: .periods) {
            self.periods = periods
        } else {
            let defaults = DailyHours()
            let start = values.lenientValue(Int.self, forKey: .startMinutes) ?? defaults.startMinutes
            let end = values.lenientValue(Int.self, forKey: .endMinutes) ?? defaults.endMinutes
            periods = [ReminderPeriod(startMinutes: start, endMinutes: end)]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if periods.count == 1 && periods[0].name.isEmpty {
            try values.encode(periods[0].startMinutes, forKey: .startMinutes)
            try values.encode(periods[0].endMinutes, forKey: .endMinutes)
        } else {
            try values.encode(periods, forKey: .periods)
            try values.encode(startMinutes, forKey: .startMinutes)
            try values.encode(endMinutes, forKey: .endMinutes)
        }
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

/// Where a reminder appears. A selected display is remembered by its stable
/// display UUID so reconnecting a monitor restores the user's choice.
public enum ReminderPosition: String, Codable, CaseIterable, Hashable {
    case random
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public enum ReminderScreen: String, Codable, CaseIterable, Hashable {
    case mouse
    case main
    case selected
}

public struct ReminderPlacement: Codable, Equatable {
    public var position: ReminderPosition
    public var screen: ReminderScreen
    public var displayID: String?

    public init(position: ReminderPosition = .random, screen: ReminderScreen = .mouse,
                displayID: String? = nil) {
        self.position = position
        self.screen = screen
        self.displayID = displayID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReminderPlacement()
        position = values.lenientValue(ReminderPosition.self, forKey: .position) ?? defaults.position
        screen = values.lenientValue(ReminderScreen.self, forKey: .screen) ?? defaults.screen
        displayID = values.lenientValue(String.self, forKey: .displayID)
    }
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
    public var placement: ReminderPlacement = .init()
    public var showMenuBarCountdown: Bool = false

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
        placement = values.lenientValue(ReminderPlacement.self, forKey: .placement) ?? defaults.placement
        showMenuBarCountdown = values.lenientValue(Bool.self, forKey: .showMenuBarCountdown)
            ?? defaults.showMenuBarCountdown
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
