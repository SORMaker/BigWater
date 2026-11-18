import Foundation
import QuartzCore
import BigWaterCore

/// The windows a reminder is shown in. The presenter decides what happens;
/// a surface only draws it and reports clicks.
@MainActor
protocol OverlaySurface: AnyObject {
    /// The person pressed a button, or the mascot itself (`.drink`).
    var onAction: ((OverlayAction) -> Void)? { get set }
    /// Picks the display for a new reminder. Nil when none can show one.
    func open(on placement: Placement) -> ScreenSpace?
    /// After displays changed: stays on the same display if it is still
    /// there, and otherwise moves as `placement` says. Nil when none is left.
    func refit(to placement: Placement) -> ScreenSpace?
    /// The pointer on the reminder's display, in the reminder's coordinates.
    var pointer: CGPoint? { get }
    func show(_ reminder: Reminder, layout: OverlayLayout, repaintAll: Bool)
    func setHidden(_ hidden: Bool)
    func close()
}

/// Calls back once per animation frame with the seconds since the last one.
@MainActor
protocol FrameTicker: AnyObject {
    func start(_ onFrame: @escaping @MainActor (TimeInterval) -> Void)
    func stop()
}

@MainActor
final class TimerTicker: FrameTicker {
    private var timer: Timer?
    private var last = 0.0

    func start(_ onFrame: @escaping @MainActor (TimeInterval) -> Void) {
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                // A stalled frame must not fling the scene forward.
                let elapsed = min(now - self.last, 1.0 / 12)
                self.last = now
                onFrame(elapsed)
            }
        }
        // Common modes keep it running while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Runs one reminder on screen: starts it, moves it along frame by frame,
/// and tells its owner what the person did.
@MainActor
final class ReminderPresenter {
    enum Event: Equatable {
        /// The person started the drink-along. Nothing is recorded yet.
        case drinkStarted
        /// The drink-along ran to its end: this is when a drink counts.
        case drinkFinished
        case putOff(minutes: Int)
        /// The person closed a preview.
        case previewEnded
        /// The reminder finished leaving on its own.
        case gone
    }

    var onEvent: ((Event) -> Void)?

    private let surface: OverlaySurface
    private let ticker: FrameTicker
    private(set) var reminder: Reminder?
    private var placement = Placement()
    private(set) var isSuspended = false

    init(surface: OverlaySurface, ticker: FrameTicker) {
        self.surface = surface
        self.ticker = ticker
        surface.onAction = { [weak self] in self?.perform($0) }
    }

    /// Nil while nothing is on screen.
    var stage: Reminder.Stage? { reminder?.stage }

    /// False when a reminder is already up or no display can show one.
    @discardableResult
    func present(style: ReminderStyle, look: Look, placement: Placement, isPreview: Bool = false,
                 entrance: Entrance = .random()) -> Bool {
        guard reminder == nil, let screen = surface.open(on: placement) else { return false }
        self.placement = placement
        isSuspended = false
        reminder = Reminder(style: style, look: look, corner: placement.corner, screen: screen,
                            isPreview: isPreview, entrance: entrance)
        render(repaintAll: true)
        syncTicker()
        return true
    }

    func perform(_ action: OverlayAction) {
        switch action {
        case .drink: drink()
        case .snooze(let minutes): putOff(minutes: minutes)
        case .endPreview: endPreview()
        }
    }

    /// From the drink button, the mascot, or the menu. In a preview any
    /// click simply ends it.
    func drink() {
        guard var current = reminder else { return }
        if current.isPreview { return endPreview() }
        guard current.drink() else { return }
        reminder = current
        syncTicker()
        render(repaintAll: true)
        onEvent?(.drinkStarted)
    }

    func putOff(minutes: Int) {
        guard OverlayAction.snoozeChoices.contains(minutes), var current = reminder else { return }
        if current.isPreview { return endPreview() }
        guard current.putOff() else { return }
        dismiss()
        onEvent?(.putOff(minutes: minutes))
    }

    private func endPreview() {
        guard reminder?.isPreview == true else { return }
        dismiss()
        onEvent?(.previewEnded)
    }

    /// Takes the reminder off the screen at once, without telling anyone.
    func dismiss() {
        guard reminder != nil else { return }
        reminder = nil
        isSuspended = false
        ticker.stop()
        surface.close()
    }

    /// The display went dark. The reminder waits as it is, a drink included.
    func suspend() {
        guard reminder != nil, !isSuspended else { return }
        isSuspended = true
        ticker.stop()
        surface.setHidden(true)
    }

    func resume() {
        guard reminder != nil, isSuspended, let screen = surface.refit(to: placement) else { return }
        isSuspended = false
        reminder?.fit(screen)
        surface.setHidden(false)
        render(repaintAll: true)
        syncTicker()
    }

    func displaysChanged() {
        guard reminder != nil else { return }
        guard let screen = surface.refit(to: placement) else { return suspend() }
        reminder?.fit(screen)
        render(repaintAll: true)
    }

    /// One animation step. Tests call this to skip the wait.
    func advance(by elapsed: Double) {
        guard var current = reminder else { return }
        let events = current.advance(by: elapsed)
        reminder = current
        if events.contains(.gone) { dismiss() } else { render(repaintAll: false) }
        for event in events {
            switch event {
            case .drinkFinished: onEvent?(.drinkFinished)
            case .gone: onEvent?(.gone)
            }
        }
    }

    private func render(repaintAll: Bool) {
        guard !isSuspended, var current = reminder else { return }
        current.hover(at: surface.pointer)
        reminder = current
        surface.show(current, layout: current.layout, repaintAll: repaintAll)
    }

    private func syncTicker() {
        if reminder?.isAnimating == true && !isSuspended {
            ticker.start { [weak self] in self?.advance(by: $0) }
        } else {
            ticker.stop()
        }
    }
}
