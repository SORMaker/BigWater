import SwiftUI
import BigWaterCore
import BigWaterArt

@MainActor
final class SettingsModel: ObservableObject {
    @Published var preferences: AppPreferences
    @Published var scheduleText = ""
    @Published var stateTitle = "距离下次提醒"
    @Published var countdownOverride: String?
    @Published var remainingTime: TimeInterval = 0
    @Published var countdownDeadline: Date?
    @Published var isManuallyPaused = false
    @Published var isAwaitingAcknowledgment = false
    @Published var isVisible = false
    @Published var canPreview = true
    @Published var todayDrinkTimes: [Date] = []
    @Published var history = HydrationHistory()
    @Published var currentDate = Date()
    @Published var canRecordDrink = true
    @Published var canUndoDrink = false
    @Published var displays: [ReminderDisplay] = []
    @Published var menuBarStatus = MenuBarStatus(schedule: ReminderSchedule(), canPresentReminder: true)
    @Published var validationText: String?
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var loginStatusText: String?
    var onPreferencesChange: ((AppPreferences) -> Void)?
    var onPause: ((Int) -> Void)?
    var onDrink: (() -> Void)?
    var onUndoDrink: (() -> Void)?
    var onRemoveDrink: ((Date) -> Void)?
    var onAddDrink: ((Date) -> Bool)?
    var onEditDrink: ((Date, Date) -> Bool)?
    var onHistoryReferenceDate: (() -> Date)?
    var onSnooze: ((Int) -> Void)?
    var onResume: (() -> Void)?
    var onPreview: (() -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Void)?
    var onOpenLoginSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(preferences: AppPreferences) { self.preferences = preferences }

    var hours: Double {
        get { preferences.intervalHours }
        set { change { $0.intervalHours = newValue } }
    }

    var hoursText: String {
        hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
    }

    func change(_ edit: (inout AppPreferences) -> Void) {
        var candidate = preferences
        edit(&candidate)
        guard candidate.weekdayHours.isValid,
              candidate.weekendHours?.isValid != false else {
            validationText = "结束时间需要晚于开始时间，且各时段不能重叠。"
            return
        }
        validationText = nil
        preferences = candidate.validated()
        onPreferencesChange?(preferences)
    }

    func countdown(at now: Date) -> String {
        if let countdownOverride { return countdownOverride }
        let value = max(0, countdownDeadline?.timeIntervalSince(now) ?? remainingTime)
        let seconds = Int(ceil(value))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    }
}

struct SettingsView: View {
    static let preferredSize = NSSize(width: 356, height: 540)
    @ObservedObject var model: SettingsModel
    @ObservedObject var updater: AppUpdater
    @State private var showingMoreSettings = false
    @State private var showingHistory = false
    @State private var showingHours = false
    @State private var pauseMinutes = "30"
    @State private var draftWeekdayHours = DailyHours()
    @State private var draftWeekendHours: DailyHours?
    @State private var hoursEditMessage: String?
    private let ink = Color(nsColor: WaterPalette.ink)
    private let clay = Color(nsColor: WaterPalette.clay)
    private let cream = Color(nsColor: WaterPalette.cream)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showingHistory {
                        historyPage
                    } else if showingHours {
                        hoursPage
                    } else if showingMoreSettings {
                        moreSettings
                    } else {
                        header
                        countdownCard
                        reminderActions
                        intervalRow
                        VStack(alignment: .leading, spacing: 16) {
                            historyOptions
                            hoursOptions
                        }
                        .padding(12)
                        .background(.white.opacity(0.45))
                        .overlay(Rectangle().stroke(ink.opacity(0.08), lineWidth: 1))
                        appOptions
                    }
                }
                .font(.system(size: 13))
                // Follow the visible width when expanded sections need a scroll bar.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .id("settingsTop")
            }
            .onChange(of: model.isVisible) { visible in
                if visible { proxy.scrollTo("settingsTop", anchor: .top) }
                else { showingMoreSettings = false; showingHistory = false; showingHours = false }
            }
            .onChange(of: showingMoreSettings) { _ in
                proxy.scrollTo("settingsTop", anchor: .top)
            }
            .onChange(of: showingHistory) { _ in
                proxy.scrollTo("settingsTop", anchor: .top)
            }
            .onChange(of: showingHours) { _ in
                proxy.scrollTo("settingsTop", anchor: .top)
            }
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(cream)
        .foregroundStyle(ink)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: PixelArt.settingsBottle())
                .resizable().interpolation(.none).scaledToFit().frame(width: 30, height: 54)
                .accessibilityHidden(true)
            Text("Big Water").font(.system(size: 25, weight: .semibold, design: .serif))
            Spacer(minLength: 0)
            Button { showingMoreSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ink.opacity(0.6))
            .accessibilityLabel("更多设置")
            .help("更多设置")
        }
    }

    @ViewBuilder
    private var moreSettings: some View {
        Button { showingMoreSettings = false } label: {
            Label("返回", systemImage: "chevron.left")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Text("更多设置").font(.system(size: 20, weight: .semibold))
        VStack(alignment: .leading, spacing: 10) {
            Text("暂停提醒").fontWeight(.medium)
            pauseControls
        }
        Divider()
        reminderOptions
        Divider()
        VStack(alignment: .leading, spacing: 10) {
            Text("菜单栏").fontWeight(.medium)
            Toggle("显示剩余分钟", isOn: preferenceBinding(\.showMenuBarCountdown))
                .toggleStyle(.switch).controlSize(.small)
            Text("可在水瓶旁显示剩余分钟、暂停或待确认等状态。")
                .font(.caption).foregroundStyle(ink.opacity(0.55))
        }
        Divider()
        placementOptions
        Divider()
        appearanceOptions
    }

    private var countdownCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.stateTitle).fontWeight(.medium)
            if model.isVisible {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    countdownNumber(at: context.date)
                }
            } else {
                countdownNumber(at: Date())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78))
        .overlay(alignment: .top) { Rectangle().fill(clay.opacity(0.65)).frame(height: 3) }
        .overlay(Rectangle().stroke(ink.opacity(0.10), lineWidth: 1))
    }

    private func countdownNumber(at now: Date) -> some View {
        Text(model.countdown(at: now))
            .font(.system(size: 30, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .accessibilityLabel("\(model.stateTitle) \(model.countdown(at: now))")
    }

    private var intervalRow: some View {
        HStack {
            Text("提醒间隔（小时）").fontWeight(.medium)
            Spacer()
            HStack(spacing: 0) {
                intervalButton("−", label: "减少提醒间隔", disabled: model.hours <= ReminderSchedule.minimumHours) {
                    model.hours = max(ReminderSchedule.minimumHours, model.hours - 0.5)
                }
                Text(model.hoursText).font(.system(size: 20, weight: .medium, design: .monospaced))
                    .frame(width: 48, height: 34)
                    .accessibilityLabel("提醒间隔 \(model.hoursText) 小时")
                intervalButton("+", label: "增加提醒间隔", disabled: model.hours >= ReminderSchedule.maximumHours) {
                    model.hours = min(ReminderSchedule.maximumHours, model.hours + 0.5)
                }
            }
            .background(.white.opacity(0.5))
            .overlay(Rectangle().stroke(ink.opacity(0.13), lineWidth: 1))
        }
    }

    /// The same actions as the on-screen reminder, reachable from the
    /// keyboard, VoiceOver, or when the reminder is on another display.
    private var reminderActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("我刚喝过水") { model.onDrink?() }
                    .buttonStyle(.borderedProminent).tint(clay)
                    .disabled(!model.canRecordDrink)
                if model.canUndoDrink {
                    Button("撤销刚才") { model.onUndoDrink?() }
                        .buttonStyle(.plain)
                        .help("撤销刚才的喝水记录")
                        .accessibilityLabel("撤销刚才的喝水记录")
                }
                Spacer(minLength: 0)
            }
            if model.isAwaitingAcknowledgment {
                HStack(spacing: 8) {
                    Button("10 分钟后") { model.onSnooze?(10) }
                    Button("20 分钟后") { model.onSnooze?(20) }
                }
            }
        }
        .controlSize(.regular)
    }

    private var pauseControls: some View {
        HStack(spacing: 8) {
            if model.isManuallyPaused {
                Button("恢复计时") { model.onResume?() }
                    .buttonStyle(.borderedProminent).tint(clay)
            } else {
                TextField("分钟", text: $pauseMinutes)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .accessibilityLabel("暂停时长，分钟")
                    .onSubmit { pause() }
                Text("分钟")
                Button("暂停提醒") { pause() }
                    .disabled(pauseDuration == nil)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    private var pauseDuration: Int? {
        guard let minutes = Int(pauseMinutes), minutes > 0 else { return nil }
        return minutes
    }

    private func pause() {
        guard let minutes = pauseDuration else { return }
        model.onPause?(minutes)
    }

    private var reminderOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("提醒方式").fontWeight(.medium)
            VStack(alignment: .leading, spacing: 12) {
                Picker("提醒方式", selection: preferenceBinding(\.style)) {
                    Text("角色动画").tag(ReminderStyle.animated)
                    Text("轻量提示").tag(ReminderStyle.compact)
                }
                .pickerStyle(.segmented).labelsHidden()
                Toggle("提醒时播放声音", isOn: preferenceBinding(\.soundEnabled))
                    .toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var hoursOptions: some View {
        Button { showingHours = true } label: {
            HStack {
                Text("作息时间")
                Spacer()
                Text(hoursSummary)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(ink.opacity(0.6))
                Image(systemName: "chevron.right").font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var hoursSummary: String {
        let weekday = model.preferences.weekdayHours
        let hours = Calendar.autoupdatingCurrent.isDateInWeekend(model.currentDate)
            ? (model.preferences.weekendHours ?? weekday) : weekday
        if hours.periods.count > 2 { return "\(hours.periods.count) 个时段" }
        return hours.periods.map {
            String(format: "%02d:%02d–%02d:%02d", $0.startMinutes / 60, $0.startMinutes % 60,
                   $0.endMinutes / 60, $0.endMinutes % 60)
        }.joined(separator: " / ")
    }

    private var hoursPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { showingHours = false } label: {
                Label("返回", systemImage: "chevron.left").contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("作息时间").font(.system(size: 20, weight: .semibold))
            Text("时段之间暂停计时，下一时段接着剩余时间继续。")
                .font(.caption).foregroundStyle(ink.opacity(0.6))
            hoursRow(weekend: false)
            Toggle("周末使用单独作息", isOn: Binding(
                get: { draftWeekendHours != nil },
                set: { draftWeekendHours = $0 ? draftWeekdayHours : nil }
            ))
            .toggleStyle(.switch).controlSize(.small)
            if draftWeekendHours != nil { hoursRow(weekend: true) }
            if let error = hoursDraftError ?? hoursEditMessage {
                Text(error).font(.caption).foregroundStyle(clay)
            }
            Button("保存作息", action: saveHours)
                .buttonStyle(.borderedProminent).tint(clay)
                .disabled(hoursDraftError != nil)
        }
        .onAppear {
            draftWeekdayHours = model.preferences.weekdayHours
            draftWeekendHours = model.preferences.weekendHours
            hoursEditMessage = nil
        }
    }

    private func hoursRow(weekend: Bool) -> some View {
        let hours = weekend ? (draftWeekendHours ?? draftWeekdayHours) : draftWeekdayHours
        return VStack(alignment: .leading, spacing: 10) {
            Text(weekend ? "周末" : (draftWeekendHours == nil ? "每天" : "工作日"))
                .fontWeight(.medium)
            ForEach(hours.periods.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("时段 \(index + 1)").font(.caption).foregroundStyle(ink.opacity(0.6))
                        Spacer()
                        if hours.periods.count > 1 {
                            Button { removePeriod(weekend: weekend, index: index) } label: {
                                Image(systemName: "trash").frame(width: 24, height: 20)
                            }
                            .buttonStyle(.plain).foregroundStyle(ink.opacity(0.5))
                            .accessibilityLabel("删除\(weekend ? "周末" : "平日")时段 \(index + 1)")
                        }
                    }
                    timePicker(weekend: weekend, index: index, isEnd: false)
                    timePicker(weekend: weekend, index: index, isEnd: true)
                }
                .padding(12).background(.white.opacity(0.6))
                .overlay(Rectangle().stroke(ink.opacity(0.1), lineWidth: 1))
            }
            Button { addPeriod(weekend: weekend) } label: {
                Label("添加时段", systemImage: "plus")
            }
            .buttonStyle(.plain).foregroundStyle(clay)
        }
    }

    private func timePicker(weekend: Bool, index: Int, isEnd: Bool) -> some View {
        let time = hoursBinding(weekend: weekend, index: index, isEnd: isEnd)
        let period = (weekend ? "周末" : (draftWeekendHours == nil ? "每天" : "工作日")) + "时段 \(index + 1)"
        let label = isEnd ? "结束" : "开始"
        let hour = time.wrappedValue / 60
        let minute = time.wrappedValue % 60
        return HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            Picker("\(period)\(label)小时", selection: Binding(
                get: { time.wrappedValue / 60 },
                set: { time.wrappedValue = $0 == 24 ? 1_440 : $0 * 60 + time.wrappedValue % 60 }
            )) {
                ForEach(0..<(isEnd ? 25 : 24), id: \.self) { hour in
                    Text(String(format: "%02d", hour)).tag(hour)
                }
            }
            .frame(width: 72)
            Text(":")
            Picker("\(period)\(label)分钟", selection: Binding(
                get: { time.wrappedValue % 60 },
                set: { time.wrappedValue = (time.wrappedValue / 60) * 60 + $0 }
            )) {
                // Display an existing custom minute until the user chooses a half hour.
                if minute != 0 && minute != 30 {
                    Text(String(format: "%02d", minute)).tag(minute).disabled(true)
                }
                Text("00").tag(0)
                Text("30").tag(30)
            }
            .frame(width: 72)
            .disabled(hour == 24)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .monospacedDigit()
        .controlSize(.regular)
    }

    private var appearanceOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("角色与外观").fontWeight(.medium)
            VStack(alignment: .leading, spacing: 12) {
                Picker("角色", selection: appearanceBinding(\.character)) {
                    Text("Claude").tag(ReminderCharacter.claude)
                    Text("水滴").tag(ReminderCharacter.droplet)
                }.pickerStyle(.segmented)
                Picker("配色", selection: appearanceBinding(\.theme)) {
                    Text("海蓝").tag(ReminderTheme.blue)
                    Text("薄荷").tag(ReminderTheme.mint)
                    Text("蜜桃").tag(ReminderTheme.peach)
                }.pickerStyle(.segmented)
                Button("预览当前效果") { model.onPreview?() }
                    .disabled(!model.canPreview)
            }
        }
    }

    private var placementOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提醒位置").fontWeight(.medium)
            Picker("出场位置", selection: placementBinding(\.position)) {
                Text("随机出场").tag(ReminderPosition.random)
                Text("左上角").tag(ReminderPosition.topLeft)
                Text("右上角").tag(ReminderPosition.topRight)
                Text("左下角").tag(ReminderPosition.bottomLeft)
                Text("右下角").tag(ReminderPosition.bottomRight)
            }
            Picker("显示屏幕", selection: placementBinding(\.screen)) {
                Text("鼠标所在屏幕").tag(ReminderScreen.mouse)
                Text("主屏幕").tag(ReminderScreen.main)
                Text("指定屏幕").tag(ReminderScreen.selected)
            }
            if model.preferences.placement.screen == .selected {
                Picker("指定屏幕", selection: Binding(
                    get: { model.preferences.placement.displayID ?? "" },
                    set: { value in model.change { $0.placement.displayID = value.isEmpty ? nil : value } }
                )) {
                    Text("请选择屏幕").tag("")
                    ForEach(model.displays) { display in Text(display.name).tag(display.id) }
                    if let saved = model.preferences.placement.displayID,
                       !model.displays.contains(where: { $0.id == saved }) {
                        Text("已保存的屏幕（未连接）").tag(saved)
                    }
                }
                if model.preferences.placement.displayID == nil
                    || !model.displays.contains(where: { $0.id == model.preferences.placement.displayID }) {
                    Text("屏幕未连接时，暂时在主屏幕提醒。")
                        .font(.caption).foregroundStyle(ink.opacity(0.6))
                }
            }
        }
        .pickerStyle(.menu)
    }

    private func placementBinding<T>(_ keyPath: WritableKeyPath<ReminderPlacement, T>) -> Binding<T> {
        Binding(get: { model.preferences.placement[keyPath: keyPath] },
                set: { value in model.change { $0.placement[keyPath: keyPath] = value } })
    }

    private var historyOptions: some View {
        Button { showingHistory = true } label: {
            HStack {
                Text("喝水记录")
                Spacer()
                Text("今天 \(model.todayDrinkTimes.count) 次").foregroundStyle(ink.opacity(0.6))
                Image(systemName: "chevron.right").font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var historyPage: some View {
        Button { showingHistory = false } label: {
            Label("返回", systemImage: "chevron.left").contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Text("喝水记录").font(.system(size: 20, weight: .semibold))
        HydrationHistoryView(history: model.history, today: model.currentDate,
                             onRemove: { model.onRemoveDrink?($0) },
                             onAdd: { model.onAddDrink?($0) ?? false },
                             onEdit: { model.onEditDrink?($0, $1) ?? false },
                             referenceDate: { model.onHistoryReferenceDate?() ?? model.currentDate })
    }

    private var appOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                loginOptions
                HStack {
                    Text("自动检查更新")
                    Spacer()
                    Toggle("自动检查更新", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(!updater.isAvailable)
                }
            }
            Button { model.onQuit?() } label: {
                HStack {
                    Text("退出 Big Water")
                    Spacer()
                    Text("↗")
                }
                .foregroundStyle(clay)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            versionOptions
        }
    }

    private var loginOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("登录时启动")
                Spacer()
                Toggle("登录时启动", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.onLaunchAtLoginChange?($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch).controlSize(.small)
            }
            .help(model.loginStatusText ?? "登录时启动 Big Water")
            if model.loginNeedsApproval {
                Button("打开系统登录项") { model.onOpenLoginSettings?() }
            }
        }
    }

    private var versionOptions: some View {
        HStack {
            Text("版本 \(updater.version)").foregroundStyle(ink.opacity(0.6))
            Spacer()
            Button(updater.availableVersion.map { "更新至 \($0)…" } ?? "检查更新…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            .help(updater.statusText ?? "检查是否有新版本")
        }
        .controlSize(.regular)
    }

    private func preferenceBinding<T>(_ keyPath: WritableKeyPath<AppPreferences, T>) -> Binding<T> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { value in
            model.change { $0[keyPath: keyPath] = value }
        })
    }

    private func appearanceBinding<T>(_ keyPath: WritableKeyPath<ReminderAppearance, T>) -> Binding<T> {
        Binding(get: { model.preferences.appearance[keyPath: keyPath] }, set: { value in
            model.change { $0.appearance[keyPath: keyPath] = value }
        })
    }

    private func hoursBinding(weekend: Bool, index: Int, isEnd: Bool) -> Binding<Int> {
        Binding(get: {
            let hours = weekend ? (draftWeekendHours ?? draftWeekdayHours) : draftWeekdayHours
            guard hours.periods.indices.contains(index) else { return 0 }
            return isEnd ? hours.periods[index].endMinutes : hours.periods[index].startMinutes
        }, set: { minutes in
            var hours = weekend ? (draftWeekendHours ?? draftWeekdayHours) : draftWeekdayHours
            guard hours.periods.indices.contains(index) else { return }
            if isEnd { hours.periods[index].endMinutes = minutes }
            else { hours.periods[index].startMinutes = minutes }
            if weekend { draftWeekendHours = hours } else { draftWeekdayHours = hours }
            hoursEditMessage = nil
        })
    }

    private func sortedHours(_ hours: DailyHours) -> DailyHours {
        DailyHours(periods: hours.periods.sorted { $0.startMinutes < $1.startMinutes })
    }

    private var hoursDraftError: String? {
        guard sortedHours(draftWeekdayHours).isValid,
              draftWeekendHours.map({ sortedHours($0).isValid }) != false else {
            return "结束时间需要晚于开始时间，且各时段不能重叠。"
        }
        return nil
    }

    private func saveHours() {
        guard hoursDraftError == nil else { return }
        model.change {
            $0.weekdayHours = sortedHours(draftWeekdayHours)
            $0.weekendHours = draftWeekendHours.map(sortedHours)
        }
        if model.validationText == nil { showingHours = false }
    }

    private func removePeriod(weekend: Bool, index: Int) {
        var hours = weekend ? (draftWeekendHours ?? draftWeekdayHours) : draftWeekdayHours
        guard hours.periods.count > 1, hours.periods.indices.contains(index) else { return }
        hours.periods.remove(at: index)
        if weekend { draftWeekendHours = hours } else { draftWeekdayHours = hours }
        hoursEditMessage = nil
    }

    private func addPeriod(weekend: Bool) {
        var hours = weekend ? (draftWeekendHours ?? draftWeekdayHours) : draftWeekdayHours
        let sorted = sortedHours(hours).periods
        let endpoints = [0] + sorted.map(\.endMinutes)
        let starts = sorted.map(\.startMinutes) + [1_440]
        let gaps = zip(endpoints, starts).filter { $0.1 - $0.0 >= 30 }
        let following = gaps.last(where: { $0.0 >= (sorted.last?.endMinutes ?? 0) })
        guard let gap = following ?? gaps.first else {
            hoursEditMessage = "没有空余时间，请先缩短一个现有时段。"
            return
        }
        let start = gap.0 + (gap.1 - gap.0 >= 60 && gap.0 != 0 ? 30 : 0)
        hours.periods.append(ReminderPeriod(startMinutes: start, endMinutes: min(start + 120, gap.1)))
        if weekend { draftWeekendHours = hours } else { draftWeekdayHours = hours }
        hoursEditMessage = nil
    }

    private func intervalButton(_ symbol: String, label: String, disabled: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol).font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(disabled ? ink.opacity(0.2) : clay)
                .frame(width: 30, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).accessibilityLabel(label)
    }
}
