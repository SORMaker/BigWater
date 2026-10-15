import SwiftUI
import BigWaterCore
import BigWaterArt

@MainActor
final class SettingsModel: ObservableObject {
    @Published var hours: Double {
        didSet { onIntervalChange?(hours) }
    }
    @Published var nextReminderAt: Date?
    var onIntervalChange: ((Double) -> Void)?
    var onQuit: (() -> Void)?

    init(hours: Double) { self.hours = ReminderSchedule.validated(hours) }

    var hoursText: String {
        hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    private let ink = Color(nsColor: WaterPalette.ink)
    private let clay = Color(nsColor: WaterPalette.clay)
    private let cream = Color(nsColor: WaterPalette.cream)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: PixelArt.settingsBottle())
                    .interpolation(.none)
                    .frame(width: 36, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Big Water")
                        .font(.system(size: 24, weight: .semibold, design: .serif))
                        .foregroundStyle(ink)
                    Text("喝口水，再继续。")
                        .font(.system(size: 12))
                        .foregroundStyle(ink.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 22)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("提醒间隔")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink)
                    Text("每 \(model.hoursText) 小时")
                        .font(.system(size: 11))
                        .foregroundStyle(ink.opacity(0.6))
                }
                Spacer()
                HStack(spacing: 0) {
                    intervalButton("−", label: "减少提醒间隔", disabled: model.hours <= ReminderSchedule.minimumHours) {
                        model.hours = max(ReminderSchedule.minimumHours, model.hours - 0.5)
                    }
                    Text(model.hoursText)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(ink)
                        .frame(width: 51, height: 34)
                        .accessibilityLabel("提醒间隔 \(model.hoursText) 小时")
                    intervalButton("+", label: "增加提醒间隔", disabled: model.hours >= ReminderSchedule.maximumHours) {
                        model.hours = min(ReminderSchedule.maximumHours, model.hours + 0.5)
                    }
                }
                .background(.white.opacity(0.5))
                .overlay(Rectangle().stroke(ink.opacity(0.13), lineWidth: 1))
            }

            Group {
                if let next = model.nextReminderAt {
                    Text("下次提醒  \(next.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("点一下 Claude，开始下次计时")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(ink.opacity(0.5))
            .padding(.top, 14)
            .padding(.bottom, 20)

            Rectangle().fill(ink.opacity(0.12)).frame(height: 1)
            Button { model.onQuit?() } label: {
                HStack {
                    Text("退出 Big Water").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("↗").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(clay)
                .contentShape(Rectangle())
                .padding(.top, 14)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(22)
        .frame(width: 296)
        .background(cream)
    }

    private func intervalButton(_ symbol: String, label: String, disabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(disabled ? ink.opacity(0.2) : clay)
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}
