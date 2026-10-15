import AppKit
import StenoKit
import SwiftUI

/// A dictation with the Fix a word flow: pick a word, correct it in an anchored popover, then a
/// note with Copy Corrected Text and Undo. Shared by Today and History.
struct FixableTranscriptEntry: View {
    let entry: TranscriptEntry
    var highlights: [NSRange] = []
    /// Set by the Fix a word button: the next word selected in the text opens the form.
    @Binding var picksWord: Bool
    var accessibilityActions: [TranscriptAccessibilityAction] = []
    /// Starts with the form open, for previews and render tests.
    var initialFix: FixWordState?
    var initialResult: FixWordResult?
    /// The text flows in the system font at this size on a line 1.5 times it.
    var fontSize: CGFloat

    @EnvironmentObject private var controller: DictationController
    @Environment(\.groveTheme) private var groveTheme
    @Environment(\.groveFeedback) private var feedback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var flowWidth: CGFloat = 560
    @State private var fix: FixWordState?
    @State private var isFormShown = false
    @State private var result: FixWordResult?
    @State private var commonWord: String?
    /// Why the Everywhere option could not apply, shown in the form.
    @State private var scopeNote: String?
    /// After Undo of an Everywhere fix: the word correction it added stays.
    @State private var undoNote: String?
    /// The words to choose from, while the form was opened from the list rather than from a
    /// clicked word.
    @State private var wordChoices: [FixWordChoice] = []
    @State private var didApplyInitialState = false
    /// A fix or an undo is on its way to History. A second press waits for it: both would be
    /// worked out against the same text.
    @State private var isWorking = false
    /// How many fixes the dictation had after the fix this note reports, which Undo is for.
    @State private var appliedFixCount: Int?

    /// The words flow to the card's width, and the form, the result and the common-word question
    /// use Grove's materials.
    var body: some View {
        let size = fontSize
        let text = entry.displayText
        let metrics = GroveFlowText.metrics(size: size, width: flowWidth, dynamicTypeSize: dynamicTypeSize)
        let located = fix.flatMap { TranscriptLineCounter.locate($0.range, in: GroveFlowText.displayText(text), metrics: metrics) }
        let isEmpty = !entry.hasWords
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if isEmpty {
                    Text(entry.insertionStatus == .noSpeech ? "No speech detected" : "No text")
                        .groveFont(size)
                        .foregroundStyle(groveTheme.ink3Color)
                } else {
                    GroveFlowText(text: text, size: size, marks: marks(in: text), picksWord: picksWord,
                                  onPickWord: { range in begin(range: range) },
                                  concealsCopy: entry.concealedCopy == true, width: $flowWidth)
                        .overlay(alignment: .topLeading) { flowCaret(metrics: metrics, text: text) }
                }
            }
            .modifier(FixWordPopover(anchor: located?.rect, inlineMinimumX: 0, isPresented: $isFormShown) {
                GroveFixWordForm(state: Binding(get: { fix ?? placeholder }, set: { fix = $0 }), note: scopeNote,
                                 choices: wordChoices, isBusy: isWorking,
                                 scopes: FixWordState.Scope.offered(for: entry), onCancel: cancel,
                                 onFix: { apply(confirmed: false) })
                    .environment(\.groveTheme, groveTheme)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppNames.name(for: entry))
            .accessibilityValue(isEmpty ? (entry.insertionStatus == .noSpeech ? "No speech detected" : "No text") : text)
            // Without a role, other apps see an element of unknown kind with no value.
            .accessibilityAddTraits(.isStaticText)
            .modifier(FixableEntryAccessibilityActions(actions: flowingActions(isEmpty: isEmpty)))
            if picksWord && !isFormShown {
                HStack(spacing: 8) {
                    Text("Select a word in the text to fix it.")
                        .groveFont(12.5)
                        .foregroundStyle(groveTheme.ink2Color)
                    // The way in without a pointer: Tab reaches it, and the list holds every word.
                    Button("Choose from a List…", action: chooseFromList)
                        .buttonStyle(.groveText)
                }
            }
            if let result, result.entryID == entry.id {
                GroveNote(systemImage: "checkmark", tint: groveTheme.accentColor, wash: groveTheme.accent.opacity(0.10).color,
                          text: result.message) {
                    Button(action: copyCorrected) { Label("Copy Corrected Text", systemImage: "doc.on.doc") }
                        .buttonStyle(.grove(.primary, .small))
                    Button("Undo", action: undo)
                        .buttonStyle(.grove(.ghost, .small))
                        .disabled(isWorking)
                }
            } else if let undoNote {
                Text(undoNote)
                    .groveFont(12.5)
                    .foregroundStyle(groveTheme.ink2Color)
            }
        }
        .zIndex(isFormShown ? 1 : 0)
        .onAppear(perform: applyInitialState)
        .onChange(of: isFormShown) { shown in
            if !shown, result == nil, commonWord == nil { fix = nil }
            if !shown { wordChoices = [] }
        }
        .onChange(of: fix?.range.location) { _ in
            // A note on why the last word could be fixed only here says nothing about the next.
            if !wordChoices.isEmpty { scopeNote = nil }
        }
        .onChange(of: commonWord) { word in
            guard let word, let feedback else { return }
            feedback.confirm(title: Self.commonWordTitle(word), message: "", confirmTitle: Self.commonWordConfirmTitle,
                             isDestructive: false, onConfirm: { apply(confirmed: true) },
                             onCancel: cancelCommonWord)
        }
    }

    @ViewBuilder
    private func flowCaret(metrics: TranscriptMetrics, text: String) -> some View {
        if isFormShown, let range = fix?.range, let located = TranscriptLineCounter.locate(range, in: text, metrics: metrics) {
            Text("‸")
                .font(.system(size: 14 * metrics.scale, weight: .semibold))
                .foregroundStyle(groveTheme.accentColor)
                .position(x: located.rect.midX, y: located.rect.maxY + 2)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    private func marks(in text: String) -> TranscriptTextMarks {
        TranscriptTextMarks(
            highlights: highlights,
            strike: isFormShown ? fix?.range : nil,
            fixed: FixWordState.fixedRanges(for: DictationRecordBridge.fixes(for: entry), in: text)
        )
    }

    private var placeholder: FixWordState {
        FixWordState(entryID: entry.id, range: NSRange(location: 0, length: 0), word: "", replacement: "")
    }

    private var commonWordTitle: String { Self.commonWordTitle(commonWord ?? "") }

    static func commonWordTitle(_ word: String) -> String {
        "“\(word)” is a common word. Fix it in this and future dictations?"
    }

    /// The confirm button names the scope the question asks about: this dictation and the ones
    /// after it, never the dictations before.
    static let commonWordConfirmTitle = "Fix This and Future Dictations"

    private func applyInitialState() {
        guard !didApplyInitialState else { return }
        didApplyInitialState = true
        if let initialFix {
            fix = initialFix
            isFormShown = true
        }
        if let initialResult { result = initialResult }
    }

    private func begin(range: NSRange) {
        let source = entry.displayText as NSString
        guard range.length > 0, NSMaxRange(range) <= source.length else { return }
        let word = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !word.isEmpty else { return }
        let trimmed = source.range(of: word, options: [], range: range)
        let wordRange = trimmed.location == NSNotFound ? range : trimmed
        result = nil
        undoNote = nil
        scopeNote = nil
        wordChoices = []
        fix = FixWordState(entryID: entry.id, range: wordRange, word: word, replacement: word)
        picksWord = false
        isFormShown = true
    }

    /// The dictation's actions, where Fix a Word opens the form with the list of words: a
    /// VoiceOver user cannot click a word in the text.
    private func flowingActions(isEmpty: Bool) -> [TranscriptAccessibilityAction] {
        accessibilityActions.map { action in
            guard action.startsFixWord, !isEmpty else { return action }
            return TranscriptAccessibilityAction(name: "Fix a Word…", perform: chooseFromList, startsFixWord: true)
        }
    }

    /// Opens the form on the dictation's first word, with every word to choose from.
    private func chooseFromList() {
        let choices = FixWordChoice.choices(in: entry.displayText)
        guard let first = choices.first else { return }
        result = nil
        undoNote = nil
        scopeNote = nil
        wordChoices = choices
        fix = FixWordState(entryID: entry.id, range: first.range, word: first.word, replacement: first.word)
        picksWord = false
        isFormShown = true
    }

    private func cancel() {
        isFormShown = false
        fix = nil
    }

    /// The form closed to ask about the common word and kept the fix for the answer; Cancel
    /// drops it.
    private func cancelCommonWord() {
        commonWord = nil
        fix = nil
    }

    private func apply(confirmed: Bool) {
        guard let fix, !isWorking else { return }
        let replacement = fix.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty, replacement != fix.word else { return }
        let fixer = WordFixers.current(for: controller)
        guard let occurrence = DictationRecordBridge.occurrence(of: fix.word, in: fix.range, text: entry.displayText) else {
            isFormShown = false
            self.fix = nil
            showProblem(WordFixError.wordNotFound.errorDescription ?? "The fix wasn’t made.")
            return
        }
        let appName = AppNames.name(for: entry)
        let textAtPress = entry.cleanText
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let fixed = try await fixer.applyWordFix(
                    entryID: fix.entryID, original: fix.word, occurrence: occurrence,
                    replacement: replacement, appliesToFuture: fix.scope == .future,
                    confirmingCommonWord: confirmed, expectingText: textAtPress)
                commonWord = nil
                scopeNote = nil
                appliedFixCount = fixed.fixes?.count
                result = FixWordResult(entryID: fix.entryID, original: fix.word, replacement: replacement,
                                       appliedToFuture: fix.scope == .future, appName: appName)
                isFormShown = false
                self.fix = nil
                announce("Changed \(fix.word) to \(replacement)" + (fix.scope == .future ? ". Added to Word Corrections." : "."))
            } catch WordFixError.commonWord(let word) {
                isFormShown = false
                commonWord = word
            } catch WordFixError.keptAsSpoken(let word) {
                limitToThisDictation("Steno always keeps “\(word)” as spoken, so it can be fixed only in this dictation.")
            } catch WordFixError.conflictingCorrection(let existing) {
                limitToThisDictation("A word correction already changes “\(fix.word)” to “\(existing.preferred)”. Fix it in this dictation, or change it in Settings › Word Corrections.")
            } catch WordFixError.futureCorrectionsUnavailable {
                limitToThisDictation("Word Corrections can’t be changed right now. Fix it in this dictation.")
            } catch WordFixError.concealedDictation {
                limitToThisDictation(WordFixError.concealedDictation.errorDescription ?? "")
            } catch WordFixError.dictationChanged {
                // The text moved on since the word was chosen; the occurrence no longer points at it.
                isFormShown = false
                self.fix = nil
                showProblem(WordFixError.dictationChanged.errorDescription ?? "The fix wasn’t made.")
            } catch let error as WordFixError {
                // The fix can't be made as asked (too long, too many fixes, text changed): say why
                // and leave the form open.
                scopeNote = error.errorDescription
                isFormShown = true
            } catch {
                isFormShown = false
                self.fix = nil
                showProblem(Self.failureMessage(for: error))
            }
        }
    }

    /// The Everywhere option can't apply: keep the form open with Just this dictation chosen.
    private func limitToThisDictation(_ note: String) {
        fix?.scope = .thisDictation
        scopeNote = note
        isFormShown = true
    }

    private func undo() {
        guard !isWorking else { return }
        let fixer = WordFixers.current(for: controller)
        let keptCorrection = result?.appliedToFuture == true
        let fixCount = appliedFixCount
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await fixer.undoLastWordFix(entryID: entry.id, expectingFixCount: fixCount)
                result = nil
                undoNote = keptCorrection ? "The correction stays in Word Corrections." : nil
            } catch {
                result = nil
                showProblem(Self.failureMessage(for: error, fallback: "The fix couldn’t be undone."))
            }
        }
    }

    private static func failureMessage(for error: Error, fallback: String = "The fix wasn’t made.") -> String {
        if let message = (error as? LocalizedError)?.errorDescription, !message.isEmpty { return message }
        return fallback
    }

    /// Says why a fix or an undo wasn’t made, in the window and to VoiceOver.
    private func showProblem(_ message: String) {
        if let feedback {
            feedback.post(message, systemImage: "exclamationmark.triangle", tone: .caution)
        } else {
            announce(message)
        }
    }

    private func copyCorrected() {
        let fixer = WordFixers.current(for: controller)
        Task { await fixer.copyCorrectedText(entryID: entry.id) }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

private struct FixableEntryAccessibilityActions: ViewModifier {
    let actions: [TranscriptAccessibilityAction]

    func body(content: Content) -> some View {
        actions.reduce(AnyView(content)) { view, action in
            AnyView(view.accessibilityAction(named: Text(action.name), action.perform))
        }
    }
}
