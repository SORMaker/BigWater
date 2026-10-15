import AppKit
import SwiftUI
import OSLog
import ServiceManagement
import BigWaterCore
import BigWaterArt

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let loginPreferenceKey = "launchAtLogin"
    static let presentationRetryDelay: TimeInterval = 30
    private let logger = Logger(subsystem: "com.oil.bigwater", category: "reminders")
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let overlay = OverlayController()
    private var overlayDay: DateComponents?
    private var isPreviewing = false
    private var configuration = AppPreferences()
    private var history = HydrationHistory()
    private var schedule = ReminderSchedule()
    private var settings: SettingsModel!
    private var reminderTimer: Timer?
    private var checkpointTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isSleeping = false
    private var isSessionActive = true
    private var isScreenAwake = true
    private let dateNow: () -> Date
    private let uptimeNow: () -> TimeInterval
    private let systemState: () -> SystemState
    private let preferences: UserDefaults
    private lazy var storage = AppStorage(defaults: preferences)

    private var canPresentReminder: Bool { !isSleeping && isSessionActive && isScreenAwake }

    /// What the console session and displays report right now.
    struct SystemState {
        var isSessionActive: Bool
        var isScreenAwake: Bool

        static func current() -> SystemState {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let screenAwake = NSScreen.screens.contains {
                guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                else { return false }
                return CGDisplayIsAsleep(number.uint32Value) == 0
            }
            return SystemState(isSessionActive: session?[kCGSessionOnConsoleKey as String] as? Bool ?? true,
                               isScreenAwake: screenAwake)
        }
    }

    init(dateNow: @escaping () -> Date = Date.init,
         uptimeNow: @escaping () -> TimeInterval = { ReminderClock.uptime },
         systemState: @escaping () -> SystemState = SystemState.current,
         preferences: UserDefaults = .standard) {
        self.dateNow = dateNow
        self.uptimeNow = uptimeNow
        self.systemState = systemState
        self.preferences = preferences
        super.init()
    }

    /// Notifications can be missed (for example while another user is on
    /// the console), so every wake-type event re-reads the real state.
    private func refreshSystemState() {
        let state = systemState()
        isSessionActive = state.isSessionActive
        isScreenAwake = state.isScreenAwake
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }

        configuration = storage.loadPreferences()
        history = storage.loadHistory()
        refreshSystemState()
        schedule = ReminderSchedule(hours: configuration.intervalHours, now: dateNow(), uptime: uptimeNow(),
                                    isSessionActive: canPresentReminder,
                                    weekdayHours: configuration.weekdayHours, weekendHours: configuration.weekendHours,
                                    snapshot: storage.loadProgress())
        settings = SettingsModel(preferences: configuration)
        settings.onPreferencesChange = { [weak self] in self?.changePreferences(to: $0) }
        settings.onPause = { [weak self] in self?.pause(for: $0) }
        settings.onDrink = { [weak self] in self?.drinkFromMenu() }
        settings.onSnooze = { [weak self] in self?.snoozeFromMenu(minutes: $0) }
        settings.onResume = { [weak self] in self?.resumeCountdown() }
        settings.onPreview = { [weak self] in self?.previewAppearance() }
        settings.onLaunchAtLoginChange = { [weak self] in self?.changeLaunchAtLogin(to: $0) }
        settings.onOpenLoginSettings = { SMAppService.openSystemSettingsLoginItems() }
        settings.onQuit = { NSApp.terminate(nil) }
        overlay.onAcknowledge = { [weak self] in self?.acknowledged(drink: false) }
        overlay.onDrink = { [weak self] in self?.acknowledged(drink: true) }
        overlay.onSnooze = { [weak self] in self?.snooze(minutes: $0) }
        overlay.onPreviewEnd = { [weak self] in
            self?.isPreviewing = false
            self?.updateSettings()
        }
        overlay.onFinished = { [weak self] in self?.checkReminder() }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(rootView: SettingsView(model: settings))
        popover.contentSize = SettingsView.preferredSize

        let item = NSStatusBar.system.statusItem(withLength: 28)
        if let button = item.button {
            button.image = PixelArt.menuIcon()
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Big Water 喝水提醒设置")
            button.target = self
            button.action = #selector(toggleSettings)
        }
        statusItem = item
        observeSessionChanges()
        configureLoginItem()
        checkReminder()

        // CLI preview retains the existing end-to-end reminder test behavior.
        // The settings-page preview is separate and never changes the schedule.
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.presentReminder() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { toggleSettings() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if settings != nil { persistProgress() }
        reminderTimer?.invalidate()
        checkpointTimer?.invalidate()
        overlay.stop()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    func popoverDidClose(_ notification: Notification) { settings.isVisible = false }

    @objc private func toggleSettings() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            checkReminder()
            refreshLoginStatus()
            settings.isVisible = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func changePreferences(to candidate: AppPreferences) {
        let next = candidate.validated()
        if next.intervalHours != schedule.intervalHours {
            schedule.setInterval(hours: next.intervalHours, now: dateNow(), uptime: uptimeNow())
        }
        if next.weekdayHours != configuration.weekdayHours || next.weekendHours != configuration.weekendHours {
            schedule.setHours(weekday: next.weekdayHours, weekend: next.weekendHours,
                              at: dateNow(), uptime: uptimeNow())
        }
        configuration = next
        checkReminder()
    }

    private func acknowledged(drink: Bool) {
        guard !isPreviewing else { return }
        let wasOutstanding = schedule.isAwaitingAcknowledgment
        let now = dateNow()
        let uptime = uptimeNow()
        schedule.update(at: now, uptime: uptime, isSessionActive: canPresentReminder)
        guard wasOutstanding else { checkReminder(); return }
        if drink {
            // A visible real button still expresses a drink confirmation if
            // its click wins the race with the daily closing callback.
            history.recordDrink(at: now)
            logger.info("Drink confirmed")
        }
        schedule.acknowledge(at: now, uptime: uptime)
        checkReminder()
    }

    private func snooze(minutes: Int) {
        schedule.update(at: dateNow(), uptime: uptimeNow(), isSessionActive: canPresentReminder)
        guard !isPreviewing, schedule.isAwaitingAcknowledgment else { checkReminder(); return }
        schedule.snooze(minutes: minutes, at: dateNow(), uptime: uptimeNow())
        checkReminder()
    }

    /// Menu actions go through the visible reminder when there is one, so it
    /// plays the same exit as a click on its own button.
    private func drinkFromMenu() {
        if !isPreviewing && overlay.isAwaitingAcknowledgment { overlay.confirmDrink() }
        else { acknowledged(drink: true) }
    }

    private func snoozeFromMenu(minutes: Int) {
        if !isPreviewing && overlay.isAwaitingAcknowledgment { overlay.snooze(minutes: minutes) }
        else { snooze(minutes: minutes) }
    }

    private func pause(for minutes: Int) {
        overlay.stop()
        isPreviewing = false
        schedule.pause(for: minutes, at: dateNow(), uptime: uptimeNow())
        checkReminder()
    }

    private func resumeCountdown() {
        schedule.resume(at: dateNow(), uptime: uptimeNow())
        checkReminder()
    }

    private func previewAppearance() {
        guard canPresentReminder, !overlay.isActive else { return }
        if overlay.start(appearance: configuration.appearance, style: configuration.style, isPreview: true) {
            isPreviewing = true
            overlayDay = schedule.localDay
            popover.performClose(nil)
            updateSettings()
        }
    }

    private func presentReminder() {
        presentReminder(at: dateNow(), uptime: uptimeNow())
    }

    private func presentReminder(at now: Date, uptime: TimeInterval) {
        schedule.update(at: now, uptime: uptime, isSessionActive: canPresentReminder)
        guard canPresentReminder, schedule.isWithinReminderHours, !schedule.isManuallyPaused,
              !overlay.isActive,
              overlay.start(appearance: configuration.appearance, style: configuration.style) else { return }
        popover.performClose(nil)
        overlayDay = schedule.localDay
        schedule.reminderDidStart()
        if configuration.soundEnabled { NSSound(named: NSSound.Name("Glass"))?.play() }
        persistProgress(at: now, uptime: uptime)
        armReminderTimer()
        logger.info("Reminder started")
    }

    private func checkReminder() {
        // State, windows and persistence share one observation of time. A
        // second clock read during saving must not silently cross the cutoff.
        let now = dateNow()
        let uptime = uptimeNow()
        schedule.update(at: now, uptime: uptime, isSessionActive: canPresentReminder)
        let sceneExpired = overlay.isActive && overlayDay != schedule.localDay
        if isPreviewing && (!canPresentReminder || sceneExpired || schedule.isDue) {
            overlay.stop()
            isPreviewing = false
        }
        if !isPreviewing {
            if !schedule.isWithinReminderHours || schedule.isManuallyPaused || sceneExpired { overlay.stop() }
            if schedule.isWithinReminderHours && !schedule.isManuallyPaused && canPresentReminder {
                overlay.resume()
                if schedule.isDue || (schedule.isAwaitingAcknowledgment && !overlay.isActive) {
                    presentReminder(at: now, uptime: uptime)
                }
            } else if !canPresentReminder {
                overlay.suspend()
            }
        }
        persistProgress(at: now, uptime: uptime)
        armReminderTimer()
    }

    private func persistProgress(at now: Date? = nil, uptime: TimeInterval? = nil) {
        let snapshot = schedule.snapshot(at: now ?? dateNow(), uptime: uptime ?? uptimeNow())
        storage.save(preferences: configuration, progress: snapshot, history: history)
    }

    private func armReminderTimer() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        updateSettings()
        if let due = schedule.nextCheckAt {
            // Still due here means the overlay could not be shown (no usable
            // screen, or an exit animation still running). Retry slowly; screen
            // changes and the overlay finishing also trigger a check.
            let delay = schedule.isDue ? Self.presentationRetryDelay : max(due.timeIntervalSince(dateNow()), 0.1)
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkReminder() }
            }
            RunLoop.main.add(timer, forMode: .common)
            reminderTimer = timer
        }
        // Checkpoint active progress every 30 seconds for unexpected exits.
        // Sleeping, paused and outstanding states need no polling.
        if schedule.isCounting {
            if checkpointTimer == nil {
                let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkReminder() }
                }
                timer.tolerance = 2
                RunLoop.main.add(timer, forMode: .common)
                checkpointTimer = timer
            }
        } else {
            checkpointTimer?.invalidate()
            checkpointTimer = nil
        }
    }

    private func updateSettings() {
        let now = dateNow()
        settings.preferences = configuration
        settings.remainingTime = schedule.remainingTime
        settings.countdownDeadline = schedule.isCounting ? schedule.nextReminderAt : nil
        settings.countdownOverride = nil
        settings.isManuallyPaused = schedule.isManuallyPaused
        settings.isAwaitingAcknowledgment = schedule.isAwaitingAcknowledgment && !isPreviewing
        settings.canPreview = canPresentReminder && !overlay.isActive
        settings.todayDrinkTimes = history.drinks(on: now)
        if !schedule.isWithinReminderHours {
            settings.stateTitle = "休息时间"
            settings.countdownOverride = "休息中"
            let start = schedule.nextBoundaryAt.formatted(date: .omitted, time: .shortened)
            settings.scheduleText = "本地 \(start) 后使用电脑，再开始计时"
        } else if schedule.isManuallyPaused {
            settings.stateTitle = "计时已暂停"
            let until = schedule.pausedUntil?.formatted(date: .omitted, time: .shortened) ?? ""
            settings.scheduleText = "\(until) 自动恢复，保留当前剩余时间"
        } else if !canPresentReminder {
            settings.stateTitle = "休眠暂停"
            settings.scheduleText = "亮屏后接着剩余时间继续计时"
        } else if schedule.isAwaitingAcknowledgment {
            settings.stateTitle = "等待你的确认"
            settings.countdownOverride = "喝口水吧"
            settings.scheduleText = "喝水后点提醒里或下面的按钮，也可以稍后再提醒"
        } else if let next = schedule.nextReminderAt {
            settings.stateTitle = schedule.isSnoozed ? "稍后提醒" : "距离下次提醒"
            settings.scheduleText = "下次提醒 \(next.formatted(date: .omitted, time: .shortened)) · 休眠时暂停"
        } else {
            settings.stateTitle = "今天不再提醒"
            settings.countdownOverride = "明天见"
            settings.scheduleText = "剩余作息不足一个间隔，明天使用时重新计时"
        }
        statusItem?.button?.toolTip = "Big Water · \(settings.scheduleText)"
    }

    private func observeSessionChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.isSleeping = true
            self?.checkReminder()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.isSleeping = false
            self?.refreshSystemState()
            self?.checkReminder()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.isSessionActive = false
            self?.checkReminder()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.refreshSystemState()
            self?.checkReminder()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.refreshSystemState()
            self?.checkReminder()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.isScreenAwake = false
            self?.checkReminder()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            // Displays may have been added, removed or put to sleep.
            if self?.isSleeping == false { self?.refreshSystemState() }
            self?.overlay.screenParametersChanged()
            self?.checkReminder()
        }
        observe(.default, .NSSystemClockDidChange) { [weak self] in self?.checkReminder() }
        observe(.default, .NSSystemTimeZoneDidChange) { [weak self] in self?.checkReminder() }
        observe(.default, .NSCalendarDayChanged) { [weak self] in self?.checkReminder() }
    }

    private func configureLoginItem() {
        if preferences.object(forKey: Self.loginPreferenceKey) == nil { changeLaunchAtLogin(to: true) }
        else { refreshLoginStatus() }
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
            } else if service.status != .notRegistered { try service.unregister() }
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
