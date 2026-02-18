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
