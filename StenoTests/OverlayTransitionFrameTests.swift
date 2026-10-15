import AppKit
import Testing
@testable import Steno
@testable import StenoKit

/// Drives the Grove overlay through real transitions on a real window and records what the
/// window server shows, frame by frame (see `WindowFrameRecorder`).
///
/// The survey writes contact sheets to `STENO_FRAME_OUTPUT` and runs only when that is set.
@Suite("Grove overlay transitions, frame by frame", .serialized)
@MainActor
struct OverlayTransitionFrameTests {
    struct Look: Sendable, CustomTestStringConvertible {
        let notch: Bool
        var testDescription: String { notch ? "notch" : "capsule" }
    }

    nonisolated static let looks: [Look] = [Look(notch: true), Look(notch: false)]

    nonisolated static var frameOutput: URL? {
        ProcessInfo.processInfo.environment["STENO_FRAME_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static let words = "Move the planning meeting from Thursday to Friday and send the updated agenda before lunch"
    static let inserted = OverlayState.result(.inserted(appName: "Mail", method: .typed), showsWords: true)

    /// One step of a sequence: wait, then act. With `marks`, the wait also lasts until the
    /// presenter has traced one of them, so the step lands in the phase it names however late
    /// a busy machine runs the animation.
    struct Step {
        let after: Duration
        var marks: [String] = []
        let label: String
        let action: @MainActor (WaveformOverlayPresenter) -> Void
    }

    static func listen(_ after: Duration = .zero) -> Step {
        Step(after: after, label: "call show(listening)") { $0.show(state: .listening(handsFree: false, elapsedSeconds: 0)) }
    }
    static func transcribe(_ after: Duration) -> Step {
        Step(after: after, label: "call show(transcribing)") { $0.show(state: .transcribing) }
    }
    static func insert(_ after: Duration) -> Step {
        Step(after: after, label: "call show(inserted)") { $0.show(state: inserted, insertedWords: words) }
    }
    static func wait(_ after: Duration) -> Step { Step(after: after, label: "wait") { _ in } }
    /// Waits until the presenter traces one of `marks`, then `after` more.
    static func wait(for marks: [String], then after: Duration = .zero) -> Step {
        Step(after: after, marks: marks, label: "wait") { _ in }
    }
    /// The traces a result writes when it starts to leave.
    static let leaving = ["fade begin", "retract begin"]

    @Test("Survey: every look, live words on and off, through a result and a restart",
          .enabled(if: frameOutput != nil),
          .enabled("the window server must be drawing") { await WindowFrameRecorder.canCaptureWindows }, arguments: looks)
    func survey(look: Look) async throws {
        let root = try #require(Self.frameOutput)
        for live in [true, false] {
            let tag = "\(look.testDescription)-\(live ? "live" : "nolive")"
            // (a) A result that leaves on its own.
            try await record(look: look, live: live, name: "\(tag)-a-result-hides", to: root, steps: [
                Self.listen(), Self.transcribe(.milliseconds(700)), Self.insert(.milliseconds(400)), Self.wait(.milliseconds(3_000)),
            ])
            // (b) A new dictation while the result shows: just after it appears, mid-hold and as it leaves.
            for (moment, delay) in [("appear", 60), ("hold", 1_000), ("leaving", 2_060), ("leaving-late", 2_200)] {
                try await record(look: look, live: live, name: "\(tag)-b-restart-\(moment)", to: root, steps: [
                    Self.listen(), Self.transcribe(.milliseconds(700)), Self.insert(.milliseconds(400)),
                    Self.listen(.milliseconds(delay)), Self.wait(.milliseconds(800)),
                ])
            }
        }
        // (c) A notice over nothing, a notice over the result, and a copied result.
        try await record(look: look, live: true, name: "\(look.testDescription)-c-notice-hidden", to: root, steps: [
            Step(after: .zero, label: "call showNotice") { $0.showNotice("Hands-free is off") }, Self.wait(.milliseconds(2_300)),
        ])
        try await record(look: look, live: true, name: "\(look.testDescription)-c-notice-over-result", to: root, steps: [
            Self.listen(), Self.transcribe(.milliseconds(500)), Self.insert(.milliseconds(300)),
            Step(after: .milliseconds(300), label: "call showNotice") { $0.showNotice("Hands-free is off", duration: .milliseconds(600)) },
            Self.wait(.milliseconds(2_800)),
        ])
        try await record(look: look, live: true, name: "\(look.testDescription)-c-copied-restart", to: root, steps: [
            Self.listen(), Self.transcribe(.milliseconds(500)),
            Step(after: .milliseconds(300), label: "call show(copied)") {
                $0.show(state: .result(.copied(.secureField), showsWords: true), insertedWords: Self.words)
            },
            Self.listen(.milliseconds(1_200)), Self.wait(.milliseconds(800)),
        ])
    }

    // MARK: - Regression

    /// A result leaves once: after its fade (or the notch's retraction) begins it only grows
    /// fainter, and once the panel is ordered out nothing of it is drawn again.
    @Test("A result that leaves on its own never comes back on screen",
          .enabled("the window server must be drawing; it is not while the displays sleep") { await WindowFrameRecorder.canCaptureWindows },
          arguments: looks)
    func resultLeavesOnce(look: Look) async throws {
        let recording = try await record(look: look, live: true, name: "regression-\(look.testDescription)-a", to: Self.frameOutput, steps: [
            Self.listen(), Self.transcribe(.milliseconds(300)), Self.insert(.milliseconds(300)),
            Self.wait(for: ["orderOut"], then: .milliseconds(300)),
        ])
        let leaving = try #require(recording.time(of: "fade begin") ?? recording.time(of: "retract begin"), "the result left")
        let orderedOut = try #require(recording.time(of: "orderOut"), "the panel was ordered out")
        var previous = 1.0
        for frame in recording.visibleFrames where frame.time > leaving {
            let opacity = frame.opacity
            #expect(opacity <= previous + 0.05,
                    "\(look): opacity rose from \(previous) to \(opacity) at \(Int((frame.time - leaving) * 1000)) ms into leaving")
            previous = opacity
        }
        // Captures run on their own thread; one already under way may finish just after the order-out.
        let after = recording.visibleFrames.filter { $0.time > orderedOut + 0.02 }
        #expect(after.isEmpty, "\(look): \(after.count) frames drawn after the order-out, up to \(Int(((after.last?.time ?? orderedOut) - orderedOut) * 1000)) ms, alpha up to \(after.map(\.alpha).max() ?? 0)")
    }

    struct Restart: Sendable, CustomTestStringConvertible {
        let look: Look
        let name: String
        /// After the result shows.
        let milliseconds: Int
        /// Restart once the result has begun to leave, rather than at a time.
        var whileLeaving = false
        var testDescription: String { "\(look.testDescription)-\(name)" }
    }

    nonisolated static let restarts: [Restart] = looks.flatMap { look in
        [Restart(look: look, name: "holding", milliseconds: 900),
         Restart(look: look, name: "leaving", milliseconds: 200, whileLeaving: true)]
    }

    /// A new dictation while a result is up starts from nothing, as one from a hidden overlay
    /// does: the result's words never show inside the listening island, and the panel appears
    /// afresh rather than morphing out of the card.
    @Test("A new dictation over a result appears fresh, without the result's words",
          .enabled("the window server must be drawing; it is not while the displays sleep") { await WindowFrameRecorder.canCaptureWindows },
          arguments: restarts)
    func restartAppearsFresh(restart: Restart) async throws {
        final class Box { var rect: CGRect? }
        let label = Box()
        let recording = try await record(look: restart.look, live: true, name: "regression-\(restart.testDescription)-b", to: Self.frameOutput, steps: [
            // Long enough for the capture thread, which can stall for a few hundred milliseconds on a
            // window that has just come on screen when the machine is busy.
            Self.listen(), Self.transcribe(.milliseconds(1_000)), Self.insert(.milliseconds(300)),
            Step(after: .milliseconds(200), label: "measure the result's words") { label.rect = $0.hostedEvidenceGroveLabelWindowRect() },
            restart.whileLeaving
                ? Step(after: .zero, marks: Self.leaving, label: "call show(listening)") { $0.show(state: .listening(handsFree: false, elapsedSeconds: 0)) }
                : Self.listen(.milliseconds(restart.milliseconds - 200)),
            Self.wait(.milliseconds(1_200)),
        ])
        let words = try #require(label.rect, "the result showed words")
        let restarted = try #require(recording.marks.last { $0.label == "call show(listening)" }?.time)
        let presented = recording.marks.filter { $0.time >= restarted && $0.label.hasPrefix("present") }
        #expect(presented.first?.label.contains("appearing=true") == true,
                "\(restart): presented as \(presented.first?.label ?? "nothing")")
        // Frames are judged from the moment the presenter showed the new island, which a busy
        // main thread can delay well past the call.
        let shown = presented.first?.time ?? restarted
        // What a fresh listening island draws where the result's words were: the first session's,
        // from its appearance until it stopped.
        let started = try #require(recording.marks.first { $0.label == "call show(listening)" }?.time)
        let stopped = try #require(recording.time(of: "call show(transcribing)"))
        let settled = recording.visibleFrames.filter { $0.time > started && $0.time < stopped }
        try #require(!settled.isEmpty, "\(restart): the first listening island showed")
        let fresh = settled.map { $0.brightness(in: words) }.max() ?? 0
        let frames = recording.visibleFrames.filter { $0.time > shown + 0.02 }
        // It shows, and stays: a show during the result's fade must not be faded with it.
        #expect(frames.last.map { $0.opacity > 0.9 } == true,
                "\(restart): the listening island showed (last opacity \(frames.last?.opacity ?? 0))")
        for frame in frames {
            let ink = frame.brightness(in: words)
            #expect(ink <= fresh + 0.03,
                    "\(restart): the result's words showed at \(Int((frame.time - shown) * 1000)) ms (brightness \(ink), fresh \(fresh))")
        }
    }

    // MARK: - Harness

    /// A presenter with a real window on the main display, in `look`, with motion on.
    static func makePresenter(look: Look, live: Bool) -> WaveformOverlayPresenter {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.appearance = .grove
        presenter.placementOverride = look.notch ? .notch : .capsule
        presenter.updateAppearance(NSAppearance(named: .darkAqua))
        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: false, reduceTransparency: false, increaseContrast: false, preferredBodyPointSize: 13
        ))
        presenter.setLiveTranscriptEnabled(live)
        presenter.setStopAction {}
        presenter.onCopyResult = {}
        presenter.onUndoDiscard = {}
        presenter.onOpenSettings = { _ in }
        presenter.pinNextSessionToDisplay(containing: NSScreen.main.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) })
        presenter.prepareWindow()
        return presenter
    }

    /// Runs `steps` on a fresh presenter while recording its window, writes the contact sheet
    /// `name`.png under `directory` when given, and returns the recording.
    @discardableResult
    func record(look: Look, live: Bool, name: String, to directory: URL?, steps: [Step],
                configure: ((WaveformOverlayPresenter) -> Void)? = nil) async throws -> WindowFrameRecorder.Recording {
        try #require(WindowFrameRecorder.isAvailable)
        if directory != nil, let filter = ProcessInfo.processInfo.environment["STENO_FRAME_FILTER"],
           !filter.split(separator: ",").contains(where: { name.contains($0) }) {
            return WindowFrameRecorder.Recording(start: 0, frames: [], marks: [])
        }
        let presenter = Self.makePresenter(look: look, live: live)
        configure?(presenter)
        let windowNumber = try #require(presenter.hostedEvidenceWindowNumber())
        let recorder = WindowFrameRecorder(windowID: CGWindowID(windowNumber))
        presenter.setHostedTraceHandler { recorder.mark($0) }
        recorder.start()
        for step in steps {
            if !step.marks.isEmpty {
                try #require(await eventuallyOnMain { recorder.hasMark(containing: step.marks) }, "no \(step.marks) traced")
            }
            if step.after > .zero { try await Task.sleep(for: step.after) }
            recorder.mark(step.label)
            step.action(presenter)
        }
        let recording = recorder.stop()
        presenter.setHostedTraceHandler(nil)
        presenter.hide()
        if let directory {
            try FrameContactSheet.write(recording, title: name, to: directory.appendingPathComponent(name + ".png"))
            let log = recording.marks.map { String(format: "%7.1f ms  %@", ($0.time - recording.start) * 1000, $0.label) }
            try log.joined(separator: "\n").write(to: directory.appendingPathComponent(name + ".log"), atomically: true, encoding: .utf8)
            let rows = recording.frames.map { frame -> String in
                let box = frame.opaqueBox().map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" } ?? "-"
                return String(format: "%7.1f\t%@\t%.2f\t%@\t%@", (frame.time - recording.start) * 1000,
                              frame.isOnscreen ? "on" : "off", frame.alpha, NSStringFromRect(frame.bounds), box)
            }
            try rows.joined(separator: "\n").write(to: directory.appendingPathComponent(name + ".frames.tsv"), atomically: true, encoding: .utf8)
        }
        return recording
    }
}
