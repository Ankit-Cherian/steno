#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

private final class MockMacAccessibilityClient: MacAccessibilityClient, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotStorage: MacAXTargetSnapshot
    private var trustedStorage = true
    private var capturedErrorStorage: EditorTargetUnavailableReason?
    private var settableStorage = true
    private var settableErrorStorage: EditorTargetUnavailableReason?
    private var contextReadErrorStorage: EditorTargetUnavailableReason?
    private var setResultStorage: MacAXSetTextResult = .inserted
    private var prefixStorage = ""
    private var suffixStorage = ""
    private var rangeRequestsStorage: [EditorTextSelection] = []
    private var writesStorage: [String] = []
    private var selectionRequestCountStorage = 0
    private var characterCountRequestCountStorage = 0

    init(snapshot: MacAXTargetSnapshot = makeTargetSnapshot()) {
        snapshotStorage = snapshot
    }

    func isProcessTrusted() -> Bool {
        lock.withLock { trustedStorage }
    }

    func captureFocusedTarget(expectedBundleIdentifier: String) throws -> MacAXTargetSnapshot {
        try lock.withLock {
            if let capturedErrorStorage { throw capturedErrorStorage }
            guard snapshotStorage.process.bundleIdentifier == expectedBundleIdentifier else {
                throw EditorTargetUnavailableReason.bundleIdentifierMismatch
            }
            // Mirror the system client contract: protection is classified
            // before selection or character-count access.
            if !snapshotStorage.isProtected {
                selectionRequestCountStorage += 1
                characterCountRequestCountStorage += 1
            }
            return snapshotStorage
        }
    }

    func string(for range: EditorTextSelection, in element: MacAXElementReference) throws -> String {
        try lock.withLock {
            rangeRequestsStorage.append(range)
            if let contextReadErrorStorage { throw contextReadErrorStorage }
            return range.location < snapshotStorage.selection.location ? prefixStorage : suffixStorage
        }
    }

    func isSelectedTextSettable(in element: MacAXElementReference) throws -> Bool {
        try lock.withLock {
            if let settableErrorStorage { throw settableErrorStorage }
            return settableStorage
        }
    }

    func setSelectedText(_ text: String, in element: MacAXElementReference) -> MacAXSetTextResult {
        lock.withLock {
            writesStorage.append(text)
            return setResultStorage
        }
    }

    func setSnapshot(_ snapshot: MacAXTargetSnapshot) {
        lock.withLock { snapshotStorage = snapshot }
    }

    func setCapturedError(_ error: EditorTargetUnavailableReason?) {
        lock.withLock { capturedErrorStorage = error }
    }

    func setSettable(_ value: Bool) {
        lock.withLock { settableStorage = value }
    }

    func setSettableError(_ error: EditorTargetUnavailableReason?) {
        lock.withLock { settableErrorStorage = error }
    }

    func setContextReadError(_ error: EditorTargetUnavailableReason?) {
        lock.withLock { contextReadErrorStorage = error }
    }

    func setSetResult(_ result: MacAXSetTextResult) {
        lock.withLock { setResultStorage = result }
    }

    func setContext(prefix: String, suffix: String) {
        lock.withLock {
            prefixStorage = prefix
            suffixStorage = suffix
        }
    }

    var rangeRequests: [EditorTextSelection] {
        lock.withLock { rangeRequestsStorage }
    }

    var writes: [String] {
        lock.withLock { writesStorage }
    }

    var selectionRequestCount: Int {
        lock.withLock { selectionRequestCountStorage }
    }

    var characterCountRequestCount: Int {
        lock.withLock { characterCountRequestCountStorage }
    }
}

private func makeTargetSnapshot(
    processIdentifier: Int32 = 42,
    launchMarker: UInt64 = 100,
    bundleIdentifier: String = "com.example.Editor",
    windowID: String = "window-1",
    elementID: String = "element-1",
    role: String = "AXTextArea",
    subrole: String? = nil,
    isProtected: Bool = false,
    selection: EditorTextSelection = EditorTextSelection(location: 700, length: 3),
    characterCount: Int = 1_500
) -> MacAXTargetSnapshot {
    MacAXTargetSnapshot(
        process: EditorTargetProcessIdentity(
            processIdentifier: processIdentifier,
            launchMarker: launchMarker,
            bundleIdentifier: bundleIdentifier
        ),
        window: MacAXElementReference(testIdentifier: windowID),
        element: MacAXElementReference(testIdentifier: elementID),
        role: role,
        subrole: subrole,
        isProtected: isProtected,
        selection: selection,
        characterCount: characterCount
    )
}

private let editorContext = AppContext(
    bundleIdentifier: "com.example.Editor",
    appName: "Editor"
)

private func capturedHandle(client: MockMacAccessibilityClient) throws -> EditorTargetHandle {
    try EditorTargetHandle.capture(target: editorContext, client: client).get()
}

@Test("Editor context reads only bounded ranges and trims both sides")
func editorContextIsBounded() async throws {
    let client = MockMacAccessibilityClient()
    client.setContext(
        prefix: String(repeating: "p", count: 512),
        suffix: String(repeating: "s", count: 512)
    )
    let handle = try capturedHandle(client: client)

    guard case .available(let context) = await handle.context() else {
        Issue.record("Expected bounded editor context")
        return
    }

    #expect(client.rangeRequests == [
        EditorTextSelection(location: 188, length: 512),
        EditorTextSelection(location: 703, length: 512)
    ])
    #expect(context.prefix.count == 256)
    #expect(context.suffix.count == 256)
    #expect(context.prefix.utf8.count + context.suffix.utf8.count <= 8 * 1_024)
}

@Test("Editor context enforces the serialized byte ceiling for escaped content")
func editorContextEnforcesByteCeiling() async throws {
    let client = MockMacAccessibilityClient()
    client.setContext(
        prefix: String(repeating: "\u{001F}", count: 512),
        suffix: String(repeating: "\u{001F}", count: 512)
    )
    let handle = try capturedHandle(client: client)

    guard case .available(let context) = await handle.context() else {
        Issue.record("Expected bounded editor context")
        return
    }
    #expect(context.prefix.count <= 256)
    #expect(context.suffix.count <= 256)
    let serialized = try JSONSerialization.data(withJSONObject: [
        "leadingText": context.prefix,
        "trailingText": context.suffix
    ])
    #expect(serialized.count <= 8 * 1_024)
}

@Test("Secure targets fail before any context read")
func secureEditorTargetFailsClosed() {
    let client = MockMacAccessibilityClient(
        snapshot: makeTargetSnapshot(subrole: "AXSecureTextField", isProtected: true)
    )

    let result = EditorTargetHandle.capture(target: editorContext, client: client)
    guard case .failure(let reason) = result else {
        Issue.record("Secure target unexpectedly produced a handle")
        return
    }
    #expect(reason == .secureOrProtectedElement)
    #expect(client.selectionRequestCount == 0)
    #expect(client.characterCountRequestCount == 0)
    #expect(client.rangeRequests.isEmpty)
}

@Test("Protected-content targets fail before selection, count, or string reads")
func protectedContentEditorTargetFailsClosed() {
    let client = MockMacAccessibilityClient(
        snapshot: makeTargetSnapshot(subrole: nil, isProtected: true)
    )

    let result = EditorTargetHandle.capture(target: editorContext, client: client)
    guard case .failure(let reason) = result else {
        Issue.record("Protected-content target unexpectedly produced a handle")
        return
    }
    #expect(reason == .secureOrProtectedElement)
    #expect(client.selectionRequestCount == 0)
    #expect(client.characterCountRequestCount == 0)
    #expect(client.rangeRequests.isEmpty)
}

@Test("Selection and timeout failures make context unavailable")
func editorContextFailuresAreUnavailable() async throws {
    let client = MockMacAccessibilityClient()
    let handle = try capturedHandle(client: client)
    client.setCapturedError(.timedOut)

    #expect(await handle.context() == .unavailable(.timedOut))
    #expect(client.rangeRequests.isEmpty)
}

@Test(
    "Context-only AX failures preserve exact-target direct insertion",
    arguments: [
        EditorTargetUnavailableReason.parameterizedTextUnavailable,
        .timedOut,
        .accessibilityError,
    ]
)
func contextReadFailureDoesNotPoisonDirectInsertion(
    reason: EditorTargetUnavailableReason
) async throws {
    let client = MockMacAccessibilityClient(snapshot: makeTargetSnapshot(
        selection: EditorTextSelection(location: 6, length: 3),
        characterCount: 14
    ))
    client.setContextReadError(reason)
    let handle = try capturedHandle(client: client)

    #expect(await handle.context() == .unavailable(reason))
    #expect(await handle.replaceSelectedText(with: "hello") == .inserted)
    #expect(client.writes == ["hello"])
}

@Test(
    "A later context-read failure preserves baseline proof without sticky invalidation",
    arguments: [
        EditorTargetUnavailableReason.parameterizedTextUnavailable,
        .timedOut,
        .accessibilityError,
    ]
)
func laterContextReadFailureFailsClosedWithoutPoisoningHandle(
    reason: EditorTargetUnavailableReason
) async throws {
    let client = MockMacAccessibilityClient(snapshot: makeTargetSnapshot(
        selection: EditorTextSelection(location: 6, length: 3),
        characterCount: 14
    ))
    client.setContext(prefix: "before", suffix: "after")
    let handle = try capturedHandle(client: client)
    #expect(await handle.context() == .available(EditorContextSnapshot(
        prefix: "before",
        suffix: "after",
        selection: EditorTextSelection(location: 6, length: 3),
        characterCount: 14
    )))

    client.setContextReadError(reason)
    switch await handle.revalidate() {
    case .failure(let failure):
        #expect(failure == reason)
    case .success:
        Issue.record("Lost bounded-context proof unexpectedly revalidated")
    }
    #expect(await handle.replaceSelectedText(with: "never") == .rejected(reason))
    #expect(client.writes.isEmpty)

    client.setContextReadError(nil)
    if case .failure(let failure) = await handle.revalidate() {
        Issue.record("Recovered context read remained poisoned by \(failure)")
    }
    #expect(await handle.replaceSelectedText(with: "hello") == .inserted)
    #expect(client.writes == ["hello"])
}

@Test("A non-frontmost application cannot produce an editor handle")
func nonFrontmostApplicationFailsClosed() {
    let client = MockMacAccessibilityClient()
    client.setCapturedError(.applicationNotFrontmost)

    let result = EditorTargetHandle.capture(target: editorContext, client: client)
    guard case .failure(let reason) = result else {
        Issue.record("Non-frontmost application unexpectedly produced a handle")
        return
    }
    #expect(reason == .applicationNotFrontmost)
    #expect(client.rangeRequests.isEmpty)
    #expect(client.writes.isEmpty)
}

@Test("An AX provider returning more text than requested fails closed")
func oversizedParameterizedTextFailsClosed() async throws {
    let client = MockMacAccessibilityClient()
    client.setContext(prefix: String(repeating: "x", count: 513), suffix: "")
    let handle = try capturedHandle(client: client)

    #expect(await handle.context() == .unavailable(.parameterizedTextUnavailable))
}

@Test("An AX provider returning less text than requested fails closed")
func truncatedParameterizedTextFailsClosed() async throws {
    let client = MockMacAccessibilityClient()
    client.setContext(prefix: String(repeating: "x", count: 511), suffix: "")
    let handle = try capturedHandle(client: client)

    #expect(await handle.context() == .unavailable(.parameterizedTextUnavailable))
}

@Test("Bounded context drift invalidates an otherwise identical target")
func boundedContextDriftInvalidatesTarget() async throws {
    let client = MockMacAccessibilityClient(snapshot: makeTargetSnapshot(
        selection: EditorTextSelection(location: 6, length: 3),
        characterCount: 14
    ))
    client.setContext(prefix: "before", suffix: "after")
    let handle = try capturedHandle(client: client)
    #expect(await handle.context() == .available(
        EditorContextSnapshot(
            prefix: "before",
            suffix: "after",
            selection: EditorTextSelection(location: 6, length: 3),
            characterCount: 14
        )
    ))

    client.setContext(prefix: "change", suffix: "after")
    switch await handle.revalidate() {
    case .failure(let reason):
        #expect(reason == .targetChanged)
    case .success:
        Issue.record("Changed bounded context passed exact revalidation")
    }
    #expect(await handle.replaceSelectedText(with: "never") == .rejected(.targetChanged))
    #expect(client.writes.isEmpty)
}

@Test("Exact selected-text replacement requires a settable attribute")
func exactReplacementRequiresSettableSelectedText() async throws {
    let client = MockMacAccessibilityClient()
    let handle = try capturedHandle(client: client)
    client.setSettable(false)

    #expect(await handle.replaceSelectedText(with: "hello") == .rejected(.selectedTextNotSettable))
    #expect(client.writes.isEmpty)
}

@Test("Indeterminate AX writes are surfaced without a retry")
func indeterminateWriteIsSurfaced() async throws {
    let client = MockMacAccessibilityClient()
    let handle = try capturedHandle(client: client)
    client.setSetResult(.indeterminate)

    #expect(await handle.replaceSelectedText(with: "hello") == .indeterminate)
    #expect(client.writes == ["hello"])
}

@Test("Ten thousand focus transitions never authorize a stale handle")
func staleHandleStressTest() async throws {
    let client = MockMacAccessibilityClient()

    for index in 0..<10_000 {
        client.setSnapshot(makeTargetSnapshot(elementID: "element-\(index)"))
        let handle = try capturedHandle(client: client)
        client.setSnapshot(makeTargetSnapshot(elementID: "element-\(index + 1)"))

        switch await handle.revalidate() {
        case .failure(let reason):
            #expect(reason == .targetChanged)
        case .success:
            Issue.record("A stale handle passed exact revalidation")
        }
        #expect(await handle.replaceSelectedText(with: "never") == .rejected(.targetChanged))
    }
    #expect(client.writes.isEmpty)
}

@Test("Observed target drift permanently invalidates the session handle")
func targetDriftIsSticky() async throws {
    let original = makeTargetSnapshot()
    let client = MockMacAccessibilityClient(snapshot: original)
    let handle = try capturedHandle(client: client)
    client.setSnapshot(makeTargetSnapshot(elementID: "other"))
    if case .success = await handle.revalidate() {
        Issue.record("Drift unexpectedly passed revalidation")
    }

    client.setSnapshot(original)
    switch await handle.revalidate() {
    case .failure(let reason):
        #expect(reason == .targetChanged)
    case .success:
        Issue.record("Restoring focus re-authorized an invalidated handle")
    }
    #expect(await handle.replaceSelectedText(with: "never") == .rejected(.targetChanged))
    #expect(client.writes.isEmpty)
}

@Test("Accessibility transport honors the supplied captured target")
func accessibilityTransportRejectsDriftedCapturedTarget() async throws {
    let client = MockMacAccessibilityClient()
    let handle = try capturedHandle(client: client)
    client.setSnapshot(makeTargetSnapshot(windowID: "different-window"))
    let transport = AccessibilityInsertionTransport(client: client)

    do {
        try await transport.insert(text: "never", target: editorContext, editorTarget: handle)
        Issue.record("Expected exact-target insertion to fail")
    } catch let error as MacInsertionError {
        guard case .exactTargetUnavailable(let reason) = error else {
            Issue.record("Unexpected insertion error: \(error)")
            return
        }
        #expect(reason == .targetChanged)
    }
    #expect(client.writes.isEmpty)
}
#endif
