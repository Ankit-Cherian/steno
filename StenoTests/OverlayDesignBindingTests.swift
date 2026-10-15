import Foundation
import Testing
@testable import Steno
import StenoKit

@MainActor
@Suite("The overlay shows the Grove look")
struct OverlayDesignBindingTests {
    @Test("The controller gives the overlay the forest glass look")
    func overlayIsGrove() {
        let overlay = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        overlay.appearance = .quill
        let controller = makeTestDictationController(hotkey: StorageRecoveryTestHotkeyService(), overlay: overlay)
        #expect(overlay.appearance == .grove)
        _ = controller
    }
}
