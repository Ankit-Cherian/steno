#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

private enum ExactTargetTestError: Error {
    case unavailable
}

private actor ExactTargetEventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor ExactTargetCountingClipboard: ClipboardService {
    private(set) var copyCount = 0
    private(set) var latestText: String?
    private let eventLog: ExactTargetEventLog?

    init(eventLog: ExactTargetEventLog? = nil) {
        self.eventLog = eventLog
    }

    func setString(_ text: String) async throws {
        try Task.checkCancellation()
        copyCount += 1
        latestText = text
        await eventLog?.append("clipboard")
    }
}

private actor ExactTargetThrowingClipboard: ClipboardService {
    private(set) var copyAttempts = 0

    func setString(_ text: String) async throws {
        _ = text
        copyAttempts += 1
        throw ExactTargetTestError.unavailable
    }
}

private actor ExactTargetBlockingClipboard: ClipboardService {
    private(set) var copyCount = 0
    private(set) var copiedTexts: [String] = []
    private var copyWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func setString(_ text: String) async throws {
        try Task.checkCancellation()
        copyCount += 1
        copiedTexts.append(text)
        let waiters = copyWaiters
        copyWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilCopied() async {
        guard copyCount == 0 else { return }
        await withCheckedContinuation { continuation in
            copyWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ExactTargetPasteGate {
    private(set) var pasteCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func paste() async -> AutoPasteOutcome {
        pasteCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return .attempted
    }

    func waitUntilStarted() async {
        guard pasteCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor AuthorizedPasteGate {
    private(set) var pasteCount = 0
    private var hasStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pasteIfAuthorized(_ permit: InsertionCommitPermit?) async -> AutoPasteOutcome {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        guard let permit,
              permit.performIfAuthorized({ true }) == true else {
            return .skipped(reason: "Auto-paste canceled.")
        }
        pasteCount += 1
        return .attempted
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class ExactTargetAccessibilityClient: MacAccessibilityClient, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotStorage: MacAXTargetSnapshot
    private var settableStorage = true
    private var setResultStorage: MacAXSetTextResult = .inserted
    private var writesStorage: [String] = []
    private var textStorage: String
    private var contentReadCountStorage = 0

    init(
        snapshot: MacAXTargetSnapshot = makeExactTargetSnapshot(),
        text: String = ""
    ) {
        snapshotStorage = snapshot
        textStorage = text
    }

    func isProcessTrusted() -> Bool {
        true
    }

    func captureFocusedTarget(expectedBundleIdentifier: String) throws -> MacAXTargetSnapshot {
        try lock.withLock {
            guard snapshotStorage.process.bundleIdentifier == expectedBundleIdentifier else {
                throw EditorTargetUnavailableReason.bundleIdentifierMismatch
            }
            return snapshotStorage
        }
    }

    func string(for range: EditorTextSelection, in element: MacAXElementReference) throws -> String {
        _ = element
        return try lock.withLock {
            contentReadCountStorage += 1
            let utf16Count = textStorage.utf16.count
            guard range.location >= 0,
                  range.length >= 0,
                  range.location <= utf16Count,
                  range.length <= utf16Count - range.location else {
                throw EditorTargetUnavailableReason.parameterizedTextUnavailable
            }
            return (textStorage as NSString).substring(
                with: NSRange(location: range.location, length: range.length)
            )
        }
    }

    func isSelectedTextSettable(in element: MacAXElementReference) throws -> Bool {
        _ = element
        return lock.withLock { settableStorage }
    }

    func setSelectedText(_ text: String, in element: MacAXElementReference) -> MacAXSetTextResult {
        _ = element
        return lock.withLock {
            writesStorage.append(text)
            return setResultStorage
        }
    }

    func setSnapshot(_ snapshot: MacAXTargetSnapshot) {
        lock.withLock { snapshotStorage = snapshot }
    }

    func simulateDirectInsertion(_ text: String, actualText: String? = nil) {
        lock.withLock {
            let selection = snapshotStorage.selection
            let replacement = actualText ?? text
            textStorage = (textStorage as NSString).replacingCharacters(
                in: NSRange(location: selection.location, length: selection.length),
                with: replacement
            )
            snapshotStorage = snapshotStorage.replacingMutableTextState(
                selection: EditorTextSelection(
                    location: selection.location + replacement.utf16.count,
                    length: 0
                ),
                characterCount: textStorage.utf16.count
            )
        }
    }

    func driftElement(to elementID: String) {
        lock.withLock {
            snapshotStorage = MacAXTargetSnapshot(
                process: snapshotStorage.process,
                window: snapshotStorage.window,
                element: MacAXElementReference(testIdentifier: elementID),
                role: snapshotStorage.role,
                subrole: snapshotStorage.subrole,
                isProtected: snapshotStorage.isProtected,
                selection: snapshotStorage.selection,
                characterCount: snapshotStorage.characterCount
            )
        }
    }

    func setSettable(_ settable: Bool) {
        lock.withLock { settableStorage = settable }
    }

    func setSetResult(_ result: MacAXSetTextResult) {
        lock.withLock { setResultStorage = result }
    }

    var writes: [String] {
        lock.withLock { writesStorage }
    }

    var text: String {
        lock.withLock { textStorage }
    }

    var selection: EditorTextSelection {
        lock.withLock { snapshotStorage.selection }
    }

    var contentReadCount: Int {
        lock.withLock { contentReadCountStorage }
    }
}

private extension MacAXTargetSnapshot {
    func replacingMutableTextState(
        selection: EditorTextSelection,
        characterCount: Int
    ) -> MacAXTargetSnapshot {
        MacAXTargetSnapshot(
            process: process,
            window: window,
            element: element,
            role: role,
            subrole: subrole,
            isProtected: isProtected,
            selection: selection,
            characterCount: characterCount
        )
    }
}

private final class ExactTargetPostedChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ chunk: String) {
        lock.withLock { storage.append(chunk) }
    }

    var chunks: [String] {
        lock.withLock { storage }
    }
}

private func containsUnpairedUTF16Surrogate(_ text: String) -> Bool {
    let units = Array(text.utf16)
    var index = 0
    while index < units.count {
        let unit = units[index]
        if (0xD800...0xDBFF).contains(unit) {
            guard index + 1 < units.count,
                  (0xDC00...0xDFFF).contains(units[index + 1]) else {
                return true
            }
            index += 2
        } else if (0xDC00...0xDFFF).contains(unit) {
            return true
        } else {
            index += 1
        }
    }
    return false
}

private let exactTargetAppContext = AppContext(
    bundleIdentifier: "com.example.ExactEditor",
    appName: "Exact Editor"
)

private func makeExactTargetSnapshot(
    windowID: String = "window-1",
    elementID: String = "element-1",
    selection: EditorTextSelection = EditorTextSelection(location: 0, length: 0),
    characterCount: Int = 0
) -> MacAXTargetSnapshot {
    MacAXTargetSnapshot(
        process: EditorTargetProcessIdentity(
            processIdentifier: 42,
            launchMarker: 100,
            bundleIdentifier: exactTargetAppContext.bundleIdentifier
        ),
        window: MacAXElementReference(testIdentifier: windowID),
        element: MacAXElementReference(testIdentifier: elementID),
        role: "AXTextArea",
        subrole: nil,
        isProtected: false,
        selection: selection,
        characterCount: characterCount
    )
}

private func makeExactTargetHandle(
    client: ExactTargetAccessibilityClient
) throws -> EditorTargetHandle {
    try EditorTargetHandle.capture(target: exactTargetAppContext, client: client).get()
}

@Test("Captured targets prioritize accessibility, direct typing, then clipboard")
func exactTargetTransportOrdering() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    let events = ExactTargetEventLog()
    let clipboard = ExactTargetCountingClipboard(eventLog: events)
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(clipboard: clipboard),
        ClosureInsertionTransport(method: .direct) { _, _ in
            await events.append("direct")
            throw ExactTargetTestError.unavailable
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            await events.append("accessibility")
            throw ExactTargetTestError.unavailable
        }
    ])

    let result = await service.insert(
        text: "authoritative final",
        target: exactTargetAppContext,
        editorTarget: handle
    )

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(await events.snapshot() == ["accessibility", "direct", "clipboard"])
    #expect(await clipboard.copyCount == 1)
}

@Test("A successful exact accessibility write stops all fallback transports")
func exactAccessibilitySuccessStopsFallback() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    let events = ExactTargetEventLog()
    let clipboard = ExactTargetCountingClipboard()
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(clipboard: clipboard),
        ClosureInsertionTransport(method: .direct) { _, _ in
            await events.append("direct-commit")
        },
        AccessibilityInsertionTransport(client: client)
    ])

    let result = await service.insert(
        text: "one write",
        target: exactTargetAppContext,
        editorTarget: handle
    )

    #expect(result.status == .inserted)
    #expect(result.method == .accessibility)
    #expect(client.writes == ["one write"])
    #expect(await events.snapshot().isEmpty)
    #expect(await clipboard.copyCount == 0)
}

@Test("Target drift prevents direct and paste commits while copying the final once")
func targetDriftCopiesOnceWithoutDirectOrPasteCommit() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    client.setSnapshot(makeExactTargetSnapshot(elementID: "different-element"))

    let clipboard = ExactTargetCountingClipboard()
    let commits = ExactTargetEventLog()
    let service = InsertionService(transports: [
        AccessibilityInsertionTransport(client: client),
        ClosureInsertionTransport(method: .direct) { _, _ in
            switch await handle.revalidate() {
            case .success:
                await commits.append("direct")
            case .failure(let reason):
                throw MacInsertionError.exactTargetUnavailable(reason)
            }
        },
        ClipboardInsertionTransport(
            clipboard: clipboard,
            autoPaste: { _, _ in
                await commits.append("generic-paste")
                return .attempted
            },
            exactTargetAutoPaste: { _, editorTarget, _ in
                guard case .success = await editorTarget.revalidate() else {
                    return .skipped(reason: "Target changed—final text copied.")
                }
                await commits.append("exact-paste")
                return .attempted
            }
        )
    ])

    let result = await service.insert(
        text: "safe recovery",
        target: exactTargetAppContext,
        editorTarget: handle
    )

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(result.errorMessage == "Target changed—final text copied.")
    #expect(client.writes.isEmpty)
    #expect(await commits.snapshot().isEmpty)
    #expect(await clipboard.copyCount == 1)
    #expect(await clipboard.latestText == "safe recovery")
}

@Test("Late target drift copies canonical recovery instead of the shaped attempt")
func targetDriftCopiesCanonicalRecoveryText() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    client.setSettable(false)

    let clipboard = ExactTargetCountingClipboard()
    let commits = ExactTargetEventLog()
    let service = InsertionService(transports: [
        AccessibilityInsertionTransport(client: client),
        ClosureInsertionTransport(method: .direct) { text, _ in
            await commits.append("direct-attempt:\(text)")
            throw ExactTargetTestError.unavailable
        },
        ClipboardInsertionTransport(
            clipboard: clipboard,
            exactTargetAutoPaste: { _, editorTarget, _ in
                client.setSnapshot(makeExactTargetSnapshot(elementID: "different-element"))
                guard case .success = await editorTarget.revalidate() else {
                    return .skipped(reason: "Target changed—canonical final copied.")
                }
                await commits.append("paste")
                return .attempted
            }
        )
    ])

    let result = await service.insert(
        text: " this continues",
        target: exactTargetAppContext,
        editorTarget: handle,
        clipboardRecoveryText: "This continues"
    )

    #expect(result.status == .copiedOnly)
    #expect(result.insertedText == "This continues")
    #expect(result.errorMessage == "Target changed—canonical final copied.")
    #expect(client.writes.isEmpty)
    #expect(await commits.snapshot() == ["direct-attempt: this continues"])
    #expect(await clipboard.copyCount == 2)
    #expect(await clipboard.latestText == "This continues")
}

@Test("Missing exact paste support never invokes the generic auto-paste callback")
func exactTargetDoesNotUseGenericAutoPaste() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    let clipboard = ExactTargetCountingClipboard()
    let events = ExactTargetEventLog()
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(
            clipboard: clipboard,
            autoPaste: { _, _ in
                await events.append("generic-paste")
                return .attempted
            }
        )
    ])

    let result = await service.insert(
        text: "copy only",
        target: exactTargetAppContext,
        editorTarget: handle
    )

    #expect(result.status == .copiedOnly)
    #expect(result.errorMessage == "Exact-target auto-paste is unavailable; final text was copied.")
    #expect(await clipboard.copyCount == 1)
    #expect(await events.snapshot().isEmpty)
}

@Test("An indeterminate AX write is terminal and cannot fall through")
func indeterminateAccessibilityWriteIsTerminal() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    client.setSetResult(.indeterminate)
    let clipboard = ExactTargetCountingClipboard()
    let commits = ExactTargetEventLog()
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(clipboard: clipboard),
        ClosureInsertionTransport(method: .direct) { _, _ in
            await commits.append("direct")
        },
        AccessibilityInsertionTransport(client: client)
    ])

    let result = await service.insert(
        text: "maybe inserted",
        target: exactTargetAppContext,
        editorTarget: handle
    )

    #expect(result.status == .failed)
    #expect(result.method == .accessibility)
    #expect(result.errorMessage == "The editor did not confirm whether the insertion completed")
    #expect(client.writes == ["maybe inserted"])
    #expect(await commits.snapshot().isEmpty)
    #expect(await clipboard.copyCount == 0)
}

@Test("Direct typing revalidates every chunk and treats post-event drift as terminal")
func directTypingPostEventDriftIsTerminal() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    let posted = ExactTargetPostedChunks()
    let clipboard = ExactTargetCountingClipboard()
    let direct = DirectTypingInsertionTransport(
        isProcessTrusted: { true },
        preparedEventPoster: { _, _, chunk, index in
            posted.append(chunk)
            client.simulateDirectInsertion(chunk)
            if index == 0 {
                client.driftElement(to: "same-length-drift")
            }
        }
    )
    let service = InsertionService(transports: [
        direct,
        ClipboardInsertionTransport(clipboard: clipboard)
    ])

    let result = await service.insert(
        text: String(repeating: "a", count: 45),
        target: exactTargetAppContext,
        editorTarget: handle
    )

    #expect(result.status == .failed)
    #expect(result.method == .direct)
    #expect(result.errorMessage == "The editor did not confirm whether the insertion completed")
    #expect(posted.chunks == [String(repeating: "a", count: 20)])
    #expect(await clipboard.copyCount == 0)
}

@Test("Direct typing advances captured context and selection across every chunk")
func directTypingAdvancesExpectedStateAcrossChunks() async throws {
    let initialText = "prefix SELECTED suffix"
    let initialSelection = EditorTextSelection(location: 7, length: 8)
    let client = ExactTargetAccessibilityClient(
        snapshot: makeExactTargetSnapshot(
            selection: initialSelection,
            characterCount: initialText.utf16.count
        ),
        text: initialText
    )
    let handle = try makeExactTargetHandle(client: client)
    guard case .available(let capturedContext) = await handle.context() else {
        Issue.record("Expected nonempty exact-target context")
        return
    }
    #expect(capturedContext.prefix == "prefix ")
    #expect(capturedContext.suffix == " suffix")

    let posted = ExactTargetPostedChunks()
    let direct = DirectTypingInsertionTransport(
        isProcessTrusted: { true },
        preparedEventPoster: { _, _, chunk, _ in
            posted.append(chunk)
            client.simulateDirectInsertion(chunk)
        }
    )
    let inserted = String(repeating: "x", count: 45)

    try await direct.insert(
        text: inserted,
        target: exactTargetAppContext,
        editorTarget: handle
    )

    #expect(posted.chunks.count == 3)
    #expect(posted.chunks.joined() == inserted)
    #expect(client.text == "prefix \(inserted) suffix")
    #expect(client.selection == EditorTextSelection(location: 52, length: 0))
    guard case .success = await handle.revalidate() else {
        Issue.record("Expected advanced exact-target state to remain valid")
        return
    }
}

@Test("Direct typing verifies the final posted chunk and keeps mismatch terminal")
func directTypingFinalChunkMismatchIsTerminal() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    guard case .available = await handle.context() else {
        Issue.record("Expected exact-target context baseline")
        return
    }
    let posted = ExactTargetPostedChunks()
    let clipboard = ExactTargetCountingClipboard()
    let direct = DirectTypingInsertionTransport(
        isProcessTrusted: { true },
        preparedEventPoster: { _, _, chunk, index in
            posted.append(chunk)
            client.simulateDirectInsertion(
                chunk,
                actualText: index == 2 ? String(repeating: "z", count: chunk.utf16.count) : nil
            )
        }
    )
    let service = InsertionService(transports: [
        direct,
        ClipboardInsertionTransport(clipboard: clipboard)
    ])

    let result = await service.insert(
        text: String(repeating: "a", count: 45),
        target: exactTargetAppContext,
        editorTarget: handle
    )

    #expect(result.status == .failed)
    #expect(result.method == .direct)
    #expect(result.errorMessage == "The editor did not confirm whether the insertion completed")
    #expect(posted.chunks.count == 3)
    #expect(await clipboard.copyCount == 0)
}

@Test("Direct typing chunks preserve UTF-16 scalar boundaries")
func directTypingChunksNeverSplitSurrogatePairs() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    let posted = ExactTargetPostedChunks()
    let direct = DirectTypingInsertionTransport(
        isProcessTrusted: { true },
        preparedEventPoster: { _, _, chunk, _ in
            posted.append(chunk)
            client.simulateDirectInsertion(chunk)
        }
    )
    let text = "1234567890123456789🙂 tail 👨‍👩‍👧‍👦 ending"

    try await direct.insert(
        text: text,
        target: exactTargetAppContext,
        editorTarget: handle
    )

    let chunks = posted.chunks
    #expect(chunks.joined() == text)
    #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
    #expect(chunks.allSatisfy { !containsUnpairedUTF16Surrogate($0) })
    #expect(client.contentReadCount == 0)
}

@Test("A pre-commit exact-target rejection may use the revalidated clipboard fallback")
func precommitAccessibilityRejectionFallsThroughSafely() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    client.setSetResult(.rejected)
    let clipboard = ExactTargetCountingClipboard()
    let commits = ExactTargetEventLog()
    let service = InsertionService(transports: [
        AccessibilityInsertionTransport(client: client),
        ClipboardInsertionTransport(
            clipboard: clipboard,
            exactTargetAutoPaste: { _, editorTarget, _ in
                guard case .success = await editorTarget.revalidate() else {
                    return .skipped(reason: "Exact target unavailable.")
                }
                await commits.append("paste")
                return .attempted
            }
        )
    ])

    let result = await service.insert(
        text: "fallback once",
        target: exactTargetAppContext,
        editorTarget: handle,
        clipboardRecoveryText: "fallback once",
        commitAuthorization: InsertionCommitAuthorization()
    )

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(result.errorMessage == nil)
    #expect(client.writes == ["fallback once"])
    #expect(await clipboard.copyCount == 1)
    #expect(await commits.snapshot() == ["paste"])
}

@Test("Cancellation while a rejected owner releases prevents the next transport")
func cancellationWinsWhenRejectedOwnerReleases() {
    let authorization = InsertionCommitAuthorization()
    let accessibilityLease = InsertionCommitLease()
    let fallbackLease = InsertionCommitLease()

    #expect(authorization.acquire(accessibilityLease))
    authorization.invalidate()
    authorization.release(accessibilityLease)

    #expect(authorization.isInvalidated)
    #expect(!authorization.acquire(fallbackLease))
}

@Test("A clipboard error after ownership is ambiguous and blocks fallback")
func clipboardPostClaimErrorIsTerminal() async {
    let clipboard = ExactTargetThrowingClipboard()
    let fallbackEvents = ExactTargetEventLog()
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(clipboard: clipboard),
        ClosureInsertionTransport(method: .direct) { _, _ in
            await fallbackEvents.append("direct")
        }
    ])

    let result = await service.insert(
        text: "ambiguous clipboard",
        target: .unknown,
        editorTarget: nil,
        clipboardRecoveryText: "ambiguous clipboard",
        commitAuthorization: InsertionCommitAuthorization()
    )

    #expect(result.status == .failed)
    #expect(result.method == .clipboardPaste)
    #expect(await clipboard.copyAttempts == 1)
    #expect(await fallbackEvents.snapshot().isEmpty)
}

@Test("Only the committed owner may continue after cancellation")
func committedOwnerContinuesWhileOtherOwnersAreDenied() {
    let authorization = InsertionCommitAuthorization()
    let owner = InsertionCommitLease()
    let other = InsertionCommitLease()

    #expect(authorization.acquire(owner))
    authorization.invalidate()
    #expect(authorization.ownerMayContinue(owner))
    #expect(!authorization.acquire(other))

    authorization.seal(owner)
    #expect(authorization.ownerMayContinue(owner))
    #expect(!authorization.acquire(other))
    #expect(!authorization.canStartNewCommit)
}

@Test("Mac paste production boundary rejects a revoked commit permit")
func macPasteBoundaryRejectsRevokedPermit() {
    let authorization = InsertionCommitAuthorization()
    let lease = InsertionCommitLease()
    #expect(authorization.acquire(lease))
    authorization.seal(lease)
    let permit = InsertionCommitPermit(
        authorization: authorization,
        lease: lease
    )
    authorization.invalidate()

    var postedEventPairs = 0
    let attempted = MacPasteHelper.performCommandVPasteIfAuthorized(
        commitPermit: permit
    ) {
        postedEventPairs += 1
        return true
    }

    #expect(!attempted)
    #expect(postedEventPairs == 0)
}

@Test("Cancellation before insertion causes no clipboard or paste side effect")
func cancellationBeforeClipboardCommitHasNoSideEffect() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    let clipboard = ExactTargetCountingClipboard()
    let commits = ExactTargetEventLog()
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(
            clipboard: clipboard,
            exactTargetAutoPaste: { _, _, _ in
                await commits.append("paste")
                return .attempted
            }
        )
    ])

    let task = Task {
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            // Preserve the cancelled task state before entering the service.
        }
        return await service.insert(
            text: "never copied",
            target: exactTargetAppContext,
            editorTarget: handle
        )
    }
    task.cancel()
    let result = await task.value

    #expect(result.status == .failed)
    #expect(result.method == .none)
    #expect(await clipboard.copyCount == 0)
    #expect(await commits.snapshot().isEmpty)
}

@Test("Cancellation after clipboard copy suppresses paste without a second copy")
func cancellationAfterCopySuppressesPasteWithoutDuplication() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    let clipboard = ExactTargetBlockingClipboard()
    let commits = ExactTargetEventLog()
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(
            clipboard: clipboard,
            exactTargetAutoPaste: { _, _, _ in
                await commits.append("paste")
                return .attempted
            }
        )
    ])

    let task = Task {
        await service.insert(
            text: "copied once",
            target: exactTargetAppContext,
            editorTarget: handle
        )
    }
    await clipboard.waitUntilCopied()
    task.cancel()
    await clipboard.release()
    let result = await task.value

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(result.errorMessage == "Auto-paste canceled after copying.")
    #expect(await clipboard.copyCount == 1)
    #expect(await commits.snapshot().isEmpty)
}

@Test("Generic auto-paste rechecks coordinator authorization at the paste boundary")
func genericAutoPasteCancellationAtBoundarySuppressesPaste() async {
    let clipboard = ExactTargetCountingClipboard()
    let pasteGate = AuthorizedPasteGate()
    let authorization = InsertionCommitAuthorization()
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(
            clipboard: clipboard,
            autoPaste: { _, permit in
                await pasteGate.pasteIfAuthorized(permit)
            }
        )
    ])

    let insertion = Task {
        await service.insert(
            text: "canonical text",
            target: exactTargetAppContext,
            editorTarget: nil,
            clipboardRecoveryText: "canonical text",
            commitAuthorization: authorization
        )
    }
    await pasteGate.waitUntilStarted()
    authorization.invalidate()
    await pasteGate.release()

    let result = await insertion.value
    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(result.errorMessage == "Auto-paste canceled.")
    #expect(await clipboard.copyCount == 1)
    #expect(await clipboard.latestText == "canonical text")
    #expect(await pasteGate.pasteCount == 0)
}

@Test("Cancellation after a shaped clipboard attempt restores canonical recovery")
func cancellationAfterShapedCopyRestoresCanonicalRecovery() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    let clipboard = ExactTargetBlockingClipboard()
    let commits = ExactTargetEventLog()
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(
            clipboard: clipboard,
            exactTargetAutoPaste: { _, _, _ in
                await commits.append("paste")
                return .attempted
            }
        )
    ])

    let task = Task {
        await service.insert(
            text: " contextual continuation",
            target: exactTargetAppContext,
            editorTarget: handle,
            clipboardRecoveryText: "Canonical continuation"
        )
    }
    await clipboard.waitUntilCopied()
    task.cancel()
    await clipboard.release()
    let result = await task.value

    #expect(result.status == .copiedOnly)
    #expect(result.insertedText == "Canonical continuation")
    #expect(await clipboard.copyCount == 2)
    #expect(await clipboard.copiedTexts == [
        " contextual continuation",
        "Canonical continuation",
    ])
    #expect(await commits.snapshot().isEmpty)
}

@Test("Cancellation after the paste commit begins cannot duplicate copy or paste")
func cancellationAfterPasteCommitDoesNotDuplicate() async throws {
    let client = ExactTargetAccessibilityClient()
    let handle = try makeExactTargetHandle(client: client)
    let clipboard = ExactTargetCountingClipboard()
    let pasteGate = ExactTargetPasteGate()
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(
            clipboard: clipboard,
            exactTargetAutoPaste: { _, _, _ in
                await pasteGate.paste()
            }
        )
    ])

    let task = Task {
        await service.insert(
            text: "committed once",
            target: exactTargetAppContext,
            editorTarget: handle
        )
    }
    await pasteGate.waitUntilStarted()
    task.cancel()
    await pasteGate.release()
    let result = await task.value

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(await clipboard.copyCount == 1)
    #expect(await pasteGate.pasteCount == 1)
}
#endif
