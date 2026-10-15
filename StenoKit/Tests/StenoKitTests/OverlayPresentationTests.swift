import Foundation
import Testing
@testable import StenoKit

@Suite("Overlay presentation for every state")
struct OverlayPresentationTests {
    struct Expected: CustomTestStringConvertible, Sendable {
        let state: OverlayState
        let width: CGFloat
        let nib: NibLayer.Mode
        let mark: NibLayer.ResultMark?
        let label: String
        let duration: TimeInterval?
        let announcement: String
        var action: OverlayPresentation.Action? = nil
        var keyHint: String? = nil

        var testDescription: String { label }
    }

    /// Copy, widths, marks, times and VoiceOver lines from the overlay board.
    static let board: [Expected] = [
        .init(state: .listening(handsFree: false, elapsedSeconds: 3), width: 220, nib: .live, mark: nil,
              label: "Listening", duration: nil, announcement: "Listening"),
        .init(state: .listening(handsFree: true, elapsedSeconds: 130), width: 300, nib: .live, mark: nil,
              label: "Hands-free", duration: nil, announcement: "Listening, hands-free"),
        .init(state: .transcribing, width: 220, nib: .working, mark: nil,
              label: "Transcribing\u{2026}", duration: nil, announcement: "Transcribing"),
        .init(state: .busy(.stillFinishing), width: 300, nib: .working, mark: nil,
              label: "Still finishing the last one", duration: 1.6, announcement: "Still finishing the last one"),
        .init(state: .busy(.handsFreeDeferred), width: 300, nib: .working, mark: nil,
              label: "Starts when the last one finishes", duration: 1.6,
              announcement: "Hands-free starts when the last one finishes"),
        .init(state: .busy(.modelLoading), width: 300, nib: .working, mark: nil,
              label: "Still loading the speech model", duration: 1.6, announcement: "Still loading the speech model"),
        .init(state: .busy(.pasteWaitsForDictation), width: 300, nib: .working, mark: nil,
              label: "Finish this dictation first", duration: 1.6,
              announcement: "Finish this dictation, then paste the last one"),
        .init(state: .busy(.nothingToPaste), width: 300, nib: .working, mark: nil,
              label: "No dictation to paste yet", duration: 1.6, announcement: "No dictation to paste yet"),
        .init(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: false), width: 220, nib: .rest,
              mark: .check, label: "Inserted", duration: 0.6, announcement: "Inserted into Mail"),
        .init(state: .result(.inserted(appName: "Mail", method: .accessibility), showsWords: true), width: 220,
              nib: .rest, mark: .check, label: "Inserted into Mail", duration: 2, announcement: "Inserted into Mail"),
        .init(state: .result(.inserted(appName: "Terminal", method: .pasted), showsWords: false), width: 220,
              nib: .rest, mark: .check, label: "Pasted into Terminal", duration: 2, announcement: "Pasted into Terminal"),
        .init(state: .result(.copied(.secureField), showsWords: true), width: 300, nib: .rest, mark: .copy,
              label: "Password field. Copied.", duration: 4, announcement: "Password field. Copied. Press Command V.",
              keyHint: "\u{2318}V"),
        .init(state: .result(.copied(.appChanged), showsWords: true), width: 300, nib: .rest, mark: .copy,
              label: "App changed. Copied.", duration: 4, announcement: "App changed. Copied. Press Command V.",
              keyHint: "\u{2318}V"),
        .init(state: .noSpeechDetected, width: 220, nib: .rest, mark: .microphone,
              label: "No speech detected", duration: 2, announcement: "No speech detected"),
        .init(state: .result(.failed(savedInHistory: true), showsWords: true), width: 340, nib: .rest, mark: .caution,
              label: "Couldn\u{2019}t insert. Saved in History.", duration: 6,
              announcement: "Couldn\u{2019}t insert. Saved in History.", action: .copy),
        .init(state: .result(.notPasted, showsWords: true), width: 340, nib: .rest, mark: .caution,
              label: "Not pasted. Saved in History.", duration: 6,
              announcement: "Not pasted. Saved in History.", action: .copy),
        .init(state: .result(.microphoneAccessOff, showsWords: true), width: 340, nib: .rest, mark: .caution,
              label: "Microphone access is off", duration: 6, announcement: "Microphone access is off",
              action: .openSettings),
        .init(state: .result(.microphoneDisconnected(insertedPartial: true), showsWords: true), width: 340, nib: .rest,
              mark: .caution, label: "Mic disconnected. Earlier words inserted.", duration: 6,
              announcement: "Microphone disconnected. Inserted what you said before that."),
        .init(state: .result(.transcriptionFailed, showsWords: true), width: 340, nib: .rest, mark: .caution,
              label: "Couldn\u{2019}t transcribe this recording", duration: 6,
              announcement: "Couldn\u{2019}t transcribe this recording"),
        .init(state: .result(.shortcutsUnavailable, showsWords: true), width: 340, nib: .rest, mark: .caution,
              label: "Shortcuts unavailable. Open Steno.", duration: 6, announcement: "Shortcuts unavailable. Open Steno."),
        .init(state: .result(.speechModelMissing, showsWords: true), width: 340, nib: .rest, mark: .caution,
              label: "Speech model not found. Open Steno.", duration: 6,
              announcement: "Speech model not found. Open Steno."),
    ]

    @Test("Each state has the board's width, quill, mark, words, time on screen and VoiceOver line", arguments: board)
    func boardState(expected: Expected) {
        let presentation = OverlayPresentation.make(for: expected.state)
        #expect(presentation.width.rawValue == expected.width)
        #expect(presentation.nib == expected.nib)
        #expect(presentation.mark == expected.mark)
        #expect(presentation.label == expected.label)
        #expect(presentation.duration == expected.duration)
        #expect(presentation.announcement == expected.announcement)
        #expect(presentation.action == expected.action)
        #expect(presentation.keyHint == expected.keyHint)
    }

    @Test("Discarded offers Undo for the rest of its window, at most 5 s")
    func discardedUndo() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let fresh = OverlayPresentation.make(for: .discarded(undoUntil: now.addingTimeInterval(5)), now: now)
        #expect(fresh.label == "Recording discarded")
        #expect(fresh.action == .undo)
        #expect(fresh.action?.title == "Undo")
        #expect(fresh.duration == 5)
        #expect(fresh.width == .handsFree)
        #expect(fresh.nib == .rest)
        #expect(fresh.mark == nil)
        #expect(fresh.announcement == "Recording discarded. Undo available.")

        let partial = OverlayPresentation.make(for: .discarded(undoUntil: now.addingTimeInterval(2)), now: now)
        let duration = try #require(partial.duration)
        #expect(abs(duration - 2) < 0.001)

        let expired = OverlayPresentation.make(for: .discarded(undoUntil: now.addingTimeInterval(-1)), now: now)
        #expect(expired.action == nil)
    }

    @Test("1.0 states render as their 1.1 equivalents", arguments: [
        (OverlayState.inserted, OverlayState.result(.inserted(appName: nil, method: .typed), showsWords: false)),
        (.copiedOnly, .result(.copied(.other), showsWords: true)),
    ])
    func legacyStates(legacy: OverlayState, modern: OverlayState) {
        #expect(OverlayPresentation.make(for: legacy) == OverlayPresentation.make(for: modern))
    }

    @Test("A 1.0 failure is a problem line carrying the message")
    func legacyFailure() {
        let presentation = OverlayPresentation.make(for: .failure(message: "The document closed."))
        #expect(presentation.label == "The document closed.")
        #expect(presentation.width == .problem)
        #expect(presentation.mark == .caution)
        #expect(presentation.duration == 6)
        #expect(presentation.announcement == "The document closed.")
    }

    @Test("Every copy reason has its own words and the same pattern", arguments: [
        (CopyReason.secureField, "Password field. Copied."), (.fieldChanged, "Field changed. Copied."),
        (.appChanged, "App changed. Copied."), (.appNotResponding, "App didn\u{2019}t respond. Copied."),
        (.accessibilityOff, "Accessibility is off. Copied."), (.noTextField, "No text field. Copied."),
        (.other, "Copied."),
    ])
    func copyReasons(reason: CopyReason, label: String) {
        let presentation = OverlayPresentation.make(for: .result(.copied(reason), showsWords: true))
        #expect(presentation.label == label)
        #expect(presentation.announcement == label + " Press Command V.")
        #expect(presentation.tone == .primary)
    }

    @Test("Not pasted never tells the user to press Command V")
    func notPastedNeverSaysPaste() {
        let presentation = OverlayPresentation.make(for: .result(.notPasted, showsWords: true))
        #expect(presentation.keyHint == nil)
        #expect(presentation.announcement?.contains("Command V") == false)
        #expect(!presentation.label.contains("\u{2318}"))
    }

    @Test("Transcribing keeps the width it had, so × does not move", arguments: [
        OverlayPresentation.Width.hold, .handsFree,
    ])
    func transcribingKeepsWidth(width: OverlayPresentation.Width) {
        let presentation = OverlayPresentation.make(for: .transcribing, previousWidth: width)
        #expect(presentation.width == width)
        #expect(presentation.showsDiscard)
        #expect(!presentation.showsStop)
    }

    @Test("Hands-free shows Stop and ×; a hold shows only ×")
    func controlsPerMode() {
        let hold = OverlayPresentation.make(for: .listening(handsFree: false, elapsedSeconds: 0))
        let handsFree = OverlayPresentation.make(for: .listening(handsFree: true, elapsedSeconds: 0))
        #expect(!hold.showsStop && hold.showsDiscard)
        #expect(handsFree.showsStop && handsFree.showsDiscard)
        for result in OverlayPresentationTests.board.map(\.state) where !result.isRecordingOrWorking {
            #expect(!OverlayPresentation.make(for: result).showsStop)
        }
    }

    @Test("A hold shows no time until 10 s; hands-free always does; the last minute counts down", arguments: [
        (false, 0, nil as Int?, "Listening", nil as String?, false),
        (false, 9, nil, "Listening", nil, false),
        (false, 14, nil, "Listening", "0:14", false),
        (true, 0, nil, "Hands-free", "0:00", false),
        (true, 130, nil, "Hands-free", "2:10", false),
        (true, 3_558, 3_600, "Stops in 0:42", nil, true),
        (false, 3_600, 3_600, "Stops in 0:00", nil, true),
    ])
    func listeningLine(handsFree: Bool, elapsed: Int, limit: Int?, label: String, time: String?, countdown: Bool) {
        let line = OverlayPresentation.listeningLine(handsFree: handsFree, elapsedSeconds: elapsed, limitSeconds: limit)
        #expect(line.label == label)
        #expect(line.time == time)
        #expect(line.countdown == countdown)
    }

    @Test("Only the brief success is drawn smaller; problems and copies are full strength")
    func tones() {
        #expect(OverlayPresentation.make(for: .inserted).tone == .brief)
        #expect(OverlayPresentation.make(for: .noSpeechDetected).tone == .quiet)
        #expect(OverlayPresentation.make(for: .busy(.stillFinishing)).tone == .quiet)
        #expect(OverlayPresentation.make(for: .result(.notPasted, showsWords: true)).tone == .primary)
        let countdown = OverlayPresentation.make(for: .listening(handsFree: true, elapsedSeconds: 3_540), limitSeconds: 3_600)
        #expect(countdown.tone == .countdown)
        #expect(countdown.time == nil)
    }

    @Test("Only busy notices give way to what was showing before")
    func noticesRestore() {
        for expected in OverlayPresentationTests.board {
            let presentation = OverlayPresentation.make(for: expected.state)
            if case .busy = expected.state {
                #expect(presentation.restoresPrevious)
            } else {
                #expect(!presentation.restoresPrevious)
            }
        }
    }
}

@Suite("Overlay result timing")
struct OverlayResultTimerTests {
    @Test("A timed state expires after its duration")
    func expiresAfterDuration() {
        let timer = OverlayResultTimer(duration: 4, now: 100)
        #expect(!timer.isExpired(now: 103.99))
        #expect(timer.isExpired(now: 104))
        #expect(timer.delay(now: 101) == 3)
    }

    @Test("Hover holds the time; leaving resumes what was left")
    func hoverHoldsAndResumes() {
        var timer = OverlayResultTimer(duration: 6, now: 0)
        timer.hold(now: 2)
        #expect(timer.isHeld)
        #expect(!timer.isExpired(now: 100))
        #expect(timer.delay(now: 100) == nil)
        timer.release(now: 100)
        #expect(!timer.isExpired(now: 103.9))
        #expect(timer.isExpired(now: 104))
    }

    @Test("Leaving near the end still leaves at least a second to read")
    func minimumAfterHover() {
        var timer = OverlayResultTimer(duration: 0.6, now: 0)
        timer.hold(now: 0.5)
        timer.release(now: 10)
        #expect(!timer.isExpired(now: 10.9))
        #expect(timer.isExpired(now: 11))
    }

    @Test("Cancelling stops the clock")
    func cancel() {
        var timer = OverlayResultTimer(duration: 2, now: 0)
        timer.cancel()
        #expect(!timer.isRunning)
        #expect(!timer.isExpired(now: 10))
    }
}

private extension OverlayState {
    var isRecordingOrWorking: Bool {
        switch self {
        case .listening: true
        default: false
        }
    }
}
