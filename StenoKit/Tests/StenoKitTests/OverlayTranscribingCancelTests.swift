#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

@MainActor
private final class ActionCounter {
    var cancels = 0
    var stops = 0
}

@Test("The overlay keeps Cancel, and only Cancel, while transcribing")
@MainActor
func overlayOffersCancelWhileTranscribing() {
    let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
    presenter.hostedEvidencePrepareOffscreen()
    let counter = ActionCounter()
    presenter.setCancelAction { counter.cancels += 1 }
    presenter.setStopAction { counter.stops += 1 }

    presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
    presenter.show(state: .transcribing)

    #expect(presenter.hostedEvidenceCancelIsAvailable())
    #expect(!presenter.hostedEvidenceStopIsAvailable())
    #expect(presenter.hostedEvidenceStatusTextClearsControls())

    presenter.hostedEvidencePressCancel()
    #expect(counter.cancels == 1)
    #expect(counter.stops == 0)
    #expect(!presenter.hostedEvidenceCancelIsAvailable())

    // A second press on the now-hidden control does nothing.
    presenter.hostedEvidencePressCancel()
    #expect(counter.cancels == 1)
    presenter.hide()
}

@Test("The overlay removes Cancel once transcription reaches a result", arguments: [
    OverlayState.inserted,
    .copiedOnly,
    .noSpeechDetected,
    .failure(message: "Transcription failed."),
])
@MainActor
func overlayRemovesCancelAfterTranscription(result: OverlayState) {
    let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
    presenter.hostedEvidencePrepareOffscreen()
    let counter = ActionCounter()
    presenter.setCancelAction { counter.cancels += 1 }

    presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
    presenter.show(state: .transcribing)
    presenter.show(state: result)

    #expect(!presenter.hostedEvidenceCancelIsAvailable())
    presenter.hostedEvidencePressCancel()
    #expect(counter.cancels == 0)
    presenter.hide()
}
#endif
