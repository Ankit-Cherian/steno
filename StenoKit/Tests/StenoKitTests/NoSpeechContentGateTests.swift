#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

private let terminalContext = AppContext(
    bundleIdentifier: "com.apple.Terminal",
    appName: "Terminal"
)

private let aggressiveProfile = StyleProfile(
    name: "Aggressive",
    tone: .natural,
    structureMode: .paragraph,
    fillerPolicy: .aggressive,
    commandPolicy: .transform
)

private struct GateOutcome {
    var result: InsertResult
    var keys: FakeKeyPoster
    var pasteboard: FakePasteboard
    var history: [TranscriptEntry]
}

private func dictate(
    _ recognizedText: String,
    target: AppContext = productionPathContext,
    profile: StyleProfile? = nil
) async throws -> GateOutcome {
    let keys = FakeKeyPoster()
    let pasteboard = FakePasteboard(items: [copiedImageItem])
    let accessibility = FakeAccessibilityClient(focusedBundle: target.bundleIdentifier)
    let service = InsertionService(transports: MacInsertionTransportFactory.makeTransports(
        orderedMethods: defaultInsertionOrder,
        clipboard: pasteboard,
        system: makeFakeInsertionSystem(
            keys: keys,
            activator: FakeApplicationActivator(
                frontmost: target.bundleIdentifier,
                running: [target.bundleIdentifier]
            ),
            accessibility: accessibility
        ),
        clipboardRestoreDelay: .milliseconds(20)
    ))
    let harness = try makeProductionCoordinator(
        recognizedText: recognizedText,
        insertionService: service,
        accessibility: accessibility,
        profile: profile
    )
    let sessionID = try await harness.coordinator.startPressToTalk(
        appContext: target,
        options: SessionStartOptions()
    )
    let result = try await harness.coordinator.stopPressToTalk(sessionID: sessionID)
    return GateOutcome(
        result: result,
        keys: keys,
        pasteboard: pasteboard,
        history: await harness.historyStore.recent(limit: 10)
    )
}

@Test("Recognized text with no letter or digit is treated as no speech", arguments: [".", "...", "…", "?", ", ", "- -"])
func punctuationOnlyRecognitionIsNoSpeech(recognized: String) async throws {
    let outcome = try await dictate(recognized)

    #expect(outcome.result.status == .noSpeech)
    #expect(outcome.keys.events.isEmpty)
    #expect(outcome.history.isEmpty)
}

@Test("Fillers that aggressive cleanup removes entirely are treated as no speech", arguments: ["um uh", "uh, um"])
func fillerOnlyAggressiveCleanupIsNoSpeech(recognized: String) async throws {
    let outcome = try await dictate(recognized, target: terminalContext, profile: aggressiveProfile)

    #expect(outcome.result.status == .noSpeech)
    #expect(outcome.keys.events.isEmpty)
    #expect(outcome.history.isEmpty)
    // The user's clipboard is untouched.
    #expect(outcome.pasteboard.items == [copiedImageItem])
    #expect(outcome.pasteboard.transientWrites.isEmpty)
    #expect(outcome.pasteboard.plainWrites.isEmpty)
}

@Test("Spoken words still insert, including a spoken punctuation command")
func spokenWordsStillInsert() async throws {
    let words = try await dictate("hello there")
    #expect(words.result.status == .inserted)
    #expect(words.keys.typedText.joined() == "Hello there")

    let digits = try await dictate("42")
    #expect(digits.result.status == .inserted)

    let command = try await dictate("period")
    #expect(command.result.status != .noSpeech)
    #expect(command.history.count == 1)

    let newLine = try await dictate("new line")
    #expect(newLine.result.status != .noSpeech)
    #expect(newLine.history.count == 1)
}
#endif
