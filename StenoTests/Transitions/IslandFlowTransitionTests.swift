import AppKit
import StenoKit
import Testing
@testable import Steno
@testable import StenoKit

/// The island's own controls on a real controller: Stop, Discard while
/// listening and while transcribing, Undo after a discard, Copy on a result that was not
/// inserted, and the no-speech answer.
@Suite("Island flow transitions", .serialized)
@MainActor
struct IslandFlowTransitionTests {
    private func session(outcome: ScriptedCoordinator.Outcome) async throws -> WindowDictation {
        let session = try await WindowDictation.make(outcome: outcome)
        session.overlay.appearance = .grove
        return session
    }

    private func until(_ condition: @MainActor () async -> Bool) async -> Bool {
        await eventuallyOnMain(condition)
    }

    private func shown(_ session: WindowDictation) -> OverlayState? { session.overlay.hostedEvidenceShownStates().last }

    private func isListening(_ session: WindowDictation) -> Bool {
        if case .listening(true, _) = shown(session) { return true }
        return false
    }

    @Test("Stop on the island ends a hands-free dictation and the island says it was inserted")
    func stop() async throws {
        let session = try await session(outcome: .init(text: "Send it now.", status: .inserted))
        defer { Task { await session.close() } }
        session.controller.toggleHandsFree()
        #expect(await until { isListening(session) && session.overlay.hostedEvidenceStopIsAvailable() }, "no Stop")
        session.overlay.hostedEvidencePressStop()
        #expect(await until { session.controller.recentEntries.first?.cleanText == "Send it now." }, "Stop finished nothing")
        #expect(await until {
            if case .result(.inserted, _) = shown(session) { return true }
            return false
        }, "the island shows \(String(describing: shown(session)))")
    }

    @Test("Discard on the island throws a long recording away, and Undo on it inserts it once")
    func discardThenUndo() async throws {
        let session = try await session(outcome: .init(text: "Keep it.", status: .inserted))
        defer { Task { await session.close() } }
        session.controller.undoDiscardMinimumRecording = 0
        session.controller.toggleHandsFree()
        #expect(await until { isListening(session) && session.overlay.hostedEvidenceCancelIsAvailable() }, "no Discard")
        session.overlay.hostedEvidencePressCancel()
        #expect(await until { session.overlay.hostedEvidenceActionTitle() == "Undo" }, "no Undo, shows \(String(describing: shown(session)))")
        #expect(session.controller.recentEntries.isEmpty)
        session.overlay.hostedEvidencePressAction()
        #expect(await until { session.controller.recentEntries.first?.cleanText == "Keep it." }, "Undo inserted nothing")
        #expect(await session.coordinator.count("transcribe") == 1)
    }

    @Test("Discard while transcribing cancels it, and nothing is added")
    func cancelTranscribing() async throws {
        let session = try await session(outcome: .init(text: "Never mind.", status: .inserted))
        defer { Task { await session.close() } }
        await session.coordinator.hold()
        session.controller.toggleHandsFree()
        #expect(await until { isListening(session) })
        session.controller.stopRecording()
        #expect(await until { shown(session) == .transcribing && session.overlay.hostedEvidenceCancelIsAvailable() },
                "no Discard while transcribing")
        // Discard while the transcription is in progress, not before it has begun.
        #expect(await until { await session.coordinator.count("transcribe") == 1 })
        session.overlay.hostedEvidencePressCancel()
        // The island's button hands the cancel to the main actor on its next turn, so the held
        // transcription is let go only once the cancel has landed, as a person's would be.
        #expect(await until { session.controller.recordingLifecycleState == .idle }, "Discard did not cancel")
        await session.coordinator.release()
        #expect(await until { await session.coordinator.count("returned") == 1 })
        #expect(await session.coordinator.count("finished") == 0, "the canceled transcription finished")
        #expect(session.controller.recentEntries.isEmpty, "a canceled dictation was saved")
        #expect(shown(session) != .transcribing || !session.overlay.hostedEvidenceIsVisible(), "the island stayed on Transcribing")
    }

    @Test("A dictation that was not inserted offers Copy on the island, and Copy copies its words")
    func copyNotInserted() async throws {
        let session = try await session(outcome: .init(text: "Paste me later.", status: .failed))
        defer { Task { await session.close() } }
        session.controller.toggleHandsFree()
        #expect(await until { isListening(session) })
        session.controller.stopRecording()
        #expect(await until { session.overlay.hostedEvidenceActionTitle() == "Copy" },
                "no Copy, shows \(String(describing: shown(session)))")
        session.overlay.hostedEvidencePressAction()
        let copied = await until { await session.clipboard.latestValue == "Paste me later." }
        #expect(copied, "Copy did not copy")
    }

    @Test("No speech: the island says so and adds nothing")
    func noSpeech() async throws {
        let session = try await session(outcome: .init(text: "", status: .noSpeech))
        defer { Task { await session.close() } }
        session.controller.toggleHandsFree()
        #expect(await until { isListening(session) })
        session.controller.stopRecording()
        #expect(await until { session.overlay.hostedEvidenceShownStates().contains(.noSpeechDetected) },
                "shows \(String(describing: shown(session)))")
        #expect(session.controller.recentEntries.isEmpty)
    }
}
