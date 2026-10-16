import AppKit
import SwiftUI
import OSLog
import ServiceManagement
import BigWaterCore
import BigWaterArt

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    // State marked private(set) is read by the session checks via @testable.
    private static let loginPreferenceKey = "launchAtLogin"
    static let presentationRetryDelay: TimeInterval = 30
    private let logger = Logger(subsystem: "com.oil.bigwater", category: "reminders")
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    let overlay = OverlayController()
    private var overlayDay: DateComponents?
    private(set) var isPreviewing = false
    private(set) var configuration = AppPreferences()
    private(set) var history = HydrationHistory()
    private(set) var schedule = ReminderSchedule()
    private(set) var settings: SettingsModel!
    private(set) var updater: AppUpdater!
    private(set) var reminderTimer: Timer?
    private var checkpointTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isSleeping = false
    private var isSessionActive = true
    private var isScreenAwake = true
    private struct DrinkUndo {
        let date: Date
        var schedule: ReminderSchedule?
    }
    private var drinkUndo: DrinkUndo?
    private var lastDrinkUptime: TimeInterval?
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
        updater = AppUpdater()
        updater.beforeCheckForUpdates = { [weak self] in self?.popover.performClose(nil) }
        updater.onUpdateAvailabilityChange = { [weak self] in self?.refreshUpdateIndicator() }
        settings.onPreferencesChange = { [weak self] in self?.changePreferences(to: $0) }
        settings.onPause = { [weak self] in self?.pause(for: $0) }
        settings.onDrink = { [weak self] in self?.drinkFromMenu() }
        settings.onUndoDrink = { [weak self] in self?.undoLastDrink() }
        settings.onRemoveDrink = { [weak self] in self?.removeDrink(at: $0) }
        settings.onAddDrink = { [weak self] in self?.addPastDrink(at: $0) ?? false }
        settings.onEditDrink = { [weak self] in self?.editDrink(from: $0, to: $1) ?? false }
        settings.onHistoryReferenceDate = { [weak self] in self?.dateNow() ?? Date() }
        settings.onSnooze = { [weak self] in self?.snoozeFromMenu(minutes: $0) }
        settings.onResume = { [weak self] in self?.resumeCountdown() }
        settings.onPreview = { [weak self] in self?.previewAppearance() }
        settings.onLaunchAtLoginChange = { [weak self] in self?.changeLaunchAtLogin(to: $0) }
        settings.onOpenLoginSettings = { SMAppService.openSystemSettingsLoginItems() }
        settings.onQuit = { NSApp.terminate(nil) }
        overlay.onAcknowledge = { [weak self] in self?.acknowledged() }
        overlay.onDrink = { [weak self] in self?.acknowledged() }
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
        popover.contentViewController = NSHostingController(rootView: SettingsView(model: settings, updater: updater))
        popover.contentSize = SettingsView.preferredSize

        let item = NSStatusBar.system.statusItem(withLength: 28)
        if let button = item.button {
            button.image = PixelArt.menuIcon()
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Big Water 喝水提醒设置")
            button.target = self
            button.action = #selector(toggleSettings)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
            return
        }
        showSettings()
    }

    @objc private func showSettings() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            checkReminder()
            refreshLoginStatus()
            settings.isVisible = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    private func showQuickMenu() {
        guard let item = statusItem else { return }
        popover.performClose(nil)
        checkReminder()
        item.menu = makeQuickMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// Rebuilt on every right click so pause and undo always reflect live state.
    func makeQuickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("我刚喝过水", #selector(quickDrink), enabled: settings.canRecordDrink)
        add("撤销刚才的喝水记录", #selector(quickUndo), enabled: settings.canUndoDrink)
        menu.addItem(.separator())
        add("暂停 30 分钟", #selector(quickPauseThirty))
        add("暂停 60 分钟", #selector(quickPauseSixty))
        if schedule.isManuallyPaused { add("恢复计时", #selector(quickResume)) }
        menu.addItem(.separator())
        add("打开设置…", #selector(showSettings))
        add("退出 Big Water", #selector(quickQuit))
        return menu
    }

    @objc private func quickDrink() { drinkFromMenu() }
    @objc private func quickUndo() { undoLastDrink() }
    @objc private func quickPauseThirty() { pause(for: 30) }
    @objc private func quickPauseSixty() { pause(for: 60) }
    @objc private func quickResume() { resumeCountdown() }
    @objc private func quickQuit() { NSApp.terminate(nil) }

    private func changePreferences(to candidate: AppPreferences) {
        let next = candidate.validated()
        if next.intervalHours != configuration.intervalHours
            || next.weekdayHours != configuration.weekdayHours
            || next.weekendHours != configuration.weekendHours {
            drinkUndo?.schedule = nil
        }
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

    private func acknowledged() {
        guard !isPreviewing else { return }
        let wasOutstanding = schedule.isAwaitingAcknowledgment
        let now = dateNow()
        let uptime = uptimeNow()
        schedule.update(at: now, uptime: uptime, isSessionActive: canPresentReminder)
        guard wasOutstanding else { checkReminder(); return }
        // A click on the character or drink button confirms the outstanding
        // reminder, even if it wins the race with the daily closing callback.
        recordDrink(at: now, uptime: uptime)
    }

    private func recordDrink(at now: Date, uptime: TimeInterval) {
        // Treat a double click as one drink, including spontaneous menu records.
        if let lastDrinkUptime, uptime >= lastDrinkUptime, uptime - lastDrinkUptime < 1 { return }
        schedule.update(at: now, uptime: uptime, isSessionActive: canPresentReminder)
        drinkUndo = DrinkUndo(date: now, schedule: schedule)
        self.lastDrinkUptime = uptime
        history.recordDrink(at: now)
        schedule.recordDrink(at: now, uptime: uptime)
        logger.info("Drink confirmed")
        checkReminder()
    }

    private func undoLastDrink() {
        guard let undo = drinkUndo, history.removeDrink(at: undo.date) else { return }
        drinkUndo = nil
        lastDrinkUptime = nil
        if let previous = undo.schedule {
            overlay.stop()
            isPreviewing = false
            schedule = previous
        }
        checkReminder()
    }

    private func removeDrink(at date: Date) {
        if drinkUndo?.date == date { undoLastDrink(); return }
        guard history.removeDrink(at: date) else { return }
        checkReminder()
    }

    private func addPastDrink(at date: Date) -> Bool {
        guard history.addPastDrink(at: date, now: dateNow()) else { return false }
        // History corrections never acknowledge a reminder or restart its clock.
        checkReminder()
        return true
    }

    private func editDrink(from original: Date, to replacement: Date) -> Bool {
        guard history.updateDrink(from: original, to: replacement, now: dateNow()) else { return false }
        if drinkUndo?.date == original { drinkUndo = nil }
        checkReminder()
        return true
    }

    private func snooze(minutes: Int) {
        schedule.update(at: dateNow(), uptime: uptimeNow(), isSessionActive: canPresentReminder)
        guard !isPreviewing, schedule.isAwaitingAcknowledgment else { checkReminder(); return }
        drinkUndo?.schedule = nil
        schedule.snooze(minutes: minutes, at: dateNow(), uptime: uptimeNow())
        checkReminder()
    }

    /// Menu actions go through the visible reminder when there is one, so it
    /// plays the same exit as a click on its own button.
    private func drinkFromMenu() {
        if !isPreviewing && overlay.isActive {
            // A second menu click during the same exit is still the same drink.
            guard schedule.isAwaitingAcknowledgment else { return }
            if overlay.isAwaitingAcknowledgment { overlay.confirmDrink(); return }
        }
        overlay.stop()
        isPreviewing = false
        recordDrink(at: dateNow(), uptime: uptimeNow())
    }

    private func snoozeFromMenu(minutes: Int) {
        if !isPreviewing && overlay.isAwaitingAcknowledgment { overlay.snooze(minutes: minutes) }
        else { snooze(minutes: minutes) }
    }

    private func pause(for minutes: Int) {
        drinkUndo?.schedule = nil
        overlay.stop()
        isPreviewing = false
        schedule.pause(for: minutes, at: dateNow(), uptime: uptimeNow())
        checkReminder()
    }

    private func resumeCountdown() {
        drinkUndo?.schedule = nil
        schedule.resume(at: dateNow(), uptime: uptimeNow())
        checkReminder()
    }

    private func previewAppearance() {
        guard canPresentReminder, !overlay.isActive else { return }
        if overlay.start(appearance: configuration.appearance, style: configuration.style, isPreview: true,
                         placement: configuration.placement) {
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
              overlay.start(appearance: configuration.appearance, style: configuration.style,
                            placement: configuration.placement) else { return }
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
        // Keep an undo's old countdown on the same awake-time clock, including
        // sleep/wake transitions, until a later scheduling choice supersedes it.
        drinkUndo?.schedule?.update(at: now, uptime: uptime, isSessionActive: canPresentReminder)
        schedule.update(at: now, uptime: uptime, isSessionActive: canPresentReminder)
        if !isPreviewing && overlay.isAwaitingAcknowledgment && !schedule.isAwaitingAcknowledgment {
            // A schedule update can also happen in a settings action before
            // this check. Retire any pending scene the schedule has cleared.
            // A confirmed scene is already exiting and does not enter here.
            overlay.stop()
        }
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
        settings.countdownDeadline = schedule.isCounting ? now.addingTimeInterval(schedule.remainingTime) : nil
        settings.countdownOverride = nil
        settings.isManuallyPaused = schedule.isManuallyPaused
        settings.isAwaitingAcknowledgment = schedule.isAwaitingAcknowledgment && !isPreviewing
        settings.canPreview = canPresentReminder && !overlay.isActive
        settings.todayDrinkTimes = history.drinks(on: now)
        settings.history = history
        settings.currentDate = now
        settings.canUndoDrink = drinkUndo.map { history.drinks.contains($0.date) } ?? false
        settings.canRecordDrink = isPreviewing || !overlay.isActive || schedule.isAwaitingAcknowledgment
        settings.displays = OverlayController.availableDisplays
        settings.menuBarStatus = MenuBarStatus(schedule: schedule, canPresentReminder: canPresentReminder)
        if !schedule.isWithinReminderHours {
            settings.stateTitle = "休息时间"
            settings.countdownOverride = "休息中"
            let start = schedule.nextBoundaryAt.formatted(date: .omitted, time: .shortened)
            let sameDay = Calendar.autoupdatingCurrent.isDate(now, inSameDayAs: schedule.nextBoundaryAt)
            settings.scheduleText = sameDay
                ? "\(start) 后接着剩余时间继续计时"
                : "本地 \(start) 后使用电脑，开始新的计时"
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
        let updateHint = updater.availableVersion.map { "发现新版本 \($0) · " } ?? ""
        statusItem?.button?.toolTip = "Big Water · \(updateHint)\(settings.scheduleText)"
        refreshMenuBarStatus()
    }

    private func refreshUpdateIndicator() {
        updateSettings()
    }

    private func refreshMenuBarStatus() {
        guard let item = statusItem, let button = item.button else { return }
        let status = settings.menuBarStatus
        let hasUpdate = updater.availableVersion != nil
        let title = status.title(showMinutes: configuration.showMenuBarCountdown)
        let text = title + (hasUpdate ? (title.isEmpty ? "•" : " •") : "")
        item.length = text.isEmpty ? 28 : NSStatusItem.variableLength
        button.image = PixelArt.menuIcon()
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeft
        let styled = NSMutableAttributedString(string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
        if hasUpdate, let last = text.lastIndex(of: "•") {
            styled.addAttribute(.foregroundColor, value: WaterPalette.clay,
                                range: NSRange(last...last, in: text))
        }
        button.attributedTitle = styled
        let updateHint = hasUpdate ? "，发现新版本" : ""
        let minutes = status.remainingMinutes.map { "，剩余使用时间 \($0) 分钟" } ?? ""
        button.setAccessibilityLabel("Big Water，\(status.label)\(minutes)\(updateHint)，打开设置")
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
