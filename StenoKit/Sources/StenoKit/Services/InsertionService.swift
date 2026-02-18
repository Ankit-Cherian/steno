import Foundation

public enum AutoPasteOutcome: Sendable, Equatable {
    case attempted
    case skipped(reason: String)

    public var skippedReason: String? {
        guard case .skipped(let reason) = self else { return nil }
        return reason
    }
}

public struct InsertionService: InsertionServiceProtocol, Sendable {
    private static let terminalClipboardFirstBundleIDs: Set<String> = [
        "dev.warp.warp-stable",
        "com.openai.codex",
        "com.apple.terminal",
        "com.googlecode.iterm2"
    ]

    private let transports: [any InsertionTransport]

    public init(transports: [any InsertionTransport]) {
        self.transports = transports
    }

    public func insert(text: String, target: AppContext) async -> InsertResult {
        var failures: [String] = []

        for transport in prioritizedTransports(for: target) {
            if let clipboardTransport = transport as? ClipboardInsertionTransport {
                do {
                    let outcome = try await clipboardTransport.insertAndReturnOutcome(text: text, target: target)
                    return InsertResult(
                        status: .copiedOnly,
                        method: .clipboardPaste,
                        insertedText: text,
                        errorMessage: outcome.skippedReason
                    )
                } catch {
                    failures.append("\(transport.method.rawValue): \(error.localizedDescription)")
                    continue
                }
            }

            do {
                try await transport.insert(text: text, target: target)

                let status: InsertionStatus = transport.method == .clipboardPaste ? .copiedOnly : .inserted
                return InsertResult(status: status, method: transport.method, insertedText: text)
            } catch {
                failures.append("\(transport.method.rawValue): \(error.localizedDescription)")
            }
        }

        return InsertResult(
            status: .failed,
            method: .none,
            insertedText: text,
            errorMessage: failures.joined(separator: " | ")
        )
    }

    private func prioritizedTransports(for target: AppContext) -> [any InsertionTransport] {
        guard Self.terminalClipboardFirstBundleIDs.contains(target.bundleIdentifier.lowercased()) else {
            return transports
        }

        var clipboard: [any InsertionTransport] = []
        var others: [any InsertionTransport] = []

        for transport in transports {
            if transport.method == .clipboardPaste {
                clipboard.append(transport)
            } else {
                others.append(transport)
            }
        }

        return clipboard + others
    }
}

public actor MemoryClipboardService: ClipboardService {
    public private(set) var latestValue: String = ""

    public init() {}

    public func setString(_ text: String) async throws {
        latestValue = text
    }
}

public struct ClipboardInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .clipboardPaste
    private let clipboard: ClipboardService
    private let autoPaste: (@Sendable (_ target: AppContext) async -> AutoPasteOutcome)?

    public init(
        clipboard: ClipboardService,
        autoPaste: (@Sendable (_ target: AppContext) async -> AutoPasteOutcome)? = nil
    ) {
        self.clipboard = clipboard
        self.autoPaste = autoPaste
    }

    public func insert(text: String, target: AppContext) async throws {
        _ = try await insertAndReturnOutcome(text: text, target: target)
    }

    public func insertAndReturnOutcome(text: String, target: AppContext) async throws -> AutoPasteOutcome {
        try await clipboard.setString(text)

        guard let autoPaste else {
            return .skipped(reason: "Auto-paste callback not configured.")
        }

        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms for clipboard to settle
        return await autoPaste(target)
    }
}

#if os(macOS)
import AppKit

public actor MacClipboardService: ClipboardService {
    public init() {}

    public func setString(_ text: String) async throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
