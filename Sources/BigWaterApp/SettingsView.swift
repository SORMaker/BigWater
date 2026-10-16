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
    @Published var validationText: String?
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var loginStatusText: String?
    var onPreferencesChange: ((AppPreferences) -> Void)?
    var onPause: ((Int) -> Void)?
    var onDrink: (() -> Void)?
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
            validationText = "结束时间需要晚于开始时间。"
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

    func timeDate(minutes: Int) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        return calendar.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: Date())
            ?? calendar.startOfDay(for: Date())
    }

    func minutes(from date: Date, isEnd: Bool) -> Int {
        let values = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let result = (values.hour ?? 0) * 60 + (values.minute ?? 0)
        return isEnd && result == 0 ? 1_440 : result
    }

    static func timeText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

struct SettingsView: View {
    static let preferredSize = NSSize(width: 356, height: 540)
    @ObservedObject var model: SettingsModel
    @ObservedObject var updater: AppUpdater
    @State private var showingMoreSettings = false
    @State private var pauseMinutes = "30"
    private let ink = Color(nsColor: WaterPalette.ink)
    private let clay = Color(nsColor: WaterPalette.clay)
    private let cream = Color(nsColor: WaterPalette.cream)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showingMoreSettings {
                    moreSettings
                } else {
                    header
                    countdownCard
                    if model.isAwaitingAcknowledgment { reminderActions }
                    VStack(alignment: .leading, spacing: 12) {
                        intervalRow
                        pauseControls
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        historyOptions
                        hoursOptions
                    }
                    Divider()
                    appOptions
                }
            }
            .font(.system(size: 12))
            // Follow the visible width: a scroll bar appears once an expanded
            // section overflows, and fixed-width content would jump sideways.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(cream)
        .foregroundStyle(ink)
        .onChange(of: model.isVisible) { visible in
            if !visible { showingMoreSettings = false }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: PixelArt.settingsBottle())
                .resizable().interpolation(.none).scaledToFit().frame(width: 30, height: 54)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Big Water").font(.system(size: 25, weight: .semibold, design: .serif))
                Text("喝口水，再继续。").foregroundStyle(ink.opacity(0.6))
            }
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
        reminderOptions
        Divider()
        appearanceOptions
    }

    private var countdownCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.stateTitle).font(.system(size: 11, weight: .medium))
            if model.isVisible {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    countdownNumber(at: context.date)
                }
            } else {
                countdownNumber(at: Date())
            }
            Text(model.scheduleText).font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.58))
        .overlay(Rectangle().stroke(ink.opacity(0.14), lineWidth: 1))
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
        HStack(spacing: 8) {
            Button("我刚喝过水") { model.onDrink?() }
                .buttonStyle(.borderedProminent).tint(clay)
            Button("10 分钟后") { model.onSnooze?(10) }
            Button("20 分钟后") { model.onSnooze?(20) }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
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
        .controlSize(.small)
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
                Text(model.preferences.style == .animated
                     ? "点角色或“我刚喝过水”都会记录一次，同一次提醒只记一次。"
                     : "喝水后确认，忙时可选择稍后再提醒。")
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hoursOptions: some View {
        DisclosureGroup("作息时间") {
            VStack(alignment: .leading, spacing: 12) {
                hoursRow(weekend: false)
                Toggle("周末使用单独作息", isOn: Binding(
                    get: { model.preferences.weekendHours != nil },
                    set: { enabled in model.change { $0.weekendHours = enabled ? $0.weekdayHours : nil } }
                ))
                .toggleStyle(.switch).controlSize(.small)
                if model.preferences.weekendHours != nil { hoursRow(weekend: true) }
                if let text = model.validationText {
                    Text(text).foregroundStyle(clay).font(.system(size: 11))
                }
                Text("跟随电脑本地时间。结束设为 00:00 表示当天 24:00。")
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
        }
    }

    private func hoursRow(weekend: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(weekend ? "周末" : (model.preferences.weekendHours == nil ? "每天" : "工作日"))
                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.6))
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始").font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
                    DatePicker("开始", selection: hoursBinding(weekend: weekend, isEnd: false), displayedComponents: .hourAndMinute)
                        .labelsHidden().accessibilityLabel(weekend ? "周末开始时间" : "工作日开始时间")
                }
                Text("至").foregroundStyle(ink.opacity(0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Text("结束").font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
                    DatePicker("结束", selection: hoursBinding(weekend: weekend, isEnd: true), displayedComponents: .hourAndMinute)
                        .labelsHidden().accessibilityLabel(weekend ? "周末结束时间" : "工作日结束时间")
                }
            }
            .datePickerStyle(.field).controlSize(.small)
        }
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
                Text("预览不计入喝水记录，也不重置计时。")
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
            }
        }
    }

    private var historyOptions: some View {
        DisclosureGroup("今日记录") {
            VStack(alignment: .leading, spacing: 8) {
                if model.todayDrinkTimes.isEmpty {
                    Text("喝水后点提醒里的按钮，这里会记录时间。")
                } else {
                    Text(model.todayDrinkTimes.map {
                        $0.formatted(date: .omitted, time: .shortened)
                    }.joined(separator: "  ·  "))
                    .monospacedDigit()
                }
                Text("只保存在这台电脑，不估算饮水量。")
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }
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
        .controlSize(.small)
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

    private func hoursBinding(weekend: Bool, isEnd: Bool) -> Binding<Date> {
        Binding(get: {
            let hours = weekend ? (model.preferences.weekendHours ?? model.preferences.weekdayHours) : model.preferences.weekdayHours
            return model.timeDate(minutes: isEnd ? hours.endMinutes : hours.startMinutes)
        }, set: { value in
            let minutes = model.minutes(from: value, isEnd: isEnd)
            model.change { preferences in
                var hours = weekend ? (preferences.weekendHours ?? preferences.weekdayHours) : preferences.weekdayHours
                if isEnd { hours.endMinutes = minutes } else { hours.startMinutes = minutes }
                if weekend { preferences.weekendHours = hours } else { preferences.weekdayHours = hours }
            }
        })
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
