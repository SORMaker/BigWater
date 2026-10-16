import AppKit
import SwiftUI
import BigWaterCore
@testable import BigWaterApp

/// An opt-in native UI fixture. It uses its own preference domain and generated
/// records, so exercising delete/undo never changes the user's real history.
@MainActor
func runHistoryPreview() {
    let domain = "com.oil.bigwater.uipreview.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    preferences.set(true, forKey: "launchAtLogin")
    let now = Date()
    let calendar = Calendar.autoupdatingCurrent
    var configuration = AppPreferences()
    configuration.weekdayHours = DailyHours(startMinutes: 0, endMinutes: 1_440)
    var history = HydrationHistory()
    for offset in -89...0 {
        let count = abs(offset * 7 + 3) % 6
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        for index in 0..<count {
            let time = calendar.date(byAdding: .minute, value: 480 + index * 90, to: day)!
            if time < now { history.recordDrink(at: time) }
        }
    }
    // A misdated confirmation exercises access after correcting the clock.
    history.recordDrink(at: calendar.date(byAdding: .month, value: 1, to: now)!)
    var schedule = ReminderSchedule(now: now, weekdayHours: configuration.weekdayHours)
    AppStorage(defaults: preferences).save(preferences: configuration,
                                          progress: schedule.snapshot(at: now), history: history)
    let host = HistoryPreviewHost(preferences: preferences, domain: domain)
    NSApp.delegate = host
    NSApp.run()
    withExtendedLifetime(host) {}
}

@MainActor
private final class HistoryPreviewHost: NSObject, NSApplicationDelegate {
    let delegate: AppDelegate
    let preferences: UserDefaults
    let domain: String
    private var window: NSWindow?

    init(preferences: UserDefaults, domain: String) {
        self.preferences = preferences
        self.domain = domain
        delegate = AppDelegate(preferences: preferences)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        delegate.applicationDidFinishLaunching(notification)
        delegate.settings.isVisible = true
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: SettingsView.preferredSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "BigWater 功能预览（隔离数据）"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: delegate.settings,
                                                                                 updater: delegate.updater))
        window.setContentSize(SettingsView.preferredSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        delegate.applicationWillTerminate(notification)
        preferences.removePersistentDomain(forName: domain)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        delegate.applicationShouldHandleReopen(sender, hasVisibleWindows: flag)
    }
}
