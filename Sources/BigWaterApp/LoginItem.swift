import Foundation
import OSLog
import ServiceManagement

/// Opening Big Water at login. On by default: it registers itself the first
/// time the app runs, and the person can switch it off in the panel.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    /// macOS wants the person to allow it in System Settings.
    @Published private(set) var needsApproval = false
    @Published private(set) var message: String?

    private static let choiceKey = "launchAtLogin"
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.oil.bigwater", category: "login")

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Only a real `.app` can be a login item, not a binary run from a build folder.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func configure() {
        if defaults.object(forKey: Self.choiceKey) == nil { set(true) } else { refresh() }
    }

    func set(_ enabled: Bool) {
        guard isBundled else {
            message = "请从 Big Water.app 设置登录启动"
            return
        }
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            defaults.set(enabled, forKey: Self.choiceKey)
            refresh()
        } catch {
            refresh()
            message = "设置未成功，请在系统登录项中检查"
            logger.error("Login item change failed: \(error.localizedDescription)")
        }
    }

    /// The switch shows what macOS says, which the person may have changed
    /// in System Settings since.
    func refresh() {
        guard isBundled else { return }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
        message = needsApproval ? "请在系统登录项中允许 Big Water" : nil
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
