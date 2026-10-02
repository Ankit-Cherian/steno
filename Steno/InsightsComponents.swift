import Foundation
import SwiftUI

struct InsightMetric: Identifiable {
    let id: String
    let label: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppUsageDisplay: Identifiable {
    let appBundleID: String
    let sessionCount: Int
    let wordCount: Int
    let durationMS: Int
    let estimatedDurationSessionCount: Int
    let unavailableDurationSessionCount: Int

    var id: String { appBundleID }
}

struct CleanupInsightSummary {
    let exactActions: Int
    let estimatedChanges: Int
    let fillerRemovals: Int
    let punctuationChanges: Int
    let lexiconCorrections: Int
    let exactSessionCount: Int
    let estimatedSessionCount: Int
}

struct InsightsCard<Content: View>: View {
    let theme: StenoTheme
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(
        theme: StenoTheme,
        padding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardGradient)
            .overlay(
                RoundedRectangle(cornerRadius: StenoDesign.cardCornerRadius, style: .continuous)
                    .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.cardCornerRadius, style: .continuous))

    }
}

struct InsightsMetricStrip: View {
    let metrics: [InsightMetric]
    let theme: StenoTheme

    var body: some View {
        InsightsCard(theme: theme, padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Lifetime totals")
                        .font(StenoDesign.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textDim)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 13)
                .padding(.bottom, 10)

                Rectangle()
                    .fill(theme.line)
                    .frame(height: 1)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(metrics) { metric in
                            InsightMetricCell(metric: metric, theme: theme)
                                .frame(minWidth: 180)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], alignment: .leading, spacing: 0) {
                        ForEach(metrics) { metric in
                            InsightMetricCell(metric: metric, theme: theme)
                        }
                    }
                }
            }
        }
    }
}

private struct InsightMetricCell: View {
    let metric: InsightMetric
    let theme: StenoTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: metric.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)

                Text(metric.label)
                    .font(StenoDesign.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }

            Text(metric.value)
                .font(StenoDesign.pageTitle(size: 28).monospacedDigit())
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.label), \(metric.value). \(metric.detail)")
        .help(metric.detail)
    }
}

struct AppUsageBreakdownView: View {
    let apps: [AppUsageDisplay]
    let theme: StenoTheme

    var body: some View {
        InsightsCard(theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeading

                if apps.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "macwindow")
                            .foregroundStyle(theme.textMuted)
                        Text("App usage will appear after your first saved dictation.")
                            .font(StenoDesign.callout())
                            .foregroundStyle(theme.textDim)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                } else {
                    VStack(spacing: 13) {
                        ForEach(Array(apps.prefix(6).enumerated()), id: \.element.id) { index, app in
                            AppUsageRow(
                                app: app,
                                rank: index + 1,
                                maximumSessionCount: maximumSessionCount,
                                theme: theme
                            )
                        }
                    }
                }
            }
        }
    }

    private var sectionHeading: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("App usage")
                    .font(StenoDesign.reading(size: 22))
                    .foregroundStyle(theme.text)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer()

            Text("\(apps.count) \(apps.count == 1 ? "app" : "apps")")
                .font(StenoDesign.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textDim)
        }
    }

    private var maximumSessionCount: Int {
        max(1, apps.map(\.sessionCount).max() ?? 1)
    }
}

private struct AppUsageRow: View {
    let app: AppUsageDisplay
    let rank: Int
    let maximumSessionCount: Int
    let theme: StenoTheme

    var body: some View {
        HStack(spacing: 11) {
            Text("\(rank)")
                .font(StenoDesign.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textMuted)
                .frame(width: 14, alignment: .trailing)

            AppGlyphView(
                bundleID: app.appBundleID,
                appName: appName,
                size: 25
            )

            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        appNameLabel.fixedSize()
                        Spacer(minLength: 8)
                        usageLabel.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        appNameLabel
                        usageLabel
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(theme.isLight ? 0.62 : 0.04))
                        Capsule(style: .continuous)
                            .fill(theme.accent.opacity(rank == 1 ? 0.82 : 0.48))
                            .frame(width: max(3, proxy.size.width * relativeUsage))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(rank), \(appName), \(durationDescription), \(InsightsFormatting.count(app.wordCount, "word")) spoken, \(InsightsFormatting.count(app.sessionCount, "session"))")
    }

    private var appNameLabel: some View {
        Text(appName)
            .font(StenoDesign.bodyEmphasis())
            .foregroundStyle(theme.text)
            .lineLimit(1)
    }

    private var usageLabel: some View {
        Text(summaryText)
            .font(StenoDesign.system(size: 12))
            .foregroundStyle(theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var appName: String {
        StenoDesign.appDisplayName(for: app.appBundleID)
    }

    private var relativeUsage: CGFloat {
        return CGFloat(app.sessionCount) / CGFloat(maximumSessionCount)
    }

    private var summaryText: String {
        "\(durationDescription) · \(InsightsFormatting.count(app.sessionCount, "session"))"
    }

    private var durationDescription: String {
        if app.durationMS == 0, app.unavailableDurationSessionCount > 0 {
            return "time unavailable"
        }
        let knownTime = InsightsFormatting.compactDuration(milliseconds: app.durationMS)
        let prefix = app.estimatedDurationSessionCount > 0 ? "about " : ""
        return app.unavailableDurationSessionCount > 0
            ? "\(prefix)\(knownTime) known"
            : "\(prefix)\(knownTime)"
    }
}

struct CleanupCoverageView: View {
    let summary: CleanupInsightSummary
    let theme: StenoTheme

    var body: some View {
        InsightsCard(theme: theme) {
            VStack(alignment: .leading, spacing: 17) {
                heading

                if summary.exactSessionCount > 0 {
                    VStack(alignment: .leading, spacing: 7) {
                        VStack(spacing: 0) {
                            cleanupRow(label: "Filler words removed", value: summary.fillerRemovals)
                            divider
                            cleanupRow(label: "Punctuation fixes", value: summary.punctuationChanges)
                            divider
                            cleanupRow(label: "Dictionary corrections", value: summary.lexiconCorrections)

                            if exactOtherChanges > 0 {
                                divider
                                cleanupRow(label: "Other refinements", value: exactOtherChanges)
                            }
                        }
                    }
                }

                if summary.estimatedSessionCount > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Estimated edits")
                                .font(StenoDesign.callout())
                                .foregroundStyle(theme.textDim)
                        }

                        Spacer()

                        Text("≈\(InsightsFormatting.compactCount(summary.estimatedChanges))")
                            .font(StenoDesign.mono(size: 12, weight: .semibold))
                            .foregroundStyle(theme.text)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .background(theme.ink1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.line, lineWidth: StenoDesign.borderThin)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .combine)
                }

                if summary.exactSessionCount == 0, summary.estimatedSessionCount == 0 {
                    VStack(spacing: 0) {
                        cleanupRow(label: "Recorded cleanup actions", value: 0)
                    }
                }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Cleanup history")
                    .font(StenoDesign.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
            Text(headlineText)
                .font(StenoDesign.reading(size: 22).monospacedDigit())
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .help(cleanupProvenanceText)
    }

    private func cleanupRow(label: String, value: Int) -> some View {
        HStack {
            Text(label)
                .font(StenoDesign.callout())
                .foregroundStyle(theme.textDim)
            Spacer()
            Text(InsightsFormatting.compactCount(value))
                .font(StenoDesign.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.line)
            .frame(height: 1)
    }

    private var exactOtherChanges: Int {
        max(
            0,
            summary.exactActions
                - summary.fillerRemovals
                - summary.punctuationChanges
                - summary.lexiconCorrections
        )
    }

    private var headlineText: String {
        if summary.exactSessionCount > 0 {
            return InsightsFormatting.count(summary.exactActions, "cleanup action")
        }
        if summary.estimatedSessionCount > 0 {
            return "≈\(InsightsFormatting.count(summary.estimatedChanges, "historical cleanup edit"))"
        }
        return "0 cleanup actions"
    }

    private var cleanupProvenanceText: String {
        let retention = "Insights history is retained separately from transcript history. Deleting a transcript does not remove its aggregate usage totals; transcript text is not copied into Insights."
        if summary.estimatedSessionCount > 0, summary.exactSessionCount > 0 {
            return "Exact actions and estimates from \(InsightsFormatting.count(summary.estimatedSessionCount, "imported session")) are shown separately. \(retention)"
        }
        if summary.estimatedSessionCount > 0 {
            return "Historical cleanup edits reconstructed from \(InsightsFormatting.count(summary.estimatedSessionCount, "imported session")) are estimates. \(retention)"
        }
        return "Cleanup actions are recorded as exact aggregate counts. \(retention)"
    }
}

enum InsightsFormatting {
    /// A short count for metric values, such as "1.2K" or "1M".
    static func compactCount(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(
            .number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale)
        )
    }

    /// A count with its noun in the matching singular or plural form, such as
    /// "1 session" or "1,234 sessions".
    static func count(_ value: Int, _ noun: String, locale: Locale = .autoupdatingCurrent) -> String {
        String(AttributedString(localized: "^[\(value) \(noun)](inflect: true)", locale: locale).characters)
    }

    static func compactDuration(milliseconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard milliseconds > 0 else { return "0m" }
        let totalMinutes = max(1, Int((Double(milliseconds) / 60_000.0).rounded()))
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours < 100 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return "\(hours.formatted(.number.locale(locale)))h"
    }

    /// Explains which sessions' times are estimated or missing from the total.
    static func durationDetail(
        estimatedSessions: Int,
        unavailableSessions: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if estimatedSessions > 0, unavailableSessions > 0 {
            return "\(count(estimatedSessions, "session", locale: locale)) estimated · \(count(unavailableSessions, "session", locale: locale)) unavailable"
        }
        if unavailableSessions > 0 {
            return "\(count(unavailableSessions, "session", locale: locale)) without a saved time"
        }
        if estimatedSessions > 0 {
            return "\(count(estimatedSessions, "imported duration", locale: locale)) estimated"
        }
        return "Measured capture time"
    }
}
