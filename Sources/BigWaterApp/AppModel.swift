import Combine
import Foundation
import OSLog
import BigWaterCore

/// Wakes the model at a later time. One wake-up is pending at most.
@MainActor
protocol WakeTimer: AnyObject {
    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class RunLoopWakeTimer: WakeTimer {
    private var timer: Timer?

    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// The app's one source of truth: the countdown, the drink log, the settings
/// and the reminder on screen, and every rule that ties them together.
///
/// Whatever happens (a timer, a click, the Mac waking up) goes the same way:
/// read the clocks and the system once, apply the change, then `reconcile`
/// brings the screen, the saved state and the next wake-up into line with it.
/// The views read from here and call its methods; nothing else holds state.
@MainActor
final class AppModel: ObservableObject {
    struct Dependencies {
        var now: () -> Moment = Moment.now
        var calendar: () -> Calendar = { .autoupdatingCurrent }
        var system: SystemWatching
        var store: StateStore
        var presenter: ReminderPresenter
        var timer: WakeTimer
        var playSound: () -> Void = {}
    }

    /// How soon to try again when a due reminder could not be shown: no
    /// usable display, or the last one still leaving.
    static let retryDelay: TimeInterval = 30
    /// The countdown is saved this often while it runs, so a crash loses
    /// half a minute at most. Passing the away threshold is noticed here too.
    static let checkpointInterval: TimeInterval = 30
    /// Nothing announces a return to the keyboard, so it is looked for.
    static let awayPollInterval: TimeInterval = 5

    @Published private(set) var preferences: Preferences
    @Published private(set) var schedule: Schedule
    @Published private(set) var log: DrinkLog
    /// The wall time of the last pass. Views show the state as of then.
    @Published private(set) var now: Date
    /// What is on screen, if anything.
    @Published private(set) var stage: Reminder.Stage?
    @Published private(set) var canUndo = false
    @Published private(set) var displays: [Display] = []
    /// Set by the menu bar while its panel is open.
    @Published var isPanelVisible = false

    /// After every pass, for the menu bar item.
    var onChange: (() -> Void)?
    /// A reminder or a preview just went up.
    var onReminderShown: (() -> Void)?

    private let dependencies: Dependencies
    private var presenter: ReminderPresenter { dependencies.presenter }
    private let logger = Logger(subsystem: "com.oil.bigwater", category: "reminders")

    /// The last drink, and the countdown as it was just before it.
    private struct Undo {
        let date: Date
        /// Dropped once a later choice (a snooze, a pause, new hours) has
        /// made going back to it meaningless.
        var schedule: Schedule?
    }
    private var undo: Undo?
    private var lastDrinkUptime: TimeInterval?
    /// The day the reminder on screen went up. It does not outlive that day.
    private var reminderDay: LocalDay?

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        let saved = dependencies.store.load()
        let moment = dependencies.now()
        preferences = saved.preferences
        log = saved.log
        now = moment.date
        schedule = Schedule(plan: saved.preferences.plan, now: moment, isAwake: dependencies.system.isAwake,
                            calendar: dependencies.calendar(), saved: saved.progress)
        dependencies.presenter.onEvent = { [weak self] in self?.handle($0) }
        dependencies.system.onChange = { [weak self] displaysChanged in
            if displaysChanged { self?.presenter.displaysChanged() }
            self?.refresh()
        }
    }

    // MARK: What the views show

    var calendar: Calendar { dependencies.calendar() }
    var status: StatusText { StatusText(schedule, now: now, calendar: calendar) }
    var todayCount: Int { log.count(on: now, calendar: calendar) }
    /// A reminder is waiting: the panel offers the same answers as the screen.
    var isWaiting: Bool { schedule.stage == .waiting }
    var canPreview: Bool { schedule.isAwake && stage == nil }
    /// Not while a drink is under way or the mascot is on its way out.
    var canDrink: Bool { stage != .drinking && stage != .leaving }

    /// With a reminder up, the drink action starts its drink-along instead
    /// of recording at once, and says so.
    var drinkTitle: String {
        if stage == .drinking { return "喝水中…" }
        return isWaiting ? "去喝水" : "我刚喝过水"
    }

    /// The clock right now, for views that must not trust a stale `now`.
    func currentTime() -> Date { dependencies.now().date }

    func countdown(at date: Date) -> String {
        let passed = schedule.isRunning ? date.timeIntervalSince(now) : 0
        return status.countdown(schedule.remaining - passed)
    }

    // MARK: What can happen

    /// Looks at everything again. Safe to call at any time, and called by
    /// every timer and system event.
    func refresh() {
        reconcile(observe())
    }

    /// The drink action of the panel and the menu. With a reminder up it
    /// goes through that reminder's drink-along: the menu is no way round it.
    func drink() {
        switch presenter.stage {
        case .asking:
            if schedule.stage == .waiting { presenter.drink() }
        case .drinking, .leaving:
            break
        case nil, .preview:
            presenter.dismiss()
            let pass = observe()
            record(pass)
            reconcile(pass)
        }
    }

    func snooze(minutes: Int) {
        if presenter.stage == .asking || presenter.stage == .drinking {
            presenter.putOff(minutes: minutes)
        } else {
            putOff(minutes: minutes)
        }
    }

    /// Removes the last drink and, where it still makes sense, puts the
    /// countdown back to where it was, a waiting reminder included.
    func undoLastDrink() {
        guard let undo, log.remove(at: undo.date) else { return }
        self.undo = nil
        lastDrinkUptime = nil
        if let earlier = undo.schedule {
            presenter.dismiss()
            schedule = earlier
        }
        refresh()
    }

    func removeDrink(at date: Date) {
        if undo?.date == date { return undoLastDrink() }
        guard log.remove(at: date) else { return }
        refresh()
    }

    /// Corrections to the log never answer a reminder or restart the countdown.
    @discardableResult
    func addPastDrink(at date: Date) -> Bool {
        guard log.addPast(at: date, now: dependencies.now().date, calendar: calendar) else { return false }
        refresh()
        return true
    }

    @discardableResult
    func moveDrink(from old: Date, to new: Date) -> Bool {
        guard log.move(from: old, to: new, now: dependencies.now().date, calendar: calendar) else { return false }
        if undo?.date == old { undo = nil }
        refresh()
        return true
    }

    func pause(minutes: Int) {
        undo?.schedule = nil
        presenter.dismiss()
        let pass = observe()
        schedule.pause(minutes: minutes, at: pass.moment, calendar: pass.calendar)
        reconcile(pass)
    }

    func resume() {
        undo?.schedule = nil
        let pass = observe()
        schedule.resume(at: pass.moment, calendar: pass.calendar)
        reconcile(pass)
    }

    /// Changes settings. False when the edit leaves hours that make no
    /// sense; nothing is changed then.
    @discardableResult
    func update(_ edit: (inout Preferences) -> Void) -> Bool {
        var edited = preferences
        edit(&edited)
        guard edited.weekdayHours.isValid, edited.weekendHours?.isValid != false else { return false }
        let next = edited.validated()
        guard next != preferences else { return true }
        let pass = observe()
        // New names for the same periods count the same, so undo still works.
        if !next.countsLike(preferences) { undo?.schedule = nil }
        schedule.adopt(next.plan, at: pass.moment, calendar: pass.calendar)
        if var earlier = undo?.schedule {
            var plan = earlier.plan
            plan.awayAfter = next.plan.awayAfter
            earlier.adopt(plan, at: pass.moment, calendar: pass.calendar)
            undo?.schedule = earlier
        }
        preferences = next
        reconcile(pass)
        return true
    }

    /// Shows the reminder as it is set up now. It records nothing and
    /// leaves the countdown alone.
    func preview() {
        guard dependencies.system.isAwake,
              presenter.present(style: preferences.style, look: preferences.look,
                                placement: preferences.placement, isPreview: true) else { return }
        reminderDay = schedule.day
        onReminderShown?()
        publish()
    }

    /// Shows a real reminder now, ahead of its time. For trying a build.
    func remindNow() {
        let pass = observe()
        present()
        reconcile(pass)
    }

    func prepareToQuit() {
        let pass = observe()
        save(pass)
        dependencies.timer.cancel()
        presenter.dismiss()
    }

    // MARK: One pass

    /// One reading of the clocks and the system, shared by a whole pass.
    private struct Pass {
        let moment: Moment
        let calendar: Calendar
    }

    private func observe() -> Pass {
        let pass = Pass(moment: dependencies.now(), calendar: dependencies.calendar())
        let awake = dependencies.system.isAwake
        let idle = dependencies.system.idleTime()
        // The countdown an undo would bring back keeps counting alongside.
        undo?.schedule?.advance(to: pass.moment, awake: awake, idle: idle, calendar: pass.calendar)
        schedule.advance(to: pass.moment, awake: awake, idle: idle, calendar: pass.calendar)
        return pass
    }

    /// Brings the screen, the saved state and the next wake-up into line
    /// with the countdown.
    private func reconcile(_ pass: Pass) {
        let mayShow = schedule.window == .open && !schedule.isPaused
        let outlivedItsDay = presenter.stage != nil && reminderDay != schedule.day

        if presenter.stage == .preview {
            // A preview gives way to darkness, a new day and the real thing.
            if !schedule.isAwake || outlivedItsDay || schedule.isDue { presenter.dismiss() }
        } else {
            // An unanswered reminder the countdown no longer waits for:
            // its hours ended, or a setting or a menu action cleared it.
            let isOpen = presenter.stage == .asking || presenter.stage == .drinking
            if !mayShow || outlivedItsDay || (isOpen && schedule.stage != .waiting) { presenter.dismiss() }
        }
        if presenter.stage != .preview {
            if mayShow && schedule.isAwake {
                presenter.resume()
                if schedule.isDue || (schedule.stage == .waiting && presenter.stage == nil) { present() }
            } else if !schedule.isAwake {
                presenter.suspend()
            }
        }
        save(pass)
        arm(pass)
        publish()
    }

    private func present() {
        guard schedule.isAwake, schedule.window == .open, !schedule.isPaused,
              presenter.present(style: preferences.style, look: preferences.look,
                                placement: preferences.placement) else { return }
        reminderDay = schedule.day
        schedule.reminderShown()
        onReminderShown?()
        if preferences.soundEnabled { dependencies.playSound() }
        logger.info("Reminder started")
    }

    private func handle(_ event: ReminderPresenter.Event) {
        switch event {
        case .drinkStarted, .previewEnded, .gone:
            refresh()
        case .drinkFinished:
            // Judged before looking at the clock again: a drink that ran to
            // its end counts even if the day's hours closed in the same instant.
            let wasWaiting = schedule.stage == .waiting
            let pass = observe()
            if wasWaiting { record(pass) }
            reconcile(pass)
        case .putOff(let minutes):
            putOff(minutes: minutes)
        }
    }

    private func putOff(minutes: Int) {
        let pass = observe()
        if schedule.stage == .waiting {
            undo?.schedule = nil
            schedule.snooze(minutes: minutes, at: pass.moment, calendar: pass.calendar)
        }
        reconcile(pass)
    }

    private func record(_ pass: Pass) {
        // Two clicks within a second are one drink.
        if let last = lastDrinkUptime, pass.moment.uptime >= last, pass.moment.uptime - last < 1 { return }
        undo = Undo(date: pass.moment.date, schedule: schedule)
        lastDrinkUptime = pass.moment.uptime
        log.record(at: pass.moment.date, calendar: pass.calendar)
        schedule.recordDrink(at: pass.moment, calendar: pass.calendar)
        logger.info("Drink recorded")
    }

    private func save(_ pass: Pass) {
        dependencies.store.save(preferences: preferences,
                                progress: schedule.progress(at: pass.moment, calendar: pass.calendar), log: log)
    }

    private func arm(_ pass: Pass) {
        var delay = schedule.nextWake.map { max($0.timeIntervalSince(pass.moment.date), 0.1) }
        if schedule.isDue { delay = Self.retryDelay }
        if schedule.isRunning { delay = min(delay ?? .infinity, Self.checkpointInterval) }
        let watchingForReturn = schedule.isAway && schedule.isAwake && schedule.window == .open
            && !schedule.isPaused && schedule.stage != .waiting
        if watchingForReturn { delay = min(delay ?? .infinity, Self.awayPollInterval) }
        if let delay {
            dependencies.timer.schedule(after: delay) { [weak self] in self?.refresh() }
        } else {
            // Asleep: a wake notification starts things again.
            dependencies.timer.cancel()
        }
    }

    private func publish() {
        now = schedule.asOf
        stage = presenter.stage
        canUndo = undo.map { log.drinks.contains($0.date) } ?? false
        let connected = Display.connected
        if connected != displays { displays = connected }
        onChange?()
    }
}
