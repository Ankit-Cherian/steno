#if os(macOS)
import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

// Each copy-instead-of-insert decision carries a typed reason from the place
// it is made. These run the production transports with only key posting,
// activation, the Accessibility client and the clipboard replaced.

private let terminal = AppContext(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")

private struct ReasonScenario {
    let keys = FakeKeyPoster()
    let activator: FakeApplicationActivator
    let accessibility: FakeAccessibilityClient
    let pasteboard = FakePasteboard()

    init(
        accessibility: FakeAccessibilityClient = FakeAccessibilityClient(),
        activator: FakeApplicationActivator = FakeApplicationActivator()
    ) {
        self.accessibility = accessibility
        self.activator = activator
    }

    func service(ownAppTextFocus: OwnAppTextFocus = .live) -> InsertionService {
        InsertionService(
            transports: MacInsertionTransportFactory.makeTransports(
                orderedMethods: defaultInsertionOrder,
                clipboard: pasteboard,
                system: makeFakeInsertionSystem(keys: keys, activator: activator, accessibility: accessibility),
                clipboardRestoreDelay: .milliseconds(20)
            ),
            ownAppTextFocus: ownAppTextFocus
        )
    }

    func dictate(
        _ text: String,
        service: InsertionService? = nil,
        duringTranscription: () -> Void = {}
    ) async throws -> InsertResult {
        let harness = try makeProductionCoordinator(
            recognizedText: text,
            insertionService: service ?? self.service(),
            accessibility: accessibility
        )
        let sessionID = try await harness.coordinator.startPressToTalk(
            appContext: productionPathContext,
            options: SessionStartOptions()
        )
        duringTranscription()
        return try await harness.coordinator.stopPressToTalk(sessionID: sessionID)
    }
}

@Suite("Typed copy reasons")
struct InsertionCopyReasonTests {
    @Test("A secure field is reported as a secure field")
    func secureField() async throws {
        let scenario = ReasonScenario(accessibility: FakeAccessibilityClient(secure: true))
        let result = try await scenario.dictate("hunter two")
        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .secureField)
    }

    @Test("Focus moving to another field is reported as a changed field")
    func fieldChanged() async throws {
        let scenario = ReasonScenario()
        let result = try await scenario.dictate("meant for field a") {
            scenario.accessibility.focus("field-B")
        }
        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .fieldChanged)
    }

    @Test("Steno's own window with no text field is reported as no text field")
    func noTextField() async throws {
        let scenario = ReasonScenario()
        let service = scenario.service(ownAppTextFocus: OwnAppTextFocus(
            ownBundleIdentifier: productionPathBundleID,
            focusAcceptsText: { false }
        ))
        let result = try await scenario.dictate("note for later", service: service)
        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .noTextField)
        #expect(result.errorMessage == nil)
    }

    @Test("A clipboard that changed before the paste is reported as such, and nothing is pasted")
    func clipboardChanged() async {
        let scenario = ReasonScenario(
            accessibility: FakeAccessibilityClient(focusedBundle: terminal.bundleIdentifier),
            activator: FakeApplicationActivator(frontmost: terminal.bundleIdentifier, running: [terminal.bundleIdentifier])
        )
        scenario.pasteboard.simulateExternalWriteAfterNextTransientWrite(
            FakePasteboard.Item(representations: ["public.utf8-plain-text": Data("other".utf8)])
        )
        let result = await scenario.service().insert(text: "git status", target: terminal)
        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .clipboardChanged)
        #expect(scenario.keys.events.isEmpty)
    }

    @Test("Missing Accessibility permission is reported as Accessibility off")
    func accessibilityOff() async {
        let scenario = ReasonScenario(
            accessibility: FakeAccessibilityClient(focusedBundle: terminal.bundleIdentifier, trusted: false),
            activator: FakeApplicationActivator(frontmost: terminal.bundleIdentifier, running: [terminal.bundleIdentifier])
        )
        let result = await scenario.service().insert(text: "git status", target: terminal)
        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .accessibilityOff)
        #expect(scenario.keys.events.isEmpty)
    }

    @Test("A target app that is no longer running is reported as a changed app")
    func appChanged() async {
        let scenario = ReasonScenario(
            accessibility: FakeAccessibilityClient(focusedBundle: "com.apple.Notes"),
            activator: FakeApplicationActivator(frontmost: "com.apple.Notes", running: ["com.apple.Notes"])
        )
        let result = await scenario.service().insert(text: "git status", target: terminal)
        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .appChanged)
        #expect(scenario.keys.events.isEmpty)
    }

    @Test("A sent paste carries no copy reason")
    func pasteHasNoReason() async {
        let scenario = ReasonScenario(
            accessibility: FakeAccessibilityClient(focusedBundle: terminal.bundleIdentifier),
            activator: FakeApplicationActivator(frontmost: terminal.bundleIdentifier, running: [terminal.bundleIdentifier])
        )
        let result = await scenario.service().insert(text: "git status", target: terminal)
        #expect(result.pasteAttempted == true)
        #expect(result.copyReason == nil)
    }

    @Test("Copying without inserting never activates an app or sends a key")
    func copyWithoutInserting() async {
        let scenario = ReasonScenario()
        let result = await scenario.service().copyWithoutInserting(
            text: "Undo text",
            reason: .appChanged,
            concealed: false,
            commitAuthorization: InsertionCommitAuthorization()
        )
        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .appChanged)
        #expect(scenario.pasteboard.plainText == "Undo text")
        #expect(scenario.keys.events.isEmpty)
        #expect(scenario.activator.activationRequests.isEmpty)
        #expect(scenario.accessibility.writes.isEmpty)
    }

    @Test("Copying without inserting can mark the copy concealed")
    func copyWithoutInsertingConcealed() async {
        let scenario = ReasonScenario()
        let result = await scenario.service().copyWithoutInserting(
            text: "hunter two",
            reason: .appChanged,
            concealed: true,
            commitAuthorization: InsertionCommitAuthorization()
        )
        #expect(result.copyIsConcealed == true)
        #expect(scenario.pasteboard.concealedWrites == ["hunter two"])
        #expect(scenario.pasteboard.plainWrites.isEmpty)
    }

    @Test("Target reasons map to the reason a person would recognise", arguments: [
        (EditorTargetUnavailableReason.secureOrProtectedElement, InsertionCopyReason.secureField),
        (.timedOut, .appNotResponding),
        (.accessibilityPermissionMissing, .accessibilityOff),
        (.applicationNotFrontmost, .appChanged),
        (.bundleIdentifierMismatch, .appChanged),
        (.targetChanged, .fieldChanged),
        (.focusedElementUnavailable, .fieldChanged),
        (.cancelled, .other),
    ])
    func targetReasons(reason: EditorTargetUnavailableReason, expected: InsertionCopyReason) {
        #expect(InsertionCopyReason(reason) == expected)
    }

    @Test("A result without a copy reason decodes, and one with it round-trips")
    func insertResultCoding() throws {
        let legacy = Data(#"{"status":"copiedOnly","method":"clipboardPaste","insertedText":"x"}"#.utf8)
        #expect(try JSONDecoder().decode(InsertResult.self, from: legacy).copyReason == nil)
        let result = InsertResult(status: .copiedOnly, method: .clipboardPaste, insertedText: "x", copyReason: .secureField)
        let decoded = try JSONDecoder().decode(InsertResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
    }
}
#endif
