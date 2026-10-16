import AppKit
import Combine
import Sparkle

/// Sparkle owns scheduling, persisted update preferences, verification and install.
/// Keep the command-line check runners offline: only a configured .app starts it.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isAvailable = false
    @Published private(set) var statusText: String?
    @Published private(set) var availableVersion: String? {
        didSet { onUpdateAvailabilityChange?() }
    }
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    var beforeCheckForUpdates: (() -> Void)?
    var onUpdateAvailabilityChange: (() -> Void)?
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else {
            statusText = "请打开已安装的 Big Water 检查更新。"
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                     updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        do {
            try controller.updater.start()
            isAvailable = true
        } catch {
            statusText = "无法启动更新检查：\(error.localizedDescription)"
            return
        }
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &subscriptions)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        beforeCheckForUpdates?()
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    // A dockless app has no main window to return to. Show a menu-bar indicator
    // for scheduled updates, and bring Sparkle forward only on a user's click.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Sparkle's standard user driver invokes its delegate on the main thread.
        MainActor.assumeIsolated {
            if !state.userInitiated { availableVersion = update.displayVersionString }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}
