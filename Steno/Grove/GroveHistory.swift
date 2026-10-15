import StenoKit
import SwiftUI

/// History in the Grove window: a rounded list panel with the search field on top, and the
/// reader beside it on the window's ground.
struct GroveHistoryView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.groveTheme) private var theme
    @Environment(\.groveFeedback) private var feedback
    @Environment(\.sectionPlaces) private var places
    @Binding var searchQuery: String
    @Binding var focusRequest: HistoryFocusRequest?
    @State private var selectedFilter: HistoryFilter
    @State private var selectedEntryID: UUID?
    /// The last filtered list, reused while the dictations, the search and the filter are the
    /// same. The body asks for it several times per redraw.
    @State private var filterMemo = GroveHistoryFilterMemo()
    /// What was said around the open dictation, kept while the dictations and the selection are
    /// the same: it searches all of them.
    @State private var aroundMemo = GroveAroundThenMemo()
    @State private var picksWord = false
    @State private var whatHappenedRequest = 0
    @StateObject private var listKeys = GroveKeyFocus()
    @FocusState private var searchFocused: Bool
    private let initialFix: FixWordState?
    private let initialFixResult: FixWordResult?
    private let initialBeforeCleanupExpanded: Bool

    init(
        searchQuery: Binding<String> = .constant(""),
        focusRequest: Binding<HistoryFocusRequest?> = .constant(nil),
        initialSelectedEntryID: UUID? = nil,
        initialFilter: HistoryFilter = .all,
        initialFix: FixWordState? = nil,
        initialFixResult: FixWordResult? = nil,
        initialBeforeCleanupExpanded: Bool = false
    ) {
        _searchQuery = searchQuery
        _focusRequest = focusRequest
        _selectedEntryID = State(initialValue: initialSelectedEntryID)
        _selectedFilter = State(initialValue: initialFilter)
        self.initialFix = initialFix
        self.initialFixResult = initialFixResult
        self.initialBeforeCleanupExpanded = initialBeforeCleanupExpanded
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            listPanel
                .frame(width: GroveMetrics.historyListWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(theme.panelBackground())
            GroveHistoryReader(
                entry: selectedEntry, empty: readerEmpty, query: searchQuery,
                around: aroundThen, picksWord: $picksWord, whatHappenedRequest: whatHappenedRequest,
                initialFix: initialFix, initialFixResult: initialFixResult,
                initialBeforeCleanupExpanded: initialBeforeCleanupExpanded,
                onCopy: copy, onFixWord: beginFixWord, onRerun: cleanUpAgain,
                onRestore: { controller.restoreOriginalCleanup(for: $0) },
                onDelete: confirmDelete, onWhatHappened: showWhatHappened,
                onSelect: { select($0, focusList: $1) })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(theme.panelBackground())
        }
        .groveColumn(theme, fillsHeight: true)
        .dictationCommands(commandActions)
        .onAppear {
            restorePlace()
            applyFocusRequest()
            reconcileSelection()
        }
        .onChange(of: listRevision) { _ in reconcileSelection() }
        .onChange(of: focusRequest) { _ in applyFocusRequest() }
        .onChange(of: selectedEntryID) { id in
            picksWord = false
            places?.historyEntryID = id
        }
        .onChange(of: selectedFilter) { places?.historyFilter = $0 }
    }

    /// Comes back to the dictation and filter shown when History was last left, unless this
    /// view was opened on a dictation of its own.
    private func restorePlace() {
        guard let places, selectedEntryID == nil else { return }
        if let filter = places.historyFilter { selectedFilter = filter }
        selectedEntryID = places.historyEntryID
    }

    /// ⌘F focuses the search, ⌘E starts Fix a Word, ⌘I shows How it was written. The keys can
    /// keep the actions of an earlier draw, so each finds the selected dictation when it runs.
    private var commandActions: DictationCommandActions {
        let entry = selectedEntry
        return DictationCommandActions(
            search: { searchFocused = true },
            fixWord: entry.flatMap { entry in
                entry.hasWords && WordFixers.current(for: controller).isAvailable ? { selectedEntry.map(beginFixWord) } : nil
            },
            howItWasWritten: entry.map { _ in { selectedEntry.map(showWhatHappened) } })
    }

    // MARK: List

    /// The search field, then the dictations by day, or a line that says why there are none.
    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroveSearchField(text: $searchQuery, filter: $selectedFilter, focus: $searchFocused,
                             onDeleteAll: confirmDeleteAll)
                .padding(.bottom, 14)
            if controller.recentEntries.isEmpty {
                firstRun
            } else if filteredEntries.isEmpty {
                noMatches
            } else {
                list
            }
        }
        .padding(.horizontal, GroveMetrics.panelInset - 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var list: some View {
        GroveHistoryRows(
            items: filterMemo.items(controller.recentEntries, query: searchQuery, filter: selectedFilter),
            countLine: trimmedQuery.isEmpty ? nil
                : filteredEntries.count == 1 ? "1 dictation matches “\(trimmedQuery)”"
                : "\(filteredEntries.count) dictations match “\(trimmedQuery)”",
            selectedEntryID: selectedEntryID, showsFocus: listKeys.isFocused,
            onSelect: { select($0, focusList: true) }, menu: { menu(for: $0) })
            .equatable()
            .background(GroveKeyHandling(
                focus: listKeys,
                onMove: move,
                onDelete: { if let entry = selectedEntry { confirmDelete(entry) } },
                onCopy: { if let entry = selectedEntry { copy(entry) } }))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Dictations")
    }

    private var firstRun: some View {
        VStack(alignment: .leading, spacing: 4) {
            GroveQuill(colors: .quiet(theme))
                .frame(width: 24, height: 24)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text("No dictations yet")
                .groveFont(13, .semibold)
                .foregroundStyle(theme.inkColor)
            Text("Each finished dictation is saved here, on this Mac. History keeps the latest 1,000.")
                .groveFont(13)
                .foregroundStyle(theme.ink3Color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noMatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            if trimmedQuery.isEmpty {
                Text("No dictations in “\(selectedFilter.menuTitle)”")
                    .groveFont(13, .semibold)
                    .foregroundStyle(theme.inkColor)
                Button("Show All") { selectedFilter = .all }
                    .buttonStyle(.groveText)
                    .padding(.leading, -8)
            } else {
                Text("No dictations match “\(trimmedQuery)”")
                    .groveFont(13, .semibold)
                    .foregroundStyle(theme.inkColor)
                Text("Check the spelling or try another word.")
                    .groveFont(13)
                    .foregroundStyle(theme.ink3Color)
                Button("Clear Search") { searchQuery = "" }
                    .buttonStyle(.groveText)
                    .padding(.leading, -8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func menu(for entry: TranscriptEntry) -> some View {
        if entry.hasWords {
            Button("Copy") { copy(entry) }
        }
        if entry.hasWords, WordFixers.current(for: controller).isAvailable {
            Button("Fix a Word…") { beginFixWord(entry) }
        }
        Button("How It Was Written") { showWhatHappened(entry) }
        Divider()
        Button("Clean Up Again") { cleanUpAgain(entry) }
        Button("Restore Original Cleanup") { controller.restoreOriginalCleanup(for: entry) }
            .disabled(entry.originalCleanText == nil)
        Divider()
        Button("Delete…") { confirmDelete(entry) }
    }

    // MARK: Actions

    private func select(_ entry: TranscriptEntry, focusList: Bool = false) {
        if !filteredEntries.contains(where: { $0.id == entry.id }) {
            searchQuery = ""
            selectedFilter = .all
        }
        selectedEntryID = entry.id
        if focusList { listKeys.request() }
    }

    private func move(_ direction: GroveMove) {
        let entries = filteredEntries
        guard let index = entries.firstIndex(where: { $0.id == selectedEntryID }) else {
            selectedEntryID = entries.first?.id
            return
        }
        switch direction {
        case .up: selectedEntryID = entries[max(0, index - 1)].id
        case .down: selectedEntryID = entries[min(entries.count - 1, index + 1)].id
        default: break
        }
    }

    private func copy(_ entry: TranscriptEntry) {
        controller.pasteEntry(entry) { copied in
            if copied { feedback?.post("Copied to the clipboard", systemImage: "doc.on.doc") }
        }
    }

    private func cleanUpAgain(_ entry: TranscriptEntry) {
        controller.retryCleanup(for: entry) { changed in
            if !changed { feedback?.post("Cleanup gave the same words.", systemImage: "equal") }
        }
    }

    private func beginFixWord(_ entry: TranscriptEntry) {
        guard entry.hasWords, WordFixers.current(for: controller).isAvailable else { return }
        selectedEntryID = entry.id
        picksWord = true
    }

    private func showWhatHappened(_ entry: TranscriptEntry) {
        selectedEntryID = entry.id
        whatHappenedRequest += 1
    }

    private func confirmDelete(_ entry: TranscriptEntry) {
        guard let feedback else { return }
        feedback.confirm(title: HistoryRules.deleteOneTitle, message: HistoryRules.deleteOneMessage,
                         confirmTitle: HistoryRules.deleteOneButton) {
            controller.deleteEntry(entry) { deleted in
                if deleted { feedback.post("Dictation deleted", systemImage: "trash") }
            }
        }
    }

    private func confirmDeleteAll() {
        guard let feedback else { return }
        feedback.confirm(title: HistoryRules.deleteAllConfirmationTitle(listedCount: controller.recentEntries.count),
                         message: HistoryRules.deleteAllMessage, confirmTitle: HistoryRules.deleteAllButton) {
            Task {
                await HistoryRules.deleteAllHistory(using: controller)
                if controller.status == "History deleted." { feedback.post("History deleted", systemImage: "trash") }
            }
        }
    }

    private func applyFocusRequest() {
        guard let request = focusRequest else { return }
        searchQuery = ""
        selectedFilter = .all
        selectedEntryID = request.entryID
        if request.showsWhatHappened { whatHappenedRequest += 1 }
        focusRequest = nil
    }

    private func reconcileSelection() {
        if !filteredEntries.contains(where: { $0.id == selectedEntryID }) {
            selectedEntryID = filteredEntries.first?.id
        }
    }

    // MARK: Data

    private var trimmedQuery: String { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredEntries: [TranscriptEntry] {
        filterMemo.entries(controller.recentEntries, query: searchQuery, filter: selectedFilter)
    }

    /// Changes when the filtered list is rebuilt, which is when the selection may need to move.
    private var listRevision: Int {
        _ = filteredEntries
        return filterMemo.revision
    }

    /// Why the reader has no dictation to show.
    private var readerEmpty: GroveHistoryReader.Empty {
        if controller.recentEntries.isEmpty { return .noDictations }
        guard filteredEntries.isEmpty else { return .noSelection }
        return trimmedQuery.isEmpty ? .noneInFilter(selectedFilter.menuTitle) : .noMatches
    }

    private var selectedEntry: TranscriptEntry? {
        filteredEntries.first { $0.id == selectedEntryID }
    }

    private var aroundThen: [TranscriptEntry] {
        guard let selectedEntry else { return [] }
        return aroundMemo.around(selectedEntry, in: controller.recentEntries)
    }
}

/// History's list: the dictations by day, the selected one marked. It compares the list it was
/// given rather than redrawing whenever History does, so a change of app state that leaves the
/// list as it was (a status, a setting, a recording) does not walk a thousand rows.
private struct GroveHistoryRows<Menu: View>: View, @preconcurrency Equatable {
    let items: [GroveHistoryListItem]
    let countLine: String?
    let selectedEntryID: UUID?
    let showsFocus: Bool
    /// Not compared: they act on the dictation they are given.
    let onSelect: (TranscriptEntry) -> Void
    @ViewBuilder let menu: (TranscriptEntry) -> Menu
    @Environment(\.groveTheme) private var theme

    static func == (a: Self, b: Self) -> Bool {
        a.items.sharesBuffer(with: b.items) && a.countLine == b.countLine
            && a.selectedEntryID == b.selectedEntryID && a.showsFocus == b.showsFocus
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let countLine {
                        Text(countLine)
                            .groveFont(12)
                            .foregroundStyle(theme.ink2Color)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                    ForEach(items) { item in
                        switch item.kind {
                        case .header(let title):
                            Text(title)
                                .groveFont(11, .semibold)
                                .foregroundStyle(theme.ink3Color)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        case .row(let entry, let endsDay):
                            // The list takes Tab once and the arrows move in it, so a row is no stop of its own.
                            GroveEarlierRow(entry: entry, isSelected: entry.id == selectedEntryID,
                                            showsFocus: showsFocus, isTabStop: false, hint: "Shows this dictation") {
                                onSelect(entry)
                            }
                            .equatable()
                            .id(entry.id)
                            .contextMenu { menu(entry) }
                            .accessibilityIdentifier("history.row.\(entry.id.uuidString)")
                            .padding(.bottom, endsDay ? 14 : 0)
                        }
                    }
                }
            }
            .onChange(of: selectedEntryID) { id in
                if let id { withAnimation(nil) { scroll.scrollTo(id) } }
            }
        }
    }
}

/// The reader: where a dictation went and when, the words large, four text actions, how it was
/// written, what was said around it, and the words before cleanup. It sits on the window's ground.
struct GroveHistoryReader: View {
    let entry: TranscriptEntry?
    var empty: Empty = .noSelection
    let query: String
    let around: [TranscriptEntry]
    @Binding var picksWord: Bool
    var whatHappenedRequest: Int
    var initialFix: FixWordState?
    var initialFixResult: FixWordResult?
    var initialBeforeCleanupExpanded = false
    var onCopy: (TranscriptEntry) -> Void = { _ in }
    var onFixWord: (TranscriptEntry) -> Void = { _ in }
    var onRerun: (TranscriptEntry) -> Void = { _ in }
    var onRestore: (TranscriptEntry) -> Void = { _ in }
    var onDelete: (TranscriptEntry) -> Void = { _ in }
    var onWhatHappened: (TranscriptEntry) -> Void = { _ in }
    var onSelect: (TranscriptEntry, Bool) -> Void = { _, _ in }

    @EnvironmentObject private var controller: DictationController
    @Environment(\.groveTheme) private var theme
    @State private var beforeCleanupExpanded = false
    @State private var showsAllWords = false
    /// The lines the words take without the limit.
    @State private var wrappedLines = 0
    @State private var didApplyInitialState = false

    private static let whatHappenedID = "history.whatHappened"

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let entry {
                        content(entry)
                    } else {
                        placeholder(title: empty.title, message: empty.message)
                    }
                }
                .grovePanelInset()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: whatHappenedRequest) { _ in
                withAnimation(nil) { scroll.scrollTo(Self.whatHappenedID, anchor: .center) }
            }
        }
        .onAppear {
            guard !didApplyInitialState else { return }
            didApplyInitialState = true
            beforeCleanupExpanded = initialBeforeCleanupExpanded
        }
        .onChange(of: entry?.id) { _ in
            beforeCleanupExpanded = false
            showsAllWords = false
        }
    }

    /// Why there is no dictation to read: none yet, none that match, or none chosen.
    enum Empty: Equatable {
        case noDictations
        case noMatches
        /// No dictation in the named filter.
        case noneInFilter(String)
        case noSelection

        var title: String {
            switch self {
            case .noDictations: "Nothing here yet"
            case .noMatches: "No dictations match"
            case .noneInFilter: "No dictations to show"
            case .noSelection: "Select a dictation"
            }
        }

        var message: String {
            switch self {
            case .noDictations: "Your dictations appear here as you make them."
            case .noMatches: "Try another word, or clear the search."
            case .noneInFilter(let filter): "None are in “\(filter)”."
            case .noSelection: "Read it, copy it, or see how it was written."
            }
        }
    }

    private func placeholder(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).groveFont(15, .semibold).foregroundStyle(theme.inkColor)
            Text(message).groveFont(13).foregroundStyle(theme.ink3Color)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func content(_ entry: TranscriptEntry) -> some View {
        GroveEntryMeta(entry: entry, size: 12, iconSize: 16, showsDay: true)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
        words(entry)
        notes(entry)
        actionRow(entry)
            .padding(.leading, -8)
            .padding(.bottom, 36)
        howItWasWritten(entry)
            .id(Self.whatHappenedID)
            .padding(.bottom, 32)
        if !around.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Around then")
                    .groveFont(12, .semibold)
                    .foregroundStyle(theme.ink3Color)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(around) { other in
                    GroveEarlierRow(entry: other, lines: 1, hint: "Shows this dictation") { onSelect(other, false) }
                        .equatable()
                        .padding(.horizontal, -10)
                }
            }
            .padding(.bottom, 24)
        }
        BeforeCleanupView(before: entry.rawText, after: entry.cleanText, isExpanded: $beforeCleanupExpanded)
    }

    /// The dictation at the hero sizes: 22 pt to 140 characters, 17 pt to 500, then 15 pt capped
    /// at 12 lines with "Show all". Still the flowing text, so selection and Fix a word work.
    @ViewBuilder
    private func words(_ entry: TranscriptEntry) -> some View {
        let text = entry.displayText
        let capped = GroveHero.lineLimit(for: text).map { wrappedLines > $0 } ?? false
        if !entry.hasWords {
            Text(entry.insertionStatus == .noSpeech ? "No speech detected" : "No text")
                .font(.system(size: 22))
                .foregroundStyle(theme.ink3Color)
                .padding(.bottom, 12)
        } else {
            FixableTranscriptEntry(
                entry: entry,
                highlights: HistoryRules.matchRanges(of: query, in: text),
                picksWord: $picksWord,
                accessibilityActions: actions(for: entry),
                initialFix: initialFix?.entryID == entry.id ? initialFix : nil,
                initialResult: initialFixResult?.entryID == entry.id ? initialFixResult : nil,
                fontSize: GroveHero.size(for: text))
                .environment(\.groveFlowLineLimit, showsAllWords ? nil : GroveHero.lineLimit(for: text))
                .onPreferenceChange(GroveFlowLinesKey.self) { wrappedLines = $0 }
                .id(entry.id)
                .padding(.bottom, capped ? 6 : 12)
            if capped {
                Button(showsAllWords ? "Show Fewer Words" : "Show All \(entry.wordCount) Words") { showsAllWords.toggle() }
                    .buttonStyle(.groveQuiet())
                    .groveFont(12)
                    .foregroundStyle(theme.ink2Color)
                    .padding(.bottom, 10)
            }
        }
    }

    /// Copy, Fix a Word, Clean Up Again and Delete as text. They wrap in a narrow reader rather
    /// than cutting their words short.
    private func actionRow(_ entry: TranscriptEntry) -> some View {
        GroveFlowLayout(spacing: 4, lineSpacing: 4) {
            if entry.hasWords {
                Button("Copy") { onCopy(entry) }
                    .buttonStyle(.groveText)
                    .accessibilityIdentifier("history.copy")
            }
            if entry.hasWords, WordFixers.current(for: controller).isAvailable {
                Button("Fix a Word") { onFixWord(entry) }
                    .buttonStyle(.groveText)
            }
            Button("Clean Up Again") { onRerun(entry) }
                .buttonStyle(.groveText)
                .help("Run cleanup again on the saved words with your current settings")
            Button("Delete") { onDelete(entry) }
                .buttonStyle(.groveText)
                .accessibilityHint("Asks before deleting")
        }
    }

    /// What to say beside the words when it did not end as a normal insert, or when cleanup ran
    /// again. Plain sentences with their action as a text button.
    @ViewBuilder
    private func notes(_ entry: TranscriptEntry) -> some View {
        if entry.insertionStatus == .failed {
            (Text("Not inserted.").fontWeight(.medium).foregroundColor(theme.cautionColor)
                + Text(" Copy it from here and paste it where you need it.").foregroundColor(theme.ink2Color))
                .groveFont(13)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
                .accessibilityElement(children: .combine)
        }
        if let original = entry.originalCleanText {
            let changes = CleanupDiff.changeCount(before: original, after: entry.cleanText)
            HStack(spacing: 6) {
                Text("Cleanup ran again with your current settings: \(changes == 1 ? "1 change" : "\(changes) changes").")
                    .groveFont(13)
                    .foregroundStyle(theme.ink2Color)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Restore Original Cleanup") { onRestore(entry) }
                    .buttonStyle(.groveText)
            }
            .padding(.bottom, 10)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func howItWasWritten(_ entry: TranscriptEntry) -> some View {
        if let record = DictationRecordBridge.record(for: entry),
           let model = GroveHowItWasWritten.Model.make(entry: entry, record: record, appName: AppNames.name(for: entry)) {
            GroveHowItWasWritten(model: model)
        } else {
            GroveHowItWasWrittenUnavailable()
        }
    }

    private func actions(for entry: TranscriptEntry) -> [TranscriptAccessibilityAction] {
        var actions = [TranscriptAccessibilityAction(name: "Copy") { onCopy(entry) }]
        if WordFixers.current(for: controller).isAvailable {
            actions.append(TranscriptAccessibilityAction(name: "Fix a Word", perform: { onFixWord(entry) }, startsFixWord: true))
        }
        actions.append(TranscriptAccessibilityAction(name: "How It Was Written") { onWhatHappened(entry) })
        actions.append(TranscriptAccessibilityAction(name: "Delete") { onDelete(entry) })
        return actions
    }
}

/// One line of History's list: a day's title, or a dictation. A dictation that ends its day
/// carries the space before the next title.
struct GroveHistoryListItem: Identifiable {
    enum ID: Hashable {
        case header(String)
        case row(UUID)
    }

    enum Kind {
        case header(String)
        case row(TranscriptEntry, endsDay: Bool)
    }

    let id: ID
    let kind: Kind
}

/// Remembers History's filtered list and its day groups. A redraw that changes neither the
/// dictations, the search nor the filter skips the text search over every dictation and the
/// regrouping, and hands the list the same group array so it can see nothing changed without
/// comparing a thousand dictations.
///
/// "Same dictations" means the same array buffer: the memo keeps its own reference to the
/// array it last saw, so the controller's array can only change by being copied.
@MainActor
final class GroveHistoryFilterMemo {
    private var source: [TranscriptEntry] = []
    private var query: String?
    private var filter: HistoryFilter = .all
    private var value: [TranscriptEntry] = []
    private var itemsDay: Date?
    private var listItems: [GroveHistoryListItem]?
    /// Counts the times the list was rebuilt, for a cheap "did the list change" check.
    private(set) var revision = 0

    func entries(_ entries: [TranscriptEntry], query: String, filter: HistoryFilter) -> [TranscriptEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.query == trimmed, self.filter == filter, entries.sharesBuffer(with: source) { return value }
        source = entries
        self.query = trimmed
        self.filter = filter
        value = filter == .all && trimmed.isEmpty ? entries : HistoryRules.entries(entries, matching: trimmed, filter: filter)
        listItems = nil
        revision += 1
        return value
    }

    /// The filtered list as a flat run of day titles and dictations, so the list can build only
    /// the rows on screen. The titles say "Today" and "Yesterday", so a new day rebuilds it.
    func items(_ entries: [TranscriptEntry], query: String, filter: HistoryFilter) -> [GroveHistoryListItem] {
        let filtered = self.entries(entries, query: query, filter: filter)
        let day = Calendar.current.startOfDay(for: Date())
        if let listItems, itemsDay == day { return listItems }
        var made: [GroveHistoryListItem] = []
        made.reserveCapacity(filtered.count + 64)
        for group in HistoryDayGroup.groups(filtered) {
            made.append(GroveHistoryListItem(id: .header(group.id), kind: .header(group.title)))
            for (index, entry) in group.entries.enumerated() {
                made.append(GroveHistoryListItem(id: .row(entry.id), kind: .row(entry, endsDay: index == group.entries.count - 1)))
            }
        }
        listItems = made
        itemsDay = day
        return made
    }
}

/// The dictations said around one, remembered while the dictations are the same array and the
/// same dictation is open.
@MainActor
final class GroveAroundThenMemo {
    private var source: [TranscriptEntry] = []
    private var selected: (id: UUID, createdAt: Date)?
    private var value: [TranscriptEntry] = []

    func around(_ entry: TranscriptEntry, in entries: [TranscriptEntry]) -> [TranscriptEntry] {
        if let selected, selected.id == entry.id, selected.createdAt == entry.createdAt, entries.sharesBuffer(with: source) {
            return value
        }
        source = entries
        selected = (entry.id, entry.createdAt)
        value = GroveRules.aroundThen(for: entry, in: entries)
        return value
    }
}
