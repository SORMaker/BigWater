import AppKit
import SwiftUI
import OSLog
import ServiceManagement
import BigWaterCore
import BigWaterArt

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let preferenceKey = "reminderIntervalHours"
    private static let loginPreferenceKey = "launchAtLogin"
    private let logger = Logger(subsystem: "com.oil.bigwater", category: "reminders")
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let overlay = OverlayController()
    private var overlayDay: DateComponents?
    private var schedule = ReminderSchedule()
    private var settings: SettingsModel!
    private var reminderTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isSleeping = false
    private var isSessionActive = true
    private var isScreenAwake = true
    private let dateNow: () -> Date
    private let uptimeNow: () -> TimeInterval
    private let preferences: UserDefaults

    private var canPresentReminder: Bool { !isSleeping && isSessionActive && isScreenAwake }

    init(dateNow: @escaping () -> Date = Date.init,
         uptimeNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         preferences: UserDefaults = .standard) {
        self.dateNow = dateNow
        self.uptimeNow = uptimeNow
        self.preferences = preferences
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }

        let stored = preferences.object(forKey: Self.preferenceKey) as? Double
        // Login launches can happen before the display or user session wakes.
        isSessionActive = (CGSessionCopyCurrentDictionary() as? [String: Any])?[kCGSessionOnConsoleKey as String] as? Bool ?? true
        isScreenAwake = NSScreen.screens.contains {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsAsleep(number.uint32Value) == 0
        }
        schedule = ReminderSchedule(hours: stored ?? ReminderSchedule.defaultHours,
                                    now: dateNow(), uptime: uptimeNow(),
                                    isSessionActive: canPresentReminder)
        settings = SettingsModel(hours: schedule.intervalHours)
        settings.onIntervalChange = { [weak self] hours in self?.changeInterval(to: hours) }
        settings.onLaunchAtLoginChange = { [weak self] enabled in self?.changeLaunchAtLogin(to: enabled) }
        settings.onOpenLoginSettings = { SMAppService.openSystemSettingsLoginItems() }
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
        configureLoginItem()
        checkReminder()

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
            checkReminder()
            refreshLoginStatus()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func changeInterval(to hours: Double) {
        schedule.setInterval(hours: hours, now: dateNow(), uptime: uptimeNow())
        preferences.set(schedule.intervalHours, forKey: Self.preferenceKey)
        checkReminder()
    }

    private func acknowledged() {
        schedule.acknowledge(at: dateNow(), uptime: uptimeNow())
        logger.info("Claude clicked; next reminder scheduled")
        checkReminder()
    }

    private func presentReminder() {
        schedule.update(at: dateNow(), uptime: uptimeNow(), isSessionActive: canPresentReminder)
        guard canPresentReminder, schedule.isWithinReminderHours,
              !schedule.isAwaitingAcknowledgment, !overlay.isActive, overlay.start() else { return }
        popover.performClose(nil)
        overlayDay = schedule.localDay
        schedule.reminderDidStart()
        armReminderTimer()
        logger.info("Reminder started")
    }

    private func checkReminder() {
        schedule.update(at: dateNow(), uptime: uptimeNow(), isSessionActive: canPresentReminder)
        // Retire every old-day scene, including a paused exit animation.
        // Same-day exit animations can still resume after a short sleep.
        if !schedule.isWithinReminderHours || (overlay.isActive && overlayDay != schedule.localDay) {
            overlay.stop()
        }
        if schedule.isWithinReminderHours && canPresentReminder {
            overlay.resume()
            if schedule.isDue { presentReminder() }
        } else if !canPresentReminder {
            overlay.suspend()
        }
        armReminderTimer()
    }

    private func armReminderTimer() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        updateSettings()
        guard let due = schedule.nextCheckAt else { return }
        let timer = Timer(timeInterval: max(due.timeIntervalSince(dateNow()), 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReminder() }
        }
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
            self?.checkReminder()
        }
        observe(.default, .NSSystemClockDidChange) { [weak self] in self?.checkReminder() }
        observe(.default, .NSSystemTimeZoneDidChange) { [weak self] in self?.checkReminder() }
        observe(.default, .NSCalendarDayChanged) { [weak self] in self?.checkReminder() }
    }

    private func suspendSession() {
        checkReminder()
    }

    private func resumeSessionIfPossible() {
        guard canPresentReminder else { return }
        checkReminder()
    }

    private func updateSettings() {
        if !schedule.isWithinReminderHours {
            settings.scheduleText = "休息时间 · 06:00 后使用电脑再计时"
        } else if !canPresentReminder {
            let minutes = Int(ceil(schedule.remainingTime / 60))
            settings.scheduleText = "已暂停 · 亮屏后继续剩余 \(minutes) 分钟"
        } else if schedule.isAwaitingAcknowledgment {
            settings.scheduleText = "点一下 Claude，开始下次计时"
        } else if let next = schedule.nextReminderAt {
            settings.scheduleText = "下次提醒  \(next.formatted(date: .omitted, time: .shortened))"
        } else {
            settings.scheduleText = "今天不再提醒 · 明天使用时重新计时"
        }
    }

    private func configureLoginItem() {
        // Respect a later change in macOS Login Items instead of re-enabling it
        // on every launch. Only the first app launch supplies the default.
        if preferences.object(forKey: Self.loginPreferenceKey) == nil {
            changeLaunchAtLogin(to: true)
        } else {
            refreshLoginStatus()
        }
    }

    private func changeLaunchAtLogin(to enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            settings.loginStatusText = "请从 Big Water.app 设置登录启动"
            return
        }
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            preferences.set(enabled, forKey: Self.loginPreferenceKey)
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            settings.loginStatusText = "设置未成功，请在系统登录项中检查"
            logger.error("Login item change failed: \(error.localizedDescription)")
        }
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        settings.launchAtLogin = status == .enabled || status == .requiresApproval
        settings.loginNeedsApproval = status == .requiresApproval
        settings.loginStatusText = status == .requiresApproval ? "请在系统登录项中允许 Big Water" : nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         perform: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { perform() }
        }
        observers.append((center, token))
    }
}
