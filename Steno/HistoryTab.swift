import SwiftUI
import StenoKit

struct HistoryTab: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchQuery: String = ""
    @State private var expandedIDs: Set<UUID> = []
    @State private var currentTime = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: StenoDesign.md) {
            // Header bar
            HStack {
                Text("History")
                    .font(StenoDesign.heading2())
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                HStack(spacing: StenoDesign.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(StenoDesign.textSecondary)
                        .font(StenoDesign.caption())
                    TextField("Search transcripts...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(StenoDesign.callout())
                        .accessibilityLabel("Search transcripts")
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(StenoDesign.caption())
                                .foregroundStyle(StenoDesign.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, StenoDesign.sm)
                .padding(.vertical, StenoDesign.xs + StenoDesign.xxs)
                .background(StenoDesign.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: StenoDesign.radiusSmall)
                        .stroke(StenoDesign.border, lineWidth: StenoDesign.borderNormal)
                )
                .frame(maxWidth: StenoDesign.searchBarMaxWidth)
            }

            // Content
            if filteredEntries.isEmpty {
                Spacer()
                Text(searchQuery.isEmpty ? "No transcripts yet" : "No matching transcripts")
                    .font(StenoDesign.body())
                    .foregroundStyle(StenoDesign.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: StenoDesign.sm) {
                        ForEach(groupedEntries, id: \.label) { group in
                            // Day header
                            Text(group.label)
                                .font(StenoDesign.bodyEmphasis())
                                .foregroundStyle(StenoDesign.textSecondary)
                                .padding(.top, StenoDesign.sm)
                                .accessibilityAddTraits(.isHeader)

                            ForEach(group.entries) { entry in
                                entryRow(entry)
                            }
                        }
                    }
                    .padding(.bottom, StenoDesign.lg)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: StenoDesign.animationNormal),
                        value: filteredEntries.count
                    )
                }
            }
        }
        .padding(.vertical, StenoDesign.lg)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            currentTime = now
        }
    }

    private var filteredEntries: [TranscriptEntry] {
        if searchQuery.isEmpty {
            return controller.recentEntries
        }
        return controller.recentEntries.filter {
            $0.cleanText.localizedCaseInsensitiveContains(searchQuery)
            || $0.rawText.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var groupedEntries: [DayGroup] {
        let calendar = Calendar.current
        var groups: [String: [TranscriptEntry]] = [:]
        var order: [String] = []

        for entry in filteredEntries {
            let label = dayLabel(for: entry.createdAt, calendar: calendar)
            if groups[label] == nil {
                order.append(label)
                groups[label] = []
            }
            groups[label]?.append(entry)
        }

        return order.map { DayGroup(label: $0, entries: groups[$0] ?? []) }
    }

    private func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }

    private func relativeTimestamp(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // Use currentTime to force refresh
        _ = currentTime
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func entryRow(_ entry: TranscriptEntry) -> some View {
        let isExpanded = expandedIDs.contains(entry.id)

        return VStack(alignment: .leading, spacing: StenoDesign.sm) {
            // Top line: app name + status pill
            HStack {
                Text(appName(for: entry.appBundleID))
                    .font(StenoDesign.captionEmphasis())
                    .foregroundStyle(StenoDesign.textSecondary)
                Spacer()
                statusPill(entry.insertionStatus)
            }

            // Body text
            HStack(alignment: .top, spacing: StenoDesign.xs) {
                Text(entry.cleanText.isEmpty ? entry.rawText : entry.cleanText)
                    .font(StenoDesign.callout())
                    .foregroundStyle(StenoDesign.textPrimary)
                    .lineLimit(isExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: StenoDesign.animationFast)) {
                            if isExpanded {
                                expandedIDs.remove(entry.id)
                            } else {
                                expandedIDs.insert(entry.id)
                            }
                        }
                    }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
                    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            }

            // Bottom line: timestamp + copy/paste
            HStack {
                Text(relativeTimestamp(for: entry.createdAt))
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
                Spacer()

                CopyButtonView {
                    controller.copyEntry(entry)
                }

                Button {
                    controller.pasteEntry(entry)
                } label: {
                    HStack(spacing: StenoDesign.xs) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Paste")
                    }
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste transcript")
            }
        }
        .accessibilityElement(children: .contain)
        .cardStyle()
        .contextMenu {
            Button {
                controller.copyEntry(entry)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                controller.pasteEntry(entry)
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            Divider()
            Button(role: .destructive) {
                controller.deleteEntry(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func statusPill(_ status: InsertionStatus) -> some View {
        let (label, bgColor): (String, Color) = {
            switch status {
            case .inserted:
                return ("Inserted", StenoDesign.successBackground)
            case .copiedOnly:
                return ("Copied", StenoDesign.warningBackground)
            case .failed:
                return ("Failed", StenoDesign.errorBackground)
            }
        }()

        let fgColor: Color = {
            switch status {
            case .inserted: return StenoDesign.success
            case .copiedOnly: return StenoDesign.warning
            case .failed: return StenoDesign.error
            }
        }()

        return Text(label)
            .font(StenoDesign.labelEmphasis())
            .foregroundStyle(fgColor)
            .padding(.horizontal, StenoDesign.sm)
            .padding(.vertical, StenoDesign.xxs)
            .background(bgColor)
            .clipShape(Capsule())
            .accessibilityLabel("Status: \(label)")
    }

    private func appName(for bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

private struct DayGroup {
    let label: String
    let entries: [TranscriptEntry]
}
