import Foundation

/// Everything the app keeps between launches, saved as one value so that a
/// drink and the countdown it restarted can never be written apart.
public struct SavedState: Codable, Equatable, Sendable {
    public var preferences: Preferences?
    public var progress: SavedProgress?
    public var history: DrinkLog?

    public init(preferences: Preferences?, progress: SavedProgress?, history: DrinkLog?) {
        self.preferences = preferences
        self.progress = progress
        self.history = history
    }

    /// Each part is read on its own: an unreadable countdown does not hide
    /// the settings or the log beside it.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preferences = values.lenient(Preferences.self, .preferences)
        progress = values.lenient(SavedProgress.self, .progress)
        history = values.lenient(DrinkLog.self, .history)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// What was read, and whether saving it again would drop anything.
    public struct Reading: Equatable, Sendable {
        public var state: SavedState?
        /// False for a damaged save and for one from a newer build that holds
        /// values this build would not write back. The caller should keep a
        /// copy of such data before overwriting it.
        public var isComplete: Bool

        public init(state: SavedState?, isComplete: Bool) {
            self.state = state
            self.isComplete = isComplete
        }
    }

    public static func read(_ data: Data) -> Reading {
        guard let state = try? JSONDecoder().decode(SavedState.self, from: data) else {
            return Reading(state: nil, isComplete: false)
        }
        guard let original = try? JSONSerialization.jsonObject(with: data),
              let rewritten = state.encoded().flatMap({ try? JSONSerialization.jsonObject(with: $0) })
        else { return Reading(state: state, isComplete: false) }
        return Reading(state: state, isComplete: contains(rewritten, everythingIn: original))
    }

    /// True when every value of `original` is in `rewritten` unchanged.
    /// Values the newer format adds on its own are fine.
    private static func contains(_ rewritten: Any, everythingIn original: Any) -> Bool {
        switch (original, rewritten) {
        case let (old as [String: Any], new as [String: Any]):
            return old.allSatisfy { key, value in new[key].map { contains($0, everythingIn: value) } ?? false }
        case let (old as [Any], new as [Any]):
            return old.count == new.count && zip(old, new).allSatisfy { contains($1, everythingIn: $0) }
        case let (old as NSObject, new as NSObject):
            return old == new
        default:
            return false
        }
    }
}
