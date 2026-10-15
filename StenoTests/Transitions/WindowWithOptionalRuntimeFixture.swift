import AppKit
import Foundation
@testable import Steno
@testable import StenoKit

/// A real controller with its own History and an offscreen overlay, whose speech runtime can be
/// absent (`coordinator: nil`, as right after launch or during a runtime rebuild).
@MainActor
struct WindowWithOptionalRuntime {
    let controller: DictationController
    let hotkey: TransitionHotkey
    let history: HistoryStore
    let overlay: WaveformOverlayPresenter
    let directory: URL

    static func make(coordinator: (any DictationSessionCoordinating)?, entries: [TranscriptEntry] = []) async throws -> WindowWithOptionalRuntime {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StenoWindowOptionalRuntime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clipboard = MemoryClipboardService()
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        for entry in entries.reversed() { try await history.append(entry: entry) }
        let overlay = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        overlay.hostedEvidencePrepareOffscreen()
        let hotkey = TransitionHotkey()
        let permissions = PermissionStatusSnapshot(microphone: .granted, accessibility: .granted, inputMonitoring: .granted)
        let controller = makeTestDictationController(
            hotkey: hotkey, overlay: overlay, coordinator: coordinator, historyStore: history,
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"), clipboardService: clipboard,
            permissionStatusReader: { permissions })
        controller.microphoneAccessProvider = { permissions.microphone }
        controller.microphonePermissionStatus = permissions.microphone
        controller.accessibilityPermissionStatus = permissions.accessibility
        controller.inputMonitoringPermissionStatus = permissions.inputMonitoring
        await controller.refreshHistory()
        return WindowWithOptionalRuntime(controller: controller, hotkey: hotkey, history: history, overlay: overlay, directory: directory)
    }

    func close() async {
        await controller.teardownAndWait()
        overlay.hide()
        try? FileManager.default.removeItem(at: directory)
    }
}
