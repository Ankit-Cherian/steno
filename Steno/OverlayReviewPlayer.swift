#if DEBUG
import AppKit
import SwiftUI
import StenoKit

/// Drives the real overlay with synthetic levels, words and outcomes in the isolated review
/// app, so every state can be reviewed without dictating. Nothing here touches the
/// microphone, the clipboard, History, settings or Insights.
@MainActor
final class OverlayReviewPlayer: ObservableObject {
    /// One reviewable overlay state.
    enum Sample: String, CaseIterable, Identifiable {
        case dictation = "Play a hands-free dictation"
        case hold = "Holding Option"
        case holdPastTen = "Holding past 10 s"
        case handsFree = "Hands-free"
        case lastMinute = "Last minute"
        case transcribing = "Transcribing"
        case stillFinishing = "Still finishing"
        case handsFreeWaits = "Hands-free waits"
        case inserted = "Inserted"
        case insertedSayingWhere = "Inserted into Mail"
        case pasted = "Pasted into Terminal"
        case copiedPassword = "Copied: password field"
        case copiedAppChanged = "Copied: app changed"
        case noSpeech = "No speech"
        case discarded = "Discarded, with Undo"
        case couldNotInsert = "Couldn’t insert"
        case notPasted = "Not pasted"
        case microphoneOff = "Microphone off"
        case microphoneDisconnected = "Microphone disconnected"
        case couldNotTranscribe = "Couldn’t transcribe"
        case notReady = "Not ready"
        case liveWaiting = "Live words: waiting"
        case liveWords = "Live words: wet and dry ink"
        case liveLong = "Live words: long dictation"
        case livePreviewStopped = "Live words: preview stopped"

        var id: String { rawValue }
    }

    /// The two forms of the Grove overlay. A notch shows only on a built-in display with a
    /// notch; the review forces either so every state can be seen in both.
    enum Form: String, CaseIterable, Identifiable {
        case notch = "Notch"
        case capsule = "Capsule"

        var id: String { rawValue }
    }

    @Published private(set) var isRunning = false
    @Published var form: Form = .notch {
        didSet { presenter.placementOverride = form == .notch ? .notch : .capsule }
    }
    private let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: true)
    private var playbackTask: Task<Void, Never>?
    private var levelTimer: Timer?
    private var playbackID: UUID?

    init() {
        presenter.setCancelAction { [weak self] in self?.stop() }
        presenter.setStopAction { [weak self] in self?.finish() }
        presenter.onCopyResult = {}
        presenter.onUndoDiscard = { [weak self] in self?.show(.transcribing) }
        presenter.onOpenSettings = { _ in }
        presenter.placementOverride = .notch
        presenter.appearance = .grove
    }

    func show(_ sample: Sample) {
        stop()
        isRunning = true
        let id = UUID()
        playbackID = id
        presenter.setLiveTranscriptEnabled(sample.showsLiveWords)
        switch sample {
        case .dictation:
            playDictation(id: id)
        case .hold:
            listen(handsFree: false, elapsed: 2)
        case .holdPastTen:
            listen(handsFree: false, elapsed: 14)
        case .handsFree:
            listen(handsFree: true, elapsed: 130)
        case .lastMinute:
            listen(handsFree: true, elapsed: 3_558)
            presenter.showRecordingLimitWarning(limitSeconds: 3_600)
        case .transcribing:
            presenter.show(state: .listening(handsFree: false, elapsedSeconds: 4))
            presenter.show(state: .transcribing)
        case .stillFinishing:
            presenter.show(state: .listening(handsFree: false, elapsedSeconds: 4))
            presenter.show(state: .transcribing)
            presenter.show(state: .busy(.stillFinishing))
        case .handsFreeWaits:
            presenter.show(state: .busy(.handsFreeDeferred))
        case .inserted:
            presenter.show(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: false))
        case .insertedSayingWhere:
            presenter.show(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: true))
        case .pasted:
            presenter.show(state: .result(.inserted(appName: "Terminal", method: .pasted), showsWords: true))
        case .copiedPassword:
            presenter.show(state: .result(.copied(.secureField), showsWords: true))
        case .copiedAppChanged:
            presenter.show(state: .result(.copied(.appChanged), showsWords: true))
        case .noSpeech:
            presenter.show(state: .noSpeechDetected)
        case .discarded:
            presenter.show(state: .discarded(undoUntil: Date().addingTimeInterval(5)))
        case .couldNotInsert:
            presenter.show(state: .result(.failed(savedInHistory: true), showsWords: true))
        case .notPasted:
            presenter.show(state: .result(.notPasted, showsWords: true))
        case .microphoneOff:
            presenter.show(state: .result(.microphoneAccessOff, showsWords: true))
        case .microphoneDisconnected:
            presenter.show(state: .result(.microphoneDisconnected(insertedPartial: true), showsWords: true))
        case .couldNotTranscribe:
            presenter.show(state: .result(.transcriptionFailed, showsWords: true))
        case .notReady:
            presenter.show(state: .busy(.modelLoading))
        case .liveWaiting:
            listen(handsFree: true, elapsed: 9)
        case .liveWords:
            listen(handsFree: true, elapsed: 9)
            presenter.updateLiveTranscript(snapshot(
                stable: "Move the planning meeting from Thursday to Friday. Send the updated agenda ",
                wet: "before lunch so every", revision: 1))
        case .liveLong:
            listen(handsFree: true, elapsed: 271)
            presenter.updateLiveTranscript(snapshot(stable: Self.longSample, wet: "The second set of originals will follow", revision: 1))
        case .livePreviewStopped:
            listen(handsFree: true, elapsed: 72)
            presenter.showLiveTranscriptUnavailable()
        }
    }

    func stop() {
        playbackID = nil
        playbackTask?.cancel()
        playbackTask = nil
        levelTimer?.invalidate()
        levelTimer = nil
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

    // MARK: - Playback

    private var session = LiveTranscriptionSession(
        sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1,
        runtimeIdentity: LiveTranscriptionRuntimeIdentity(
            protocolVersion: 0, runtimeIdentifier: "preview", modelIdentifier: "preview",
            vadIdentifier: nil, currentASRContextCount: 0, peakASRContextCount: 0))

    private func listen(handsFree: Bool, elapsed: Int) {
        session = LiveTranscriptionSession(
            sessionID: UUID(), controllerGeneration: session.controllerGeneration, runtimeGeneration: 1,
            runtimeIdentity: session.runtimeIdentity)
        presenter.show(state: .listening(handsFree: handsFree, elapsedSeconds: elapsed))
        startSyntheticLevel()
    }

    /// A speech-like level at 30 Hz: syllables rising and falling, with short pauses.
    private func startSyntheticLevel() {
        levelTimer?.invalidate()
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                let t = CACurrentMediaTime() - start
                let syllable = max(0, sin(t * 2 * .pi * 3.1))
                let phrase = max(0, sin(t * 2 * .pi * 0.35) + 0.25)
                self?.presenter.updateInputLevel(Float(min(1, 0.85 * syllable * phrase)))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func snapshot(stable: String, wet: String, revision: UInt64) -> LiveTranscriptionSnapshot {
        LiveTranscriptionSnapshot(
            session: session, stablePrefix: stable, revisableTail: wet,
            lastAcceptedRevision: revision, decodedAudioWatermark: revision * 12_800)
    }

    private func playDictation(id: UUID) {
        presenter.setLiveTranscriptEnabled(true)
        listen(handsFree: true, elapsed: 0)
        playbackTask = Task { [weak self] in
            for (index, text) in Self.sampleFrames.enumerated() {
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
                guard let self, playbackID == id else { return }
                let words = text.split(separator: " ")
                let wetCount = min(3, words.count)
                let stable = words.dropLast(wetCount).joined(separator: " ")
                let wet = words.suffix(wetCount).joined(separator: " ")
                presenter.updateLiveTranscript(snapshot(
                    stable: stable.isEmpty ? "" : stable + " ", wet: wet, revision: UInt64(index + 1)))
            }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self, playbackID == id else { return }
            finish()
        }
    }

    private func finish() {
        guard isRunning else { return }
        playbackTask?.cancel()
        levelTimer?.invalidate()
        levelTimer = nil
        let id = UUID()
        playbackID = id
        presenter.show(state: .transcribing)
        playbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self, playbackID == id else { return }
            presenter.show(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: true))
            isRunning = false
        }
    }

    static let longSample = "The parties agree that the closing date will move from September 18 to September 25, and that the escrow instructions will be updated to reflect the new date. Please keep the exact wording of section four, and do not change the meaning of the indemnity clause. Send the revised draft to both counsel before Thursday so there is time for review, and note that the signature pages can be exchanged electronically. "

    static var sampleFrames: [String] {
        let sample = "Move the planning meeting from Thursday to Friday. Send the updated agenda before lunch so everyone has time to read it. We need to decide which rooms to book and check that there are enough chairs for the group. Leave a few minutes at the end for questions. After the meeting, pick up tomatoes, pasta, olive oil, and a loaf of bread. Check whether we need coffee before leaving. If the weather stays dry, take the path along the river and turn left at the bridge. The cafe has a few tables outside where we can stop after the walk. Bring a light jacket in case it gets cold on the way home."
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

private extension OverlayReviewPlayer.Sample {
    var showsLiveWords: Bool {
        switch self {
        case .dictation, .liveWaiting, .liveWords, .liveLong, .livePreviewStopped: true
        default: false
        }
    }
}
#endif
