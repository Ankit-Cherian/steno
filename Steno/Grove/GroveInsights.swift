import os
import SwiftUI
import StenoKit

// MARK: - What the page says

/// The numbers behind Insights' opening sentence and the line under it, worked out from the
/// usage ledger. The ledger holds daily totals and never dictation text.
struct GroveInsightsSummary: Equatable {
    /// Time saved is measured against typing at this speed.
    static let typingWordsPerMinute = 40

    enum Scope: Equatable {
        case thisMonth
        /// Nothing was dictated this month yet, so the sentence counts everything.
        case allTime
    }

    struct BusiestDay: Equatable {
        var date: Date
        var words: Int
    }

    var scope: Scope
    var words: Int
    /// Typing time minus speaking time, when both are known and the difference is a minute or more.
    var timeSavedMS: Int?
    var paceWordsPerMinute: Int?
    var paceIsEstimate: Bool
    var streakDays: Int
    var busiestDay: BusiestDay?
    var rangeLabel: String

    /// A run of the sentence and whether the figure in it is set apart.
    struct Piece: Equatable {
        var text: String
        var isFigure = false
    }

    static func make(snapshot: UsageAnalyticsSnapshot, now: Date = Date(), calendar: Calendar = .current) -> GroveInsightsSummary {
        let day = calendar.startOfDay(for: now)
        if let cached = memo.withLock({ $0 }), cached.snapshot == snapshot, cached.day == day, cached.calendar == calendar {
            return cached.summary
        }
        let summary = compute(snapshot: snapshot, now: now, calendar: calendar)
        memo.withLock { $0 = (snapshot, day, calendar, summary) }
        return summary
    }

    private static let memo = OSAllocatedUnfairLock<(snapshot: UsageAnalyticsSnapshot, day: Date, calendar: Calendar, summary: GroveInsightsSummary)?>(initialState: nil)

    private static func compute(snapshot: UsageAnalyticsSnapshot, now: Date, calendar: Calendar) -> GroveInsightsSummary {
        let monthDays = snapshot.dailyUsage.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
        let monthWords = monthDays.reduce(0) { $0 + $1.wordCount }
        let pace = snapshot.averageWordsPerMinute > 0 ? Int(snapshot.averageWordsPerMinute.rounded()) : nil

        let scope: Scope = monthWords > 0 ? .thisMonth : .allTime
        let words = scope == .thisMonth ? monthWords : snapshot.totalWords
        let measured = scope == .thisMonth ? monthDays.reduce(0) { $0 + $1.durationMS } : snapshot.totalDurationMS
        let hasUnmeasured = scope == .thisMonth
            ? monthDays.contains { $0.unavailableDurationSessionCount > 0 }
            : snapshot.unavailableDurationSessionCount > 0
        // A session without a saved time is spoken at the usual pace rather than counted as no time.
        let speakingMS: Int? = !hasUnmeasured && measured > 0
            ? measured
            : pace.map { words * 60_000 / max(1, $0) }
        let typingMS = words * 60_000 / typingWordsPerMinute
        let saved = speakingMS.map { typingMS - $0 }.flatMap { $0 >= 60_000 ? $0 : nil }

        let busiest = snapshot.dailyUsage.filter { $0.wordCount > 0 }
            .max { ($0.wordCount, $0.date) < ($1.wordCount, $1.date) }
            .map { BusiestDay(date: $0.date, words: $0.wordCount) }

        return GroveInsightsSummary(
            scope: scope, words: words, timeSavedMS: saved, paceWordsPerMinute: pace,
            paceIsEstimate: snapshot.estimatedDurationSessionCount > 0,
            streakDays: snapshot.currentStreak, busiestDay: busiest,
            rangeLabel: rangeLabel(scope: scope, now: now, calendar: calendar))
    }

    /// "October 1 to 7", or "October 1" on the first, or "All time".
    static func rangeLabel(scope: Scope, now: Date, calendar: Calendar = .current) -> String {
        guard scope == .thisMonth else { return "All time" }
        let day = calendar.component(.day, from: now)
        let month = now.formatted(.dateTime.month(.wide))
        return day == 1 ? "\(month) 1" : "\(month) 1 to \(day)"
    }

    /// "12,480 words so far this month, about 3 hours 46 minutes of typing saved."
    var opening: [Piece] {
        var pieces = [Piece(text: Self.wordsText(words), isFigure: true),
                      Piece(text: scope == .thisMonth ? " so far this month" : " in all")]
        if let timeSavedMS {
            pieces += [Piece(text: ", about "), Piece(text: Self.spokenDuration(timeSavedMS), isFigure: true),
                       Piece(text: " of typing saved.")]
        } else {
            pieces.append(Piece(text: "."))
        }
        return pieces
    }

    /// "You speak at 146 words a minute, and you’ve dictated 18 days in a row. All of it was
    /// heard and written on this Mac." Each clause appears only when the ledger supports it.
    var followUp: [Piece] {
        var pieces: [Piece] = []
        let pace = paceWordsPerMinute.map {
            [Piece(text: paceIsEstimate ? "speak at about " : "speak at "),
             Piece(text: "\($0.formatted()) words a minute", isFigure: true)]
        }
        let streak = streakDays >= 2
            ? [Piece(text: "dictated "), Piece(text: "\(streakDays.formatted()) days in a row", isFigure: true)]
            : nil
        switch (pace, streak) {
        case let (pace?, streak?):
            pieces = [Piece(text: "You ")] + pace + [Piece(text: ", and you’ve ")] + streak + [Piece(text: ". ")]
        case let (pace?, nil):
            pieces = [Piece(text: "You ")] + pace + [Piece(text: ". ")]
        case let (nil, streak?):
            pieces = [Piece(text: "You’ve ")] + streak + [Piece(text: ". ")]
        case (nil, nil):
            break
        }
        pieces.append(Piece(text: "All of it was heard and written on this Mac."))
        return pieces
    }

    static func plain(_ pieces: [Piece]) -> String { pieces.map(\.text).joined() }

    static func wordsText(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "word" : "words")" }

    /// "3 hours 46 minutes", "2 hours", "1 hour 5 minutes", "45 minutes".
    static func spokenDuration(_ milliseconds: Int) -> String {
        let minutes = max(1, Int((Double(milliseconds) / 60_000).rounded()))
        let hours = minutes / 60, rest = minutes % 60
        func unit(_ value: Int, _ noun: String) -> String { "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")" }
        if hours == 0 { return unit(rest, "minute") }
        return rest == 0 ? unit(hours, "hour") : "\(unit(hours, "hour")) \(unit(rest, "minute"))"
    }

    /// The pieces as one run of text, the figures semibold ink and the rest in `rest`.
    @MainActor
    static func text(_ pieces: [Piece], figure: Color, rest: Color, figureWeight: Font.Weight) -> Text {
        pieces.reduce(Text("")) { text, piece in
            text + (piece.isFigure
                ? Text(piece.text).fontWeight(figureWeight).foregroundColor(figure)
                : Text(piece.text).foregroundColor(rest))
        }
    }
}

// MARK: - Calendar

/// Every day of the window as a small rounded cell: the accent in four steps for more words, a
/// neutral cell for a day without dictation, today outlined in ink. Arrows move a day (up and
/// down) or a week (left and right).
struct GroveDayGrid: View {
    let days: [UsageCalendarDay]
    var calendar: Calendar = .current
    var currentStreak = 0
    /// What shows beside the calendar, so it can move under it when the room is narrow.
    var facts: [GroveInsightFact] = []
    @Environment(\.groveTheme) private var theme
    @Environment(\.sectionPlaces) private var places
    @State private var selectedDate: Date?
    /// The selection draws a ring only after the person has chosen a day or used the keys.
    @State private var hasChosen = false
    @State private var width: CGFloat = 640
    @StateObject private var keys = GroveKeyFocus()

    /// The largest and smallest cells: the calendar grows to fill the panel, and only shrinks
    /// below the comfortable size in a narrow window.
    static let maximumCell: CGFloat = 28
    static let minimumCell: CGFloat = 8
    /// Beside the facts only while cells stay at least this large; below it the facts go under.
    static let sideBySideCell: CGFloat = 16
    static let gap: CGFloat = 4
    private let labelWidth: CGFloat = 12
    private let labelGap: CGFloat = 6
    private let factsWidth: CGFloat = 190
    private let factsSpacing: CGFloat = 32

    var body: some View {
        let weeks = UsageCalendar(days: days, calendar: calendar).weeks
        VStack(alignment: .leading, spacing: 20) {
            if weeks.isEmpty {
                Text("No calendar range is available yet.")
                    .groveFont(13)
                    .foregroundStyle(theme.ink3Color)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                let besideFacts = width - factsSpacing - factsWidth
                let sideBySide = !facts.isEmpty && cellSize(columns: weeks.count, in: besideFacts) >= Self.sideBySideCell
                let size = cellSize(columns: weeks.count, in: sideBySide ? besideFacts : width)
                if sideBySide {
                    HStack(alignment: .top, spacing: factsSpacing) {
                        calendarBlock(weeks, size: size)
                        factsColumn.padding(.top, 18)
                    }
                } else {
                    calendarBlock(weeks, size: size)
                    if !facts.isEmpty {
                        HStack(alignment: .top, spacing: factsSpacing) { factsContent }
                    }
                }
            }
        }
        // The width offered, not the width drawn: cells sized for a wider panel would otherwise
        // hold this frame open after the panel narrows, and the calendar would never shrink back.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: GroveGridWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(GroveGridWidthKey.self) { value in
            if value > 100, abs(value - width) > 0.5 { width = value }
        }
        .onAppear {
            restorePlace()
            reconcile()
        }
        .onChange(of: days.map(\.date)) { _ in reconcile() }
        .onChange(of: selectedDate) { date in if hasChosen { places?.insightsDay = date } }
        .onChange(of: hasChosen) { chosen in if chosen { places?.insightsDay = selectedDate } }
        .background(GroveKeyHandling(focus: keys, onMove: moveSelection))
    }

    // MARK: Layout

    private func fullWidth(columns: Int, cell: CGFloat) -> CGFloat {
        labelWidth + labelGap + CGFloat(columns) * cell + CGFloat(max(0, columns - 1)) * Self.gap
    }

    /// The cell that lets the weeks fill `available`, within the largest and smallest cells.
    private func cellSize(columns: Int, in available: CGFloat) -> CGFloat {
        let room = available - labelWidth - labelGap
        let fit = (room - Self.gap * CGFloat(max(0, columns - 1))) / CGFloat(max(1, columns))
        return max(Self.minimumCell, min(Self.maximumCell, fit.rounded(.down)))
    }

    private var factsColumn: some View {
        VStack(alignment: .leading, spacing: 14) { factsContent }
            .frame(width: factsWidth, alignment: .leading)
    }

    @ViewBuilder
    private var factsContent: some View {
        ForEach(facts) { fact in
            // Dates and counts wrap rather than truncate.
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.title).groveFont(11).foregroundStyle(theme.ink3Color)
                Text(fact.value).groveFont(13, .medium).foregroundStyle(theme.inkColor)
                Text(fact.detail).groveFont(12).foregroundStyle(theme.ink3Color)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }

    private func calendarBlock(_ weeks: [UsageCalendarWeek], size: CGFloat) -> some View {
        let maximum = max(1, days.map(\.wordCount).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            monthLabels(weeks, size: size)
                .padding(.leading, labelWidth + labelGap)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: labelGap) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(weekdayLabel(row: row))
                            .groveFont(10)
                            .foregroundStyle(theme.ink3Color)
                            .frame(width: labelWidth, height: size, alignment: .leading)
                    }
                }
                .accessibilityHidden(true)
                GroveDayGridSurface(
                    weeks: weeks, size: size, gap: Self.gap, maximumWords: maximum, calendar: calendar,
                    selectedDate: hasChosen ? selectedDate : nil, colors: surfaceColors(), label: Self.label(for:),
                    spokenLabel: Self.spokenLabel(for:),
                    onSelect: { selectedDate = $0; hasChosen = true; keys.request() })
            }
            legendRow(width: fullWidth(columns: weeks.count, cell: size))
            // Its own row, so a long day wraps instead of being cut off beside the legend. Before
            // a day is chosen it says that one can be: nothing else on the calendar does.
            Group {
                if hasChosen {
                    selectedLine
                } else {
                    Text("Choose a day to see how much you dictated.")
                        .groveFont(12)
                        .foregroundStyle(theme.ink3Color)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, labelWidth + labelGap)
            .padding(.top, 4)
            .frame(width: fullWidth(columns: weeks.count, cell: size), alignment: .leading)
        }
    }

    /// A month's name above the first week that holds its first day.
    private func monthLabels(_ weeks: [UsageCalendarWeek], size: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                if let name = Self.monthLabel(for: week, at: index, calendar: calendar) {
                    Text(name)
                        .groveFont(11)
                        .foregroundStyle(theme.ink3Color)
                        .fixedSize()
                        .offset(x: CGFloat(index) * (size + Self.gap))
                }
            }
        }
        .frame(height: 13, alignment: .topLeading)
    }

    /// Less and More around the five fills, and the chosen day once there is one.
    private func legendRow(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("Less").groveFont(10).foregroundStyle(theme.ink3Color)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Self.fill(level: level, theme: theme)).frame(width: 10, height: 10)
            }
            Text("More").groveFont(10).foregroundStyle(theme.ink3Color)
        }
        .padding(.leading, labelWidth + labelGap)
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var selectedLine: some View {
        if let day = selectedDay {
            (Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())).fontWeight(.medium).foregroundColor(theme.inkColor)
                + Text("  " + UsageCalendar.dayDetail(day, streak: currentStreak)).foregroundColor(theme.ink2Color))
                .groveFont(12)
                .accessibilityElement(children: .combine)
        }
    }

    private var selectedDay: UsageCalendarDay? {
        guard let selectedDate else { return nil }
        return days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    /// Comes back to the day chosen when Insights was last left, while it is still in the window.
    private func restorePlace() {
        guard let day = places?.insightsDay, days.contains(where: { calendar.isDate($0.date, inSameDayAs: day) }) else { return }
        selectedDate = day
        hasChosen = true
    }

    private func reconcile() {
        if let selectedDate, days.contains(where: { calendar.isDate($0.date, inSameDayAs: selectedDate) }) { return }
        selectedDate = days.last(where: \.isActive)?.date ?? days.last?.date
    }

    private func moveSelection(_ direction: GroveMove) {
        let offset: Int
        switch direction {
        case .left: offset = -7
        case .right: offset = 7
        case .up: offset = -1
        case .down: offset = 1
        }
        guard let current = selectedDate,
              let candidate = calendar.date(byAdding: .day, value: offset, to: current),
              let target = days.first(where: { calendar.isDate($0.date, inSameDayAs: candidate) }) else { return }
        selectedDate = target.date
        hasChosen = true
    }

    // MARK: Labels

    /// M, W and F beside the Monday, Wednesday and Friday rows, whichever day the week starts on.
    private func weekdayLabel(row: Int) -> String {
        let weekday = (calendar.firstWeekday - 1 + row) % 7 + 1 // 1 is Sunday
        guard [2, 4, 6].contains(weekday) else { return "" }
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
    }

    /// The first week names its month, and every later week that holds a month's first day names
    /// that month. A first week that holds a 1st names the new month: the days before it are a
    /// sliver of the old one, and the new month would otherwise go unnamed.
    static func monthLabel(for week: UsageCalendarWeek, at index: Int, calendar: Calendar) -> String? {
        let inRange = week.cells.filter(\.isInRange)
        guard let first = inRange.first else { return nil }
        let firstOfMonth = inRange.first { calendar.component(.day, from: $0.date) == 1 }
        if index == 0 { return (firstOfMonth ?? first).date.formatted(.dateTime.month(.abbreviated)) }
        return firstOfMonth?.date.formatted(.dateTime.month(.abbreviated))
    }

    // MARK: Levels

    /// 0 for no words, then 1 to 4 by a quarter of the busiest day each.
    static func level(words: Int, maximum: Int) -> Int {
        guard words > 0 else { return 0 }
        let share = Double(words) / Double(max(1, maximum))
        return min(4, max(1, Int((share * 4).rounded(.up))))
    }

    /// Solid greens from a pale empty day to the forest. The forest at partial opacity turned
    /// sage on white and read as grey.
    static let lightRamp: [UInt32] = [0xEEF5F0, 0xC4E6CF, 0x8FD0A8, 0x4FA374, 0x2A6B49]
    static let darkRamp: [UInt32] = [0x232826, 0x1F4A33, 0x2E6E4A, 0x4C9E6F, 0x7FD3A0]
    /// The ramp for a theme's scheme.
    static func ramp(for theme: GroveTheme) -> [UInt32] {
        theme.isDark ? darkRamp : lightRamp
    }

    static func fill(level: Int, theme: GroveTheme) -> Color { fillQuill(level: level, theme: theme).color }

    static func fillQuill(level: Int, theme: GroveTheme) -> QuillColor {
        let level = min(max(level, 0), 4)
        if level == 0, theme.increaseContrast {
            return QuillColor(hex: theme.isDark ? 0x343B37 : 0xD5E6DB)
        }
        return QuillColor(hex: ramp(for: theme)[level])
    }

    /// A day before Steno kept counts: paler than an empty day, so the months still line up.
    static func uncountedQuill(theme: GroveTheme) -> QuillColor {
        QuillColor(hex: theme.isDark ? 0x1F2221 : 0xF6F9F7)
    }

    /// What a day says to VoiceOver and in its tooltip: the date, then what was dictated.
    static func label(for cell: UsageCalendarCell) -> String {
        let date = cell.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        guard cell.isInRange, let usage = cell.usage else { return date }
        return "\(date). \(UsageCalendar.dayDetail(usage))"
    }

    /// The label as VoiceOver should say it: "159 words, about 1 minute, 51 seconds, 6 dictations",
    /// not "≈1 min 51 s" between middle dots.
    static func spokenLabel(for cell: UsageCalendarCell) -> String {
        let date = cell.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        guard cell.isInRange, let usage = cell.usage else { return date }
        return "\(date). \(UsageCalendar.dayDetail(usage, spoken: true))"
    }

    private func surfaceColors() -> GroveDayGridSurface.Colors {
        GroveDayGridSurface.Colors(
            empty: Self.fillQuill(level: 0, theme: theme).nsColor,
            levels: (1...4).map { Self.fillQuill(level: $0, theme: theme).nsColor },
            uncounted: Self.uncountedQuill(theme: theme).nsColor,
            selected: (keys.isFocused ? theme.accent : theme.ink).nsColor)
    }
}

/// A named fact beside the calendar.
struct GroveInsightFact: Identifiable, Equatable {
    var title: String
    var value: String
    var detail: String
    var id: String { title }
}

private struct GroveGridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Apps

/// Where your words went: the top apps by words as a ranked list. Each row is an icon and a
/// name, with the words and their share of all words at the right edge. No bars: a bar under
/// every name read as a scroll bar.
struct GroveAppWordRows: View {
    let apps: [AppUsageDisplay]
    var limit = 4
    @Environment(\.groveTheme) private var theme

    /// Apps with words, most words first.
    static func ranked(_ apps: [AppUsageDisplay]) -> [AppUsageDisplay] {
        apps.filter { $0.wordCount > 0 }.sorted { ($0.wordCount, $1.appBundleID) > ($1.wordCount, $0.appBundleID) }
    }

    /// The app's share of every counted word, as a whole percent; "<1%" for a sliver, and ">99%"
    /// for nearly all, so 100% only ever means every word.
    static func share(_ words: Int, of total: Int) -> String {
        guard total > 0, words > 0 else { return "0%" }
        let percent = Double(words) / Double(total) * 100
        if percent < 1 { return "<1%" }
        if words < total, percent > 99 { return ">99%" }
        return "\(Int(percent.rounded()))%"
    }

    var body: some View {
        let ranked = Self.ranked(apps)
        let total = ranked.reduce(0) { $0 + $1.wordCount }
        VStack(spacing: 0) {
            if ranked.isEmpty {
                Text("No words counted yet.")
                    .groveFont(13)
                    .foregroundStyle(theme.ink3Color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            ForEach(ranked.prefix(limit)) { app in
                let name = AppNames.name(for: app.appBundleID)
                let share = Self.share(app.wordCount, of: total)
                HStack(spacing: 10) {
                    GroveAppIcon(bundleID: app.appBundleID, size: 20)
                    Text(name).groveFont(13).foregroundStyle(theme.inkColor).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(app.wordCount.formatted()).groveFont(13).monospacedDigit().foregroundStyle(theme.ink2Color)
                    Text(share).groveFont(13).monospacedDigit().foregroundStyle(theme.ink3Color)
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .frame(minHeight: 34)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name), \(GroveInsightsSummary.wordsText(app.wordCount)), \(share)")
            }
        }
    }
}

// MARK: - States

/// Empty, loading and error: a sentence at the top of the page, in the same column.
struct GroveInsightsState: View {
    enum Kind { case empty, loading, error }
    let kind: Kind
    var onRetry: (() -> Void)?
    @Environment(\.groveTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 22))
                .foregroundStyle(kind == .loading ? theme.ink3Color : theme.inkColor)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .groveFont(13)
                .lineSpacing(2)
                .foregroundStyle(theme.ink2Color)
                .fixedSize(horizontal: false, vertical: true)
            if kind == .error, let onRetry {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.groveText)
                    .padding(.leading, -8)
                    .padding(.top, 4)
            }
        }
        .grovePanelInset()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.panelBackground())
        .groveColumn(theme, fillsHeight: true)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch kind {
        case .empty: "No usage yet"
        case .loading: "Loading usage…"
        case .error: "Insights couldn’t load"
        }
    }

    private var message: String {
        switch kind {
        case .empty: "Totals and the calendar fill in after your first dictation."
        case .loading: "Reading the usage file on this Mac."
        case .error: "The usage file couldn’t be read. History isn’t affected."
        }
    }
}

// MARK: - Page

/// Insights in the Grove window: one sentence on the month, a line under it, every day of six
/// months, and where the words went. Reads only the metadata ledger, never dictation text.
struct GroveInsightsView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.groveTheme) private var theme

    private let snapshotOverride: UsageAnalyticsSnapshot?
    private let loadingOverride: Bool
    private let errorOverride: String?
    private let retryOverride: (() -> Void)?
    private let usesControllerData: Bool
    private let now: Date

    init() {
        snapshotOverride = nil
        loadingOverride = false
        errorOverride = nil
        retryOverride = nil
        usesControllerData = true
        now = Date()
    }

    init(snapshot: UsageAnalyticsSnapshot?, isLoading: Bool, loadError: String?, onRetry: (() -> Void)?, now: Date = Date()) {
        snapshotOverride = snapshot
        loadingOverride = isLoading
        errorOverride = loadError
        retryOverride = onRetry
        usesControllerData = false
        self.now = now
    }

    var body: some View {
        let snapshot = resolvedSnapshot
        Group {
            if resolvedIsLoading && snapshot == nil {
                GroveInsightsState(kind: .loading)
            } else if resolvedLoadError != nil && snapshot == nil {
                GroveInsightsState(kind: .error, onRetry: retryAction)
            } else if let snapshot, snapshot.totalSessions > 0 {
                loaded(snapshot)
            } else {
                GroveInsightsState(kind: .empty)
            }
        }
        .task {
            guard usesControllerData else { return }
            await controller.refreshUsageAnalytics()
        }
    }

    private func loaded(_ snapshot: UsageAnalyticsSnapshot) -> some View {
        let summary = GroveInsightsSummary.make(snapshot: snapshot, now: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(warnings, id: \.self) { warning in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.cautionColor)
                            .accessibilityHidden(true)
                        Text(warning)
                            .groveFont(12.5)
                            .foregroundStyle(theme.ink2Color)
                            .textSelection(.enabled)
                    }
                    .padding(.bottom, 14)
                }
                Text(summary.rangeLabel)
                    .groveFont(12, .semibold)
                    .foregroundStyle(theme.ink3Color)
                    .padding(.bottom, 10)
                    .accessibilityAddTraits(.isHeader)
                GroveInsightsSummary.text(summary.opening, figure: theme.inkColor, rest: theme.ink2Color, figureWeight: .semibold)
                    .groveFont(22)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                    .help("Time saved is typing at \(GroveInsightsSummary.typingWordsPerMinute) words a minute, minus the time you spent speaking.")
                    .accessibilityLabel(GroveInsightsSummary.plain(summary.opening))
                GroveInsightsSummary.text(summary.followUp, figure: theme.inkColor, rest: theme.ink2Color, figureWeight: .medium)
                    .groveFont(13)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 40)
                    .accessibilityLabel(GroveInsightsSummary.plain(summary.followUp))
                sectionLabel("The last six months")
                GroveDayGrid(days: InsightsData.calendarDays(snapshot), currentStreak: snapshot.currentStreak,
                             facts: facts(summary))
                    .padding(.bottom, 40)
                sectionLabel("Where your words went", suffix: " · all time")
                GroveAppWordRows(apps: InsightsData.appUsage(snapshot))
            }
            .grovePanelInset()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(theme.panelBackground())
            .groveColumn(theme)
        }
        .background(theme.pageGroundColor)
    }

    private func sectionLabel(_ title: String, suffix: String = "") -> some View {
        (Text(title).fontWeight(.semibold) + Text(suffix))
            .groveFont(12)
            .foregroundStyle(theme.ink3Color)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }

    /// The busiest day of the window. When the ledger holds only daily totals there is no hour
    /// of the day to say, so no usual hours are shown.
    private func facts(_ summary: GroveInsightsSummary) -> [GroveInsightFact] {
        guard let busiest = summary.busiestDay else { return [] }
        return [GroveInsightFact(
            title: "Busiest day", value: busiest.date.formatted(.dateTime.weekday(.wide).month(.wide).day()),
            detail: GroveInsightsSummary.wordsText(busiest.words))]
    }

    // MARK: Data

    private var warnings: [String] {
        var result: [String] = []
        if let error = resolvedLoadError { result.append(error) }
        if usesControllerData, !controller.usageAnalyticsWriteWarning.isEmpty { result.append(controller.usageAnalyticsWriteWarning) }
        return result
    }

    private var resolvedSnapshot: UsageAnalyticsSnapshot? {
        guard usesControllerData else { return snapshotOverride }
        return controller.usageAnalyticsSnapshot.dailyUsage.isEmpty ? nil : controller.usageAnalyticsSnapshot
    }

    private var resolvedIsLoading: Bool {
        usesControllerData ? controller.isLoadingUsageAnalytics : loadingOverride
    }

    private var resolvedLoadError: String? {
        if usesControllerData { return controller.usageAnalyticsError.isEmpty ? nil : controller.usageAnalyticsError }
        return errorOverride
    }

    private var retryAction: (() -> Void)? {
        if usesControllerData { return { Task { await controller.refreshUsageAnalytics() } } }
        return retryOverride
    }
}
