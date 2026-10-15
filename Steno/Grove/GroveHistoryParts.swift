import AppKit
import StenoKit
import SwiftUI

// MARK: - Search

/// The search field on top of History's list: a quiet well in ink at 5%, a magnifier and the
/// word "Search". The magnifier opens the filter and the rest of History's actions, as the
/// magnifier of a macOS search field does; a filter that is on is named at the field's edge so
/// the list is never filtered without saying so.
struct GroveSearchField: View {
    @Binding var text: String
    @Binding var filter: HistoryFilter
    var prompt = "Search dictations"
    var focus: FocusState<Bool>.Binding
    var onDeleteAll: () -> Void = {}
    @Environment(\.groveTheme) private var theme
    /// Which options menu has the keyboard focus, so its label draws the ring.
    @State private var focusedMenu: String?

    var body: some View {
        HStack(spacing: 6) {
            magnifierMenu
            field
            if !text.isEmpty { clearButton }
            if filter != .all { filterMenu }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.quietFieldColor))
        .groveFocusRing(focus.wrappedValue, cornerRadius: 8)
    }

    private var magnifierMenu: some View {
        optionsMenu(identifier: "history.more") {
            // The size, box and place the borderless menu drew it in, so nothing moves.
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(theme.ink3Color)
                .frame(width: 22, height: 19)
                .offset(x: -0.5)
        }
        .padding(.horizontal, -4)
    }

    private var filterMenu: some View {
        optionsMenu(identifier: "history.filter") {
            // As the borderless menu drew it: 13 pt in the tint, 3.5 pt in from its edges.
            Text(filter.menuTitle)
                .groveFont(13)
                .foregroundStyle(theme.ink3Color)
                .lineLimit(1)
                .padding(.horizontal, 3.5)
                .frame(height: 20)
        }
    }

    private var field: some View {
        TextField("Search", text: $text)
            .textFieldStyle(.plain)
            .groveFont(13)
            .foregroundStyle(theme.inkColor)
            .focused(focus)
            .accessibilityLabel(prompt)
    }

    private var clearButton: some View {
        Button { text = "" } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.ink3Color)
                // A 24 pt target around the 12 pt mark; the outer padding gives the room back.
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.groveQuiet(cornerRadius: 12))
        .padding(.horizontal, -6)
        .help("Clear search")
        .accessibilityLabel("Clear search")
    }

    /// SwiftUI draws the label; a clear pull-down laid over it takes the click, at least 24 pt each
    /// way, without moving anything drawn. A SwiftUI borderless menu sizes its button to the glyph
    /// whatever the label's frame, which left a target 15 pt tall.
    private func optionsMenu<Content: View>(identifier: String, @ViewBuilder label: () -> Content) -> some View {
        label()
            .fixedSize()
            .accessibilityHidden(true)
            .groveFocusRing(focusedMenu == identifier, cornerRadius: 6)
            .overlay {
                GroveHistoryOptionsMenu(filter: filter, onSelect: { filter = $0 }, onDeleteAll: onDeleteAll) { focused in
                    if focused { focusedMenu = identifier } else if focusedMenu == identifier { focusedMenu = nil }
                }
                .frame(minWidth: 24, minHeight: 24)
                .help("Filter dictations or delete History")
                .accessibilityIdentifier(identifier)
            }
    }
}

/// The filters and Delete All History, as a clear pull-down over the magnifier or the filter's
/// name. AppKit gives it the keyboard focus only from the keyboard, and it says so, so the words
/// under it can draw the ring.
private struct GroveHistoryOptionsMenu: NSViewRepresentable {
    let filter: HistoryFilter
    let onSelect: (HistoryFilter) -> Void
    let onDeleteAll: () -> Void
    let onFocusChange: (Bool) -> Void

    final class Coordinator: NSObject {
        var onSelect: (HistoryFilter) -> Void = { _ in }
        var onDeleteAll: () -> Void = {}

        @objc func choose(_ item: NSMenuItem) {
            if let filter = (item.representedObject as? String).flatMap(HistoryFilter.init(rawValue:)) { onSelect(filter) }
        }

        @objc func deleteAll(_ item: NSMenuItem) { onDeleteAll() }
    }

    /// Reads to VoiceOver as History options with the filter that is on.
    final class PullDown: NSPopUpButton {
        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
        }

        var spokenValue: String {
            get { (cell as? Cell)?.spokenValue ?? "" }
            set { (cell as? Cell)?.spokenValue = newValue }
        }
        var onFocusChange: (Bool) -> Void = { _ in }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocusChange(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { onFocusChange(false) }
            return resigned
        }
        override func accessibilityValue() -> Any? { spokenValue }
        override func accessibilityLabel() -> String? { "History options" }
    }

    final class Cell: NSPopUpButtonCell {
        var spokenValue = ""
        override func accessibilityValue() -> Any? { spokenValue }
        override func accessibilityLabel() -> String? { "History options" }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PullDown {
        let button = PullDown(frame: .zero, pullsDown: true)
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        // Drawn clear: the label under it is SwiftUI's. A clear view still takes the click.
        button.alphaValue = 0
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            button.setContentHuggingPriority(.defaultLow, for: axis)
            button.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: PullDown, context: Context) {
        configure(button, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PullDown, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func configure(_ button: PullDown, coordinator: Coordinator) {
        coordinator.onSelect = onSelect
        coordinator.onDeleteAll = onDeleteAll
        let menu = NSMenu()
        // A pull-down's first item is its title, never chosen.
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        for item in HistoryFilter.allCases {
            let menuItem = NSMenuItem(title: item.menuTitle, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
            menuItem.target = coordinator
            menuItem.representedObject = item.rawValue
            menuItem.state = item == filter ? .on : .off
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let deleteAll = NSMenuItem(title: "Delete All History…", action: #selector(Coordinator.deleteAll(_:)), keyEquivalent: "")
        deleteAll.target = coordinator
        menu.addItem(deleteAll)
        button.menu = menu
        button.spokenValue = filter.menuTitle
        button.onFocusChange = onFocusChange
    }
}

// MARK: - How it was written

/// One sentence on how long it took after you let go, then the steps that took the time as small
/// columns. No bar: the numbers are the whole story.
struct GroveHowItWasWritten: View {
    struct Step: Equatable, Identifiable {
        var name: String
        var time: String
        var detail: String
        var id: String { name }
    }

    struct Model: Equatable {
        /// "Written", "Copied" or "Transcribed": what was done by the time the text was ready.
        var verb: String
        /// The time after release, such as "0.9 s", when the record kept the timings for it.
        var afterRelease: String?
        var steps: [Step]

        /// Nil when the record holds no timed step, which reads as a dictation saved before
        /// step records existed.
        static func make(entry: TranscriptEntry, record: DictationRecord, appName: String) -> Model? {
            let summary = WhatHappenedSummary.make(entry: entry, record: record, appName: appName)
            guard !summary.rows.isEmpty else { return nil }
            return Model(verb: verb(for: record), afterRelease: afterReleaseText(record), steps: steps(for: summary, record: record))
        }

        /// The steps in the order recorded: heard, transcribed, cleaned up, then what became of
        /// the text. Each is present only when it was timed.
        static func steps(for summary: WhatHappenedSummary, record: DictationRecord) -> [Step] {
            summary.rows.map { row in
                switch row.step {
                case "Recorded":
                    Step(name: "Heard", time: time(record.recordingMS, row), detail: record.microphoneName ?? "")
                case "Transcribed":
                    Step(name: row.step, time: time(record.transcriptionMS, row), detail: capitalizingFirst(row.detail))
                case "Cleaned up":
                    Step(name: row.step, time: time(record.cleanupMS, row), detail: cleanupDetail(record))
                default:
                    Step(name: row.step, time: time(record.insertionMS, row), detail: capitalizingFirst(row.detail))
                }
            }
        }

        /// A step's time by this section's rule, from the record's milliseconds.
        private static func time(_ milliseconds: Int?, _ row: WhatHappenedSummary.Row) -> String {
            milliseconds.map(timeText) ?? row.time
        }

        /// What the person waited for: transcription, cleanup and insertion, added up. A record
        /// that kept only the total uses that.
        static func millisecondsAfterRelease(_ record: DictationRecord) -> Int? {
            let parts = [record.transcriptionMS, record.cleanupMS, record.insertionMS].compactMap { $0 }
            if !parts.isEmpty { return parts.reduce(0, +) }
            return record.endToEndMS
        }

        /// "0.9 s", "12.4 s", "4 min 1 s", or "under 0.1 s".
        static func afterReleaseText(_ record: DictationRecord) -> String? {
            millisecondsAfterRelease(record).map(timeText)
        }

        /// Every duration in this section: seconds with one decimal under a minute, whole minutes
        /// and seconds from a minute on, and "under 0.1 s" for what would read as 0.0 s.
        static func timeText(_ milliseconds: Int) -> String {
            if milliseconds < 100 { return "under 0.1 s" }
            let tenths = (Double(milliseconds) / 100).rounded()
            if tenths < 600 { return String(format: "%.1f s", tenths / 10) }
            let total = Int((Double(milliseconds) / 1_000).rounded())
            let minutes = total / 60, seconds = total % 60
            return seconds == 0 ? "\(minutes) min" : "\(minutes) min \(seconds) s"
        }

        static func verb(for record: DictationRecord) -> String {
            switch record.outcome ?? record.insertionMethod {
            case "copied": "Copied"
            case "failed", DictationRecord.notPastedOutcome: "Transcribed"
            default: "Written"
            }
        }

        /// "Removed “um”", "Removed “um”, added a period", "3 changes", or "Not compared" when the
        /// texts were too long to compare. A count is the number of changes cleanup made, from
        /// the record's total when the list kept only the first of them.
        static func cleanupDetail(_ record: DictationRecord) -> String {
            if record.cleanupComparisonSkipped == true { return "Not compared" }
            let changes = record.cleanupChanges ?? []
            guard !changes.isEmpty else { return "No changes" }
            let total = max(changes.count, record.cleanupChangeCount ?? 0)
            guard total <= 2 else { return "\(total) changes" }
            // The summary names up to three changes after a count: keep just the named part.
            let named = WhatHappenedSummary.cleanupDetail(changes)
            let words = named.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
            return capitalizingFirst(words)
        }

        static func capitalizingFirst(_ text: String) -> String {
            text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    let model: Model
    @Environment(\.groveTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How it was written")
                .groveFont(12, .semibold)
                .foregroundStyle(theme.ink3Color)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            if let after = model.afterRelease {
                (Text("\(model.verb) ").foregroundColor(theme.ink2Color)
                    + Text(after).fontWeight(.medium).foregroundColor(theme.inkColor)
                    + Text(" after you stopped, all on this Mac.").foregroundColor(theme.ink2Color))
                    .groveFont(13)
                    .padding(.bottom, 10)
            }
            GroveFlowLayout(spacing: 22, lineSpacing: 12, alignsTops: true) {
                ForEach(model.steps) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.name)
                            .groveFont(11)
                            .foregroundStyle(theme.ink3Color)
                        Text(step.time)
                            .groveFont(13, .medium)
                            .monospacedDigit()
                            .foregroundStyle(theme.inkColor)
                        if !step.detail.isEmpty {
                            GroveCappedWidth(maxWidth: 170) {
                                Text(step.detail)
                                    .groveFont(11)
                                    .foregroundStyle(theme.ink3Color)
                                    .lineLimit(2)
                            }
                            .help(step.detail)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(step.name), \(step.time)" + (step.detail.isEmpty ? "" : ", \(step.detail)"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How it was written")
    }
}

/// Its content at its own width up to `maxWidth`, and wrapped to that width beyond it. A flow
/// layout asks for ideal sizes, which would otherwise keep a long detail on one cut-off line.
struct GroveCappedWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified).width
        let width = min(ideal, maxWidth, proposal.width ?? .infinity)
        return content.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// For dictations saved before step details were kept.
struct GroveHowItWasWrittenUnavailable: View {
    @Environment(\.groveTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it was written")
                .groveFont(12, .semibold)
                .foregroundStyle(theme.ink3Color)
                .accessibilityAddTraits(.isHeader)
            Text("Steno didn’t record the steps for this older dictation.")
                .groveFont(13)
                .foregroundStyle(theme.ink2Color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
