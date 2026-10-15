#if os(macOS)
import AppKit
import Testing
@testable import StenoKit

@MainActor
private final class ManualClock {
    var now: TimeInterval = 1_000
}

@MainActor
private func makePresenter(clock: ManualClock? = nil, appearance: OverlayAppearanceStyle = .grove) -> WaveformOverlayPresenter {
    let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
    presenter.appearance = appearance
    presenter.hostedEvidencePrepareOffscreen()
    presenter.setHostedAccessibilityPreferences(.init(
        reduceMotion: false, reduceTransparency: false, increaseContrast: false, preferredBodyPointSize: 13
    ))
    if let clock { presenter.clock = { clock.now } }
    return presenter
}

@Suite("Overlay presenter behaviour", .serialized)
@MainActor
struct OverlayPresenterBehaviourTests {
    @Test("Each state draws at its fixed width", arguments: [
        (OverlayState.listening(handsFree: false, elapsedSeconds: 0), 220.0),
        (.listening(handsFree: true, elapsedSeconds: 0), 300),
        (.result(.inserted(appName: "Mail", method: .typed), showsWords: true), 220),
        (.result(.copied(.secureField), showsWords: true), 300),
        (.result(.failed(savedInHistory: true), showsWords: true), 340),
        (.busy(.stillFinishing), 300),
        (.discarded(undoUntil: Date().addingTimeInterval(5)), 300),
    ])
    func widths(state: OverlayState, width: Double) {
        let presenter = makePresenter(appearance: .quill)
        presenter.setLiveTranscriptEnabled(false)
        presenter.show(state: state)
        #expect(presenter.hostedEvidenceCapsuleSize() == CGSize(width: width, height: 40))
        presenter.hide()
    }

    @Test("Changing state inside a mode never resizes or moves the panel")
    func panelIsStableAcrossStates() {
        let presenter = makePresenter()
        presenter.setLiveTranscriptEnabled(false)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        let panel = presenter.hostedEvidencePanelSize()
        for state in [OverlayState.transcribing, .result(.notPasted, showsWords: true), .noSpeechDetected] {
            presenter.show(state: state)
            #expect(presenter.hostedEvidencePanelSize() == panel)
        }
        presenter.hide()
    }

    @Test("A timed result fades when its time is up, held while the pointer rests on it")
    func hoverHoldsTheResult() {
        let clock = ManualClock()
        let presenter = makePresenter(clock: clock)
        presenter.show(state: .result(.copied(.secureField), showsWords: true))
        #expect(presenter.hostedEvidenceIsVisible())

        clock.now += 1
        presenter.hostedEvidencePointer(inside: true)
        clock.now += 30
        presenter.hostedEvidenceFireResultTimer()
        #expect(presenter.hostedEvidenceIsVisible(), "held while hovered")

        presenter.hostedEvidencePointer(inside: false)
        clock.now += 2.9
        presenter.hostedEvidenceFireResultTimer()
        #expect(presenter.hostedEvidenceIsVisible(), "3 s were left when the pointer arrived")
        clock.now += 0.2
        presenter.hostedEvidenceFireResultTimer()
        #expect(!presenter.hostedEvidenceIsVisible())
    }

    @Test("The brief check leaves after 0.6 s")
    func briefCheck() {
        let clock = ManualClock()
        let presenter = makePresenter(clock: clock)
        presenter.show(state: .inserted)
        clock.now += 0.59
        presenter.hostedEvidenceFireResultTimer()
        #expect(presenter.hostedEvidenceIsVisible())
        clock.now += 0.02
        presenter.hostedEvidenceFireResultTimer()
        #expect(!presenter.hostedEvidenceIsVisible())
    }

    @Test("Finishing the dictation leaves a timed result to its own clock, and hides anything else")
    func finishResultPresentation() {
        let presenter = makePresenter(clock: ManualClock())
        presenter.show(state: .result(.failed(savedInHistory: true), showsWords: true))
        presenter.finishResultPresentation()
        #expect(presenter.hostedEvidenceIsVisible())
        presenter.show(state: .transcribing)
        presenter.finishResultPresentation()
        #expect(!presenter.hostedEvidenceIsVisible())
    }

    @Test("A busy notice gives way to the state it covered")
    func busyRestoresTranscribing() {
        let clock = ManualClock()
        let presenter = makePresenter(clock: clock)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        presenter.show(state: .transcribing)
        presenter.show(state: .busy(.stillFinishing))
        #expect(presenter.hostedEvidenceUserFacingStrings().first == "Still finishing the last one")
        clock.now += 1.6
        presenter.hostedEvidenceFireResultTimer()
        #expect(presenter.hostedEvidenceUserFacingStrings().first == "Transcribing\u{2026}")
        #expect(presenter.hostedEvidenceCancelIsAvailable())
        #expect(presenter.hostedEvidenceIsVisible())
    }

    @Test("Cancel still cancels once a notice has given way to Transcribing", arguments: [
        OverlayAppearanceStyle.quill, .grove,
    ])
    func cancelWorksAfterBusyNotice(appearance: OverlayAppearanceStyle) {
        let clock = ManualClock()
        let presenter = makePresenter(clock: clock)
        presenter.appearance = appearance
        var cancels = 0
        presenter.setCancelAction { cancels += 1 }
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        presenter.show(state: .transcribing)
        presenter.show(state: .busy(.stillFinishing))
        clock.now += 1.6
        presenter.hostedEvidenceFireResultTimer()
        #expect(presenter.hostedEvidenceUserFacingStrings().first == "Transcribing\u{2026}")
        #expect(presenter.hostedEvidenceCancelIsAvailable())
        presenter.hostedEvidencePressCancel()
        #expect(cancels == 1)
    }

    @Test("A busy notice over nothing hides again")
    func busyOverNothingHides() {
        let clock = ManualClock()
        let presenter = makePresenter(clock: clock)
        presenter.show(state: .busy(.modelLoading))
        clock.now += 1.7
        presenter.hostedEvidenceFireResultTimer()
        #expect(!presenter.hostedEvidenceIsVisible())
    }

    @Test("Copy calls the copy hook, then confirms briefly")
    func copyAction() {
        let presenter = makePresenter(clock: ManualClock())
        var copies = 0
        presenter.onCopyResult = { copies += 1 }
        presenter.show(state: .result(.failed(savedInHistory: true), showsWords: true))
        #expect(presenter.hostedEvidenceActionTitle() == "Copy")
        presenter.hostedEvidencePressAction()
        #expect(copies == 1)
        #expect(presenter.hostedEvidenceUserFacingStrings().first == "Copied.")
        #expect(presenter.hostedEvidenceActionTitle() == nil)
        presenter.hide()
    }

    @Test("Undo calls the undo hook; an action without a hook is not drawn")
    func undoAction() {
        let presenter = makePresenter(clock: ManualClock())
        presenter.show(state: .discarded(undoUntil: Date().addingTimeInterval(5)))
        #expect(presenter.hostedEvidenceActionTitle() == nil)
        var undos = 0
        presenter.onUndoDiscard = { undos += 1 }
        presenter.show(state: .discarded(undoUntil: Date().addingTimeInterval(5)))
        #expect(presenter.hostedEvidenceActionTitle() == "Undo")
        presenter.hostedEvidencePressAction()
        #expect(undos == 1)
        presenter.hide()
    }

    @Test("Open Settings… passes the problem to the settings hook")
    func openSettingsAction() {
        let presenter = makePresenter(clock: ManualClock(), appearance: .quill)
        var opened: [OverlayResult] = []
        presenter.onOpenSettings = { opened.append($0) }
        presenter.show(state: .result(.microphoneAccessOff, showsWords: true))
        #expect(presenter.hostedEvidenceActionTitle() == "Open Settings\u{2026}")
        presenter.hostedEvidencePressAction()
        #expect(opened == [.microphoneAccessOff])
    }

    @Test("The input level reaches the quill only while listening")
    func levelOnlyWhileListening() {
        let presenter = makePresenter(appearance: .quill)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        presenter.updateInputLevel(0.7)
        #expect(presenter.hostedEvidenceNibLevel() == 0.7)
        #expect(presenter.hostedEvidenceNibMode() == .live)
        presenter.show(state: .transcribing)
        presenter.updateInputLevel(0.2)
        #expect(presenter.hostedEvidenceNibLevel() == 0.7)
        #expect(presenter.hostedEvidenceNibMode() == .working)
        presenter.hide()
    }

    @Test("The quill stays across states and takes a mark for results")
    func quillStays() {
        let presenter = makePresenter(appearance: .quill)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceNibMode() == .live)
        presenter.show(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: true))
        #expect(presenter.hostedEvidenceNibMode() == .rest)
        #expect(presenter.hostedEvidencePresentation()?.mark == .check)
        presenter.hide()
    }

    @Test("Each outcome is announced once with the board's words, including a silent success")
    func announcements() {
        let presenter = makePresenter()
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        presenter.show(state: .transcribing)
        presenter.show(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: false))
        presenter.show(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: false))
        presenter.hide()
        presenter.announce(result: .inserted(appName: "Notes", method: .typed))
        #expect(presenter.hostedEvidenceAnnouncementLog() == [
            "Listening, hands-free", "Transcribing", "Inserted into Mail", "Inserted into Notes",
        ])
    }

    @Test("Hold mode hides Stop; hands-free shows it and keeps Stop and Discard apart")
    func stopOnlyInHandsFree() {
        let presenter = makePresenter()
        var stops = 0
        presenter.setStopAction { stops += 1 }
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(!presenter.hostedEvidenceStopIsAvailable())
        #expect(presenter.hostedEvidenceCancelIsAvailable())
        presenter.hide()
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceStopIsAvailable())
        #expect(presenter.hostedEvidenceStatusTextClearsControls())
        presenter.hostedEvidencePressStop()
        #expect(stops == 1)
        #expect(presenter.hostedEvidenceUserFacingStrings().contains("Discard"))
        #expect(!presenter.hostedEvidenceUserFacingStrings().contains { $0.contains("Cancel") })
        presenter.hide()
    }

    @Test("The live card shows a placeholder, then the newest words, and never shrinks while listening")
    func liveCardGrowsOnly() throws {
        let presenter = makePresenter(appearance: .quill)
        presenter.setLiveTranscriptEnabled(true)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        let placeholderCard = try #require(presenter.hostedEvidenceCardSize())
        #expect(placeholderCard == CGSize(width: 440, height: 48))
        #expect(presenter.hostedEvidenceUserFacingStrings().contains("Words appear here as you speak"))
        let session = LiveTranscriptionSession(sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1, runtimeIdentity: .pending)
        let long = String(repeating: "Move the planning meeting from Thursday to Friday. ", count: 8)
        presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
            session: session, stablePrefix: long, lastAcceptedRevision: 1, decodedAudioWatermark: 1_600))
        presenter.hostedEvidenceFlushLiveTranscript()
        let fullCard = try #require(presenter.hostedEvidenceCardSize())
        #expect(fullCard == CGSize(width: 440, height: 12 + 4 * 22 + 14))
        presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
            session: session, stablePrefix: "Short.", lastAcceptedRevision: 2, decodedAudioWatermark: 3_200))
        // The second update arrives inside the 4-per-second window; flush it directly.
        presenter.hostedEvidenceFlushLiveTranscript()
        #expect(presenter.hostedEvidenceCardSize() == fullCard)
        #expect(presenter.hostedEvidenceVisibleTranscript() == "Short.")
        presenter.hide()
    }
}
#endif
