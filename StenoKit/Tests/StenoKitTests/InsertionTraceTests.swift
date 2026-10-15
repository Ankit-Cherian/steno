#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

/// The line with every duration removed, so it can be compared literally.
private func withoutDurations(_ line: String) -> String {
    line.replacingOccurrences(of: #" \d+ ms"#, with: "", options: .regularExpression)
}

private final class TraceLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}

/// Every bundle identifier the fakes use, none of which may reach the public log line.
private let identifiers = ["com.example.ProductionPathEditor", "com.apple.Notes"]

@Test("The insertion log line names each step and why the text was copied, without the text or any app")
func insertionTraceNamesEachStepOfACopy() async {
    let activator = FakeApplicationActivator()
    let accessibility = FakeAccessibilityClient()
    activator.switchToOtherApp("com.apple.Notes", targetRefusesActivation: true)
    accessibility.focusOtherApp("com.apple.Notes")
    let service = makeProductionInsertionService(
        clipboard: FakePasteboard(),
        keys: FakeKeyPoster(),
        activator: activator,
        accessibility: accessibility
    )
    let traced = TraceLines()

    let result = await InsertionTrace.$observer.withValue({ traced.append($0) }) {
        await service.insert(text: "private words", target: productionPathContext)
    }

    #expect(result.status == .copiedOnly)
    #expect(traced.lines.map(withoutDurations) == [
        "insertion copied (appChanged) via clipboardPaste into target in: "
            + "activate: not frontmost after 3 tries, another app in front; direct failed applicationNotFrontmost; "
            + "focused field failed bundleIdentifierMismatch; accessibility failed bundleIdentifierMismatch; "
            + "clipboard snapshot 0 items; clipboard write; activate: not frontmost after 3 tries, another app in front; "
            + "clipboardPaste skipped appChanged"
    ])
    #expect(traced.lines.allSatisfy { !$0.contains("private words") })
    #expect(traced.lines.allSatisfy { line in !identifiers.contains { line.contains($0) } })
    #expect(traced.lines.allSatisfy { !$0.contains("com.") })
}

@Test("The insertion log line for a typed dictation names the transport that inserted it")
func insertionTraceNamesTheTransportThatInserted() async {
    let service = makeProductionInsertionService(
        clipboard: FakePasteboard(),
        keys: FakeKeyPoster(),
        activator: FakeApplicationActivator(),
        accessibility: FakeAccessibilityClient()
    )
    let traced = TraceLines()

    _ = await InsertionTrace.$observer.withValue({ traced.append($0) }) {
        await service.insert(text: "hello there", target: productionPathContext)
    }

    #expect(traced.lines.map(withoutDurations) == [
        "insertion inserted via direct into target in: "
            + "activate: frontmost after 1 tries; typing 1 chunks; direct ok"
    ])
    #expect(traced.lines.allSatisfy { !$0.contains("com.") })
}
#endif
