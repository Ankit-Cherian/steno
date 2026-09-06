#if DEBUG
import AppKit
import SwiftUI
import StenoKit

/// Drives the real overlay with synthetic recognition snapshots in the isolated review app.
@MainActor
final class OverlayReviewPlayer: ObservableObject {
    @Published private(set) var isRunning = false
    private let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
    private var playbackTask: Task<Void, Never>?
    private var playbackID: UUID?

    init() {
        presenter.setCancelAction { [weak self] in self?.stop() }
        presenter.setStopAction { [weak self] in self?.finish() }
    }

    func start(appearance: AppPreferences.Appearance) {
        stop()
        updateAppearance(appearance)
        isRunning = true
        let id = UUID()
        playbackID = id
        let session = LiveTranscriptionSession(
            sessionID: UUID(), controllerGeneration: UUID(),
            runtimeGeneration: 1, runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 0, runtimeIdentifier: "preview", modelIdentifier: "preview",
                vadIdentifier: nil, currentASRContextCount: 0, peakASRContextCount: 0))
        presenter.setLiveTranscriptEnabled(true)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        playbackTask = Task { [weak self] in
            for (index, text) in Self.sampleFrames.enumerated() {
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
                guard let self, playbackID == id else { return }
                presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
                    session: session, revisableTail: text,
                    lastAcceptedRevision: UInt64(index + 1),
                    decodedAudioWatermark: UInt64(index + 1) * 12_800))
            }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self, playbackID == id else { return }
            finish()
        }
    }

    func stop() {
        playbackID = nil
        playbackTask?.cancel()
        playbackTask = nil
        presenter.hide()
        isRunning = false
    }

    func updateAppearance(_ appearance: AppPreferences.Appearance) {
        let nativeAppearance: NSAppearance?
        switch appearance.mode {
        case .system: nativeAppearance = nil
        case .light: nativeAppearance = NSAppearance(named: .aqua)
        case .dark: nativeAppearance = NSAppearance(named: .darkAqua)
        }
        presenter.updateAppearance(nativeAppearance)
        let theme = StenoDesign.theme(for: appearance)
        presenter.updateAccentColor(NSColor(theme.accent))
    }

    private func finish() {
        guard isRunning else { return }
        playbackTask?.cancel()
        let id = UUID()
        playbackID = id
        presenter.show(state: .transcribing)
        playbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self, playbackID == id else { return }
            presenter.show(state: .inserted)
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard playbackID == id else { return }
            stop()
        }
    }

    static var sampleFrames: [String] {
        let sample = "Send the revised agenda on Thursday. Keep the launch date at September 18, and leave the accessibility review in place. The next paragraph is a longer thought that grows naturally as more words arrive. It should remain comfortable to read without taking over the screen. When the passage fills the available space, the next part continues in the same position. Names, numbers, and punctuation remain exactly as the recognition snapshot supplies them. A correction may replace an earlier word instead of adding a duplicate sentence. Even a long sequence without a convenient pause should stay within the display and keep its latest words visible. This is the final sentence of the sample."
        let words = sample.split(separator: " ")
        var frames: [String] = []
        for end in stride(from: 3, through: words.count, by: 4) {
            let text = words.prefix(end).joined(separator: " ")
            if end == 7 {
                frames.append(text.replacingOccurrences(of: "Thursday", with: "Tuesday"))
            }
            frames.append(text)
        }
        if frames.last != sample { frames.append(sample) }
        return frames
    }
}
#endif
