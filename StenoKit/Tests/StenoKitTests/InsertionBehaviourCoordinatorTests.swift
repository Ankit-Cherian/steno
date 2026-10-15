#if os(macOS)
import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

// Coordinator paths behind Undo after discard and Paste Last Dictation, run
// through the production transports with only the OS seams replaced.

private struct CoordinatorScenario {
    let keys = FakeKeyPoster()
    let activator = FakeApplicationActivator()
    let accessibility: FakeAccessibilityClient
    let pasteboard = FakePasteboard()
    let harness: ProductionCoordinatorHarness

    init(recognizedText: String = "restored words", secure: Bool = false) throws {
        accessibility = FakeAccessibilityClient(secure: secure)
        let service = InsertionService(transports: MacInsertionTransportFactory.makeTransports(
            orderedMethods: defaultInsertionOrder,
            clipboard: pasteboard,
            system: makeFakeInsertionSystem(keys: keys, activator: activator, accessibility: accessibility),
            clipboardRestoreDelay: .milliseconds(20)
        ))
        harness = try makeProductionCoordinator(
            recognizedText: recognizedText,
            insertionService: service,
            accessibility: accessibility
        )
    }
}

@Suite("Insertion behaviours in the coordinator")
struct InsertionBehaviourCoordinatorTests {
    @Test("A held recording completed with a copy reason is copied, never inserted, and saved in History")
    func copyingCompletion() async throws {
        let scenario = try CoordinatorScenario()
        let coordinator = scenario.harness.coordinator
        let sessionID = try await coordinator.startPressToTalk(appContext: productionPathContext, options: SessionStartOptions())
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)

        let result = try await coordinator.completePressToTalk(sessionID: sessionID, copyingBecause: .appChanged)

        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .appChanged)
        #expect(scenario.pasteboard.plainText == "Restored words")
        #expect(scenario.keys.events.isEmpty)
        #expect(scenario.accessibility.writes.isEmpty)
        #expect(scenario.activator.activationRequests.isEmpty)
        let entry = try #require(await scenario.harness.historyStore.recent(limit: 1).first)
        #expect(entry.insertionStatus == .copiedOnly)
        #expect(entry.cleanText == "Restored words")
    }

    @Test("A held recording from a secure field is copied concealed when its app changed, and History records that")
    func copyingCompletionFromSecureField() async throws {
        let scenario = try CoordinatorScenario(secure: true)
        let coordinator = scenario.harness.coordinator
        let sessionID = try await coordinator.startPressToTalk(appContext: productionPathContext, options: SessionStartOptions())
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)

        let result = try await coordinator.completePressToTalk(sessionID: sessionID, copyingBecause: .appChanged)

        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .appChanged)
        #expect(result.copyIsConcealed == true)
        #expect(scenario.pasteboard.concealedWrites == ["Restored words"])
        #expect(scenario.pasteboard.plainWrites.isEmpty)
        let entry = try #require(await scenario.harness.historyStore.recent(limit: 1).first)
        #expect(entry.concealedCopy == true)
    }

    @Test("A dictation refused at a secure field is recorded as a concealed copy; others are not")
    func concealedCopyIsRecorded() async throws {
        let secure = try CoordinatorScenario(secure: true)
        let secureID = try await secure.harness.coordinator.startPressToTalk(appContext: productionPathContext, options: SessionStartOptions())
        let secureResult = try await secure.harness.coordinator.stopPressToTalk(sessionID: secureID)
        #expect(secureResult.copyIsConcealed == true)
        #expect(try #require(await secure.harness.historyStore.recent(limit: 1).first).concealedCopy == true)

        let plain = try CoordinatorScenario()
        let plainID = try await plain.harness.coordinator.startPressToTalk(appContext: productionPathContext, options: SessionStartOptions())
        let plainResult = try await plain.harness.coordinator.stopPressToTalk(sessionID: plainID)
        #expect(plainResult.copyIsConcealed == nil)
        #expect(try #require(await plain.harness.historyStore.recent(limit: 1).first).concealedCopy == nil)
    }

    @Test("A History entry without the concealed marker decodes, and one with it round-trips")
    func concealedMarkerCoding() throws {
        let legacy = Data(#"{"id":"6A3C5B0E-6E0B-4C3A-9C3E-1F1F1F1F1F1F","createdAt":0,"appBundleID":"x","rawText":"a","cleanText":"a","durationMS":0,"insertionStatus":"copiedOnly"}"#.utf8)
        #expect(try JSONDecoder().decode(TranscriptEntry.self, from: legacy).concealedCopy == nil)
        var entry = try JSONDecoder().decode(TranscriptEntry.self, from: legacy)
        entry.concealedCopy = true
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.concealedCopy == true)
    }

    @Test("A held recording completed without a copy reason inserts as Stop would")
    func normalCompletion() async throws {
        let scenario = try CoordinatorScenario()
        let coordinator = scenario.harness.coordinator
        let sessionID = try await coordinator.startPressToTalk(appContext: productionPathContext, options: SessionStartOptions())
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)

        let result = try await coordinator.completePressToTalk(sessionID: sessionID, copyingBecause: nil)

        #expect(result.status == .inserted)
        #expect(scenario.keys.typedText.joined() == "Restored words")
    }

    @Test("A canceled held recording can no longer be completed")
    func canceledHeldRecording() async throws {
        let scenario = try CoordinatorScenario()
        let coordinator = scenario.harness.coordinator
        let sessionID = try await coordinator.startPressToTalk(appContext: productionPathContext, options: SessionStartOptions())
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)
        #expect(await coordinator.holdsCapturedRecording(sessionID: sessionID))
        await coordinator.cancel(sessionID: sessionID)
        #expect(await !coordinator.holdsCapturedRecording(sessionID: sessionID))

        await #expect(throws: SessionCoordinatorError.self) {
            _ = try await coordinator.completePressToTalk(sessionID: sessionID)
        }
        #expect(scenario.keys.events.isEmpty)
        #expect(await scenario.harness.historyStore.recent(limit: 1).isEmpty)
    }

    @Test("Inserting earlier text types it once and records nothing in History")
    func insertTextOnce() async throws {
        let scenario = try CoordinatorScenario()

        let result = await scenario.harness.coordinator.insertText("Earlier dictation.", into: productionPathContext)

        #expect(result.status == .inserted)
        #expect(scenario.keys.typedText.joined() == "Earlier dictation.")
        #expect(await scenario.harness.historyStore.recent(limit: 1).isEmpty)
    }

    @Test("Inserting earlier text into a secure field copies it concealed instead")
    func insertTextSecureField() async throws {
        let scenario = try CoordinatorScenario(secure: true)

        let result = await scenario.harness.coordinator.insertText("Earlier dictation.", into: productionPathContext)

        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .secureField)
        #expect(scenario.keys.events.isEmpty)
        #expect(scenario.accessibility.writes.isEmpty)
        #expect(scenario.pasteboard.concealedWrites == ["Earlier dictation."])
    }
}

@Suite("Restoring a discarded recording")
struct RestoredTranscriptionStateTests {
    @Test("Work without recording starts only from idle")
    func onlyFromIdle() {
        var machine = RecordingStateMachine()
        let first = machine.beginWorkWithoutRecording()
        #expect(first)
        #expect(machine.state == .transcribing)
        let second = machine.beginWorkWithoutRecording()
        #expect(!second)

        var recording = RecordingStateMachine(initialState: .recordingHandsFree)
        let whileRecording = recording.beginWorkWithoutRecording()
        #expect(!whileRecording)
        #expect(recording.state == .recordingHandsFree)
    }
}
#endif
