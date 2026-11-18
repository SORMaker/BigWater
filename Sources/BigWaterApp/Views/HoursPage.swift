import SwiftUI
import BigWaterCore

/// Edits the hours during which reminders may appear. Every change that
/// leaves sensible hours is saved at once; one that does not stays on the
/// page with a message until it is put right.
struct HoursPage: View {
    @ObservedObject var model: AppModel
    @Binding var page: PanelView.Page
    @State private var draft = WeekHours()
    @State private var message: String?

    private enum Day { case weekday, weekend }

    var body: some View {
        PageStack {
            PageHeader(title: "作息时间", page: $page)
            VStack(alignment: .leading, spacing: 16) {
                editor(for: .weekday)
                Toggle("周末使用单独作息", isOn: Binding(
                    get: { draft.weekend != nil },
                    set: { separate in change { $0.weekend = separate ? $0.weekday : nil } }
                ))
                .toggleStyle(.switch).controlSize(.small)
                if draft.weekend != nil { editor(for: .weekend) }
                if let problem = problem ?? message {
                    Text(problem).foregroundStyle(PanelStyle.clay)
                }
            }
        }
        .onAppear {
            draft = model.preferences.hours
            message = nil
        }
    }

    private var problem: String? {
        draft.weekday.sorted.isValid && draft.weekend?.sorted.isValid != false
            ? nil : "结束时间需要晚于开始时间，且各时段不能重叠。"
    }

    private func hours(for day: Day) -> DayHours {
        day == .weekday ? draft.weekday : (draft.weekend ?? draft.weekday)
    }

    private func name(of day: Day) -> String {
        day == .weekend ? "周末" : (draft.weekend == nil ? "每天" : "工作日")
    }

    private func change(_ edit: (inout WeekHours) -> Void) {
        edit(&draft)
        message = nil
        save()
    }

    private func change(_ day: Day, _ edit: (inout DayHours) -> Void) {
        change { week in
            var hours = day == .weekday ? week.weekday : (week.weekend ?? week.weekday)
            edit(&hours)
            if day == .weekday { week.weekday = hours } else { week.weekend = hours }
        }
    }

    private func save() {
        guard problem == nil else { return }
        let sorted = WeekHours(weekday: draft.weekday.sorted, weekend: draft.weekend?.sorted)
        guard sorted != model.preferences.hours else { return }
        model.update {
            $0.weekdayHours = sorted.weekday
            $0.weekendHours = sorted.weekend
        }
    }

    private func editor(for day: Day) -> some View {
        let periods = hours(for: day).periods
        let voiceName = day == .weekend ? "周末" : "平日"
        return VStack(alignment: .leading, spacing: 10) {
            Text(name(of: day)).fontWeight(.medium)
            ForEach(periods.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        EditableTitle(
                            text: Binding(get: { hours(for: day).periods[safe: index]?.name ?? "" },
                                          set: { name in change(day) { $0.periods[safe: index]?.name = name } }),
                            placeholder: "时段 \(index + 1)",
                            accessibilityLabel: "\(voiceName)时段 \(index + 1)名称")
                        if periods.count > 1 {
                            Button {
                                change(day) { if $0.periods.indices.contains(index) { $0.periods.remove(at: index) } }
                            } label: {
                                Image(systemName: "trash").frame(width: 24, height: 20)
                            }
                            .buttonStyle(.plain).foregroundStyle(PanelStyle.ink.opacity(0.5))
                            .accessibilityLabel("删除\(voiceName)时段 \(index + 1)")
                        }
                    }
                    timeRow("开始", day: day, index: index, \.start, lastHour: 23)
                    timeRow("结束", day: day, index: index, \.end, lastHour: 24)
                }
                .padding(12)
                .background(.white.opacity(0.6))
                .overlay(Rectangle().stroke(PanelStyle.ink.opacity(0.1), lineWidth: 1))
            }
            Button {
                if let longer = hours(for: day).addingPeriod() {
                    change(day) { $0 = longer }
                } else {
                    message = "没有空余时间，请先缩短一个现有时段。"
                }
            } label: {
                Label("添加时段", systemImage: "plus")
            }
            .buttonStyle(.plain).foregroundStyle(PanelStyle.clay)
        }
    }

    /// Hour and minute menus for one end of a period, in minutes after
    /// midnight. Only an end can be 24:00.
    private func timeRow(_ label: String, day: Day, index: Int, _ field: WritableKeyPath<Period, Int>,
                         lastHour: Int) -> some View {
        let time = Binding(get: { hours(for: day).periods[safe: index]?[keyPath: field] ?? 0 },
                           set: { minutes in change(day) { $0.periods[safe: index]?[keyPath: field] = minutes } })
        let minute = time.wrappedValue % 60
        let title = "\(name(of: day))时段 \(index + 1)\(label)"
        return HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            Picker("\(title)小时", selection: Binding(
                get: { time.wrappedValue / 60 },
                set: { time.wrappedValue = $0 == 24 ? 1_440 : $0 * 60 + time.wrappedValue % 60 }
            )) {
                ForEach(0...lastHour, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .frame(width: 72)
            Text(":")
            Picker("\(title)分钟", selection: Binding(
                get: { time.wrappedValue % 60 },
                set: { time.wrappedValue = time.wrappedValue / 60 * 60 + $0 }
            )) {
                // A minute saved outside the five-minute steps stays visible
                // until another one is chosen.
                if minute % 5 != 0 { Text(String(format: "%02d", minute)).tag(minute).disabled(true) }
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) {
                    Text(String(format: "%02d", $0)).tag($0)
                }
            }
            .frame(width: 72)
            .disabled(time.wrappedValue / 60 == 24)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .monospacedDigit()
        .controlSize(.regular)
    }
}

/// A title that turns into a text field when clicked, and back on Return or
/// when it loses focus.
private struct EditableTitle: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .accessibilityLabel(accessibilityLabel)
                    .onAppear { DispatchQueue.main.async { isFocused = true } }
                    .onSubmit {
                        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        isEditing = false
                        isFocused = false
                    }
                    .onChange(of: isFocused) { focused in
                        if !focused { isEditing = false }
                    }
            } else {
                Button { isEditing = true } label: {
                    Text(text.isEmpty ? placeholder : text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("修改\(accessibilityLabel)：\(text.isEmpty ? placeholder : text)")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .frame(minHeight: 22)
    }
}

private extension Array {
    /// Reads and writes an element only where it exists.
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            if let newValue, indices.contains(index) { self[index] = newValue }
        }
    }
}
