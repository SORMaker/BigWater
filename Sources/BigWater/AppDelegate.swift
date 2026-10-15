import AppKit
import SwiftUI
import OSLog
import BigWaterCore
import BigWaterArt

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let preferenceKey = "reminderIntervalHours"
    private let logger = Logger(subsystem: "com.oil.bigwater", category: "reminders")
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let overlay = OverlayController()
    private var schedule = ReminderSchedule()
    private var settings: SettingsModel!
    private var reminderTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isSleeping = false
    private var isSessionActive = true
    private var isScreenAwake = true

    private var canPresentReminder: Bool { !isSleeping && isSessionActive && isScreenAwake }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }

        let stored = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Double
        schedule = ReminderSchedule(hours: stored ?? ReminderSchedule.defaultHours)
        settings = SettingsModel(hours: schedule.intervalHours)
        settings.onIntervalChange = { [weak self] hours in self?.changeInterval(to: hours) }
        settings.onQuit = { NSApp.terminate(nil) }
        overlay.onAcknowledge = { [weak self] in self?.acknowledged() }

        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(rootView: SettingsView(model: settings))

        let item = NSStatusBar.system.statusItem(withLength: 28)
        if let button = item.button {
            button.image = PixelArt.menuIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Big Water · 喝口水，再继续"
            button.setAccessibilityLabel("Big Water 喝水提醒设置")
            button.target = self
            button.action = #selector(toggleSettings)
        }
        statusItem = item
        observeSessionChanges()
        armReminderTimer()

        // Developer preview uses exactly the production reminder, including
        // the real click handler. It never changes the saved interval.
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.presentReminder()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { toggleSettings() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        reminderTimer?.invalidate()
        overlay.stop()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    @objc private func toggleSettings() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func changeInterval(to hours: Double) {
        schedule.setInterval(hours: hours, now: Date())
        UserDefaults.standard.set(schedule.intervalHours, forKey: Self.preferenceKey)
        armReminderTimer()
    }

    private func acknowledged() {
        schedule.acknowledge(at: Date())
        logger.info("Claude clicked; next reminder scheduled")
        armReminderTimer()
    }

    private func presentReminder() {
        guard canPresentReminder, !overlay.isActive, overlay.start() else { return }
        popover.performClose(nil)
        schedule.reminderDidStart()
        reminderTimer?.invalidate()
        reminderTimer = nil
        settings.nextReminderAt = nil
        logger.info("Reminder started")
    }

    private func checkReminder() {
        if schedule.isDue(at: Date()) { presentReminder() }
        armReminderTimer()
    }

    private func armReminderTimer() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        settings.nextReminderAt = schedule.nextReminderAt
        guard canPresentReminder, let due = schedule.nextReminderAt else { return }
        let timer = Timer(timeInterval: max(due.timeIntervalSinceNow, 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReminder() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
    }

    private func observeSessionChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.isSleeping = true
            self?.suspendSession()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.isSleeping = false
            self?.resumeSessionIfPossible()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.isSessionActive = false
            self?.suspendSession()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.isSessionActive = true
            self?.resumeSessionIfPossible()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.isScreenAwake = true
            self?.resumeSessionIfPossible()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.isScreenAwake = false
            self?.suspendSession()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.overlay.screenParametersChanged()
            if self?.canPresentReminder == true { self?.overlay.resume() }
            self?.checkReminder()
        }
        observe(.default, .NSSystemClockDidChange) { [weak self] in self?.checkReminder() }
    }

    private func suspendSession() {
        overlay.suspend()
        reminderTimer?.invalidate()
        reminderTimer = nil
    }

    private func resumeSessionIfPossible() {
        guard canPresentReminder else { return }
        overlay.resume()
        checkReminder()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         perform: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { perform() }
        }
        observers.append((center, token))
    }
}
