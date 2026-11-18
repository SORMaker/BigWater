import SwiftUI
import BigWaterCore

/// The drink log, a month at a time, as a heat map: weekdays run down and
/// weeks run across. A day's entries can be added, retimed or removed.
struct HistoryPage: View {
    @ObservedObject var model: AppModel
    @Binding var page: PanelView.Page
    @State private var shownMonth: Date?
    @State private var selectedDay: Date?
    @State private var correction: Correction?

    /// An entry being added or retimed. Changes save as they are made, so
    /// several adjustments in a row keep editing the same entry.
    private struct Correction {
        /// The entry as saved so far, or nil for one not saved yet.
        var saved: Date?
        var draft: Date
        /// "Now" when the editor opened: the latest time it accepts.
        let openedAt: Date
        var failed = false
    }

    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private let cellSize: CGFloat = 24
    private var calendar: Calendar { model.calendar }
    private var today: Date { model.now }
    private var month: MonthGrid { MonthGrid(containing: shownMonth ?? today, calendar: calendar) }
    private var day: Date { selectedDay ?? calendar.startOfDay(for: today) }
    private var entries: [Date] { model.log.drinks(on: day, calendar: calendar).reversed() }

    var body: some View {
        PageStack {
            PageHeader(title: "喝水记录", page: $page)
            if correction != nil {
                editor.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    monthBar
                    heatMap
                    legend
                    Divider()
                    dayList
                }
            }
        }
    }

    // MARK: Month

    private var monthBar: some View {
        let earliest = MonthGrid(containing: DrinkLog.cutoff(from: today, calendar: calendar), calendar: calendar).start
        let latest = MonthGrid.latest(for: model.log, today: today, calendar: calendar)
        return HStack(spacing: 12) {
            arrow("上个月", symbol: "chevron.left", disabled: month.start <= earliest) { turn(by: -1) }
            Text(month.start.formatted(.dateTime.year().month(.wide))).fontWeight(.medium)
            arrow("下个月", symbol: "chevron.right", disabled: month.start >= latest) { turn(by: 1) }
            Spacer(minLength: 0)
            Text("\(model.log.count(in: month)) 次").foregroundStyle(PanelStyle.ink.opacity(0.6))
            Button { open(editing: nil) } label: {
                Label("补记", systemImage: "plus").font(.system(size: 12, weight: .medium)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PanelStyle.link)
            .help("补记一条喝水记录")
        }
    }

    private func arrow(_ label: String, symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).help(label).accessibilityLabel(label)
    }

    private func turn(by months: Int) {
        let next = calendar.date(byAdding: .month, value: months, to: month.start)!
        shownMonth = next
        selectedDay = calendar.isDate(next, equalTo: today, toGranularity: .month)
            ? calendar.startOfDay(for: today) : next
    }

    private var heatMap: some View {
        VStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: 5) {
                    Text(weekdays[weekday]).font(.system(size: 10)).foregroundStyle(PanelStyle.ink.opacity(0.5))
                        .frame(width: 16)
                    ForEach(month.weeks.indices, id: \.self) { week in cell(month.weeks[week][weekday]) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func cell(_ date: Date?) -> some View {
        if let date {
            let count = model.log.count(on: date, calendar: calendar)
            // Days to come are dimmed, unless a corrected clock left entries there.
            let emptyFuture = date > calendar.startOfDay(for: today) && count == 0
            let isSelected = calendar.isDate(date, inSameDayAs: day)
            let name = date.formatted(.dateTime.month().day())
            Button { selectedDay = date } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(shade(count))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? PanelStyle.link : .clear, lineWidth: 2).padding(-2))
                    .frame(width: cellSize, height: cellSize)
                    .opacity(emptyFuture ? 0.3 : 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(emptyFuture)
            .help("\(name) · \(count) 次")
            .accessibilityLabel("\(name)，喝水 \(count) 次")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Color.clear.frame(width: cellSize, height: cellSize).accessibilityHidden(true)
        }
    }

    /// Four drinks or more are the darkest.
    private func shade(_ count: Int) -> Color {
        count == 0 ? PanelStyle.ink.opacity(0.06) : PanelStyle.link.opacity([0.22, 0.43, 0.68, 1.0][min(count, 4) - 1])
    }

    private var legend: some View {
        HStack(spacing: 5) {
            Text("少")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2).fill(shade(level)).frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }
            Text("多")
            Spacer()
            Text("每格一天")
        }
        .font(.system(size: 10)).foregroundStyle(PanelStyle.faint)
    }

    // MARK: One day

    @ViewBuilder
    private var dayList: some View {
        HStack {
            Text(day.formatted(.dateTime.month().day())).fontWeight(.medium)
            Spacer()
            Text("\(entries.count) 次").foregroundStyle(PanelStyle.ink.opacity(0.6))
        }
        if entries.isEmpty {
            Text("这一天暂无记录").foregroundStyle(PanelStyle.faint)
        } else {
            VStack(spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    let time = entry.formatted(date: .omitted, time: .shortened)
                    HStack {
                        Text(time).monospacedDigit()
                        Spacer()
                        rowButton("clock", help: "修改时间", label: "修改 \(time) 的记录时间") { open(editing: entry) }
                        rowButton("trash", help: "删除这条误记", label: "删除 \(time) 的喝水记录") {
                            model.removeDrink(at: entry)
                        }
                    }
                }
            }
        }
    }

    private func rowButton(_ symbol: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PanelStyle.ink.opacity(0.5))
        .help(help)
        .accessibilityLabel(label)
    }

    // MARK: Adding and retiming

    private func allowedRange(until latest: Date) -> ClosedRange<Date> {
        DrinkLog.cutoff(from: latest, calendar: calendar)...latest
    }

    private func open(editing entry: Date?) {
        let opened = model.currentTime()
        let range = allowedRange(until: opened)
        correction = Correction(saved: entry, draft: entry.map { min(max($0, range.lowerBound), range.upperBound) } ?? opened,
                                openedAt: opened)
    }

    private var editor: some View {
        let current = correction ?? Correction(saved: nil, draft: today, openedAt: today)
        return VStack(alignment: .leading, spacing: 10) {
            Text(current.saved == nil ? "补记一条记录" : "修改记录时间").fontWeight(.medium)
            HStack {
                Text("时间")
                Spacer(minLength: 8)
                DatePicker("时间", selection: Binding(get: { current.draft }, set: { correction?.draft = $0; save() }),
                           in: allowedRange(until: current.openedAt), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .onSubmit {
                        save()
                        if correction?.failed == false { close() }
                    }
            }
            if current.failed {
                Text("请选择过去 90 天内、不晚于当前时间的有效时间。")
                    .font(.system(size: 11)).foregroundStyle(PanelStyle.clay)
            }
            HStack(spacing: 14) {
                Spacer()
                Button("返回", action: close).buttonStyle(.plain).foregroundStyle(PanelStyle.link).fontWeight(.medium)
            }
        }
        .padding(12)
        .background(.white.opacity(0.58))
        .overlay(Rectangle().stroke(PanelStyle.ink.opacity(0.14), lineWidth: 1))
        .onDisappear(perform: saveIfTouched)
    }

    private func close() {
        saveIfTouched()
        correction = nil
    }

    /// Leaving the editor saves what is in it. A new entry nobody touched
    /// is taken as a change of mind and not added.
    private func saveIfTouched() {
        if let correction, correction.saved != nil || correction.draft != correction.openedAt { save() }
    }

    private func save() {
        guard var current = correction else { return }
        guard current.saved != current.draft else {
            correction?.failed = false
            return
        }
        let done = current.saved.map { model.moveDrink(from: $0, to: current.draft) }
            ?? model.addPastDrink(at: current.draft)
        current.failed = !done
        if done {
            current.saved = current.draft
            shownMonth = MonthGrid(containing: current.draft, calendar: calendar).start
            selectedDay = calendar.startOfDay(for: current.draft)
        }
        correction = current
    }
}
