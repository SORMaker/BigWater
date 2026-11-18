import AppKit
import SwiftUI
import BigWaterCore
import BigWaterArt

/// The bottle in the menu bar: a left click opens the panel, a right click
/// a short menu. It shows what the model says and holds no state of its own.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let updater: AppUpdater
    private let login: LoginItem
    private let item = NSStatusBar.system.statusItem(withLength: MenuBarController.iconOnlyLength)
    private let popover = NSPopover()
    private let icon = Painter.menuIcon()
    private static let iconOnlyLength: CGFloat = 28

    init(model: AppModel, updater: AppUpdater, login: LoginItem) {
        self.model = model
        self.updater = updater
        self.login = login
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // The panel is drawn on cream in both light and dark mode.
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(
            rootView: PanelView(model: model, updater: updater, login: login))
        popover.contentSize = PanelView.size

        if let button = item.button {
            button.image = icon
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.onChange = { [weak self] in self?.updateItem() }
        model.onReminderShown = { [weak self] in self?.popover.performClose(nil) }
        updater.beforeCheck = { [weak self] in self?.popover.performClose(nil) }
        updater.onAvailabilityChange = { [weak self] in self?.updateItem() }
        updateItem()
    }

    func openPanel() {
        if !popover.isShown { togglePanel() }
    }

    func popoverDidClose(_ notification: Notification) { model.isPanelVisible = false }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showQuickMenu() } else { togglePanel() }
    }

    private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown { return popover.performClose(nil) }
        model.refresh()
        login.refresh()
        model.isPanelVisible = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Key, so its controls work at once, but with nothing focused.
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }

    private func showQuickMenu() {
        popover.performClose(nil)
        model.refresh()
        // Attached only for this click, so a left click still opens the panel.
        item.menu = makeQuickMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// Built for every right click, so it always shows the present state.
    private func makeQuickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let groups = model.quickActions(openPanel: { [weak self] in self?.openPanel() },
                                        quit: { NSApp.terminate(nil) })
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            group.forEach { menu.addItem(ActionItem($0)) }
        }
        return menu
    }

    private func updateItem() {
        guard let button = item.button else { return }
        let status = model.status
        let newVersion = updater.availableVersion
        let title = model.preferences.showMenuBarCountdown ? status.menuTitle : ""
        // A dot beside the bottle says an update is waiting.
        let text = newVersion == nil ? title : (title.isEmpty ? "•" : title + " •")

        item.length = text.isEmpty ? Self.iconOnlyLength : NSStatusItem.variableLength
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeft
        let styled = NSMutableAttributedString(
            string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
        if newVersion != nil, let dot = text.lastIndex(of: "•") {
            styled.addAttribute(.foregroundColor, value: Palette.clay, range: NSRange(dot...dot, in: text))
        }
        button.attributedTitle = styled

        let minutes = status.remainingMinutes.map { "，剩余使用时间 \($0) 分钟" } ?? ""
        button.setAccessibilityLabel(
            "Big Water，\(status.label)\(minutes)\(newVersion == nil ? "" : "，发现新版本")，打开设置")
        button.toolTip = "Big Water · \(newVersion.map { "发现新版本 \($0) · " } ?? "")\(status.detail)"
    }
}

/// One line of the right-click menu.
struct QuickAction {
    let title: String
    var isEnabled = true
    let run: @MainActor () -> Void
}

extension AppModel {
    /// The right-click menu, in groups that a separator divides.
    func quickActions(openPanel: @escaping @MainActor () -> Void,
                      quit: @escaping @MainActor () -> Void) -> [[QuickAction]] {
        var pausing = [QuickAction(title: "暂停 30 分钟") { [self] in pause(minutes: 30) },
                       QuickAction(title: "暂停 60 分钟") { [self] in pause(minutes: 60) }]
        if schedule.isPaused { pausing.append(QuickAction(title: "恢复计时") { [self] in resume() }) }
        return [
            [QuickAction(title: drinkTitle, isEnabled: canDrink) { [self] in drink() },
             QuickAction(title: "撤销刚才的喝水记录", isEnabled: canUndo) { [self] in undoLastDrink() }],
            pausing,
            [QuickAction(title: "打开设置…", run: openPanel), QuickAction(title: "退出 Big Water", run: quit)]
        ]
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ action: QuickAction) {
        handler = action.run
        super.init(title: action.title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = action.isEnabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { MainActor.assumeIsolated { handler() } }
}
