import Foundation
import Testing
@testable import StenoKit

private enum TestInsertionError: Error {
    case failed
}

private actor CallRecorder {
    private(set) var calls: [InsertionMethod] = []

    func append(_ method: InsertionMethod) {
        calls.append(method)
    }

    func snapshot() -> [InsertionMethod] {
        calls
    }
}

private actor CommittedInsertionGate {
    private var committed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func commitAndWait() async {
        committed = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasCommitted() -> Bool {
        committed
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Test("InsertionService falls back from direct to accessibility before clipboard")
func insertionServiceFallsBackToAccessibility() async {
    let recorder = CallRecorder()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            await recorder.append(.direct)
            throw TestInsertionError.failed
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            await recorder.append(.accessibility)
        },
        ClosureInsertionTransport(method: .clipboardPaste) { _, _ in
            await recorder.append(.clipboardPaste)
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)
    #expect(result.status == .inserted)
    #expect(result.method == .accessibility)
    #expect(await recorder.snapshot() == [.direct, .accessibility])
}

@Test("InsertionService falls back to clipboard when direct and accessibility fail")
func insertionServiceFallsBackToClipboard() async {
    let recorder = CallRecorder()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            await recorder.append(.direct)
            throw TestInsertionError.failed
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            await recorder.append(.accessibility)
            throw TestInsertionError.failed
        },
        ClosureInsertionTransport(method: .clipboardPaste) { _, _ in
            await recorder.append(.clipboardPaste)
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)
    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(await recorder.snapshot() == [.direct, .accessibility, .clipboardPaste])
}

@Test("Insertion cancellation loses after a transport commits")
func insertionCancellationAfterCommitReturnsSuccess() async {
    let gate = CommittedInsertionGate()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            await gate.commitAndWait()
        }
    ])

    let insertion = Task {
        await service.insert(text: "complete text", target: .unknown)
    }
    while !(await gate.hasCommitted()) {
        await Task.yield()
    }

    insertion.cancel()
    await gate.release()
    let result = await insertion.value

    #expect(result.status == .inserted)
    #expect(result.method == .direct)
    #expect(result.insertedText == "complete text")
}
