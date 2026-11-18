import SwiftUI
import BigWaterCore
import BigWaterArt

/// Colours and small pieces shared by the panel's pages.
enum PanelStyle {
    static let ink = Color(nsColor: Palette.ink)
    static let clay = Color(nsColor: Palette.clay)
    static let cream = Color(nsColor: Palette.cream)
    static let faint = ink.opacity(0.55)
    static let link = Color(red: 0.05, green: 0.45, blue: 0.84)
}

/// The panel under the menu bar bottle. One page shows at a time.
struct PanelView: View {
    static let size = NSSize(width: 356, height: 540)

    enum Page { case home, more, hours, history }

    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @ObservedObject var login: LoginItem
    @State private var page = Page.home

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    switch page {
                    case .home: HomePage(model: model, updater: updater, login: login, page: $page)
                    case .more: MorePage(model: model, page: $page)
                    case .hours: HoursPage(model: model, page: $page)
                    case .history: HistoryPage(model: model, page: $page)
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .id("top")
            }
            .onChange(of: model.isPanelVisible) { visible in
                // Every opening starts on the home page, at its top.
                if visible { proxy.scrollTo("top", anchor: .top) } else { page = .home }
            }
            .onChange(of: page) { _ in proxy.scrollTo("top", anchor: .top) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(PanelStyle.cream)
        .foregroundStyle(PanelStyle.ink)
    }
}

/// The column every page is laid out in.
struct PageStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
    }
}

/// "Back" and a title, at the top of every page but the first.
struct PageHeader: View {
    let title: String
    @Binding var page: PanelView.Page

    var body: some View {
        Button { page = .home } label: {
            Label("返回", systemImage: "chevron.left").contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Text(title).font(.system(size: 20, weight: .semibold))
    }
}

/// A row that opens another page, with a summary on its right.
struct PageLink: View {
    let title: String
    let summary: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(summary).font(.system(size: 12)).monospacedDigit().foregroundStyle(PanelStyle.ink.opacity(0.6))
                Image(systemName: "chevron.right").font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension AppModel {
    /// A binding that reads a setting and writes it back through `update`.
    func binding<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Home

struct HomePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @ObservedObject var login: LoginItem
    @Binding var page: PanelView.Page

    var body: some View {
        PageStack {
            header
            countdownCard
            actions
            intervalRow
            VStack(alignment: .leading, spacing: 16) {
                PageLink(title: "喝水记录", summary: "今天 \(model.todayCount) 次") { page = .history }
                PageLink(title: "作息时间", summary: hoursSummary) { page = .hours }
            }
            .padding(12)
            .background(.white.opacity(0.45))
            .overlay(Rectangle().stroke(PanelStyle.ink.opacity(0.08), lineWidth: 1))
            appRows
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: Painter.panelBottle())
                .resizable().interpolation(.none).scaledToFit().frame(width: 30, height: 54)
                .accessibilityHidden(true)
            Text("Big Water").font(.system(size: 25, weight: .semibold, design: .serif))
            Spacer(minLength: 0)
            Button { page = .more } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PanelStyle.ink.opacity(0.6))
            .accessibilityLabel("更多设置")
            .help("更多设置")
        }
    }

    private var countdownCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.status.title).fontWeight(.medium)
            if model.isPanelVisible {
                // Ticks only while someone is looking.
                TimelineView(.periodic(from: .now, by: 1)) { countdown(at: $0.date) }
            } else {
                countdown(at: model.now)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78))
        .overlay(alignment: .top) { Rectangle().fill(PanelStyle.clay.opacity(0.65)).frame(height: 3) }
        .overlay(Rectangle().stroke(PanelStyle.ink.opacity(0.10), lineWidth: 1))
    }

    private func countdown(at date: Date) -> some View {
        let text = model.countdown(at: date)
        return Text(text)
            .font(.system(size: 30, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .accessibilityLabel("\(model.status.title) \(text)")
    }

    /// The same answers as the reminder on screen, for the keyboard, for
    /// VoiceOver, and for when the reminder is on another display.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(model.drinkTitle) { model.drink() }
                    .buttonStyle(.borderedProminent).tint(PanelStyle.clay)
                    .disabled(!model.canDrink)
                if model.canUndo {
                    Button("撤销刚才") { model.undoLastDrink() }
                        .buttonStyle(.plain)
                        .help("撤销刚才的喝水记录")
                        .accessibilityLabel("撤销刚才的喝水记录")
                }
                Spacer(minLength: 0)
            }
            if model.isWaiting {
                HStack(spacing: 8) {
                    ForEach(OverlayAction.snoozeChoices, id: \.self) { minutes in
                        Button("\(minutes) 分钟后") { model.snooze(minutes: minutes) }
                    }
                }
            }
        }
        .controlSize(.regular)
    }

    private var intervalMinutes: Int { Int((model.preferences.intervalHours * 60).rounded()) }

    private func setInterval(minutes: Int) {
        model.update { $0.intervalHours = Double(minutes) / 60 }
    }

    private var intervalRow: some View {
        HStack {
            Text("提醒间隔").fontWeight(.medium)
            Spacer()
            HStack(spacing: 6) {
                Picker("提醒间隔小时", selection: Binding(
                    get: { intervalMinutes / 60 },
                    set: { setInterval(minutes: $0 * 60 + ($0 == 24 ? 0 : intervalMinutes % 60)) }
                )) {
                    ForEach(0...24, id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 62)
                Text("小时")
                Picker("提醒间隔分钟", selection: Binding(
                    get: { intervalMinutes % 60 },
                    set: { setInterval(minutes: intervalMinutes / 60 * 60 + $0) }
                )) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { minute in
                        // Five minutes is the shortest interval.
                        Text(String(format: "%02d", minute)).tag(minute)
                            .disabled(intervalMinutes < 60 && minute == 0)
                    }
                }
                .frame(width: 62)
                .disabled(intervalMinutes == 24 * 60)
                Text("分钟")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .monospacedDigit()
            .controlSize(.regular)
        }
    }

    private var hoursSummary: String {
        let periods = model.preferences.hours.hours(on: model.now, calendar: model.calendar).periods
        if periods.count > 2 { return "\(periods.count) 个时段" }
        return periods.map {
            String(format: "%02d:%02d–%02d:%02d", $0.start / 60, $0.start % 60, $0.end / 60, $0.end % 60)
        }.joined(separator: " / ")
    }

    private var appRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    switchRow("登录时启动", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                        .help(login.message ?? "登录时启动 Big Water")
                    if login.needsApproval {
                        Button("打开系统登录项") { login.openSystemSettings() }
                    }
                }
                switchRow("自动检查更新", isOn: Binding(get: { updater.checksAutomatically },
                                                    set: { updater.setChecksAutomatically($0) }))
                    .disabled(!updater.isAvailable)
            }
            Button { NSApp.terminate(nil) } label: {
                HStack {
                    Text("退出 Big Water")
                    Spacer()
                    Text("↗")
                }
                .foregroundStyle(PanelStyle.clay)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            HStack {
                Text("版本 \(updater.version)").foregroundStyle(PanelStyle.ink.opacity(0.6))
                Spacer()
                Button(updater.availableVersion.map { "更新至 \($0)…" } ?? "检查更新…") { updater.check() }
                    .disabled(!updater.canCheck)
                    .help(updater.message ?? "检查是否有新版本")
            }
            .controlSize(.regular)
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

// MARK: - More settings

struct MorePage: View {
    @ObservedObject var model: AppModel
    @Binding var page: PanelView.Page
    @State private var pauseMinutes = "30"

    var body: some View {
        PageStack {
            PageHeader(title: "更多设置", page: $page)
            section("暂停提醒") { pauseControls }
            Divider()
            section("离开座位") {
                Toggle("离开时暂停计时", isOn: model.binding(\.pauseWhenAway)).toggleStyle(.switch).controlSize(.small)
                if model.preferences.pauseWhenAway {
                    Picker("无操作超过", selection: model.binding(\.awayMinutes)) {
                        ForEach(Preferences.awayMinuteChoices, id: \.self) { Text("\($0) 分钟").tag($0) }
                    }
                }
                note("键盘、鼠标和触控板一段时间没有操作就算离开，回来后接着剩余时间继续。播放视频或演示时照常计时。")
            }
            Divider()
            section("提醒方式") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("提醒方式", selection: model.binding(\.style)) {
                        Text("角色动画").tag(ReminderStyle.animated)
                        Text("轻量提示").tag(ReminderStyle.compact)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Toggle("提醒时播放声音", isOn: model.binding(\.soundEnabled)).toggleStyle(.switch).controlSize(.small)
                }
            }
            Divider()
            section("菜单栏") {
                Toggle("显示剩余分钟", isOn: model.binding(\.showMenuBarCountdown)).toggleStyle(.switch).controlSize(.small)
                note("可在水瓶旁显示剩余分钟、暂停或待确认等状态。")
            }
            Divider()
            placement
            Divider()
            section("角色与外观") {
                VStack(alignment: .leading, spacing: 12) {
                    MascotPicker(selection: model.binding(\.look.mascot), theme: model.preferences.look.theme)
                    Picker("配色", selection: model.binding(\.look.theme)) {
                        Text("海蓝").tag(Theme.blue)
                        Text("薄荷").tag(Theme.mint)
                        Text("蜜桃").tag(Theme.peach)
                    }
                    .pickerStyle(.segmented)
                    Button("预览当前效果") { model.preview() }.disabled(!model.canPreview)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).fontWeight(.medium)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(PanelStyle.faint).fixedSize(horizontal: false, vertical: true)
    }

    private var pauseLength: Int? { Int(pauseMinutes).flatMap { $0 > 0 ? $0 : nil } }

    private func pause() {
        if let minutes = pauseLength { model.pause(minutes: minutes) }
    }

    private var pauseControls: some View {
        HStack(spacing: 8) {
            if model.schedule.isPaused {
                Button("恢复计时") { model.resume() }.buttonStyle(.borderedProminent).tint(PanelStyle.clay)
            } else {
                TextField("分钟", text: $pauseMinutes)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .accessibilityLabel("暂停时长，分钟")
                    .onSubmit(pause)
                Text("分钟")
                Button("暂停提醒", action: pause).disabled(pauseLength == nil)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    private var placement: some View {
        let chosen = model.preferences.placement
        let isConnected = model.displays.contains { $0.id == chosen.displayID }
        return VStack(alignment: .leading, spacing: 12) {
            Text("提醒位置").fontWeight(.medium)
            Picker("出场位置", selection: model.binding(\.placement.corner)) {
                Text("随机出场").tag(Corner.random)
                Text("左上角").tag(Corner.topLeft)
                Text("右上角").tag(Corner.topRight)
                Text("左下角").tag(Corner.bottomLeft)
                Text("右下角").tag(Corner.bottomRight)
            }
            Picker("显示屏幕", selection: model.binding(\.placement.screen)) {
                Text("鼠标所在屏幕").tag(ScreenChoice.mouse)
                Text("主屏幕").tag(ScreenChoice.main)
                Text("指定屏幕").tag(ScreenChoice.selected)
            }
            if chosen.screen == .selected {
                Picker("指定屏幕", selection: Binding(
                    get: { chosen.displayID ?? "" },
                    set: { id in model.update { $0.placement.displayID = id.isEmpty ? nil : id } }
                )) {
                    Text("请选择屏幕").tag("")
                    ForEach(model.displays) { Text($0.name).tag($0.id) }
                    // A display that is unplugged stays chosen.
                    if let saved = chosen.displayID, !isConnected { Text("已保存的屏幕（未连接）").tag(saved) }
                }
                if !isConnected {
                    Text("屏幕未连接时，暂时在主屏幕提醒。").font(.caption).foregroundStyle(PanelStyle.ink.opacity(0.6))
                }
            }
        }
        .pickerStyle(.menu)
    }
}

/// The characters as little portraits, one tile each.
struct MascotPicker: View {
    @Binding var selection: Mascot
    let theme: Theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Mascot.allCases, id: \.self) { mascot in
                let chosen = mascot == selection
                Button { selection = mascot } label: {
                    VStack(spacing: 2) {
                        Image(nsImage: Painter.portrait(mascot, theme: theme))
                            .interpolation(.none)
                            .frame(width: 48, height: 48)
                        Text(mascot.name).font(.system(size: 11, weight: chosen ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(chosen ? Color.white : Color.white.opacity(0.35))
                    .overlay(Rectangle().stroke(chosen ? PanelStyle.clay : PanelStyle.ink.opacity(0.1),
                                                lineWidth: chosen ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mascot.spokenName)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("角色")
    }
}
