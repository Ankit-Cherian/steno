#if os(macOS)
import AppKit
import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

// Dictation started from Steno's own window targets Steno itself. These run
// the production coordinator and the production transports, with only key
// posting, activation, the Accessibility client, the clipboard and the
// app's own focus replaced.

private let pasteFirstOrder: [InsertionMethod] = [.clipboardPaste, .direct, .accessibility]

/// Counts how often the own-window focus was read.
private final class FocusProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let acceptsText: Bool
    private var readsStorage = 0

    init(acceptsText: Bool) {
        self.acceptsText = acceptsText
    }

    func read() -> Bool {
        lock.withLock {
            readsStorage += 1
            return acceptsText
        }
    }

    var reads: Int { lock.withLock { readsStorage } }
}

private struct OwnWindowScenario {
    let keys = FakeKeyPoster()
    let activator = FakeApplicationActivator()
    let accessibility = FakeAccessibilityClient()
    let pasteboard = FakePasteboard(items: [copiedImageItem])
    let focus: FocusProbe

    init(focusAcceptsText: Bool) {
        focus = FocusProbe(acceptsText: focusAcceptsText)
    }

    func run(
        _ recognizedText: String,
        order: [InsertionMethod] = defaultInsertionOrder,
        ownBundleIdentifier: String = productionPathBundleID
    ) async throws -> (InsertResult, TranscriptEntry) {
        let focus = self.focus
        let service = InsertionService(
            transports: MacInsertionTransportFactory.makeTransports(
                orderedMethods: order,
                clipboard: pasteboard,
                system: makeFakeInsertionSystem(
                    keys: keys,
                    activator: activator,
                    accessibility: accessibility
                ),
                clipboardRestoreDelay: .milliseconds(20)
            ),
            ownAppTextFocus: OwnAppTextFocus(
                ownBundleIdentifier: ownBundleIdentifier,
                focusAcceptsText: { focus.read() }
            )
        )
        let harness = try makeProductionCoordinator(
            recognizedText: recognizedText,
            insertionService: service,
            accessibility: accessibility
        )
        let sessionID = try await harness.coordinator.startPressToTalk(
            appContext: productionPathContext,
            options: SessionStartOptions()
        )
        let result = try await harness.coordinator.stopPressToTalk(sessionID: sessionID)
        let entry = try #require(await harness.historyStore.recent(limit: 1).first)
        return (result, entry)
    }
}

@Test(
    "Steno's own window with no text field focused copies the transcript without typing or pasting",
    arguments: [defaultInsertionOrder, pasteFirstOrder]
)
func ownWindowWithoutTextFocusCopiesOnly(order: [InsertionMethod]) async throws {
    let scenario = OwnWindowScenario(focusAcceptsText: false)

    let (result, entry) = try await scenario.run("note for later", order: order)

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(result.pasteAttempted == nil)
    #expect(result.errorMessage == nil)
    #expect(scenario.keys.events.isEmpty)
    #expect(scenario.accessibility.writes.isEmpty)
    #expect(scenario.activator.activationRequests.isEmpty)
    #expect(scenario.pasteboard.transientWrites.isEmpty)
    #expect(scenario.pasteboard.plainText == "Note for later")
    // The transcript stays on the clipboard; the earlier image is not put back.
    try await Task.sleep(for: .milliseconds(200))
    #expect(scenario.pasteboard.restoreCount == 0)
    #expect(scenario.pasteboard.plainText == "Note for later")
    #expect(entry.insertionStatus == .copiedOnly)
    #expect(entry.pasteAttempted == nil)
    #expect(entry.cleanText == "Note for later")
}

@Test("A text field focused in Steno's own window still receives the transcript")
func ownWindowWithTextFocusStillInserts() async throws {
    let scenario = OwnWindowScenario(focusAcceptsText: true)

    let (result, entry) = try await scenario.run("brb")

    #expect(scenario.focus.reads == 1)
    #expect(result.status == .inserted)
    #expect(result.method == .direct)
    #expect(result.errorMessage == nil)
    #expect(scenario.keys.typedText.joined() == "Brb")
    #expect(scenario.pasteboard.plainText == nil)
    #expect(entry.insertionStatus == .inserted)
}

@Test("Another app as the target never reads Steno's own focus")
func otherAppTargetSkipsOwnFocusCheck() async throws {
    let scenario = OwnWindowScenario(focusAcceptsText: false)

    let (result, _) = try await scenario.run(
        "hello there",
        ownBundleIdentifier: "com.example.NotTheTarget"
    )

    #expect(scenario.focus.reads == 0)
    #expect(result.status == .inserted)
    #expect(result.method == .direct)
    #expect(scenario.keys.typedText.joined() == "Hello there")
}

@Test("Only an editable text view or another text input client counts as a focused text field")
@MainActor
func ownFocusAcceptsOnlyEditableText() {
    let fieldEditor = NSTextView()
    fieldEditor.isFieldEditor = true
    let readOnly = NSTextView()
    readOnly.isEditable = false
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )

    #expect(OwnAppTextFocus.acceptsText(fieldEditor))
    #expect(!OwnAppTextFocus.acceptsText(readOnly))
    #expect(!OwnAppTextFocus.acceptsText(window))
    #expect(!OwnAppTextFocus.acceptsText(NSButton()))
    #expect(!OwnAppTextFocus.acceptsText(nil))
}
#endif
