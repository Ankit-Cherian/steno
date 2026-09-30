#if os(macOS)
import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

// Default settings (nearby text off) through the production coordinator and
// the production transports in their default order. Only key posting,
// activation, the Accessibility client and the clipboard are fakes.

private struct GuardScenario {
    let keys = FakeKeyPoster()
    let activator = FakeApplicationActivator()
    let accessibility: FakeAccessibilityClient
    let pasteboard = FakePasteboard()

    init(accessibility: FakeAccessibilityClient = FakeAccessibilityClient()) {
        self.accessibility = accessibility
    }

    func run(
        _ recognizedText: String,
        target: AppContext = productionPathContext,
        options: SessionStartOptions = SessionStartOptions(),
        duringTranscription: () -> Void = {}
    ) async throws -> InsertResult {
        let service = InsertionService(transports: MacInsertionTransportFactory.makeTransports(
            orderedMethods: defaultInsertionOrder,
            clipboard: pasteboard,
            system: makeFakeInsertionSystem(
                keys: keys,
                activator: activator,
                accessibility: accessibility
            ),
            clipboardRestoreDelay: .milliseconds(20)
        ))
        let harness = try makeProductionCoordinator(
            recognizedText: recognizedText,
            insertionService: service,
            accessibility: accessibility
        )
        let sessionID = try await harness.coordinator.startPressToTalk(
            appContext: target,
            options: options
        )
        duringTranscription()
        return try await harness.coordinator.stopPressToTalk(sessionID: sessionID)
    }
}

@Test("Default settings: focus moved to another field copies instead of inserting")
func defaultSettingsFocusDriftCopiesOnly() async throws {
    let scenario = GuardScenario()

    let result = try await scenario.run("meant for field a") {
        scenario.accessibility.focus("field-B")
    }

    #expect(result.status == .copiedOnly)
    #expect(result.pasteAttempted == nil)
    #expect(result.errorMessage?.localizedCaseInsensitiveContains("focused field changed") == true)
    #expect(scenario.keys.events.isEmpty)
    #expect(scenario.accessibility.writes.isEmpty)
    #expect(scenario.pasteboard.plainText == "Meant for field a")
}

@Test("Default settings: a secure field at the start copies instead of typing")
func defaultSettingsSecureFieldCopiesOnly() async throws {
    let scenario = GuardScenario(accessibility: FakeAccessibilityClient(secure: true))

    let result = try await scenario.run("hunter two")

    #expect(result.status == .copiedOnly)
    #expect(result.errorMessage?.localizedCaseInsensitiveContains("secure") == true)
    #expect(scenario.keys.events.isEmpty)
    #expect(scenario.accessibility.writes.isEmpty)
}

@Test("Default settings: focus moved into a secure field copies instead of typing")
func defaultSettingsDriftIntoSecureFieldCopiesOnly() async throws {
    let scenario = GuardScenario()

    let result = try await scenario.run("hunter two") {
        scenario.accessibility.focus("password", secure: true)
    }

    #expect(result.status == .copiedOnly)
    #expect(scenario.keys.events.isEmpty)
    #expect(scenario.accessibility.writes.isEmpty)
}

@Test("Nearby text on: a secure field that blocks the exact target still copies only")
func nearbyTextSecureFieldCopiesOnly() async throws {
    let scenario = GuardScenario(accessibility: FakeAccessibilityClient(secure: true))

    let result = try await scenario.run(
        "hunter two",
        options: SessionStartOptions(nearbyContextEnabled: true)
    )

    #expect(result.status == .copiedOnly)
    #expect(result.errorMessage?.localizedCaseInsensitiveContains("secure") == true)
    #expect(scenario.keys.events.isEmpty)
    #expect(scenario.accessibility.writes.isEmpty)
}

@Test("Default settings: an Accessibility timeout keeps today's direct insertion")
func defaultSettingsLookupTimeoutStillInserts() async throws {
    let scenario = GuardScenario()
    scenario.accessibility.failCaptures(with: .timedOut)

    let result = try await scenario.run("slow app text")

    #expect(result.status == .inserted)
    #expect(result.method == .direct)
    #expect(scenario.keys.typedText.joined() == "Slow app text")
}

@Test("Default settings: an unchanged field inserts by direct typing, in the configured order")
func defaultSettingsUnchangedFieldInsertsDirectly() async throws {
    let scenario = GuardScenario()

    let result = try await scenario.run("same field")

    #expect(result.status == .inserted)
    #expect(result.method == .direct)
    #expect(scenario.keys.typedText.joined() == "Same field")
    #expect(scenario.accessibility.writes.isEmpty)
    #expect(scenario.pasteboard.transientWrites.isEmpty)
    #expect(scenario.pasteboard.plainWrites.isEmpty)
}

@Test("A timed-out start lookup still refuses a secure field at insertion")
func startTimeoutThenSecureFieldCopiesOnly() async throws {
    let scenario = GuardScenario()
    scenario.accessibility.failCaptures(with: .timedOut)

    let result = try await scenario.run("hunter two") {
        scenario.accessibility.failCaptures(with: nil)
        scenario.accessibility.focus("password", secure: true)
    }

    #expect(result.status == .copiedOnly)
    #expect(scenario.keys.events.isEmpty)
}

@Test("Terminal paste is not sent after focus moved to another field")
func terminalFocusDriftSkipsPaste() async throws {
    let terminal = AppContext(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")
    let scenario = GuardScenario(accessibility: FakeAccessibilityClient(focusedBundle: terminal.bundleIdentifier))
    scenario.activator.switchToOtherApp(terminal.bundleIdentifier, targetRefusesActivation: false)

    let result = try await scenario.run("git status", target: terminal) {
        scenario.accessibility.focus("another-tab")
    }

    #expect(result.status == .copiedOnly)
    #expect(result.pasteAttempted == nil)
    #expect(scenario.keys.events.isEmpty)
    #expect(scenario.pasteboard.plainText == "Git status")
}

private actor OrderedEvents {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private final class SyncEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ event: String) { lock.withLock { storage.append(event) } }
    var events: [String] { lock.withLock { storage } }
}

private actor RecordingCaptureService: AudioCaptureService {
    private let events: SyncEvents
    private let audioURL: URL

    init(events: SyncEvents, audioURL: URL) {
        self.events = events
        self.audioURL = audioURL
    }

    func beginCapture(sessionID: SessionID) async throws {
        _ = sessionID
        events.append("capture-started")
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        _ = sessionID
        return audioURL
    }

    func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
    }
}

@Test("The editor lookup runs on every session, only after audio capture has started")
func editorLookupRunsAfterCaptureStarts() async throws {
    let events = SyncEvents()
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("guard-order-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    let accessibility = FakeAccessibilityClient()
    let coordinator = SessionCoordinator(
        captureService: RecordingCaptureService(events: events, audioURL: audioURL),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in RawTranscript(text: "hello") },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(transports: [
            ClosureInsertionTransport(method: .direct) { _, _ in events.append("inserted") }
        ]),
        historyStore: HistoryStore(
            storageURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("guard-order-\(UUID().uuidString).json"),
            clipboardService: MemoryClipboardService()
        ),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { target in
            events.append("lookup")
            return EditorTargetHandle.capture(target: target, client: accessibility)
        }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: productionPathContext,
        options: SessionStartOptions()
    )
    #expect(events.events == ["capture-started", "lookup"])
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(events.events.first == "capture-started")
    #expect(events.events.last == "inserted")
}
#endif
