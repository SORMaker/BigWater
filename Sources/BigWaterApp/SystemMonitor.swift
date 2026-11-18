import AppKit
import IOKit.pwr_mgt

/// What the app needs to know about the Mac around it. The model talks to
/// this protocol, so tests can stand in for sleep, displays and idle time.
@MainActor
protocol SystemWatching: AnyObject {
    /// An awake display in the person's own session: a reminder shown now
    /// would be seen.
    var isAwake: Bool { get }
    /// Seconds since the last keyboard or pointer input.
    func idleTime() -> TimeInterval
    /// Something changed: sleep, wake, displays, the session or the clock.
    /// `displaysChanged` is true when displays were added, removed or resized.
    var onChange: ((_ displaysChanged: Bool) -> Void)? { get set }
}

@MainActor
final class SystemMonitor: SystemWatching {
    /// What the session and the displays report when asked directly.
    struct Reading {
        var isSessionActive: Bool
        var isScreenAwake: Bool

        static func current() -> Reading {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let screenAwake = NSScreen.screens.contains { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                else { return false }
                return CGDisplayIsAsleep(number.uint32Value) == 0
            }
            return Reading(isSessionActive: session?[kCGSessionOnConsoleKey as String] as? Bool ?? true,
                           isScreenAwake: screenAwake)
        }
    }

    var onChange: ((Bool) -> Void)?
    private var isSleeping = false
    private var reading: Reading
    private let read: () -> Reading
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    var isAwake: Bool { !isSleeping && reading.isSessionActive && reading.isScreenAwake }

    /// The centres and the reader can be replaced to rehearse sleep and wake
    /// without putting the Mac to sleep.
    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         general: NotificationCenter = .default, read: @escaping () -> Reading = Reading.current) {
        self.read = read
        reading = read()

        // "Going dark" events are believed as they arrive. "Coming back"
        // events only prompt a fresh look at the real state: a notification
        // can be missed, for instance while another user has the console.
        observe(workspace, NSWorkspace.willSleepNotification) { $0.isSleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.isSleeping = false
            $0.reading = $0.read()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.reading.isSessionActive = false }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.reading = $0.read() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.reading.isScreenAwake = false }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.reading = $0.read() }
        observe(general, NSApplication.didChangeScreenParametersNotification, displaysChanged: true) {
            if !$0.isSleeping { $0.reading = $0.read() }
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observe(general, name) { _ in }
        }
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    /// A video or a slideshow that keeps the display on counts as being
    /// there, even with no hand on the keyboard.
    func idleTime() -> TimeInterval {
        var status: Unmanaged<CFDictionary>?
        if IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
           let assertions = status?.takeRetainedValue() as? [String: Int],
           assertions[kIOPMAssertPreventUserIdleDisplaySleep as String, default: 0] > 0 {
            return 0
        }
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, displaysChanged: Bool = false,
                         update: @escaping @MainActor (SystemMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.onChange?(displaysChanged)
            }
        }
        observers.append((center, token))
    }
}
