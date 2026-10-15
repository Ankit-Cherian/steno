import Foundation
import StenoKit

/// How a finished dictation ended, as the plate says it.
struct GroveOutcome: Equatable {
    enum Kind: Equatable { case inserted, copied }

    var kind: Kind
    /// "Inserted into Mail", "Copied · App changed".
    var title: String
    /// The words the dictation produced.
    var text: String
}

/// A dictation that needs a word and, usually, one action, shown in the window where the plate was.
struct GroveProblem: Equatable {
    enum Action: Equatable {
        /// Copy the kept words.
        case copy
        case undoDiscard
        case none
    }

    var title: String
    var message: String
    var systemImage: String
    var actionTitle: String?
    var action: Action
    /// A note that is not an error: a discard or a recording with no speech.
    var isQuiet = false
    /// The entry the note is about, so Copy can find it.
    var entryID: UUID?
}

/// What the plate region at the top of Today is showing.
enum GroveTodayPhase: Equatable {
    case idle
    case listening
    case transcribing
    /// The result is in: the words settle to cream and the check draws, then the plate folds
    /// into the latest dictation's card.
    case settled(GroveOutcome)
    /// The plate has become a note with its one action.
    case problem(GroveProblem)

    var isRecordingOrFinishing: Bool {
        switch self {
        case .listening, .transcribing, .settled: true
        case .idle, .problem: false
        }
    }
}

/// The plate's life across a dictation: listening, transcribing, then a result that settles and
/// folds into the latest card, or a problem that turns the plate into a note.
///
/// The model is driven by three facts the controller already publishes (the recording
/// lifecycle, the newest History entry and whether a discard can be undone) so it adds no
/// state to the engine. Timings are injectable so tests do not wait.
@MainActor
final class GroveTodayFlow: ObservableObject {
    struct Timing {
        /// How long to wait for the finished dictation to reach History before giving up.
        var resultWait: Duration = .seconds(2.5)
        /// How long the settled plate holds before it folds into the card.
        var settleHold: Duration = .milliseconds(1_100)
        /// How long a quiet note stays.
        var quietNote: Duration = .seconds(6)

        static let standard = Timing()
    }

    @Published private(set) var phase: GroveTodayPhase = .idle
    /// New entries stay out of the list until the plate has folded into them.
    @Published private(set) var baselineLatestID: UUID?
    @Published private(set) var isHoldingNewEntries = false

    private let timing: Timing
    private var awaitingResult = false
    /// A dictation that reached History while it was still transcribing.
    private var earlyEntry: (entry: TranscriptEntry, appName: String)?
    private var pendingTask: Task<Void, Never>?

    init(timing: Timing = .standard) {
        self.timing = timing
    }

    deinit {
        pendingTask?.cancel()
    }

    // MARK: Inputs

    /// What the controller's status line says about how the recording ended.
    enum EndHint: Equatable {
        case none, canceled, noSpeech

        static func from(status: String) -> EndHint {
            let lowered = status.lowercased()
            if lowered.contains("canceled") || lowered.contains("discarded") { return .canceled }
            if lowered.hasPrefix("no speech") { return .noSpeech }
            return .none
        }
    }

    /// The recording lifecycle changed (or the view appeared in this state). A dictation that
    /// failed leaves no note here: the window's strip says the error, on every section.
    func lifecycle(_ state: RecordingLifecycleState, latestID: UUID?, canUndoDiscard: Bool, hint: EndHint = .none) {
        switch state {
        case .recordingPressToTalk, .recordingHandsFree:
            guard phase != .listening else { return }
            cancelPending()
            awaitingResult = false
            earlyEntry = nil
            baselineLatestID = latestID
            isHoldingNewEntries = true
            phase = .listening
        case .transcribing:
            guard phase != .transcribing else { return }
            cancelPending()
            awaitingResult = false
            if !isHoldingNewEntries {
                baselineLatestID = latestID
                isHoldingNewEntries = true
            }
            phase = .transcribing
        case .idle:
            guard phase == .listening || phase == .transcribing else { return }
            if canUndoDiscard {
                show(problem: Self.discarded)
                return
            }
            switch hint {
            case .canceled:
                finish()
                return
            case .noSpeech:
                show(problem: Self.noSpeech)
                return
            case .none:
                break
            }
            if let early = earlyEntry {
                earlyEntry = nil
                resolveNow(early.entry, appName: early.appName)
                return
            }
            awaitingResult = true
            phase = .transcribing
            pendingTask = Task { [weak self, timing] in
                try? await Task.sleep(for: timing.resultWait)
                guard !Task.isCancelled else { return }
                self?.resultNeverArrived()
            }
        }
    }

    /// The newest History entry changed.
    func latestEntry(_ entry: TranscriptEntry?, appName: String) {
        guard let entry else { return }
        if awaitingResult {
            guard entry.id != baselineLatestID else { return }
            awaitingResult = false
            cancelPending()
            resolveNow(entry, appName: appName)
        } else if phase == .listening {
            // An earlier dictation's History refresh landed during this one.
            baselineLatestID = entry.id
        } else if phase == .transcribing, entry.id != baselineLatestID {
            // The result reached History before the lifecycle said it was done.
            earlyEntry = (entry, appName)
        }
    }

    private func resolveNow(_ entry: TranscriptEntry, appName: String) {
        switch Self.resolve(entry, appName: appName) {
        case .settled(let outcome): settle(outcome)
        case .problem(let problem): show(problem: problem)
        }
    }

    /// Whether the controller still holds a discard that can be undone.
    func canUndoDiscardChanged(_ canUndo: Bool) {
        if awaitingResult, canUndo {
            awaitingResult = false
            cancelPending()
            show(problem: Self.discarded)
        } else if !canUndo, case .problem(let problem) = phase, problem.action == .undoDiscard {
            finish()
        }
    }

    func dismissProblem() {
        guard case .problem = phase else { return }
        finish()
    }

    /// The person acted on a note (Copy, Undo, a settings link): it has done its job.
    func noteActed() {
        dismissProblem()
    }

    // MARK: Results

    enum Resolution: Equatable {
        case settled(GroveOutcome)
        case problem(GroveProblem)
    }

    /// Turns the saved dictation into what the plate says. Pure.
    static func resolve(_ entry: TranscriptEntry, appName: String) -> Resolution {
        let text = entry.displayText
        switch entry.insertionStatus {
        case .inserted:
            return .settled(GroveOutcome(kind: .inserted, title: "Inserted into \(appName)", text: text))
        case .copiedOnly:
            if entry.wasNotPasted { return .problem(notInserted(entry)) }
            if entry.wasPasted {
                return .settled(GroveOutcome(kind: .inserted, title: "Pasted into \(appName)", text: text))
            }
            let reason = GroveRules.copyReasonText(entry.record?.copyReason)
            return .settled(GroveOutcome(kind: .copied, title: reason.map { "Copied · \($0)" } ?? "Copied", text: text))
        case .failed:
            return .problem(notInserted(entry))
        case .noSpeech:
            return .problem(noSpeech)
        }
    }

    /// The note for words that were saved but not put where the person was typing.
    private static func notInserted(_ entry: TranscriptEntry) -> GroveProblem {
        GroveProblem(
            title: "Not inserted",
            message: "Saved in History. Copy the words and paste them where you need them.",
            systemImage: "exclamationmark.triangle", actionTitle: "Copy", action: .copy, entryID: entry.id)
    }

    static let discarded = GroveProblem(
        title: "Discarded", message: "That recording was thrown away.", systemImage: "trash",
        actionTitle: "Undo", action: .undoDiscard, isQuiet: true)

    static let noSpeech = GroveProblem(
        title: "No speech detected", message: "Nothing was inserted.",
        systemImage: "waveform.slash", actionTitle: nil, action: .none, isQuiet: true)

    // MARK: Private

    private func resultNeverArrived() {
        guard awaitingResult else { return }
        finish()
    }

    private func settle(_ outcome: GroveOutcome) {
        phase = .settled(outcome)
        pendingTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.settleHold)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func show(problem: GroveProblem) {
        cancelPending()
        awaitingResult = false
        isHoldingNewEntries = false
        phase = .problem(problem)
        if problem.isQuiet, problem.action != .undoDiscard {
            pendingTask = Task { [weak self, timing] in
                try? await Task.sleep(for: timing.quietNote)
                guard !Task.isCancelled else { return }
                self?.dismissProblem()
            }
        }
    }

    /// The plate folds into the latest card: the new entry joins the list.
    private func finish() {
        cancelPending()
        awaitingResult = false
        isHoldingNewEntries = false
        baselineLatestID = nil
        phase = .idle
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}

/// Words the plate shows while listening, trimmed to the last few lines.
enum GroveLiveWords {
    /// Characters kept, counted from the end, so the plate stays three or four lines tall. A wide
    /// character (CJK, kana, Hangul, full-width forms, emoji) counts as two.
    static let characterLimit = 230

    /// The settled words and the part that may still change, cut from the front on a word
    /// boundary and led by an ellipsis when something was cut. Line breaks and runs of spaces
    /// read as one space, so blank lines never push the newest words off the plate.
    static func display(stable: String, tail: String, limit: Int = characterLimit) -> (stable: String, tail: String) {
        LiveWordsText.newest(stable: stable, tail: tail, limit: limit)
    }

    /// Two for a character drawn about twice as wide as a Latin letter, otherwise one.
    static func width(of character: Character) -> Int {
        LiveWordsText.width(of: character)
    }
}
