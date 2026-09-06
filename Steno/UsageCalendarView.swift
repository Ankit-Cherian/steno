import Foundation
import SwiftUI

struct UsageCalendarDay: Identifiable, Sendable {
    let date: Date
    let sessionCount: Int
    let wordCount: Int
    let durationMS: Int
    let estimatedDurationSessionCount: Int
    let unavailableDurationSessionCount: Int
    let isTracked: Bool
    let isActive: Bool
    let isInCurrentStreak: Bool

    var id: Date { date }
}

struct UsageCalendarView: View {
    let days: [UsageCalendarDay]
    let theme: StenoTheme
    var calendar: Calendar = .current

    @State private var selectedDate: Date?
    @FocusState private var focusedDate: Date?

    private let minimumCellSize: CGFloat = 12
    private let maximumCellSize: CGFloat = 24
    private let cellSpacing: CGFloat = 5
    private let weekdayLabelWidth: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if weeks.isEmpty {
                emptyState
            } else {
                calendarGridContainer
                selectedDayDetail
                legend
            }
        }
        .onAppear(perform: reconcileSelection)
        .onChange(of: days.map(\.date)) { _ in
            reconcileSelection()
        }
        .onChange(of: focusedDate) { newDate in
            guard let newDate else { return }
            selectedDate = newDate
        }
        .onMoveCommand(perform: moveSelection)
    }

    private var calendarGridContainer: some View {
        GeometryReader { proxy in
            let cellSize = resolvedCellSize(for: proxy.size.width)

            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    calendarGrid(cellSize: cellSize)
                        .frame(width: calendarGridWidth(cellSize: cellSize), alignment: .leading)
                        .frame(minWidth: proxy.size.width, alignment: .leading)
                }
                .onChange(of: focusedDate) { date in
                    if let date { scroll.scrollTo(date, anchor: .center) }
                }
            }
        }
        .frame(height: calendarGridHeight(cellSize: maximumCellSize))
    }

    private func calendarGrid(cellSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: cellSpacing) {
                Color.clear
                    .frame(width: weekdayLabelWidth, height: 14)

                ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                    Text(monthLabel(for: week, at: index) ?? "")
                        .font(StenoDesign.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize()
                        .frame(width: cellSize, height: 14, alignment: .leading)
                        .accessibilityHidden(true)
                }
            }

            HStack(alignment: .top, spacing: cellSpacing) {
                VStack(spacing: cellSpacing) {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(StenoDesign.system(size: 10))
                            .foregroundStyle(theme.textDim)
                            .frame(width: weekdayLabelWidth, height: cellSize, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                }

                ForEach(weeks) { week in
                    VStack(spacing: cellSpacing) {
                        ForEach(week.cells) { cell in
                            UsageCalendarCellView(
                                cell: cell,
                                maximumDurationMS: maximumDailyDurationMS,
                                size: cellSize,
                                theme: theme,
                                calendar: calendar,
                                isSelected: selectedDate.map {
                                    calendar.isDate($0, inSameDayAs: cell.date)
                                } ?? false,
                                onSelect: {
                                    selectedDate = cell.date
                                    focusedDate = cell.date
                                }
                            )
                            .focused($focusedDate, equals: cell.date)
                            .id(cell.date)
                        }
                    }
                }
            }
        }
    }

    private var selectedDayDetail: some View {
        Group {
            if let day = selectedDay {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        selectedDayHeading(day)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 16)
                        selectedDayMetrics(day)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        selectedDayHeading(day)
                        selectedDayMetrics(day)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("Choose a day to inspect its usage.")
                    .font(StenoDesign.callout())
                    .foregroundStyle(theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(theme.isLight ? 0.52 : 0.025))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.line, lineWidth: StenoDesign.borderThin)
        )
        .accessibilityElement(children: .combine)
    }

    private func selectedDayHeading(_ day: UsageCalendarDay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year()))
                .font(StenoDesign.bodyEmphasis())
                .foregroundStyle(theme.text)
            Text(selectedDayStatus(day))
                .font(StenoDesign.caption())
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selectedDayMetrics(_ day: UsageCalendarDay) -> some View {
        HStack(spacing: 18) {
            dailyDetailMetric(label: selectedDayTimeLabel(day), value: selectedDayDuration(day))
            dailyDetailMetric(label: "Words", value: day.isTracked ? day.wordCount.formatted() : "—")
            dailyDetailMetric(label: "Sessions", value: day.isTracked ? day.sessionCount.formatted() : "—")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func dailyDetailMetric(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(StenoDesign.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.text)
            Text(label)
                .font(StenoDesign.system(size: 11))
                .foregroundStyle(theme.textDim)
        }
        .frame(minWidth: 70, alignment: .trailing)
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                intensityLegend
                Spacer(minLength: 16)
                provenanceLegend
            }

            VStack(alignment: .leading, spacing: 8) {
                intensityLegend
                provenanceLegend
            }
        }
    }

    private var intensityLegend: some View {
        HStack(spacing: 8) {
            Text("Less")
                .font(StenoDesign.system(size: 11))
                .foregroundStyle(theme.textDim)

            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(legendFill(for: level))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(level == 0 ? theme.line : theme.accent.opacity(0.18), lineWidth: StenoDesign.borderThin)
                        )
                        .frame(width: 12, height: 12)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Known dictated time intensity from less to more")

            Text("More")
                .font(StenoDesign.system(size: 11))
                .foregroundStyle(theme.textDim)
        }
    }

    private var provenanceLegend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 8) {
            legendKey(
                label: "Current streak",
                stroke: currentStreakStroke,
                strokeStyle: StrokeStyle(lineWidth: 1.5)
            )

            legendKey(
                label: "No saved coverage",
                stroke: unknownCoverageStroke,
                strokeStyle: StrokeStyle(lineWidth: StenoDesign.borderThin, dash: [2, 2])
            )

            legendKey(
                label: "Estimated time",
                stroke: estimatedDurationStroke,
                strokeStyle: StrokeStyle(lineWidth: StenoDesign.borderThin, dash: [2, 1])
            )

            legendKey(
                label: "Missing time",
                stroke: unavailableDurationStroke,
                strokeStyle: StrokeStyle(lineWidth: StenoDesign.borderThin, dash: [5, 2]),
                showsDot: true
            )
        }
    }

    private var emptyState: some View {
        HStack(spacing: 9) {
            Image(systemName: "calendar")
                .foregroundStyle(theme.textDim)
            Text("No calendar range is available yet.")
                .font(StenoDesign.callout())
                .foregroundStyle(theme.textDim)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private func legendKey(
        label: String,
        stroke: Color,
        strokeStyle: StrokeStyle,
        showsDot: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(theme.isLight ? 0.52 : 0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(stroke, style: strokeStyle)
                )
                .overlay(alignment: .bottomTrailing) {
                    if showsDot {
                        Circle()
                            .fill(stroke)
                            .frame(width: 3, height: 3)
                    }
                }
                .frame(width: 12, height: 12)

            Text(label)
                .font(StenoDesign.system(size: 11))
                .foregroundStyle(theme.textDim)
        }
        .accessibilityElement(children: .combine)
    }

    private func legendFill(for level: Int) -> Color {
        guard level > 0 else {
            return Color.white.opacity(theme.isLight ? 0.52 : 0.035)
        }

        let opacities: [Double] = theme.isLight
            ? [0.58, 0.70, 0.82, 0.94]
            : [0.52, 0.66, 0.80, 0.94]
        let color = theme.isLight ? theme.accentInk : theme.accent
        return color.opacity(opacities[level - 1])
    }

    private var maximumDailyDurationMS: Int {
        max(1, days.map(\.durationMS).max() ?? 1)
    }

    private var selectedDay: UsageCalendarDay? {
        guard let selectedDate else { return nil }
        return days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var currentStreakStroke: Color {
        theme.isLight
            ? Color(.sRGB, red: 0.43, green: 0.28, blue: 0.06, opacity: 1)
            : theme.amber
    }

    private var unknownCoverageStroke: Color {
        theme.isLight ? theme.textDim.opacity(0.95) : theme.textDim.opacity(0.82)
    }

    private var unavailableDurationStroke: Color {
        theme.isLight ? theme.accentInk.opacity(0.96) : theme.accent.opacity(0.88)
    }

    private var estimatedDurationStroke: Color {
        theme.isLight
            ? Color(.sRGB, red: 0.58, green: 0.35, blue: 0.04, opacity: 1)
            : theme.amber.opacity(0.92)
    }

    private func resolvedCellSize(for availableWidth: CGFloat) -> CGFloat {
        let totalSpacing = CGFloat(weeks.count) * cellSpacing
        let availableForCells = max(0, availableWidth - weekdayLabelWidth - totalSpacing)
        let proposed = floor(availableForCells / CGFloat(max(1, weeks.count)))
        return min(maximumCellSize, max(minimumCellSize, proposed))
    }

    private func calendarGridWidth(cellSize: CGFloat) -> CGFloat {
        weekdayLabelWidth
            + (CGFloat(weeks.count) * cellSize)
            + (CGFloat(weeks.count) * cellSpacing)
    }

    private func calendarGridHeight(cellSize: CGFloat) -> CGFloat {
        14 + 6 + (7 * cellSize) + (6 * cellSpacing)
    }

    private func reconcileSelection() {
        if let selectedDate,
           days.contains(where: { calendar.isDate($0.date, inSameDayAs: selectedDate) }) {
            return
        }

        selectedDate = days.last(where: \.isActive)?.date ?? days.last?.date
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let dayOffset: Int
        switch direction {
        case .left:
            dayOffset = -7
        case .right:
            dayOffset = 7
        case .up:
            dayOffset = -1
        case .down:
            dayOffset = 1
        @unknown default:
            return
        }

        guard
            let currentDate = focusedDate ?? selectedDate,
            let candidate = calendar.date(byAdding: .day, value: dayOffset, to: currentDate),
            let target = days.first(where: { calendar.isDate($0.date, inSameDayAs: candidate) })
        else {
            return
        }

        selectedDate = target.date
        focusedDate = target.date
    }

    private func selectedDayStatus(_ day: UsageCalendarDay) -> String {
        guard day.isTracked else {
            return "No saved usage coverage for this day."
        }
        guard day.isActive else {
            return "Saved coverage · no dictation."
        }

        var details: [String] = []
        if day.isInCurrentStreak {
            details.append("Current streak")
        }
        if day.estimatedDurationSessionCount > 0 {
            details.append("time estimated")
        }
        if day.unavailableDurationSessionCount > 0 {
            let sessionLabel = day.unavailableDurationSessionCount == 1 ? "session" : "sessions"
            details.append("\(day.unavailableDurationSessionCount) \(sessionLabel) lack time")
        }
        return details.isEmpty ? "Measured local usage." : details.joined(separator: " · ")
    }

    private func selectedDayDuration(_ day: UsageCalendarDay) -> String {
        guard day.isTracked else { return "—" }
        guard day.durationMS > 0 else {
            return day.unavailableDurationSessionCount > 0 ? "Unavailable" : "0s"
        }

        let prefix = day.estimatedDurationSessionCount > 0 ? "≈" : ""
        let totalSeconds = max(1, Int((Double(day.durationMS) / 1_000.0).rounded()))
        if totalSeconds < 60 {
            return "\(prefix)\(totalSeconds)s"
        }

        let totalMinutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if totalMinutes < 60 {
            return seconds == 0
                ? "\(prefix)\(totalMinutes)m"
                : "\(prefix)\(totalMinutes)m \(seconds)s"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0
            ? "\(prefix)\(hours)h"
            : "\(prefix)\(hours)h \(minutes)m"
    }

    private func selectedDayTimeLabel(_ day: UsageCalendarDay) -> String {
        if day.unavailableDurationSessionCount > 0 {
            return "Known time"
        }
        if day.estimatedDurationSessionCount > 0 {
            return "Est. time"
        }
        return "Time"
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return ["S", "M", "T", "W", "T", "F", "S"] }

        let firstIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[firstIndex...]) + Array(symbols[..<firstIndex])
    }

    private var weeks: [UsageCalendarWeek] {
        guard
            let firstDay = days.map(\.date).min(),
            let lastDay = days.map(\.date).max(),
            let firstWeek = calendar.dateInterval(of: .weekOfYear, for: firstDay)?.start,
            let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.start
        else {
            return []
        }

        let normalizedDays = Dictionary(
            uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.date), $0) }
        )
        let rangeStart = calendar.startOfDay(for: firstDay)
        let rangeEnd = calendar.startOfDay(for: lastDay)
        var result: [UsageCalendarWeek] = []
        var weekStart = firstWeek

        while weekStart <= lastWeek {
            let cells = (0..<7).compactMap { dayOffset -> UsageCalendarCell in
                let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) ?? weekStart
                let normalizedDate = calendar.startOfDay(for: date)
                return UsageCalendarCell(
                    date: normalizedDate,
                    usage: normalizedDays[normalizedDate],
                    isInRange: normalizedDate >= rangeStart && normalizedDate <= rangeEnd
                )
            }

            result.append(UsageCalendarWeek(id: weekStart, cells: cells))
            guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = nextWeek
        }

        return result
    }

    private func monthLabel(for week: UsageCalendarWeek, at index: Int) -> String? {
        let inRangeCells = week.cells.filter(\.isInRange)
        guard let firstInRange = inRangeCells.first else { return nil }

        if index == 0 {
            return firstInRange.date.formatted(.dateTime.month(.abbreviated))
        }

        guard let firstOfMonth = inRangeCells.first(where: { calendar.component(.day, from: $0.date) == 1 }) else {
            return nil
        }
        return firstOfMonth.date.formatted(.dateTime.month(.abbreviated))
    }
}

private struct UsageCalendarWeek: Identifiable {
    let id: Date
    let cells: [UsageCalendarCell]
}

private struct UsageCalendarCell: Identifiable {
    let date: Date
    let usage: UsageCalendarDay?
    let isInRange: Bool

    var id: Date { date }
}

private struct UsageCalendarCellView: View {
    let cell: UsageCalendarCell
    let maximumDurationMS: Int
    let size: CGFloat
    let theme: StenoTheme
    let calendar: Calendar
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .stroke(baseStroke, style: baseStrokeStyle)
                )
                .overlay(alignment: .bottomTrailing) {
                    if hasUnavailableDuration {
                        Circle()
                            .fill(unavailableDurationStroke)
                            .frame(width: max(3, size * 0.18), height: max(3, size * 0.18))
                            .padding(2)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hasEstimatedDuration {
                        Circle()
                            .fill(estimatedDurationStroke)
                            .frame(width: max(3, size * 0.18), height: max(3, size * 0.18))
                            .padding(2)
                    }
                }
                .overlay {
                    if cell.usage?.isInCurrentStreak == true {
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .stroke(currentStreakStroke, lineWidth: 1.5)
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .stroke(theme.text, lineWidth: 1.75)
                            .padding(-2)
                    }
                }
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(!cell.isInRange)
        .focusable(isSelected)
        .opacity(cell.isInRange ? 1 : 0)
        .help(Text(helpText))
        .accessibilityLabel(Text(helpText))
        .accessibilityHint(Text("Select to show this day's details."))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHidden(!cell.isInRange)
    }

    private var fill: Color {
        guard cell.isInRange, let usage = cell.usage else {
            return .clear
        }
        guard usage.isTracked else {
            return Color.white.opacity(theme.isLight ? 0.20 : 0.012)
        }
        guard usage.isActive else {
            return Color.white.opacity(theme.isLight ? 0.52 : 0.035)
        }
        if hasOnlyUnavailableDuration {
            return theme.isLight
                ? theme.accentInk.opacity(0.32)
                : theme.accent.opacity(0.34)
        }

        let opacities: [Double] = theme.isLight
            ? [0.58, 0.70, 0.82, 0.94]
            : [0.52, 0.66, 0.80, 0.94]
        let color = theme.isLight ? theme.accentInk : theme.accent
        return color.opacity(opacities[intensityLevel - 1])
    }

    private var intensityLevel: Int {
        guard let usage = cell.usage, usage.durationMS > 0 else { return 1 }
        let normalized = sqrt(Double(usage.durationMS) / Double(maximumDurationMS))
        switch normalized {
        case ..<0.35:
            return 1
        case ..<0.55:
            return 2
        case ..<0.78:
            return 3
        default:
            return 4
        }
    }

    private var baseStroke: Color {
        guard cell.isInRange, let usage = cell.usage else { return .clear }
        if !usage.isTracked {
            return unknownCoverageStroke
        }
        if hasUnavailableDuration {
            return unavailableDurationStroke
        }
        if hasEstimatedDuration {
            return estimatedDurationStroke
        }
        if usage.isActive {
            return theme.accent.opacity(0.20)
        }
        return theme.line
    }

    private var baseStrokeStyle: StrokeStyle {
        if cell.usage?.isTracked == false {
            return StrokeStyle(lineWidth: StenoDesign.borderThin, dash: [2, 2])
        }
        if hasUnavailableDuration {
            return StrokeStyle(lineWidth: StenoDesign.borderThin, dash: [5, 2])
        }
        if hasEstimatedDuration {
            return StrokeStyle(lineWidth: StenoDesign.borderThin, dash: [2, 1])
        }
        return StrokeStyle(lineWidth: StenoDesign.borderThin)
    }

    private var currentStreakStroke: Color {
        theme.isLight
            ? Color(.sRGB, red: 0.43, green: 0.28, blue: 0.06, opacity: 1)
            : theme.amber
    }

    private var unknownCoverageStroke: Color {
        theme.isLight ? theme.textDim.opacity(0.95) : theme.textDim.opacity(0.82)
    }

    private var unavailableDurationStroke: Color {
        theme.isLight ? theme.accentInk.opacity(0.96) : theme.accent.opacity(0.88)
    }

    private var estimatedDurationStroke: Color {
        theme.isLight
            ? Color(.sRGB, red: 0.58, green: 0.35, blue: 0.04, opacity: 1)
            : theme.amber.opacity(0.92)
    }

    private var helpText: String {
        let dateText = cell.date.formatted(
            .dateTime.weekday(.wide).month(.wide).day().year()
        )
        guard cell.isInRange, let usage = cell.usage else {
            return dateText
        }
        guard usage.isTracked else {
            return "\(dateText). No saved usage coverage."
        }
        guard usage.isActive else {
            return "\(dateText). No dictation."
        }

        let sessionLabel = usage.sessionCount == 1 ? "session" : "sessions"
        let wordLabel = usage.wordCount == 1 ? "word" : "words"
        let streakLabel = usage.isInCurrentStreak ? " Current streak." : ""
        return "\(dateText). \(durationDescription), \(usage.wordCount) \(wordLabel), \(usage.sessionCount) \(sessionLabel).\(streakLabel)"
    }

    private var durationDescription: String {
        guard let usage = cell.usage else { return "duration unavailable" }
        if usage.durationMS == 0, usage.unavailableDurationSessionCount > 0 {
            return "duration unavailable"
        }

        let prefix = usage.estimatedDurationSessionCount > 0 ? "about " : ""
        if usage.unavailableDurationSessionCount > 0 {
            let label = usage.unavailableDurationSessionCount == 1 ? "session" : "sessions"
            return "\(prefix)\(durationText) known time; \(usage.unavailableDurationSessionCount) \(label) lack duration"
        }
        return "\(prefix)\(durationText)"
    }

    private var hasOnlyUnavailableDuration: Bool {
        guard let usage = cell.usage else { return false }
        return usage.isActive
            && usage.durationMS == 0
            && usage.unavailableDurationSessionCount > 0
    }

    private var hasUnavailableDuration: Bool {
        guard let usage = cell.usage else { return false }
        return usage.isActive && usage.unavailableDurationSessionCount > 0
    }

    private var hasEstimatedDuration: Bool {
        guard let usage = cell.usage else { return false }
        return usage.isActive && usage.estimatedDurationSessionCount > 0
    }

    private var durationText: String {
        guard let durationMS = cell.usage?.durationMS, durationMS > 0 else { return "0 minutes" }
        let seconds = Int((Double(durationMS) / 1_000.0).rounded())
        if seconds < 60 {
            return "less than 1 minute"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }

        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hours" : "\(hours) hours \(remainder) minutes"
    }
}
