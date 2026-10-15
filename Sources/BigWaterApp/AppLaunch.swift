import AppKit

/// Runs the menu-bar app. The `BigWater` executable only calls this, so the
/// app's classes can live in a library that the session checks also build.
@MainActor
public func runBigWaterApp() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
