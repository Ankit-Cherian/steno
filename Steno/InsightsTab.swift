import SwiftUI
import StenoKit

struct InsightsTab: View {
    @EnvironmentObject private var controller: DictationController

    private let snapshotOverride: UsageAnalyticsSnapshot?
    private let loadingOverride: Bool
    private let errorOverride: String?
    private let retryOverride: (() -> Void)?
    private let usesControllerData: Bool

    init() {
        snapshotOverride = nil
        loadingOverride = false
        errorOverride = nil
        retryOverride = nil
        usesControllerData = true
    }

    init(
        snapshot: UsageAnalyticsSnapshot?,
        isLoading: Bool,
        loadError: String?,
        onRetry: (() -> Void)?
    ) {
        snapshotOverride = snapshot
        loadingOverride = isLoading
        errorOverride = loadError
        retryOverride = onRetry
        usesControllerData = false
    }

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)
        let snapshot = resolvedSnapshot
        let isLoading = resolvedIsLoading
        let loadError = resolvedLoadError
        let writeWarning = resolvedWriteWarning

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(snapshot: snapshot, theme: theme)

                if isLoading && snapshot == nil {
                    loadingState(theme: theme)
                } else if let loadError, snapshot == nil {
                    errorState(message: loadError, theme: theme)
                } else if let snapshot {
                    if let loadError {
                        warningState(message: loadError, theme: theme)
                    }
                    if let writeWarning {
                        warningState(message: writeWarning, theme: theme)
                    }
                    loadedContent(snapshot: snapshot, theme: theme)
                } else {
                    unavailableState(theme: theme)
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        .task {
            guard usesControllerData else { return }
            await controller.refreshUsageAnalytics()
        }
    }

    @ViewBuilder
    private func loadedContent(snapshot: UsageAnalyticsSnapshot, theme: StenoTheme) -> some View {
        ManuscriptInsightsLayout(
            metrics: InsightsMetricStrip(metrics: metrics(for: snapshot), theme: theme),
            calendar: calendarCard(snapshot: snapshot, theme: theme),
            details: secondaryDetails(snapshot: snapshot, theme: theme),
            theme: theme
        )
    }

    private func secondaryDetails(snapshot: UsageAnalyticsSnapshot, theme: StenoTheme) -> some View {
        ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 16) {
            AppUsageBreakdownView(
                apps: appUsage(from: snapshot),
                theme: theme
            )
            .frame(minWidth: 300, maxWidth: .infinity)
            .layoutPriority(1)

            CleanupCoverageView(
                summary: cleanupSummary(from: snapshot),
                theme: theme
            )
            .frame(width: 320)
        }
        VStack(alignment: .leading, spacing: 16) {
            AppUsageBreakdownView(apps: appUsage(from: snapshot), theme: theme)
            CleanupCoverageView(summary: cleanupSummary(from: snapshot), theme: theme)
        }
        }
    }

    private func pageHeader(snapshot: UsageAnalyticsSnapshot?, theme: StenoTheme) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                headerTitle(theme: theme)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                headerBadges(snapshot: snapshot, theme: theme)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                headerTitle(theme: theme)
                headerBadges(snapshot: snapshot, theme: theme)
            }
        }
    }

    private func headerTitle(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            StenoPageTitle("Insights")
                .foregroundStyle(theme.text)
            Text("Your dictation, over time.")
                .font(StenoDesign.subheadline())
                .foregroundStyle(theme.textMuted)
        }
    }

    private func headerBadges(snapshot: UsageAnalyticsSnapshot?, theme: StenoTheme) -> some View {
        HStack(spacing: 8) {
            if let snapshot {
                StenoBadge(text: rangeLabel(for: snapshot), tone: .neutral, theme: theme,
                    icon: "calendar", compact: true)
            }
            StenoBadge(text: "Local only", tone: .green, theme: theme,
                icon: "lock.fill", compact: true)
                .help("Aggregate Insights history is calculated and retained on this Mac, separately from transcript history.")
        }
    }

    private func calendarCard(snapshot: UsageAnalyticsSnapshot, theme: StenoTheme) -> some View {
        InsightsCard(theme: theme, padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Usage calendar")
                            .font(StenoDesign.reading(size: 22))
                            .foregroundStyle(theme.text)
                            .accessibilityAddTraits(.isHeader)
                        Text("Darker squares mean more recorded time. Markers distinguish estimates and gaps.")
                            .font(StenoDesign.subheadline())
                            .foregroundStyle(theme.textMuted)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)], alignment: .leading, spacing: 12) {
                        streakStat(value: snapshot.currentStreak, label: "Current streak", suffix: "days", theme: theme)
                        streakStat(value: snapshot.longestKnownStreak, label: "Longest known", suffix: "days", theme: theme)
                        streakStat(value: snapshot.dailyUsage.filter(\.isActive).count, label: "Active days in range", suffix: nil, theme: theme)
                    }
                }

                Rectangle()
                    .fill(theme.line)
                    .frame(height: 1)

                UsageCalendarView(
                    days: calendarDays(from: snapshot),
                    theme: theme
                )
            }
        }
    }

    private func streakStat(
        value: Int,
        label: String,
        suffix: String?,
        theme: StenoTheme
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.formatted())
                    .font(StenoDesign.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.text)
                if let suffix {
                    Text(suffix)
                        .font(StenoDesign.subheadline())
                        .foregroundStyle(theme.textMuted)
                }
            }
            Text(label)
                .font(StenoDesign.system(size: 12))
                .foregroundStyle(theme.textMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private func loadingState(theme: StenoTheme) -> some View {
        InsightsCard(theme: theme) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Building your usage history…")
                        .font(StenoDesign.bodyEmphasis())
                        .foregroundStyle(theme.text)
                    Text("Steno is backfilling saved sessions on this Mac.")
                        .font(StenoDesign.subheadline())
                        .foregroundStyle(theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
        }
    }

    private func errorState(message: String, theme: StenoTheme) -> some View {
        InsightsCard(theme: theme) {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(theme.amber)
                Text("Insights couldn’t load")
                    .font(StenoDesign.bodyEmphasis())
                    .foregroundStyle(theme.text)
                Text(message)
                    .textSelection(.enabled)
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(theme.textMuted)
                    .multilineTextAlignment(.center)

                if let retryAction {
                    Button("Try again", action: retryAction)
                        .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .ghost))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
        }
    }

    private func warningState(message: String, theme: StenoTheme) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.amber)
            Text(message)
                .textSelection(.enabled)
                .font(StenoDesign.caption())
                .foregroundStyle(theme.textMuted)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.amber.opacity(theme.isLight ? 0.08 : 0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.amber.opacity(0.30), lineWidth: StenoDesign.borderThin)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func unavailableState(theme: StenoTheme) -> some View {
        InsightsCard(theme: theme) {
            VStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(theme.accent)
                Text("Insights are ready for data")
                    .font(StenoDesign.bodyEmphasis())
                    .foregroundStyle(theme.text)
                Text("Complete a dictation or finish importing saved history to populate this dashboard.")
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(theme.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
        }
    }

    private func metrics(for snapshot: UsageAnalyticsSnapshot) -> [InsightMetric] {
        [
            InsightMetric(
                id: "words",
                label: "Words dictated",
                value: wordsValue(for: snapshot),
                detail: wordsDetail(for: snapshot),
                systemImage: "text.word.spacing"
            ),
            InsightMetric(
                id: "time",
                label: "Known time dictated",
                value: hasKnownDuration(snapshot)
                    ? durationValue(for: snapshot)
                    : "Unavailable",
                detail: durationDetail(for: snapshot),
                systemImage: "clock"
            ),
            InsightMetric(
                id: "wpm",
                label: "Average speed",
                value: hasKnownDuration(snapshot)
                    ? wpmValue(for: snapshot)
                    : "Unavailable",
                detail: hasKnownDuration(snapshot)
                    ? wpmDetail(for: snapshot)
                    : "No saved session duration",
                systemImage: "speedometer"
            ),
            InsightMetric(
                id: "sessions",
                label: "Sessions",
                value: InsightsFormatting.compactCount(snapshot.totalSessions),
                detail: "Completed dictations",
                systemImage: "waveform"
            ),
        ]
    }

    private func calendarDays(from snapshot: UsageAnalyticsSnapshot) -> [UsageCalendarDay] {
        snapshot.dailyUsage.map { day in
            UsageCalendarDay(
                date: day.date,
                sessionCount: day.sessionCount,
                wordCount: day.wordCount,
                durationMS: day.durationMS,
                estimatedDurationSessionCount: day.estimatedDurationSessionCount,
                unavailableDurationSessionCount: day.unavailableDurationSessionCount,
                isTracked: day.isTracked,
                isActive: day.isActive,
                isInCurrentStreak: day.isInCurrentStreak
            )
        }
    }

    private func appUsage(from snapshot: UsageAnalyticsSnapshot) -> [AppUsageDisplay] {
        snapshot.topApps.map { app in
            AppUsageDisplay(
                appBundleID: app.appBundleID,
                sessionCount: app.sessionCount,
                wordCount: app.wordCount,
                durationMS: app.durationMS,
                estimatedDurationSessionCount: app.estimatedDurationSessionCount,
                unavailableDurationSessionCount: app.unavailableDurationSessionCount
            )
        }
    }

    private func cleanupSummary(from snapshot: UsageAnalyticsSnapshot) -> CleanupInsightSummary {
        CleanupInsightSummary(
            exactActions: snapshot.cleanupChanges.fillerRemovals
                + snapshot.cleanupChanges.lexiconCorrections
                + snapshot.cleanupChanges.repairResolutions
                + snapshot.cleanupChanges.structureRewrites
                + snapshot.cleanupChanges.punctuationChanges
                + snapshot.cleanupChanges.commandTransforms,
            estimatedChanges: snapshot.cleanupChanges.estimatedWordChanges,
            fillerRemovals: snapshot.cleanupChanges.fillerRemovals,
            punctuationChanges: snapshot.cleanupChanges.punctuationChanges,
            lexiconCorrections: snapshot.cleanupChanges.lexiconCorrections,
            exactSessionCount: snapshot.exactCleanupSessionCount,
            estimatedSessionCount: snapshot.estimatedCleanupSessionCount,
            trackedDayCount: snapshot.dailyUsage.filter(\.isTracked).count,
            totalDayCount: snapshot.dailyUsage.count,
            coverageIntervalCount: snapshot.coverage.count
        )
    }

    private func durationDetail(for snapshot: UsageAnalyticsSnapshot) -> String {
        if snapshot.estimatedDurationSessionCount > 0,
           snapshot.unavailableDurationSessionCount > 0 {
            let estimatedLabel = snapshot.estimatedDurationSessionCount == 1 ? "session" : "sessions"
            let unavailableLabel = snapshot.unavailableDurationSessionCount == 1 ? "session" : "sessions"
            return "\(snapshot.estimatedDurationSessionCount) \(estimatedLabel) estimated · \(snapshot.unavailableDurationSessionCount) \(unavailableLabel) unavailable"
        }
        if snapshot.unavailableDurationSessionCount > 0 {
            return "\(snapshot.unavailableDurationSessionCount) sessions lack time"
        }
        if snapshot.estimatedDurationSessionCount > 0 {
            return "\(snapshot.estimatedDurationSessionCount) imported durations estimated"
        }
        return "Measured capture time"
    }

    private func wordsValue(for snapshot: UsageAnalyticsSnapshot) -> String {
        snapshot.totalWords.formatted()
    }

    private func wordsDetail(for snapshot: UsageAnalyticsSnapshot) -> String {
        let activeDays = "Across \(snapshot.activeDayCount) active \(snapshot.activeDayCount == 1 ? "day" : "days")"
        return snapshot.estimatedCleanupSessionCount > 0
            ? "\(activeDays) · imported counts reconstructed"
            : activeDays
    }

    private func durationValue(for snapshot: UsageAnalyticsSnapshot) -> String {
        let value = InsightsFormatting.compactDuration(milliseconds: snapshot.totalDurationMS)
        return snapshot.estimatedDurationSessionCount > 0 ? "≈\(value)" : value
    }

    private func wpmValue(for snapshot: UsageAnalyticsSnapshot) -> String {
        let value = "\(Int(snapshot.averageWordsPerMinute.rounded())) WPM"
        return snapshot.estimatedDurationSessionCount > 0 ? "≈\(value)" : value
    }

    private func wpmDetail(for snapshot: UsageAnalyticsSnapshot) -> String {
        snapshot.estimatedDurationSessionCount > 0
            ? "Known durations, including estimates"
            : "Known-duration sessions only"
    }

    private func hasKnownDuration(_ snapshot: UsageAnalyticsSnapshot) -> Bool {
        snapshot.exactDurationSessionCount + snapshot.estimatedDurationSessionCount > 0
    }

    private var resolvedSnapshot: UsageAnalyticsSnapshot? {
        guard usesControllerData else { return snapshotOverride }
        return controller.usageAnalyticsSnapshot.dailyUsage.isEmpty
            ? nil
            : controller.usageAnalyticsSnapshot
    }

    private var resolvedIsLoading: Bool {
        usesControllerData ? controller.isLoadingUsageAnalytics : loadingOverride
    }

    private var resolvedLoadError: String? {
        if usesControllerData {
            return controller.usageAnalyticsError.isEmpty ? nil : controller.usageAnalyticsError
        }
        return errorOverride
    }

    private var resolvedWriteWarning: String? {
        guard usesControllerData else { return nil }
        return controller.usageAnalyticsWriteWarning.isEmpty
            ? nil
            : controller.usageAnalyticsWriteWarning
    }

    private var retryAction: (() -> Void)? {
        if usesControllerData {
            return {
                Task { await controller.refreshUsageAnalytics() }
            }
        }
        return retryOverride
    }

    private func rangeLabel(for snapshot: UsageAnalyticsSnapshot) -> String {
        guard
            let start = snapshot.dailyUsage.map(\.date).min(),
            let end = snapshot.dailyUsage.map(\.date).max()
        else {
            return "Last 6 months"
        }

        let startText = start.formatted(.dateTime.month(.abbreviated).day())
        let endText = end.formatted(.dateTime.month(.abbreviated).day().year())
        return "Calendar · \(startText) – \(endText)"
    }
}
