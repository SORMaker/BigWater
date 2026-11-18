import AppKit
import BigWaterCore
@testable import BigWaterApp

/// A Mac that does what the test says.
@MainActor
final class FakeSystem: SystemWatching {
    var isAwake = true
    var idle: TimeInterval = 0
    var onChange: ((Bool) -> Void)?

    func idleTime() -> TimeInterval { idle }
}

/// Stands in for the overlay windows: remembers what it was asked to show.
@MainActor
final class FakeSurface: OverlaySurface {
    var onAction: ((OverlayAction) -> Void)?
    /// The display reminders open on. Nil plays a Mac with no usable display.
    var screen: ScreenSpace? = ScreenSpace(size: CGSize(width: 1_440, height: 900), topInset: 25)
    var pointer: CGPoint?
    private(set) var isOpen = false
    private(set) var isHidden = false
    private(set) var shown: Reminder?
    private(set) var layout: OverlayLayout?
    private(set) var opens = 0

    func open(on placement: Placement) -> ScreenSpace? {
        guard let screen else { return nil }
        isOpen = true
        opens += 1
        return screen
    }

    func refit(to placement: Placement) -> ScreenSpace? { screen }

    func show(_ reminder: Reminder, layout: OverlayLayout, repaintAll: Bool) {
        shown = reminder
        self.layout = layout
    }

    func setHidden(_ hidden: Bool) { isHidden = hidden }

    func close() {
        isOpen = false
        isHidden = false
        shown = nil
        layout = nil
    }
}

@MainActor
final class FakeTicker: FrameTicker {
    private(set) var isRunning = false
    func start(_ onFrame: @escaping @MainActor (TimeInterval) -> Void) { isRunning = true }
    func stop() { isRunning = false }
}

@MainActor
final class FakeTimer: WakeTimer {
    private(set) var delay: TimeInterval?
    private var fire: (@MainActor () -> Void)?

    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.fire = fire
    }

    func cancel() {
        delay = nil
        fire = nil
    }

    func fireNow() { fire?() }
}

/// The real model and the real presenter, on a clock, a Mac and a screen
/// that the test controls. No window is ever opened.
@MainActor
final class World {
    var clock: TestClock
    let system = FakeSystem()
    let surface = FakeSurface()
    let ticker = FakeTicker()
    let timer = FakeTimer()
    let defaults = scratchDefaults()
    private(set) var sounds = 0
    private(set) var model: AppModel!
    private(set) var presenter: ReminderPresenter!

    /// Thursday 15 October 2026, 09:00, with the standard settings.
    init(at start: Date = october(15, 9), _ edit: ((inout Preferences) -> Void)? = nil) {
        clock = TestClock(date: start)
        launch()
        if let edit { model.update(edit) }
    }

    /// Starts the app. Called again, it is a restart on the same saved state.
    func launch() {
        presenter = ReminderPresenter(surface: surface, ticker: ticker)
        model = AppModel(.init(now: { [unowned self] in self.clock.moment }, calendar: { shanghai }, system: system,
                               store: StateStore(defaults: defaults), presenter: presenter, timer: timer,
                               playSound: { [unowned self] in self.sounds += 1 }))
        model.refresh()
    }

    func quitAndRelaunch(after offline: TimeInterval = 0) {
        model.prepareToQuit()
        clock.date = clock.date.addingTimeInterval(offline)
        clock.uptime = 60
        launch()
    }

    var schedule: Schedule { model.schedule }
    var stage: Reminder.Stage? { presenter.stage }
    var drinksToday: Int { model.todayCount }

    /// The person works for a while, and the app looks at the end of it.
    func use(_ seconds: TimeInterval) {
        clock.pass(seconds)
        model.refresh()
    }

    func use(until date: Date) { use(date.timeIntervalSince(clock.date)) }

    /// Works until the next reminder is due and on screen.
    func workUntilReminded() {
        use(schedule.remaining)
        expect(stage == .asking, "a reminder should be up, got \(String(describing: stage))")
    }

    func setAwake(_ awake: Bool) {
        system.isAwake = awake
        system.onChange?(false)
    }

    /// Presses a button of the reminder on screen.
    func press(_ action: OverlayAction) { surface.onAction?(action) }

    /// Lets animation run without any time passing for the countdown.
    func animate(_ seconds: Double) { presenter.advance(by: seconds) }

    /// Long enough for a started drink-along to run out.
    func finishDrinking() { animate(ReminderScene.entranceTime + ReminderScene.standardDrinkTime + 0.1) }

    func finishLeaving() { animate(ReminderScene.cheerTime + ReminderScene.exitTime + 0.1) }
}
