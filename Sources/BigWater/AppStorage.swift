import Foundation
import BigWaterCore

/// A single saved value keeps a confirmation and its new countdown together.
/// A process exit can retain the previous checkpoint, but cannot mix new drink
/// history with an older outstanding reminder.
///
/// Each section is read on its own, so one unreadable part cannot hide the
/// others. A saved value this build cannot write back unchanged, such as one
/// from a newer build or a damaged one, is copied aside before the next save.
final class AppStorage {
    private struct State: Codable {
        var preferences: AppPreferences?
        var progress: ReminderSnapshot?
        var history: HydrationHistory?

        init(preferences: AppPreferences, progress: ReminderSnapshot, history: HydrationHistory) {
            self.preferences = preferences
            self.progress = progress
            self.history = history
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            preferences = try? values.decodeIfPresent(AppPreferences.self, forKey: .preferences)
            progress = try? values.decodeIfPresent(ReminderSnapshot.self, forKey: .progress)
            history = try? values.decodeIfPresent(HydrationHistory.self, forKey: .history)
        }
    }

    private let defaults: UserDefaults
    private let stateKey = "appStateV1"
    private var backupPrefix: String { stateKey + ".unreadable." }

    init(defaults: UserDefaults) { self.defaults = defaults }

    func loadPreferences() -> AppPreferences {
        if let saved = load()?.preferences { return saved.validated() }
        var result = AppPreferences()
        if let hours = defaults.object(forKey: "reminderIntervalHours") as? Double {
            result.intervalHours = ReminderSchedule.validated(hours)
        }
        return result
    }

    func loadProgress() -> ReminderSnapshot? { load()?.progress }
    func loadHistory() -> HydrationHistory { load()?.history ?? HydrationHistory() }

    func save(preferences: AppPreferences, progress: ReminderSnapshot, history: HydrationHistory) {
        let state = State(preferences: preferences.validated(), progress: progress, history: history)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
    }

    private func load() -> State? {
        guard let data = defaults.data(forKey: stateKey) else { return nil }
        let state = try? JSONDecoder().decode(State.self, from: data)
        if state.map({ roundTrips(data, as: $0) }) != true { keepCopy(of: data) }
        return state
    }

    /// True when saving the decoded state would write back the same content.
    private func roundTrips(_ data: Data, as state: State) -> Bool {
        guard let rewritten = try? JSONEncoder().encode(state),
              let original = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let reread = try? JSONSerialization.jsonObject(with: rewritten) as? NSDictionary
        else { return false }
        return original == reread
    }

    private func keepCopy(of data: Data) {
        let alreadyKept = defaults.dictionaryRepresentation().contains {
            $0.key.hasPrefix(backupPrefix) && $0.value as? Data == data
        }
        guard !alreadyKept else { return }
        defaults.set(data, forKey: backupPrefix + ISO8601DateFormatter().string(from: Date()))
    }
}
