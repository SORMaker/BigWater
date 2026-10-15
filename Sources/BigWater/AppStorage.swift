import Foundation
import BigWaterCore

/// A single saved value keeps a confirmation and its new countdown together.
/// A process exit can retain the previous checkpoint, but cannot mix new drink
/// history with an older outstanding reminder.
final class AppStorage {
    private struct State: Codable {
        var preferences: AppPreferences
        var progress: ReminderSnapshot
        var history: HydrationHistory
    }

    private let defaults: UserDefaults
    private let stateKey = "appStateV1"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func loadPreferences() -> AppPreferences {
        if let saved = load() { return saved.preferences.validated() }
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
        return try? JSONDecoder().decode(State.self, from: data)
    }
}
