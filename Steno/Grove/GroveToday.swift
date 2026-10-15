import StenoKit
import SwiftUI

/// A dictation row that is one button: hover tints it, keyboard focus rings only this row.
struct GroveRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12
    /// The row is the one open beside the list: a neutral fill, no bold and no accent.
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration, cornerRadius: cornerRadius, isSelected: isSelected)
    }

    private struct Rendered: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let isSelected: Bool
        @Environment(\.groveTheme) private var theme
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isSelected ? theme.rowSelectionColor : (configuration.isPressed ? theme.rowPressed : theme.ink.opacity(isHovered ? 0.04 : 0)).color)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onHover { isHovered = $0 }
        }
    }
}

/// The line under a dictation: the app's icon, "Mail · 10:24", and any exception as a coloured
/// word. "Inserted" is the normal case and is not said.
struct GroveEntryMeta: View {
    let entry: TranscriptEntry
    var size: CGFloat = 11
    var iconSize: CGFloat = 12
    /// Names the day before the time for a dictation that is not from today: a list groups by
    /// day, but a reader beside it does not.
    var showsDay = false
    @Environment(\.groveTheme) private var theme

    var body: some View {
        let chips = GroveRules.chips(for: entry).filter { $0.tone != .ok }
        HStack(spacing: 5) {
            GroveAppIcon(bundleID: entry.appBundleID, size: iconSize)
            // Only the app's name gives way in a narrow row: the time and the exceptions are what
            // tell dictations apart, and the reader beside the list names the app in full.
            HStack(spacing: 0) {
                Text(AppNames.name(for: entry))
                    .lineLimit(1)
                Text(" · \(Self.whenText(entry, showsDay: showsDay))")
                    .fixedSize()
                    .monospacedDigit()
                // The same " · " joins every part, so an exception sits as close as the time does.
                ForEach(chips) { chip in
                    Text(" · \(chip.text)")
                        .groveFont(size, chip.tone == .caution ? .medium : .regular)
                        .foregroundStyle(chip.tone == .caution ? theme.cautionColor : theme.ink3Color)
                        .fixedSize()
                }
            }
            .groveFont(size)
            .foregroundStyle(theme.ink3Color)
        }
    }
}

extension GroveEntryMeta {
    /// "10:24", or "Yesterday, 17:40", "Oct 5, 10:24" and, from another year, "Dec 31, 2025,
    /// 23:58" when `showsDay`.
    static func whenText(_ entry: TranscriptEntry, showsDay: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = TranscriptMargin.timeText(entry.createdAt, calendar: calendar)
        guard showsDay, !calendar.isDate(entry.createdAt, inSameDayAs: now) else { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(entry.createdAt, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        var day = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if calendar.component(.year, from: entry.createdAt) != calendar.component(.year, from: now) { day = day.year() }
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        return "\(entry.createdAt.formatted(day)), \(time)"
    }
}

/// A dictation in a list: the words first, then the meta line. No rule between rows. Today
/// shows it with two lines and opens History; History's list marks the open one, and "Around
/// then" shows it with one line.
struct GroveEarlierRow: View {
    let entry: TranscriptEntry
    var lines = 2
    var isSelected = false
    /// The list has the keyboard: the selected row shows the ring.
    var showsFocus = false
    /// Whether Tab stops on the row. A list with its own arrow keys takes Tab once instead.
    var isTabStop = true
    var hint = "Opens it in History"
    var onOpen: () -> Void = {}
    @Environment(\.groveTheme) private var theme

    var body: some View {
        let app = AppNames.name(for: entry)
        let time = TranscriptMargin.timeText(entry.createdAt)
        let chips = GroveRules.chips(for: entry)
        let preview = GrovePreviewText.make(entry.displayText)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.isEmpty ? "No speech detected" : preview)
                    .groveFont(13)
                    .lineSpacing(2)
                    .lineLimit(lines)
                    .foregroundStyle(theme.inkColor)
                    .groveTextDirection(rightToLeft: GrovePreviewText.isRightToLeft(preview))
                GroveEntryMeta(entry: entry)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .modifier(RowStyle(isSelected: isSelected, isTabStop: isTabStop))
        .groveFocusRing(isSelected && showsFocus, cornerRadius: 8)
        .accessibilityElement(children: .ignore)
        // The preview, not the whole dictation: a row is passed through, and the reader has the rest.
        .accessibilityLabel("\(preview.isEmpty ? "No speech detected" : preview), \(app), \(time)"
                            + (chips.isEmpty ? "" : ", " + chips.map(\.text).joined(separator: ", ")))
        .accessibilityHint(hint)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        // The row is one combined element, which hides the button inside it, so it carries the
        // button's action itself. Without it VoiceOver's press does nothing.
        .accessibilityAction { onOpen() }
    }
}

/// A Tab stop with its own ring, or, in a list that draws the ring itself, no stop at all.
private struct RowStyle: ViewModifier {
    let isSelected: Bool
    let isTabStop: Bool

    func body(content: Content) -> some View {
        let styled = content.buttonStyle(GroveRowButtonStyle(cornerRadius: 8, isSelected: isSelected))
        if isTabStop {
            styled.groveKeyboardFocus(cornerRadius: 8)
        } else {
            styled.focusable(false)
        }
    }
}

/// A row is redrawn only when something it shows changes, which is much less often than its
/// list is. The action is not compared: it only ever acts on the same dictation.
extension GroveEarlierRow: @preconcurrency Equatable {
    static func == (a: GroveEarlierRow, b: GroveEarlierRow) -> Bool {
        let x = a.entry, y = b.entry
        return a.lines == b.lines && a.isSelected == b.isSelected && a.showsFocus == b.showsFocus && a.hint == b.hint
            && a.isTabStop == b.isTabStop
            && x.id == y.id && x.createdAt == y.createdAt && x.appBundleID == y.appBundleID
            && x.insertionStatus == y.insertionStatus && x.pasteAttempted == y.pasteAttempted
            && x.cleanText == y.cleanText && x.rawText == y.rawText
            && x.record?.appName == y.record?.appName && x.record?.copyReason == y.record?.copyReason
            && (x.fixes ?? []).isEmpty == (y.fixes ?? []).isEmpty
    }
}

/// A borderless text action: secondary ink, a soft fill on hover.
struct GroveTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration)
    }

    private struct Rendered: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.groveTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityShowButtonShapes) private var showShapes
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            configuration.label
                .groveFont(13)
                .foregroundStyle(isHovered ? theme.inkColor : theme.ink2Color)
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .background(shape.fill(theme.ink.opacity(configuration.isPressed ? 0.1 : isHovered || showShapes ? 0.06 : 0).color))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }
    }
}

extension PrimitiveButtonStyle where Self == GroveFocusedButtonStyle<GroveTextButtonStyle> {
    static var groveText: Self { GroveFocusedButtonStyle(look: GroveTextButtonStyle(), cornerRadius: 6) }
}

/// Dictation text sizes: large for a sentence or two, smaller as it grows.
enum GroveHero {
    static func size(for text: String) -> CGFloat {
        text.count <= 140 ? 22 : text.count <= 500 ? 17 : 15
    }

    /// Long dictations stop after this many lines until "Show all" is chosen.
    static func lineLimit(for text: String) -> Int? {
        text.count > 500 ? 12 : nil
    }
}

/// The latest dictation, uncarded: where it went and when, the words, and three text actions.
struct GroveLatestCard: View {
    let entry: TranscriptEntry
    @Binding var picksWord: Bool
    var canFix: Bool
    var accessibilityActions: [TranscriptAccessibilityAction] = []
    var initialFix: FixWordState?
    var onCopy: () -> Void = {}
    var onWhatHappened: () -> Void = {}
    @Environment(\.groveTheme) private var theme
    /// A long dictation stops at the hero's line limit, as in History, so the rest of the day
    /// stays in view; "Show all" opens it here.
    @State private var showsAllWords = false
    /// The lines the words take without the limit.
    @State private var wrappedLines = 0

    var body: some View {
        let lineLimit = GroveHero.lineLimit(for: entry.displayText)
        let isCut = lineLimit.map { wrappedLines > $0 } ?? false
        VStack(alignment: .leading, spacing: 0) {
            // Today's page is headed with today's date, so a latest dictation from another day
            // names its day.
            GroveEntryMeta(entry: entry, size: 12, iconSize: 16, showsDay: true)
                .padding(.bottom, 10)
            FixableTranscriptEntry(
                entry: entry, picksWord: $picksWord, accessibilityActions: accessibilityActions,
                initialFix: initialFix, fontSize: GroveHero.size(for: entry.displayText))
                .environment(\.groveFlowLineLimit, showsAllWords ? nil : lineLimit)
                .onPreferenceChange(GroveFlowLinesKey.self) { wrappedLines = $0 }
                .padding(.bottom, isCut ? 6 : 8)
            if isCut {
                Button(showsAllWords ? "Show Fewer Words" : "Show All \(entry.wordCount) Words") { showsAllWords.toggle() }
                    .buttonStyle(.groveQuiet())
                    .groveFont(12)
                    .foregroundStyle(theme.ink2Color)
                    .padding(.bottom, 8)
            }
            HStack(spacing: 4) {
                if entry.hasWords {
                    Button("Copy", action: onCopy)
                        .buttonStyle(.groveText)
                        .accessibilityIdentifier("today.copy")
                }
                if canFix, entry.hasWords {
                    Button("Fix a Word") { picksWord.toggle() }
                        .buttonStyle(.groveText)
                }
                Button("How It Was Written", action: onWhatHappened)
                    .buttonStyle(.groveText)
                    .help("Open the steps and timings in History")
            }
            .padding(.leading, -8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Latest dictation")
    }
}

/// Today when nothing has been dictated yet: a small quiet quill over one quiet line.
struct GroveTodayEmpty: View {
    @Environment(\.groveTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroveQuill(colors: .quiet(theme))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text("Nothing dictated yet. Each dictation is saved in History on this Mac.")
                .groveFont(13)
                .foregroundStyle(theme.ink3Color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Today in the Grove window.
struct GroveTodayView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.groveTheme) private var theme
    @Environment(\.groveFeedback) private var feedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var flow: GroveTodayFlow
    var onOpenHistory: (UUID?, Bool) -> Void = { _, _ in }
    /// Starts with Fix a word open on the latest dictation, for render tests.
    var initialFix: FixWordState?
    /// Starts as if the current recording began from this window, for render tests.
    var initialStartedHere = false

    /// Today's lists, kept until the dictations or the hold change: the body runs about four
    /// times a second while recording, and sorting a thousand dictations by day each time is
    /// most of what it did.
    @State private var rowsMemo = GroveTodayRowsMemo()
    @State private var haloSource = GroveHaloSource()
    @State private var levelToken: UUID?
    @State private var picksWordInLatest = false

    init(flow: GroveTodayFlow = GroveTodayFlow(), onOpenHistory: @escaping (UUID?, Bool) -> Void = { _, _ in },
         initialFix: FixWordState? = nil, initialStartedHere: Bool = false) {
        _flow = StateObject(wrappedValue: flow)
        self.onOpenHistory = onOpenHistory
        self.initialFix = initialFix
        self.initialStartedHere = initialStartedHere
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                    .zIndex(1)
                dayPage
            }
            .groveColumn(theme)
            .animation(phaseAnimation, value: flow.phase)
        }
        .background(theme.pageGroundColor)
        .dictationCommands(commandActions)
        .onAppear {
            if levelToken == nil {
                let halo = haloSource
                levelToken = controller.inputLevels.add { level in
                    halo.send(level)
                }
            }
            pushLifecycle()
        }
        .onDisappear {
            if let levelToken { controller.inputLevels.remove(levelToken) }
            levelToken = nil
        }
        .onChange(of: controller.recordingLifecycleState) { state in
            pushLifecycle()
        }
        .onChange(of: controller.recentEntries.first?.id) { _ in
            // Fix a Word is armed for the dictation it was started on, not the next one.
            picksWordInLatest = false
            guard let latest = controller.recentEntries.first else { return }
            flow.latestEntry(latest, appName: AppNames.name(for: latest))
        }
        .onChange(of: flow.phase.isRecordingOrFinishing) { isUp in
            if isUp { picksWordInLatest = false }
        }
        .onChange(of: controller.canUndoDiscard) { flow.canUndoDiscardChanged($0) }
    }

    /// Only leaving the stage moves: the plate folds into the card, or a problem note takes its
    /// place. Starting a dictation and the plate's own changes (listening, transcribing, the
    /// result) are instant, as the island is: they answer a key press many times a day.
    private var phaseAnimation: Animation? { Self.animation(arrivingAt: flow.phase, reduceMotion: reduceMotion) }

    /// The plate folds into the card with a 0.35 s spring and no bounce; under Reduce Motion it
    /// is a 150 ms cross-fade.
    static func animation(arrivingAt phase: GroveTodayPhase, reduceMotion: Bool) -> Animation? {
        guard !phase.isRecordingOrFinishing else { return nil }
        return reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1)
    }

    /// ⌘E and ⌘I act on the latest dictation's card, while it is shown. The keys can keep the
    /// actions of an earlier draw, so ⌘I finds the card's dictation when it runs.
    private var commandActions: DictationCommandActions {
        guard let latest = latestCardEntry else { return DictationCommandActions() }
        return DictationCommandActions(
            fixWord: canFix && latest.hasWords ? { picksWordInLatest = true } : nil,
            howItWasWritten: { if let latest = latestCardEntry { onOpenHistory(latest.id, true) } })
    }

    /// The dictation on the latest card, while the card is shown.
    private var latestCardEntry: TranscriptEntry? {
        guard !flow.phase.isRecordingOrFinishing else { return nil }
        return rowsMemo.rows(controller.recentEntries, holding: flow.isHoldingNewEntries,
                             baseline: flow.baselineLatestID).visible.first
    }

    private func pushLifecycle() {
        flow.lifecycle(controller.recordingLifecycleState,
                       latestID: controller.recentEntries.first?.id,
                       canUndoDiscard: controller.canUndoDiscard,
                       hint: .from(status: controller.status))
    }

    // MARK: Hero

    private var status: TodayStatus {
        TodayStatus.derive(lifecycle: controller.recordingLifecycleState,
                           microphone: controller.microphonePermissionStatus,
                           recordingStartedAt: controller.recordingStartedAt,
                           startedHere: startedHere)
    }

    @ViewBuilder
    private var hero: some View {
        switch flow.phase {
        case .idle:
            GroveTodayHeader(
                status: status, shortcuts: TodayShortcuts(controller.preferences.hotkeys, inputMonitoring: controller.inputMonitoringPermissionStatus),
                microphoneName: TodayMicrophone.current(for: controller)?.name,
                onStart: { controller.startDictationFromWindow() },
                onOpenMicrophoneSettings: { controller.openMicrophoneSettings() },
                onOpenRecordingSettings: { SettingsRouter.shared.open(.recording) })
                .transition(.opacity)
        case .listening, .transcribing, .settled:
            plate
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))))
        case .problem(let problem):
            GroveProblemNote(problem: problem, onAction: { perform(problem) }, onDismiss: { flow.dismissProblem() })
                .transition(.opacity)
        }
    }

    private var plate: some View {
        GroveLivePlateWords(feed: controller.liveWordsFeed, listening: flow.phase == .listening) { words in
            GroveRecordingPlate(
                mode: plateMode,
                targetApp: controller.recordingTargetAppName,
                startedHere: startedHere,
                stableWords: words.stable,
                tailWords: words.tail,
                haloSource: haloSource,
                onStop: { controller.stopRecording() },
                onDiscard: { controller.cancelActiveRecording() },
                onCancel: { controller.cancelActiveRecording() })
        }
    }

    private var plateMode: GroveRecordingPlate.Mode {
        switch flow.phase {
        case .listening: .listening(startedAt: controller.recordingStartedAt)
        case .settled(let outcome): .settled(outcome)
        default: .transcribing
        }
    }

    static let rowLimit = 12

    /// Whether the recording in progress began from the window, so its words are copied.
    private var startedHere: Bool { initialStartedHere || controller.dictationStartedInWindow }

    private func perform(_ problem: GroveProblem) {
        switch problem.action {
        case .copy:
            if let id = problem.entryID, let entry = controller.recentEntries.first(where: { $0.id == id }) {
                copy(entry)
            }
        case .undoDiscard: controller.undoDiscard()
        case .none: break
        }
        flow.noteActed()
    }

    // MARK: Page

    private var canFix: Bool { WordFixers.current(for: controller).isAvailable }

    /// The day on a bordered page: the date and counts, then the dictations.
    private var dayPage: some View {
        let lists = rowsMemo.rows(controller.recentEntries, holding: flow.isHoldingNewEntries, baseline: flow.baselineLatestID)
        let todays = lists.today
        let words = lists.todayWords
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .groveFont(15, .semibold)
                    .foregroundStyle(theme.inkColor)
                    .accessibilityAddTraits(.isHeader)
                if !todays.isEmpty {
                    Text("\(InsightsFormatting.count(todays.count, "dictation")) · \(InsightsFormatting.count(words, "word"))")
                        .groveFont(12)
                        .monospacedDigit()
                        .foregroundStyle(theme.ink3Color)
                }
                Spacer(minLength: 8)
                // Nothing to show before the first dictation.
                if !controller.recentEntries.isEmpty {
                    Button("Show in History") { onOpenHistory(nil, false) }
                        .buttonStyle(.groveText)
                        .padding(.trailing, -8)
                }
            }
            page
        }
        .grovePanelInset()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.panelBackground())
    }

    @ViewBuilder
    private var page: some View {
        let lists = rowsMemo.rows(controller.recentEntries, holding: flow.isHoldingNewEntries, baseline: flow.baselineLatestID)
        if flow.phase.isRecordingOrFinishing {
            // While the stage is up, the latest dictation waits in the list so nothing jumps;
            // when the new one lands it takes the hero place.
            rows(lists.today, title: nil)
        } else if let latest = lists.visible.first {
            GroveLatestCard(
                entry: latest, picksWord: $picksWordInLatest, canFix: canFix,
                accessibilityActions: actions(for: latest),
                initialFix: initialFix?.entryID == latest.id ? initialFix : nil,
                onCopy: { copy(latest) },
                onWhatHappened: { onOpenHistory(latest.id, true) })
                .id(latest.id)
                .zIndex(2)
                .transition(.asymmetric(
                    insertion: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                    removal: .opacity))
            rows(lists.earlierToday, title: "Earlier today")
        } else {
            GroveTodayEmpty()
        }
    }

    @ViewBuilder
    private func rows(_ earlier: [TranscriptEntry], title: String?) -> some View {
            if !earlier.isEmpty {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Text(title)
                            .groveFont(12, .semibold)
                            .foregroundStyle(theme.ink3Color)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.bottom, 4)
                    }
                    // Today is a glance; History holds the rest. A short list also keeps every
                    // update while recording cheap.
                    ForEach(earlier.prefix(Self.rowLimit)) { entry in
                        GroveEarlierRow(entry: entry) { onOpenHistory(entry.id, false) }
                            .equatable()
                            .contextMenu { contextMenu(for: entry) }
                            .padding(.horizontal, -10)
                    }
                    if earlier.count > Self.rowLimit {
                        // Opens History on the first dictation left out, so the list picks up there.
                        let firstLeftOut = earlier[Self.rowLimit]
                        Button("\((earlier.count - Self.rowLimit).formatted()) more in History") { onOpenHistory(firstLeftOut.id, false) }
                            .buttonStyle(.groveText)
                            .help("Opens the rest of today in History")
                            .padding(.leading, -8)
                            .padding(.top, 6)
                    }
                }
                // Room above the "Earlier today" title; without a title the rows follow the date.
                .padding(.top, title == nil ? 0 : 8)
            }
    }

    private func copy(_ entry: TranscriptEntry) {
        controller.pasteEntry(entry) { copied in
            if copied { feedback?.post("Copied to the clipboard", systemImage: "doc.on.doc") }
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: TranscriptEntry) -> some View {
        if entry.hasWords {
            Button("Copy") { copy(entry) }
        }
        Button("How It Was Written") { onOpenHistory(entry.id, true) }
        Divider()
        Button("Show in History") { onOpenHistory(entry.id, false) }
    }

    private func actions(for entry: TranscriptEntry) -> [TranscriptAccessibilityAction] {
        var actions: [TranscriptAccessibilityAction] = []
        if entry.hasWords {
            actions.append(TranscriptAccessibilityAction(name: "Copy") { copy(entry) })
        }
        if canFix, entry.hasWords {
            actions.append(TranscriptAccessibilityAction(name: "Fix a Word", perform: { picksWordInLatest = true }, startsFixWord: true))
        }
        actions.append(TranscriptAccessibilityAction(name: "How It Was Written") { onOpenHistory(entry.id, true) })
        actions.append(TranscriptAccessibilityAction(name: "Show in History") { onOpenHistory(entry.id, false) })
        return actions
    }
}

/// Today's three lists for one set of dictations: what is visible (the dictations, less any
/// that arrived while the stage is up), those from today, and those from today after the
/// latest. Remembered while the dictations are the same array, the hold is the same and the
/// day has not changed.
@MainActor
final class GroveTodayRowsMemo {
    struct Lists {
        var visible: [TranscriptEntry]
        var today: [TranscriptEntry]
        var earlierToday: [TranscriptEntry]
        var todayWords: Int
    }

    private var source: [TranscriptEntry] = []
    private var holding = false
    private var baseline: UUID?
    private var day: Date?
    private var lists = Lists(visible: [], today: [], earlierToday: [], todayWords: 0)

    func rows(_ entries: [TranscriptEntry], holding: Bool, baseline: UUID?) -> Lists {
        let today = Calendar.current.startOfDay(for: Date())
        if day == today, self.holding == holding, self.baseline == baseline, entries.sharesBuffer(with: source) { return lists }
        source = entries
        self.holding = holding
        self.baseline = baseline
        day = today
        let visible: [TranscriptEntry]
        if !holding {
            visible = entries
        } else if let baseline {
            visible = entries.firstIndex(where: { $0.id == baseline }).map { Array(entries[$0...]) } ?? entries
        } else {
            visible = []
        }
        let todays = TodayEntries.todays(visible)
        let words = todays.reduce(0) { $0 + $1.wordCount }
        lists = Lists(visible: visible, today: todays, earlierToday: TodayEntries.earlierToday(visible), todayWords: words)
        return lists
    }
}

/// Hands the recording plate the live words. It alone observes them, so an update redraws the
/// plate and not Today or the window around it. A dictation's last words stay while it is
/// transcribed and settles; each new dictation starts without them.
private struct GroveLivePlateWords<Content: View>: View {
    @ObservedObject var feed: LiveWordsFeed
    let listening: Bool
    @ViewBuilder let content: (DictationController.LiveWords) -> Content
    @State private var lastWords = Self.none

    private static var none: DictationController.LiveWords { .init(stable: "", tail: "") }

    var body: some View {
        content(feed.words ?? lastWords)
            .onAppear { lastWords = feed.words ?? (listening ? Self.none : lastWords) }
            .onChange(of: listening) { if $0 { lastWords = feed.words ?? Self.none } }
            .onChange(of: feed.words) { words in
                if let words { lastWords = words }
            }
    }
}
