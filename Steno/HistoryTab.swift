import SwiftUI
import StenoKit

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case inserted = "Inserted"
    case copied = "Copied"
    case needsAttention = "Needs attention"
    var id: String { rawValue }
}

struct HistoryTab: View {
    @EnvironmentObject private var controller: DictationController
    @ScaledMetric(relativeTo: .body) private var readingPointSize: CGFloat = 18
    @State private var searchQuery = ""
    @State private var selectedFilter: HistoryFilter = .all
    @State private var selectedEntryID: UUID?
    @State private var entryToDelete: TranscriptEntry?
    @FocusState private var searchFocused: Bool

    init(initialSelectedEntryID: UUID? = nil) {
        _selectedEntryID = State(initialValue: initialSelectedEntryID)
    }

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                StenoPageTitle("History")
                Spacer()
                Label("Stored on this Mac", systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(theme.textDim)
                    .fixedSize()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            if !controller.lastError.isEmpty {
                Label(controller.lastError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(theme.danger)
                    .textSelection(.enabled)
                    .padding(.horizontal, 28).padding(.bottom, 16)
            }
            if controller.status == "Transcript copied to clipboard. Paste with Cmd+V." {
                Label("Last action: copied to clipboard. Paste with Command-V.", systemImage: "checkmark")
                    .font(.system(size: 12)).foregroundStyle(theme.textDim)
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
            GeometryReader { proxy in
                historyLayout(theme: theme, availableSize: proxy.size)

            }
        }
        .onAppear { reconcileSelection() }
        .onChange(of: filteredEntries.map(\.id)) { _ in reconcileSelection() }
        .confirmationDialog("Delete this transcript?", isPresented: Binding(get: { entryToDelete != nil }, set: { if !$0 { entryToDelete = nil } })) {
            Button("Delete transcript", role: .destructive) {
                if let entryToDelete { controller.deleteEntry(entryToDelete) }
                entryToDelete = nil
            }
            Button("Cancel", role: .cancel) { entryToDelete = nil }
        } message: {
            Text("This removes the saved transcript from this Mac. It does not remove text already inserted into another app.")
        }
    }

    @ViewBuilder
    private func historyLayout(theme: StenoTheme, availableSize: CGSize) -> some View {
        ManuscriptHistoryLayout(
            list: transcriptList(theme: theme),
            detail: transcriptDetail(theme: theme),
            theme: theme,
            availableSize: availableSize
        )
    }

    private var filteredEntries: [TranscriptEntry] {
        controller.recentEntries.filter { entry in
            let matchesFilter: Bool
            switch selectedFilter {
            case .all: matchesFilter = true
            case .inserted: matchesFilter = entry.insertionStatus == .inserted
            case .copied: matchesFilter = entry.insertionStatus == .copiedOnly
            case .needsAttention: matchesFilter = entry.insertionStatus == .failed
            }
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesFilter && (query.isEmpty || entry.cleanText.localizedCaseInsensitiveContains(query)
                || entry.rawText.localizedCaseInsensitiveContains(query)
                || StenoDesign.appDisplayName(for: entry.appBundleID).localizedCaseInsensitiveContains(query))
        }
    }

    private var selectedEntry: TranscriptEntry? {
        filteredEntries.first { $0.id == selectedEntryID }
    }

    private func transcriptList(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textDim)
                TextField("Search words or apps", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("history.search")
                    .accessibilityLabel("Search transcripts by words or app")
                    .onExitCommand { searchQuery = "" }
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                        .help("Clear search")
                        .foregroundStyle(theme.textDim)
                }
            }
            .padding(9)
            .background(theme.ink2)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(searchFocused ? theme.accent : theme.lineStrong, lineWidth: searchFocused ? 1.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 16)
            Picker("Show", selection: $selectedFilter) {
                ForEach(HistoryFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
            }
            .padding(.horizontal, 16)
            Text("\(filteredEntries.count) \(filteredEntries.count == 1 ? "transcript" : "transcripts") · newest first")
                .font(.system(size: 12)).foregroundStyle(theme.textDim)
                .padding(.horizontal, 16)

            if filteredEntries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(controller.recentEntries.isEmpty ? "Your words will be here." : "No matching transcripts.")
                        .font(.system(size: 15, weight: .semibold))
                    Text(controller.recentEntries.isEmpty ? "Completed dictations are saved locally so you can return to them." : "Try a different search or show all transcripts.")
                        .font(.system(size: 12)).foregroundStyle(theme.textDim)
                    if !controller.recentEntries.isEmpty {
                        Button("Clear search and filters") { searchQuery = ""; selectedFilter = .all }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(20)
                Spacer()
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(transcriptText(entry).isEmpty ? "No speech detected" : transcriptText(entry))
                                .font(.system(size: 13))
                                .lineSpacing(3)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Image(systemName: statusSymbol(entry.insertionStatus))
                                Text(StenoDesign.appDisplayName(for: entry.appBundleID)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
                                    .lineLimit(1)
                            }
                            .font(.system(size: 11)).foregroundStyle(theme.textDim)
                        }
                        .padding(.vertical, 9)
                        .tag(entry.id)
                        .accessibilityIdentifier("history.row.\(entry.id.uuidString)")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(StenoDesign.appDisplayName(for: entry.appBundleID)), \(entry.createdAt.formatted(date: .long, time: .shortened)). \(statusLabel(entry.insertionStatus)). \(transcriptText(entry))")
                        .contextMenu {
                            Button("Copy transcript") { controller.pasteEntry(entry) }
                            Button("Run cleanup again") { controller.retryCleanup(for: entry) }
                            Divider()
                            Button("Delete…", role: .destructive) { entryToDelete = entry }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(alignment: .topLeading) {
            Button("Find transcript") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private func transcriptDetail(theme: StenoTheme) -> some View {
        ScrollView {
            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(statusLabel(entry.insertionStatus), systemImage: statusSymbol(entry.insertionStatus))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(entry.insertionStatus == .failed ? theme.danger : theme.textDim)
                        Text(StenoDesign.appDisplayName(for: entry.appBundleID))
                            .font(StenoDesign.reading(size: 23))
                            .accessibilityAddTraits(.isHeader)
                        Text(entry.createdAt.formatted(date: .long, time: .shortened))
                            .font(.system(size: 12)).foregroundStyle(theme.textDim)
                        Text("\(transcriptText(entry).split(whereSeparator: \.isWhitespace).count) words · \(durationText(entry.durationMS))")
                            .font(.system(size: 12)).foregroundStyle(theme.textDim)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { detailActions(entry, theme: theme) }
                        VStack(alignment: .leading, spacing: 10) { detailActions(entry, theme: theme) }
                    }
                    if entry.insertionStatus == .failed || entry.insertionStatus == .copiedOnly {
                        Text("Copy your transcript, then paste it into the app where you need it.")
                            .font(.system(size: 13)).foregroundStyle(theme.textDim)
                    }
                    Divider()
                    Text(transcriptText(entry).isEmpty ? "No transcript text." : transcriptText(entry))
                        .font(StenoDesign.reading(size: min(readingPointSize, 30)))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    DisclosureGroup("Original recognition") {
                        Text(entry.rawText)
                            .font(.system(size: 14)).lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textDim)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "text.alignleft").font(.system(size: 28))
                    Text(controller.recentEntries.isEmpty ? "A place for your words" : "Select a transcript")
                        .font(StenoDesign.reading(size: 23))
                        .foregroundStyle(theme.text)
                    Text(controller.recentEntries.isEmpty ? "Your saved dictations will be ready to read, copy, and revisit here." : "Read the full text, copy it, or compare the original recognition.")
                        .font(.system(size: 13))
                }
                .foregroundStyle(theme.textDim)
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private func detailActions(_ entry: TranscriptEntry, theme: StenoTheme) -> some View {
        Button { controller.pasteEntry(entry) } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
            .buttonStyle(.borderedProminent).tint(theme.accent)
            .help("Copy this transcript to the clipboard")
            .accessibilityIdentifier("history.copy")
        Menu {
            Button("Run cleanup again") { controller.retryCleanup(for: entry) }
            Divider()
            Button("Delete transcript…", role: .destructive) { entryToDelete = entry }
        } label: { Label("More", systemImage: "ellipsis") }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("More transcript actions")
        .fixedSize()
    }

    private func reconcileSelection() {
        if !filteredEntries.contains(where: { $0.id == selectedEntryID }) { selectedEntryID = filteredEntries.first?.id }
    }

    private func transcriptText(_ entry: TranscriptEntry) -> String { entry.cleanText.isEmpty ? entry.rawText : entry.cleanText }
    private func durationText(_ duration: Int) -> String {
        let seconds = max(0, duration / 1000)
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
    private func statusLabel(_ status: InsertionStatus) -> String {
        switch status {
        case .inserted: return "Inserted"
        case .copiedOnly: return "Copied to clipboard"
        case .failed: return "Insertion failed"
        case .noSpeech: return "No speech detected"
        }
    }
    private func statusSymbol(_ status: InsertionStatus) -> String {
        switch status {
        case .inserted: return "checkmark.circle"
        case .copiedOnly: return "doc.on.clipboard"
        case .failed: return "exclamationmark.circle"
        case .noSpeech: return "mic.slash"
        }
    }
}
