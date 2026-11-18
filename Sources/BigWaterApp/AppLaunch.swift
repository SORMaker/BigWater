import AppKit
import BigWaterCore

/// Runs the menu bar app. The `BigWater` executable calls only this, so
/// everything else lives in a library that the tests can also build.
@MainActor
public func runBigWaterApp() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}

/// Puts the pieces together at launch and takes them apart at quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var system: SystemMonitor?
    private var model: AppModel?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A second copy would show every reminder twice.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            return NSApp.terminate(nil)
        }

        let system = SystemMonitor()
        let model = AppModel(.init(system: system, store: StateStore(),
                                   presenter: ReminderPresenter(surface: OverlayWindows(), ticker: TimerTicker()),
                                   timer: RunLoopWakeTimer(),
                                   playSound: { NSSound(named: NSSound.Name("Glass"))?.play() }))
        let login = LoginItem()
        self.system = system
        self.model = model
        menuBar = MenuBarController(model: model, updater: AppUpdater(), login: login)
        login.configure()
        model.refresh()

        // `--preview` shows a real reminder straight away, to try a build.
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { model.remindNow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.openPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareToQuit()
        system?.stop()
    }
}
