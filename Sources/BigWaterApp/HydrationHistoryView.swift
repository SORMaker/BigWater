import SwiftUI
import BigWaterCore
import BigWaterArt

/// A month of confirmations, arranged like a contribution heatmap: weekdays
/// run downwards and weeks run to the right.
struct HydrationHistoryView: View {
    let history: HydrationHistory
    let today: Date
    let onRemove: (Date) -> Void
    let onAdd: (Date) -> Bool
    let onEdit: (Date, Date) -> Bool
    let referenceDate: () -> Date
    @State private var displayedMonth: Date?
    @State private var selectedDate: Date?
    @State private var editorMode: EditorMode?
    @State private var editorReferenceDate = Date()
    @State private var draftDate = Date()
    @State private var correctionError: String?
    private let calendar = Calendar.autoupdatingCurrent
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private let ink = Color(nsColor: WaterPalette.ink)
    private let blue = Color(red: 0.05, green: 0.45, blue: 0.84)
    private let cellSize: CGFloat = 24

    private enum EditorMode {
        case add
        case edit(Date)
    }

    init(history: HydrationHistory, today: Date, onRemove: @escaping (Date) -> Void,
         onAdd: @escaping (Date) -> Bool,
         onEdit: @escaping (Date, Date) -> Bool,
         referenceDate: @escaping () -> Date = Date.init) {
        self.history = history
        self.today = today
        self.onRemove = onRemove
        self.onAdd = onAdd
        self.onEdit = onEdit
        self.referenceDate = referenceDate
    }

    private var month: HydrationMonth {
        HydrationMonth(containing: displayedMonth ?? today, calendar: calendar)
    }

    private var selectedDay: Date { selectedDate ?? calendar.startOfDay(for: today) }
    private var selectedDrinks: [Date] { history.drinks(on: selectedDay, calendar: calendar).reversed() }
    private var monthCount: Int { history.drinks.filter { $0 >= month.start && $0 < month.end }.count }
    private var latestMonth: Date {
        HydrationMonth.latestAvailableMonth(history: history, today: today, calendar: calendar)
    }
    private var earliestMonth: Date {
        let cutoff = calendar.date(byAdding: .day, value: -HydrationHistory.retentionDays, to: today)!
        return HydrationMonth(containing: cutoff, calendar: calendar).start
    }

    var body: some View {
        Group {
            if let editorMode {
                correctionEditor(for: editorMode)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                monthContent
            }
        }
    }

    private var monthContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                monthButton("上个月", symbol: "chevron.left", disabled: month.start <= earliestMonth) { moveMonth(-1) }
                Text(month.start.formatted(.dateTime.year().month(.wide)))
                    .fontWeight(.medium)
                monthButton("下个月", symbol: "chevron.right",
                            disabled: month.start >= latestMonth) { moveMonth(1) }
                Spacer(minLength: 0)
                Text("\(monthCount) 次").foregroundStyle(ink.opacity(0.6))
                Button(action: beginAdding) {
                    Label("补记", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(blue)
                .help("补记一条喝水记录")
            }

            VStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { weekday in
                    HStack(spacing: 5) {
                        Text(weekdays[weekday])
                            .font(.system(size: 10))
                            .foregroundStyle(ink.opacity(0.5))
                            .frame(width: 16)
                        ForEach(month.weeks.indices, id: \.self) { week in
                            dayCell(month.weeks[week][weekday])
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                Text("少")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(cellColor(level))
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                }
                Text("多")
                Spacer()
                Text("每格一天")
            }
            .font(.system(size: 10)).foregroundStyle(ink.opacity(0.55))

            Divider()
            HStack {
                Text(selectedDay.formatted(.dateTime.month().day())).fontWeight(.medium)
                Spacer()
                Text("\(selectedDrinks.count) 次").foregroundStyle(ink.opacity(0.6))
            }
            if selectedDrinks.isEmpty {
                Text("这一天暂无记录").foregroundStyle(ink.opacity(0.55))
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(selectedDrinks.enumerated()), id: \.offset) { _, drink in
                        HStack {
                            Text(drink.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                            Spacer()
                            Button { beginEditing(drink) } label: {
                                Image(systemName: "clock")
                                    .frame(width: 24, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ink.opacity(0.5))
                            .help("修改时间")
                            .accessibilityLabel("修改 \(drink.formatted(date: .omitted, time: .shortened)) 的记录时间")
                            Button { onRemove(drink) } label: {
                                Image(systemName: "trash").frame(width: 24, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ink.opacity(0.5))
                            .help("删除这条误记")
                            .accessibilityLabel("删除 \(drink.formatted(date: .omitted, time: .shortened)) 的喝水记录")
                        }
                    }
                }
            }

        }
    }

    private var correctionDateRange: ClosedRange<Date> {
        correctionDateRange(endingAt: editorReferenceDate)
    }

    private func correctionDateRange(endingAt reference: Date) -> ClosedRange<Date> {
        let upper = reference
        let lower = calendar.date(byAdding: .day, value: -HydrationHistory.retentionDays,
                                  to: calendar.startOfDay(for: reference)) ?? upper
        return lower...upper
    }

    private func correctionEditor(for mode: EditorMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(modeTitle(mode)).fontWeight(.medium)
            HStack {
                Text("时间")
                Spacer(minLength: 8)
                DatePicker("时间", selection: $draftDate, in: correctionDateRange,
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            if let correctionError {
                Text(correctionError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: WaterPalette.clay))
            }
            HStack(spacing: 14) {
                Spacer()
                Button("取消", action: cancelCorrection)
                    .buttonStyle(.plain)
                Button("保存") { saveCorrection(mode) }
                    .buttonStyle(.plain)
                    .foregroundStyle(blue)
                    .fontWeight(.medium)
            }
        }
        .padding(12)
        .background(.white.opacity(0.58))
        .overlay(Rectangle().stroke(ink.opacity(0.14), lineWidth: 1))
    }

    private func modeTitle(_ mode: EditorMode) -> String {
        switch mode {
        case .add: return "补记一条记录"
        case .edit: return "修改记录时间"
        }
    }

    private func beginAdding() {
        let now = referenceDate()
        editorReferenceDate = now
        editorMode = .add
        draftDate = now
        correctionError = nil
    }

    private func beginEditing(_ date: Date) {
        let now = referenceDate()
        let range = correctionDateRange(endingAt: now)
        editorReferenceDate = now
        editorMode = .edit(date)
        draftDate = min(max(date, range.lowerBound), range.upperBound)
        correctionError = nil
    }

    private func cancelCorrection() {
        editorMode = nil
        correctionError = nil
    }

    private func saveCorrection(_ mode: EditorMode) {
        let saved: Bool
        switch mode {
        case .add:
            saved = onAdd(draftDate)
        case .edit(let originalDate):
            saved = onEdit(originalDate, draftDate)
        }
        guard saved else {
            correctionError = "请选择过去 90 天内、不晚于当前时间的有效时间。"
            return
        }
        displayedMonth = HydrationMonth(containing: draftDate, calendar: calendar).start
        selectedDate = calendar.startOfDay(for: draftDate)
        cancelCorrection()
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let count = history.count(on: day, calendar: calendar)
            let future = day > calendar.startOfDay(for: today)
            let emptyFuture = future && count == 0
            let selected = calendar.isDate(day, inSameDayAs: selectedDay)
            Button { selectedDate = day } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(cellColor(count))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(selected ? blue : .clear, lineWidth: 2).padding(-2))
                    .frame(width: cellSize, height: cellSize)
                    .opacity(emptyFuture ? 0.3 : 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(emptyFuture)
            .help("\(day.formatted(.dateTime.month().day())) · \(count) 次")
            .accessibilityLabel("\(day.formatted(.dateTime.month().day()))，喝水 \(count) 次")
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Color.clear.frame(width: cellSize, height: cellSize).accessibilityHidden(true)
        }
    }

    private func cellColor(_ count: Int) -> Color {
        count == 0 ? ink.opacity(0.06) : blue.opacity([0.0, 0.22, 0.43, 0.68, 1.0][min(count, 4)])
    }

    private func moveMonth(_ offset: Int) {
        let next = calendar.date(byAdding: .month, value: offset, to: month.start)!
        displayedMonth = next
        selectedDate = calendar.isDate(next, equalTo: today, toGranularity: .month)
            ? calendar.startOfDay(for: today) : next
    }

    private func monthButton(_ label: String, symbol: String, disabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).help(label).accessibilityLabel(label)
    }
}
