#if DEBUG
import AppKit
import StenoKit

/// `--overlay-benchmark grove <notch|capsule>`, with `--isolated-ui-preview`: shows the
/// listening overlay with a synthetic 30 Hz level for 60 seconds, then hides it and quits, so
/// its cost can be sampled from outside (`top -pid`). It uses no microphone, History or
/// settings. Debug builds only.
@MainActor
enum OverlayBenchmark {
    static let duration: TimeInterval = 60

    struct Request: Equatable {
        let form: WaveformOverlayPresenter.PlacementOverride
    }

    private static var presenter: WaveformOverlayPresenter?
    private static var levelTimer: Timer?

    /// Reads the request from the launch arguments. Needs the isolated preview flag.
    static func request(from arguments: [String]) -> Request? {
        guard arguments.contains("--isolated-ui-preview"),
              let index = arguments.firstIndex(of: "--overlay-benchmark"),
              arguments.indices.contains(index + 2), arguments[index + 1] == "grove" else { return nil }
        let form: WaveformOverlayPresenter.PlacementOverride
        switch arguments[index + 2] {
        case "notch": form = .notch
        case "capsule": form = .capsule
        default: return nil
        }
        return Request(form: form)
    }

    static func runIfRequested() {
        guard !IsolatedAppPreview.isTestHost, let request = request(from: ProcessInfo.processInfo.arguments) else { return }
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: true)
        presenter.appearance = .grove
        presenter.placementOverride = request.form
        presenter.setLiveTranscriptEnabled(false)
        presenter.setStopAction {}
        presenter.setCancelAction {}
        self.presenter = presenter
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))

        // A speech-like level at 30 Hz: syllables rising and falling, with short pauses.
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor in
                let t = CACurrentMediaTime() - start
                let syllable = max(0, sin(t * 2 * .pi * 3.1))
                let phrase = max(0, sin(t * 2 * .pi * 0.35) + 0.25)
                presenter.updateInputLevel(Float(min(1, 0.85 * syllable * phrase)))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            Task { @MainActor in
                levelTimer?.invalidate()
                levelTimer = nil
                presenter.hide()
                self.presenter = nil
                NSApp.terminate(nil)
            }
        }
    }
}
#endif
