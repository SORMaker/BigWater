import Foundation
import BigWaterCore

/// The few things the store asks of user defaults, so tests can keep
/// everything in memory and leave no files behind.
protocol KeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func dictionaryRepresentation() -> [String: Any]
}

extension UserDefaults: KeyValueStore {}

/// Keeps the app's state in the user defaults of `com.oil.bigwater`.
///
/// The key and the JSON under it are the saved data of every installed copy.
/// Renaming either would leave people with an app that has forgotten them.
@MainActor
final class StateStore {
    nonisolated static let key = "appStateV1"
    /// Where builds before 0.4 kept the interval, their only setting.
    nonisolated static let legacyIntervalKey = "reminderIntervalHours"
    private static let backupPrefix = key + ".unreadable."

    private let defaults: KeyValueStore
    private var lastWritten: Data?

    init(defaults: KeyValueStore = UserDefaults.standard) { self.defaults = defaults }

    struct Loaded {
        var preferences: Preferences
        var progress: SavedProgress?
        var log: DrinkLog
    }

    func load() -> Loaded {
        var state: SavedState?
        if let data = defaults.data(forKey: Self.key) {
            let reading = SavedState.read(data)
            state = reading.state
            // Saving would drop something: a save from a newer build, or a
            // damaged one. Set a copy aside before it is overwritten.
            if !reading.isComplete { keepCopy(of: data) }
        }
        var preferences = state?.preferences?.validated() ?? Preferences()
        if state?.preferences == nil, let hours = defaults.object(forKey: Self.legacyIntervalKey) as? Double {
            preferences.intervalHours = Schedule.Plan.validHours(hours)
        }
        return Loaded(preferences: preferences, progress: state?.progress, log: state?.history ?? DrinkLog())
    }

    func save(preferences: Preferences, progress: SavedProgress, log: DrinkLog) {
        let state = SavedState(preferences: preferences.validated(), progress: progress, history: log)
        guard let data = state.encoded(), data != lastWritten else { return }
        defaults.set(data, forKey: Self.key)
        lastWritten = data
    }

    private func keepCopy(of data: Data) {
        let alreadyKept = defaults.dictionaryRepresentation().contains {
            $0.key.hasPrefix(Self.backupPrefix) && $0.value as? Data == data
        }
        guard !alreadyKept else { return }
        defaults.set(data, forKey: Self.backupPrefix + ISO8601DateFormatter().string(from: Date()))
    }
}
