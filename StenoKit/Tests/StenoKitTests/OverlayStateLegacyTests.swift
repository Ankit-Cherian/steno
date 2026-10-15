import Foundation
import Testing
@testable import StenoKit

@Suite("Overlay states for presenters that predate 1.1")
struct OverlayStateLegacyTests {
    @Test("1.0 states need no translation")
    func legacyStatesPassThrough() {
        let states: [OverlayState] = [.listening(handsFree: true, elapsedSeconds: 3), .transcribing, .inserted,
                                      .copiedOnly, .failure(message: "x"), .noSpeechDetected]
        for state in states { #expect(state.legacyEquivalent == nil) }
    }

    @Test("Results map to the 1.0 state with the same meaning", arguments: [
        (OverlayState.result(.inserted(appName: "Mail", method: .typed), showsWords: true), OverlayState.inserted),
        (.result(.copied(.secureField), showsWords: true), .copiedOnly),
        (.result(.notPasted, showsWords: true), .failure(message: "Not pasted. Saved in History.")),
        (.result(.failed(savedInHistory: true), showsWords: true), .failure(message: "Couldn\u{2019}t insert. Saved in History.")),
        (.busy(.stillFinishing), .failure(message: "Still finishing the last one")),
        (.busy(.pasteWaitsForDictation), .failure(message: "Finish this dictation first")),
        (.busy(.nothingToPaste), .failure(message: "No dictation to paste yet")),
    ])
    func resultsMap(state: OverlayState, expected: OverlayState) {
        #expect(state.legacyEquivalent == expected)
    }

    @Test("A discarded recording never maps to an inserted state")
    func discardedIsNotInserted() {
        let mapped = OverlayState.discarded(undoUntil: Date()).legacyEquivalent
        #expect(mapped != .inserted)
        #expect(mapped != nil)
    }
}

@MainActor
@Suite("Overlay input level")
struct OverlayInputLevelDispatchTests {
    @Test("A presenter's own level drawing is reached through the protocol")
    func dispatchesToPresenter() {
        let presenter = LevelRecordingPresenter()
        let overlay: any OverlayPresenter = presenter
        overlay.updateInputLevel(0.5)
        overlay.updateInputLevel(0)
        #expect(presenter.levels == [0.5, 0])
    }

    @Test("A presenter without level drawing ignores levels")
    func defaultIsNoOp() {
        let overlay: any OverlayPresenter = MinimalPresenter()
        overlay.updateInputLevel(1)
    }
}

@MainActor
private final class MinimalPresenter: OverlayPresenter {
    func prepareWindow() {}
    func show(state: OverlayState) {}
    func hide() {}
}

@MainActor
private final class LevelRecordingPresenter: OverlayPresenter {
    var levels: [Float] = []
    func prepareWindow() {}
    func show(state: OverlayState) {}
    func hide() {}
    func updateInputLevel(_ level: Float) { levels.append(level) }
}
