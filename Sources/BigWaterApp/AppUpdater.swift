import AppKit
import Combine
import Sparkle

/// Updates through Sparkle, which does the scheduling, the signature checks
/// and the install. This class only shows its state in the panel.
///
/// It starts only inside a real `.app` that carries a feed URL and a public
/// key, so tests and bare binaries never reach the network.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically = false
    @Published private(set) var isAvailable = false
    @Published private(set) var message: String?
    /// A version found by a scheduled check that the person has not looked at yet.
    @Published private(set) var availableVersion: String? {
        didSet { onAvailabilityChange?() }
    }

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    var beforeCheck: (() -> Void)?
    var onAvailabilityChange: (() -> Void)?
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else {
            message = "请打开已安装的 Big Water 检查更新。"
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                      userDriverDelegate: self)
        self.controller = controller
        do {
            try controller.updater.start()
            isAvailable = true
        } catch {
            message = "无法启动更新检查：\(error.localizedDescription)"
            return
        }
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.checksAutomatically = $0 }
            .store(in: &subscriptions)
    }

    func setChecksAutomatically(_ enabled: Bool) {
        guard isAvailable else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func check() {
        guard canCheck else { return }
        beforeCheck?()
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // A menu bar app has no window to come back to. A scheduled check shows a
    // dot by the bottle instead, and Sparkle steps forward only on a click.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    // Sparkle's standard user driver calls its delegate on the main thread.

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
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
