import Testing
@testable import StenoKit

private enum OrderingTestError: Error {
    case failed
}

private actor MethodCallRecorder {
    private(set) var calls: [InsertionMethod] = []

    func append(_ method: InsertionMethod) {
        calls.append(method)
    }

    func snapshot() -> [InsertionMethod] {
        calls
    }
}

@Test("InsertionService prioritizes clipboard for terminal/LLM targets")
func insertionServicePrioritizesClipboardForTerminalTargets() async {
    let recorder = MethodCallRecorder()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            await recorder.append(.direct)
            throw OrderingTestError.failed
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            await recorder.append(.accessibility)
            throw OrderingTestError.failed
        },
        ClosureInsertionTransport(method: .clipboardPaste) { _, _ in
            await recorder.append(.clipboardPaste)
        }
    ])

    let target = AppContext(bundleIdentifier: "dev.warp.Warp-Stable", appName: "Warp")
    let result = await service.insert(text: "hello", target: target)

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(await recorder.snapshot() == [.clipboardPaste])
}

@Test("InsertionService keeps configured order for non-terminal targets")
func insertionServicePreservesOrderForNonTerminalTargets() async {
    let recorder = MethodCallRecorder()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            await recorder.append(.direct)
            throw OrderingTestError.failed
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            await recorder.append(.accessibility)
            throw OrderingTestError.failed
        },
        ClosureInsertionTransport(method: .clipboardPaste) { _, _ in
            await recorder.append(.clipboardPaste)
        }
    ])

    let target = AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
    let result = await service.insert(text: "hello", target: target)

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(await recorder.snapshot() == [.direct, .accessibility, .clipboardPaste])
}

@Test("Clipboard transport returns copied-only with auto-paste skip reason")
func clipboardTransportReportsSkipReason() async {
    let clipboard = MemoryClipboardService()
    let service = InsertionService(
        transports: [
            ClipboardInsertionTransport(clipboard: clipboard) { _ in
                .skipped(reason: "Accessibility permission is required for auto-paste.")
            }
        ]
    )

    let result = await service.insert(text: "hello", target: .unknown)

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(result.errorMessage == "Accessibility permission is required for auto-paste.")
    #expect(await clipboard.latestValue == "hello")
}
