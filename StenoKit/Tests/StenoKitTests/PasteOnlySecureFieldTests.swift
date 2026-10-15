#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import StenoKit

/// With the insertion order set to paste only, a transcript that is copied instead of pasted
/// into a secure field is written concealed and recorded as concealed, as with the default order.
@Suite("PasteOnlySecureField")
struct PasteOnlySecureFieldTests {
    private func pasteOnlyScenario(
        accessibility: FakeAccessibilityClient,
        keys: FakeKeyPoster,
        pasteboard: FakePasteboard
    ) -> InsertionService {
        InsertionService(transports: MacInsertionTransportFactory.makeTransports(
            orderedMethods: [.clipboardPaste],
            clipboard: pasteboard,
            system: makeFakeInsertionSystem(
                keys: keys,
                activator: FakeApplicationActivator(),
                accessibility: accessibility
            ),
            clipboardRestoreDelay: .milliseconds(20)
        ))
    }

    @Test("With paste-only order, a secure field at the start is copied concealed and recorded as concealed")
    func pasteOnlySecureFieldAtStartCopiesConcealed() async throws {
        let keys = FakeKeyPoster()
        let pasteboard = FakePasteboard()
        let accessibility = FakeAccessibilityClient(secure: true)
        let service = pasteOnlyScenario(accessibility: accessibility, keys: keys, pasteboard: pasteboard)
        let harness = try makeProductionCoordinator(
            recognizedText: "hunter two", insertionService: service, accessibility: accessibility
        )
        let id = try await harness.coordinator.startPressToTalk(
            appContext: productionPathContext, options: SessionStartOptions()
        )
        let result = try await harness.coordinator.stopPressToTalk(sessionID: id)

        // Preconditions: the refusal itself works, nothing was typed or pasted.
        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .secureField)
        #expect(keys.events.isEmpty)
        #expect(pasteboard.plainText == "Hunter two")
        #expect(pasteboard.transientWrites.isEmpty, "the refused text was first written for a paste: \(pasteboard.transientWrites)")

        // The contract: a transcript copied instead of typed into a password field is concealed.
        let entry = try #require(await harness.historyStore.recent(limit: 1).first)
        #expect(result.copyIsConcealed == true, "copyIsConcealed: \(String(describing: result.copyIsConcealed))")
        #expect(pasteboard.isConcealed, "clipboard items: \(pasteboard.items.map { $0.representations.keys.sorted() })")
        #expect(pasteboard.concealedWrites == ["Hunter two"], "concealed \(pasteboard.concealedWrites), transient \(pasteboard.transientWrites), plain \(pasteboard.plainWrites)")
        #expect(entry.concealedCopy == true, "concealedCopy: \(String(describing: entry.concealedCopy))")
    }

    @Test("With paste-only order, focus moving into a secure field is copied concealed and recorded as concealed")
    func pasteOnlyDriftIntoSecureFieldCopiesConcealed() async throws {
        let keys = FakeKeyPoster()
        let pasteboard = FakePasteboard()
        let accessibility = FakeAccessibilityClient()
        let service = pasteOnlyScenario(accessibility: accessibility, keys: keys, pasteboard: pasteboard)
        let harness = try makeProductionCoordinator(
            recognizedText: "hunter two", insertionService: service, accessibility: accessibility
        )
        let id = try await harness.coordinator.startPressToTalk(
            appContext: productionPathContext, options: SessionStartOptions()
        )
        accessibility.focus("password", secure: true)
        let result = try await harness.coordinator.stopPressToTalk(sessionID: id)

        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .secureField)
        #expect(keys.events.isEmpty)
        #expect(pasteboard.plainText == "Hunter two")
        #expect(pasteboard.transientWrites.isEmpty, "the refused text was first written for a paste: \(pasteboard.transientWrites)")

        let entry = try #require(await harness.historyStore.recent(limit: 1).first)
        #expect(result.copyIsConcealed == true, "copyIsConcealed: \(String(describing: result.copyIsConcealed))")
        #expect(pasteboard.isConcealed, "clipboard items: \(pasteboard.items.map { $0.representations.keys.sorted() })")
        #expect(entry.concealedCopy == true, "concealedCopy: \(String(describing: entry.concealedCopy))")
    }

    @Test("With paste-only order, a field that turns secure after the paste write leaves a concealed copy, not the paste write")
    func pasteOnlyFieldTurningSecureAfterThePasteWriteRewritesTheCopyConcealed() async throws {
        let keys = FakeKeyPoster()
        let pasteboard = FakePasteboard()
        let accessibility = FakeAccessibilityClient()
        pasteboard.onTransientWrite { accessibility.focus("password", secure: true) }
        let service = pasteOnlyScenario(accessibility: accessibility, keys: keys, pasteboard: pasteboard)
        let harness = try makeProductionCoordinator(
            recognizedText: "hunter two", insertionService: service, accessibility: accessibility
        )
        let id = try await harness.coordinator.startPressToTalk(
            appContext: productionPathContext, options: SessionStartOptions()
        )
        let result = try await harness.coordinator.stopPressToTalk(sessionID: id)

        // Preconditions: the paste write happened, then the secure field refused the paste.
        #expect(result.status == .copiedOnly)
        #expect(result.copyReason == .secureField)
        #expect(keys.events.isEmpty)
        #expect(pasteboard.transientWrites == ["Hunter two"])

        #expect(result.copyIsConcealed == true, "copyIsConcealed: \(String(describing: result.copyIsConcealed))")
        #expect(pasteboard.concealedWrites == ["Hunter two"], "concealed \(pasteboard.concealedWrites), transient \(pasteboard.transientWrites), plain \(pasteboard.plainWrites)")
        #expect(pasteboard.isConcealed, "clipboard items: \(pasteboard.items.map { $0.representations.keys.sorted() })")
        #expect(pasteboard.items.first?.representations["org.nspasteboard.TransientType"] == nil)
        #expect(pasteboard.plainText == "Hunter two")
        let entry = try #require(await harness.historyStore.recent(limit: 1).first)
        #expect(entry.concealedCopy == true, "concealedCopy: \(String(describing: entry.concealedCopy))")
    }
}
#endif
