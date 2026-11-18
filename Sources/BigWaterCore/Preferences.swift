import Foundation

public enum ReminderStyle: String, Codable, CaseIterable, Sendable {
    /// The mascot comes in from a screen edge.
    case animated
    /// A small card in a corner.
    case compact
}

public enum Mascot: String, Codable, CaseIterable, Sendable {
    case claude, droplet
}

public enum Theme: String, Codable, CaseIterable, Sendable {
    case blue, mint, peach
}

public struct Look: Codable, Equatable, Sendable {
    public var theme: Theme
    public var mascot: Mascot

    public init(theme: Theme = .blue, mascot: Mascot = .claude) {
        self.theme = theme
        self.mascot = mascot
    }

    private enum CodingKeys: String, CodingKey { case theme, mascot = "character" }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = values.lenient(Theme.self, .theme) ?? .blue
        mascot = values.lenient(Mascot.self, .mascot) ?? .claude
    }
}

public enum Corner: String, Codable, CaseIterable, Sendable {
    case random, topLeft, topRight, bottomLeft, bottomRight
}

public enum ScreenChoice: String, Codable, CaseIterable, Sendable {
    /// The display the pointer is on.
    case mouse
    /// The system's primary display.
    case main
    /// One display, remembered by its UUID so it survives reconnecting.
    case selected
}

public struct Placement: Codable, Equatable, Sendable {
    public var corner: Corner
    public var screen: ScreenChoice
    public var displayID: String?

    public init(corner: Corner = .random, screen: ScreenChoice = .mouse, displayID: String? = nil) {
        self.corner = corner
        self.screen = screen
        self.displayID = displayID
    }

    private enum CodingKeys: String, CodingKey { case corner = "position", screen, displayID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        corner = values.lenient(Corner.self, .corner) ?? .random
        screen = values.lenient(ScreenChoice.self, .screen) ?? .mouse
        displayID = values.lenient(String.self, .displayID)
    }
}

/// Everything the person can set. The coding keys are the saved format of
/// every installed copy; a new field needs a default so old saves still load.
public struct Preferences: Codable, Equatable, Sendable {
    public var intervalHours = Schedule.Plan.defaultHours
    public var weekdayHours = DayHours.standard
    public var weekendHours: DayHours?
    public var style = ReminderStyle.animated
    public var soundEnabled = false
    public var look = Look()
    public var placement = Placement()
    public var showMenuBarCountdown = false
    public var pauseWhenAway = true
    public var awayMinutes = 5

    public static let awayMinuteChoices = [3, 5, 10, 15]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case intervalHours, weekdayHours, weekendHours, style, soundEnabled, look = "appearance"
        case placement, showMenuBarCountdown, pauseWhenAway, awayMinutes
    }

    /// Keeps every value this build understands, from older and newer builds
    /// alike; anything missing or unknown falls back to its default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let standard = Preferences()
        intervalHours = values.lenient(Double.self, .intervalHours) ?? standard.intervalHours
        weekdayHours = values.lenient(DayHours.self, .weekdayHours) ?? standard.weekdayHours
        weekendHours = values.lenient(DayHours.self, .weekendHours)
        style = values.lenient(ReminderStyle.self, .style) ?? standard.style
        soundEnabled = values.lenient(Bool.self, .soundEnabled) ?? standard.soundEnabled
        look = values.lenient(Look.self, .look) ?? standard.look
        placement = values.lenient(Placement.self, .placement) ?? standard.placement
        showMenuBarCountdown = values.lenient(Bool.self, .showMenuBarCountdown) ?? standard.showMenuBarCountdown
        pauseWhenAway = values.lenient(Bool.self, .pauseWhenAway) ?? standard.pauseWhenAway
        awayMinutes = values.lenient(Int.self, .awayMinutes) ?? standard.awayMinutes
    }

    public var hours: WeekHours { WeekHours(weekday: weekdayHours, weekend: weekendHours) }

    /// What the countdown needs to know.
    public var plan: Schedule.Plan {
        Schedule.Plan(intervalHours: intervalHours, hours: hours,
                      awayAfter: pauseWhenAway ? TimeInterval(awayMinutes) * 60 : nil)
    }

    /// The same values with anything out of range put back in range.
    public func validated() -> Preferences {
        var result = self
        result.intervalHours = Schedule.Plan.validHours(intervalHours)
        if !weekdayHours.isValid { result.weekdayHours = .standard }
        if weekendHours?.isValid == false { result.weekendHours = nil }
        if !Self.awayMinuteChoices.contains(awayMinutes) { result.awayMinutes = Preferences().awayMinutes }
        return result
    }

    /// True when both count the same way: same interval, same periods.
    public func countsLike(_ other: Preferences) -> Bool {
        intervalHours == other.intervalHours && hours.hasSameTiming(as: other.hours)
    }
}
