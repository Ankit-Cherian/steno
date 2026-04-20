import SwiftUI
import StenoKit

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case copied
    case inserted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .copied:
            return "Copied"
        case .inserted:
            return "Inserted"
        }
    }
}

private struct HistoryGroup: Identifiable {
    let id = UUID()
    let label: String
    let entries: [TranscriptEntry]
}

struct HistoryTab: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery = ""
    @State private var selectedFilter: HistoryFilter = .all
    @State private var selectedEntryID: UUID?
    @State private var currentTime = Date()

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)

        HStack(spacing: 0) {
            leftColumn(theme: theme)
                .frame(width: 520)

            Rectangle()
                .fill(theme.line)
                .frame(width: 1)

            rightColumn(theme: theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 14)
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .onAppear {
            if selectedEntryID == nil {
                selectedEntryID = filteredEntries.first?.id
            }
        }
        .onChange(of: filteredEntries.map(\.id)) { ids in
            if let selectedEntryID, ids.contains(selectedEntryID) {
                return
            }
            self.selectedEntryID = ids.first
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            currentTime = now
        }
    }

    private var filteredEntries: [TranscriptEntry] {
        controller.recentEntries.filter { entry in
            let matchesFilter: Bool
            switch selectedFilter {
            case .all:
                matchesFilter = true
            case .copied:
                matchesFilter = entry.insertionStatus == .copiedOnly
            case .inserted:
                matchesFilter = entry.insertionStatus == .inserted
            }

            guard matchesFilter else { return false }
            guard !searchQuery.isEmpty else { return true }

            let appName = StenoDesign.appDisplayName(for: entry.appBundleID)
            return entry.cleanText.localizedCaseInsensitiveContains(searchQuery)
                || entry.rawText.localizedCaseInsensitiveContains(searchQuery)
                || appName.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var groupedEntries: [HistoryGroup] {
        let calendar = Calendar.current
        var grouped: [String: [TranscriptEntry]] = [:]
        var order: [String] = []

        for entry in filteredEntries {
            let label = groupLabel(for: entry.createdAt, calendar: calendar)
            if grouped[label] == nil {
                grouped[label] = []
                order.append(label)
            }
            grouped[label]?.append(entry)
        }

        return order.compactMap { label in
            guard let entries = grouped[label] else { return nil }
            return HistoryGroup(label: label, entries: entries)
        }
    }

    private var selectedEntry: TranscriptEntry? {
        guard let selectedEntryID else { return filteredEntries.first }
        return filteredEntries.first(where: { $0.id == selectedEntryID }) ?? filteredEntries.first
    }

    private func leftColumn(theme: StenoTheme) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textMuted)
                    TextField("Search transcripts, apps, words…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(StenoDesign.callout())
                        .foregroundStyle(theme.text)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.white.opacity(theme.isLight ? 0.76 : 0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                filterChips(theme: theme)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            HStack {
                Text("\(filteredEntries.count) OF \(controller.recentEntries.count) TRANSCRIPTS")
                    .font(StenoDesign.mono(size: 10, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(theme.textMuted)
                Spacer()
                HStack(spacing: 4) {
                    Text("Newest first")
                    Image(systemName: "arrow.up.arrow.down")
                }
                .font(StenoDesign.mono(size: 10, weight: .regular))
                .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groupedEntries) { group in
                        HStack(spacing: 10) {
                            Text(group.label)
                                .font(StenoDesign.mono(size: 10, weight: .medium))
                                .tracking(1.8)
                                .foregroundStyle(theme.textMuted)
                            Rectangle()
                                .fill(theme.line)
                                .frame(height: 1)
                            Text("\(group.entries.count)")
                                .font(StenoDesign.mono(size: 10, weight: .regular))
                                .foregroundStyle(theme.textMuted)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 12)

                        VStack(spacing: 6) {
                            ForEach(group.entries) { entry in
                                HistoryRowView(
                                    entry: entry,
                                    isSelected: selectedEntry?.id == entry.id,
                                    now: currentTime,
                                    theme: theme,
                                    onSelect: { selectedEntryID = entry.id },
                                    onCopy: { controller.copyEntry(entry) },
                                    onPaste: { controller.pasteEntry(entry) }
                                )
                            }
                        }
                    }

                    if groupedEntries.isEmpty {
                        VStack(spacing: 6) {
                            Text(searchQuery.isEmpty ? "No transcripts yet." : "No transcripts match that search.")
                                .font(StenoDesign.body())
                                .foregroundStyle(theme.textDim)
                            Text("Try a different query or clear filters.")
                                .font(StenoDesign.mono(size: 10, weight: .regular))
                                .foregroundStyle(theme.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
    }

    private func rightColumn(theme: StenoTheme) -> some View {
        ScrollView {
            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        AppGlyphView(
                            bundleID: entry.appBundleID,
                            appName: StenoDesign.appDisplayName(for: entry.appBundleID),
                            size: 28
                        )

                        Text(StenoDesign.appDisplayName(for: entry.appBundleID))
                            .font(StenoDesign.bodyEmphasis())
                            .foregroundStyle(theme.text)

                        StenoBadge(
                            text: statusLabel(for: entry.insertionStatus),
                            tone: entry.insertionStatus == .inserted ? .green : .amber,
                            theme: theme,
                            compact: true
                        )

                        Spacer()

                        Button(role: .destructive) {
                            controller.deleteEntry(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .ghost))
                    }

                    Text(headline(for: entry))
                        .font(StenoDesign.system(size: 21, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineSpacing(3)

                    Text("\(StenoDesign.timeText(for: entry.createdAt)) · \(StenoDesign.relativeDateText(for: entry.createdAt, now: currentTime)) · \(wordCount(for: entry)) words · \(durationText(for: entry.durationMS))")
                        .font(StenoDesign.mono(size: 10.5, weight: .regular))
                        .tracking(1.2)
                        .foregroundStyle(theme.textMuted)

                    HStack(spacing: 8) {
                        Button {
                            controller.copyEntry(entry)
                        } label: {
                            Label("Copy transcript", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .primary))

                        Button {
                            controller.pasteEntry(entry)
                        } label: {
                            Label("Paste to \(StenoDesign.appDisplayName(for: entry.appBundleID))", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .ghost))

                        Spacer()

                        Button {
                            controller.retryCleanup(for: entry)
                        } label: {
                            Label("Re-run cleanup", systemImage: "sparkles")
                        }
                        .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .soft))
                    }

                    detailCard(
                        theme: theme,
                        title: "CLEANED TEXT",
                        body: entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
                    )

                    DisclosureGroup {
                        Text(entry.rawText)
                            .font(StenoDesign.body())
                            .foregroundStyle(theme.textDim)
                            .lineSpacing(4)
                            .padding(.top, 12)
                    } label: {
                        HStack {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12, weight: .medium))
                            Text("RAW · UNPROCESSED")
                                .font(StenoDesign.mono(size: 10, weight: .medium))
                                .tracking(1.6)
                        }
                        .foregroundStyle(theme.textMuted)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(theme.cardGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 12)
            } else {
                Text("Select a transcript")
                    .font(StenoDesign.body())
                    .foregroundStyle(theme.textDim)
                    .padding(20)
            }
        }
    }

    private func filterChips(theme: StenoTheme) -> some View {
        HStack(spacing: 2) {
            ForEach(HistoryFilter.allCases) { filter in
                Button(filter.title) {
                    selectedFilter = filter
                }
                .buttonStyle(FilterChipButtonStyle(theme: theme, isSelected: selectedFilter == filter))
            }
        }
        .padding(2)
        .background(Color.white.opacity(theme.isLight ? 0.76 : 0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func detailCard(theme: StenoTheme, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(StenoDesign.mono(size: 10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(theme.textMuted)
            Text(body)
                .font(StenoDesign.body())
                .foregroundStyle(theme.text)
                .lineSpacing(4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(theme.cardGradient)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func groupLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "TODAY"
        }
        if calendar.isDateInYesterday(date) {
            return "YESTERDAY"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now), date > weekAgo {
            return "THIS WEEK"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func statusLabel(for status: InsertionStatus) -> String {
        switch status {
        case .inserted:
            return "Inserted"
        case .copiedOnly:
            return "Copied"
        case .failed:
            return "Failed"
        case .noSpeech:
            return "No Speech"
        }
    }

    private func headline(for entry: TranscriptEntry) -> String {
        let source = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Transcript" }

        let sentence = trimmed.components(separatedBy: ".").first ?? trimmed
        return sentence.count > 70 ? "\(sentence.prefix(67))..." : sentence
    }

    private func durationText(for durationMS: Int) -> String {
        guard durationMS > 0 else { return "0s" }
        let seconds = Int(round(Double(durationMS) / 1000.0))
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }

    private func wordCount(for entry: TranscriptEntry) -> Int {
        let source = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
        return source.split(whereSeparator: \.isWhitespace).count
    }
}

private struct HistoryRowView: View {
    let entry: TranscriptEntry
    let isSelected: Bool
    let now: Date
    let theme: StenoTheme
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 999)
                    .fill(isSelected ? theme.accent : .clear)
                    .frame(width: 2)
                    .padding(.vertical, 14)
                    .shadow(color: theme.accentGlow, radius: isSelected ? 8 : 0)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        AppGlyphView(
                            bundleID: entry.appBundleID,
                            appName: StenoDesign.appDisplayName(for: entry.appBundleID),
                            size: 18
                        )
                        Text(StenoDesign.appDisplayName(for: entry.appBundleID))
                            .font(StenoDesign.bodyEmphasis())
                            .foregroundStyle(theme.text)
                        Text(StenoDesign.timeText(for: entry.createdAt))
                            .font(StenoDesign.mono(size: 10, weight: .regular))
                            .foregroundStyle(theme.textMuted)
                        Text("·")
                            .font(StenoDesign.mono(size: 10, weight: .regular))
                            .foregroundStyle(theme.textMuted)
                        Text(StenoDesign.relativeDateText(for: entry.createdAt, now: now))
                            .font(StenoDesign.mono(size: 10, weight: .regular))
                            .foregroundStyle(theme.textMuted)
                        Spacer()
                        StenoBadge(
                            text: entry.insertionStatus == .inserted ? "Inserted" : "Copied",
                            tone: entry.insertionStatus == .inserted ? .green : .amber,
                            theme: theme,
                            compact: true
                        )
                    }

                    Text((entry.cleanText.isEmpty ? entry.rawText : entry.cleanText))
                        .font(StenoDesign.callout())
                        .foregroundStyle(theme.textDim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack {
                        Text("\(wordCount) words · \(durationText)")
                            .font(StenoDesign.mono(size: 10, weight: .regular))
                            .foregroundStyle(theme.textMuted)
                        Spacer()
                        HStack(spacing: 6) {
                            HistoryRowActionButton(
                                title: "Copy",
                                systemImage: "doc.on.doc",
                                accent: false,
                                theme: theme,
                                action: onCopy
                            )
                            HistoryRowActionButton(
                                title: "Paste",
                                systemImage: "doc.on.clipboard",
                                accent: true,
                                theme: theme,
                                action: onPaste
                            )
                        }
                        .opacity(isHovering || isSelected ? 1 : 0)
                        .offset(x: isHovering || isSelected ? 0 : 6)
                        .animation(.easeInOut(duration: StenoDesign.animationFast), value: isHovering || isSelected)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? theme.strongSelectedAccentBorder : (isHovering ? theme.lineStrong : .clear), lineWidth: StenoDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [theme.selectedAccentFill, Color.white.opacity(theme.isLight ? 0.78 : 0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }

        return AnyShapeStyle(Color.white.opacity(theme.isLight ? (isHovering ? 0.70 : 0.0) : (isHovering ? 0.03 : 0.0)))
    }

    private var wordCount: Int {
        let source = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
        return source.split(whereSeparator: \.isWhitespace).count
    }

    private var durationText: String {
        let seconds = max(0, Int(round(Double(entry.durationMS) / 1000)))
        return seconds > 0 ? "\(seconds)s" : "0s"
    }
}

private struct HistoryRowActionButton: View {
    let title: String
    let systemImage: String
    let accent: Bool
    let theme: StenoTheme
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(StenoDesign.mono(size: 10.5, weight: .medium))
            .foregroundStyle(accent ? (isHovering ? theme.accent : theme.textDim) : theme.textDim)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                isHovering
                    ? (accent ? AnyShapeStyle(theme.accentSoft) : AnyShapeStyle(Color.white.opacity(theme.isLight ? 0.72 : 0.05)))
                    : AnyShapeStyle(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isHovering ? theme.lineStrong : .clear, lineWidth: StenoDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct FilterChipButtonStyle: ButtonStyle {
    let theme: StenoTheme
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StenoDesign.callout().weight(.medium))
            .foregroundStyle(isSelected ? theme.text : theme.textMuted)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(isSelected ? Color.white.opacity(theme.isLight ? 0.88 : 0.08) : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? theme.lineStrong : .clear, lineWidth: StenoDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
