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
            guard !Task.isCancelled else {
                return Self.cancelledResult(text: text)
            }
            if let clipboardTransport = transport as? ClipboardInsertionTransport {
                do {
                    let outcome = try await clipboardTransport.insertAndReturnOutcome(text: text, target: target)
                    return InsertResult(
                        status: .copiedOnly,
                        method: .clipboardPaste,
                        insertedText: text,
                        errorMessage: outcome.skippedReason
                    )
                } catch is CancellationError {
                    return Self.cancelledResult(text: text)
                } catch {
                    failures.append("\(transport.method.rawValue): \(error.localizedDescription)")
                    continue
                }
            }

            do {
                try await transport.insert(text: text, target: target)
                let status: InsertionStatus = transport.method == .clipboardPaste ? .copiedOnly : .inserted
                return InsertResult(status: status, method: transport.method, insertedText: text)
            } catch is CancellationError {
                return Self.cancelledResult(text: text)
            } catch {
                guard !Task.isCancelled else {
                    return Self.cancelledResult(text: text)
                }
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

    private static func cancelledResult(text: String) -> InsertResult {
        InsertResult(
            status: .failed,
            method: .none,
            insertedText: text,
            errorMessage: "Insertion canceled."
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
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        try await clipboard.setString(text)

        guard let autoPaste else {
            return .skipped(reason: "Auto-paste callback not configured.")
        }

        guard !Task.isCancelled else {
            return .skipped(reason: "Auto-paste canceled after copying.")
        }

        do {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms for clipboard to settle
        } catch {
            return .skipped(reason: "Auto-paste canceled after copying.")
        }
        guard !Task.isCancelled else {
            return .skipped(reason: "Auto-paste canceled after copying.")
        }
        let outcome = await autoPaste(target)
        return outcome
    }
}

#if os(macOS)
import AppKit

public actor MacClipboardService: ClipboardService {
    public init() {}

    public func setString(_ text: String) async throws {
        try Task.checkCancellation()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
