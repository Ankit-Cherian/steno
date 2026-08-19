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
        await insertUsingAvailableTarget(
            text: text,
            target: target,
            editorTarget: nil,
            clipboardRecoveryText: text,
            commitAuthorization: nil
        )
    }

    #if os(macOS)
    public func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?
    ) async -> InsertResult {
        await insertUsingAvailableTarget(
            text: text,
            target: target,
            editorTarget: editorTarget,
            clipboardRecoveryText: text,
            commitAuthorization: nil
        )
    }

    public func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String
    ) async -> InsertResult {
        await insertUsingAvailableTarget(
            text: text,
            target: target,
            editorTarget: editorTarget,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: nil
        )
    }

    public func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult {
        await insertUsingAvailableTarget(
            text: text,
            target: target,
            editorTarget: editorTarget,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: commitAuthorization
        )
    }
    #endif

    private func insertUsingAvailableTarget(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization?
    ) async -> InsertResult {
        var failures: [String] = []

        for transport in prioritizedTransports(
            for: target,
            prefersExactSelection: editorTarget != nil
        ) {
            let commitLease = commitAuthorization.map { _ in InsertionCommitLease() }
            guard !Task.isCancelled else {
                return Self.cancelledResult(text: text)
            }
            guard commitAuthorization?.canStartNewCommit != false else {
                if commitAuthorization?.isInvalidated == true {
                    return Self.cancelledResult(text: text)
                }
                return Self.terminalCommitResult(text: text, method: transport.method)
            }
            guard commitAuthorization == nil || commitLease != nil else {
                return Self.cancelledResult(text: text)
            }
            if let clipboardTransport = transport as? ClipboardInsertionTransport {
                do {
                    let outcome = try await clipboardTransport.insertAndReturnOutcome(
                        text: clipboardRecoveryText,
                        target: target,
                        editorTarget: editorTarget,
                        exactTargetText: text,
                        commitAuthorization: commitAuthorization,
                        commitLease: commitLease
                    )
                    let committedText = outcome.skippedReason == nil ? text : clipboardRecoveryText
                    return InsertResult(
                        status: .copiedOnly,
                        method: .clipboardPaste,
                        insertedText: committedText,
                        errorMessage: outcome.skippedReason
                    )
                } catch is CancellationError {
                    return Self.cancelledResult(text: text)
                } catch {
                    if let commitAuthorization {
                        if commitAuthorization.isInvalidated {
                            return Self.cancelledResult(text: text)
                        }
                        if !commitAuthorization.canStartNewCommit {
                            return InsertResult(
                                status: .failed,
                                method: transport.method,
                                insertedText: text,
                                errorMessage: error.localizedDescription
                            )
                        }
                    }
                    failures.append("\(transport.method.rawValue): \(error.localizedDescription)")
                    continue
                }
            }

            do {
                #if os(macOS)
                if let editorTarget,
                   let accessibility = transport as? AccessibilityInsertionTransport {
                    try await accessibility.insert(
                        text: text,
                        target: target,
                        editorTarget: editorTarget,
                        commitAuthorization: commitAuthorization,
                        commitLease: commitLease
                    )
                } else if let editorTarget,
                          let direct = transport as? DirectTypingInsertionTransport {
                    try await direct.insert(
                        text: text,
                        target: target,
                        editorTarget: editorTarget,
                        commitAuthorization: commitAuthorization,
                        commitLease: commitLease
                    )
                } else if let accessibility = transport as? AccessibilityInsertionTransport {
                    try await accessibility.insert(
                        text: text,
                        target: target,
                        commitAuthorization: commitAuthorization,
                        commitLease: commitLease
                    )
                } else if let direct = transport as? DirectTypingInsertionTransport {
                    try await direct.insert(
                        text: text,
                        target: target,
                        commitAuthorization: commitAuthorization,
                        commitLease: commitLease
                    )
                } else {
                    try await transport.insert(text: text, target: target)
                }
                #else
                try await transport.insert(text: text, target: target)
                #endif
                let status: InsertionStatus = transport.method == .clipboardPaste ? .copiedOnly : .inserted
                return InsertResult(status: status, method: transport.method, insertedText: text)
            } catch is CancellationError {
                return Self.cancelledResult(text: text)
            } catch {
                guard !Task.isCancelled else {
                    return Self.cancelledResult(text: text)
                }
                #if os(macOS)
                if let macError = error as? MacInsertionError,
                   case .attributeUpdateIndeterminate = macError {
                    return InsertResult(
                        status: .failed,
                        method: transport.method,
                        insertedText: text,
                        errorMessage: error.localizedDescription
                    )
                }
                #endif
                if let commitAuthorization {
                    if commitAuthorization.isInvalidated {
                        return Self.cancelledResult(text: text)
                    }
                    if !commitAuthorization.canStartNewCommit {
                        return InsertResult(
                            status: .failed,
                            method: transport.method,
                            insertedText: text,
                            errorMessage: error.localizedDescription
                        )
                    }
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

    private static func terminalCommitResult(
        text: String,
        method: InsertionMethod
    ) -> InsertResult {
        InsertResult(
            status: .failed,
            method: method,
            insertedText: text,
            errorMessage: "Insertion outcome is already committed or indeterminate."
        )
    }

    private func prioritizedTransports(
        for target: AppContext,
        prefersExactSelection: Bool
    ) -> [any InsertionTransport] {
        guard Self.terminalClipboardFirstBundleIDs.contains(target.bundleIdentifier.lowercased()) else {
            guard prefersExactSelection else { return transports }
            return transports.sorted { lhs, rhs in
                Self.exactTargetPriority(lhs.method) < Self.exactTargetPriority(rhs.method)
            }
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

    private static func exactTargetPriority(_ method: InsertionMethod) -> Int {
        switch method {
        case .accessibility: 0
        case .direct: 1
        case .clipboardPaste: 2
        case .none: 3
        }
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
    private let autoPaste: (@Sendable (
        _ target: AppContext,
        _ commitPermit: InsertionCommitPermit?
    ) async -> AutoPasteOutcome)?
    #if os(macOS)
    private let exactTargetAutoPaste: (@Sendable (
        _ target: AppContext,
        _ editorTarget: EditorTargetHandle,
        _ commitPermit: InsertionCommitPermit?
    ) async -> AutoPasteOutcome)?
    #endif

    /// Auto-paste callbacks must forward `commitPermit` unchanged to the
    /// synchronous paste side-effect boundary. A non-`nil` permit represents
    /// coordinator authorization that can be revoked while the callback is
    /// suspended in app activation or exact-target revalidation.
    public init(
        clipboard: ClipboardService,
        autoPaste: (@Sendable (
            _ target: AppContext,
            _ commitPermit: InsertionCommitPermit?
        ) async -> AutoPasteOutcome)? = nil,
        exactTargetAutoPaste: (@Sendable (
            _ target: AppContext,
            _ editorTarget: EditorTargetHandle,
            _ commitPermit: InsertionCommitPermit?
        ) async -> AutoPasteOutcome)? = nil
    ) {
        self.clipboard = clipboard
        self.autoPaste = autoPaste
        #if os(macOS)
        self.exactTargetAutoPaste = exactTargetAutoPaste
        #endif
    }

    public func insert(text: String, target: AppContext) async throws {
        _ = try await insertAndReturnOutcome(text: text, target: target)
    }

    public func insertAndReturnOutcome(text: String, target: AppContext) async throws -> AutoPasteOutcome {
        try await insertAndReturnOutcome(
            text: text,
            target: target,
            editorTarget: nil
        )
    }

    #if os(macOS)
    public func insertAndReturnOutcome(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?
    ) async throws -> AutoPasteOutcome {
        try await insertAndReturnOutcome(
            text: text,
            target: target,
            editorTarget: editorTarget,
            exactTargetText: text,
            commitAuthorization: nil,
            commitLease: nil
        )
    }

    /// Uses `exactTargetText` only for a revalidated exact paste. If that
    /// commit cannot be proven, the clipboard is left with canonical `text`.
    public func insertAndReturnOutcome(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        exactTargetText: String
    ) async throws -> AutoPasteOutcome {
        try await insertAndReturnOutcome(
            text: text,
            target: target,
            editorTarget: editorTarget,
            exactTargetText: exactTargetText,
            commitAuthorization: nil,
            commitLease: nil
        )
    }

    func insertAndReturnOutcome(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        exactTargetText: String,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) async throws -> AutoPasteOutcome {
        try Task.checkCancellation()
        guard commitAuthorization?.canStartNewCommit != false else {
            throw CancellationError()
        }

        if let editorTarget, let exactTargetAutoPaste {
            guard case .success = await editorTarget.revalidate() else {
                try await commitClipboard(
                    text,
                    authorization: commitAuthorization,
                    lease: commitLease
                )
                return .skipped(reason: "Target changed—final text copied.")
            }

            try await commitClipboard(
                exactTargetText,
                authorization: commitAuthorization,
                lease: commitLease
            )
            guard !Task.isCancelled,
                  ownerMayContinue(commitAuthorization, lease: commitLease) else {
                try await restoreCanonicalClipboard(text, afterAttempting: exactTargetText)
                return .skipped(reason: "Auto-paste canceled after copying.")
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                try await restoreCanonicalClipboard(text, afterAttempting: exactTargetText)
                return .skipped(reason: "Auto-paste canceled after copying.")
            }
            guard !Task.isCancelled,
                  ownerMayContinue(commitAuthorization, lease: commitLease) else {
                try await restoreCanonicalClipboard(text, afterAttempting: exactTargetText)
                return .skipped(reason: "Auto-paste canceled after copying.")
            }
            let outcome = await exactTargetAutoPaste(
                target,
                editorTarget,
                makeCommitPermit(commitAuthorization, lease: commitLease)
            )
            if outcome.skippedReason != nil, text != exactTargetText {
                try await restoreCanonicalClipboard(text, afterAttempting: exactTargetText)
            }
            return outcome
        }

        // A captured editor handle changes the safety contract: generic app
        // activation cannot prove that the same field and selection still own
        // the paste. Keep the authoritative final on the clipboard, but never
        // route it through the legacy callback when exact paste support is not
        // configured.
        if editorTarget != nil {
            try await commitClipboard(
                text,
                authorization: commitAuthorization,
                lease: commitLease
            )
            return .skipped(reason: "Exact-target auto-paste is unavailable; final text was copied.")
        }

        try await commitClipboard(
            text,
            authorization: commitAuthorization,
            lease: commitLease
        )

        guard let autoPaste else {
            return .skipped(reason: "Auto-paste callback not configured.")
        }

        guard !Task.isCancelled,
              ownerMayContinue(commitAuthorization, lease: commitLease) else {
            return .skipped(reason: "Auto-paste canceled after copying.")
        }

        do {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms for clipboard to settle
        } catch {
            return .skipped(reason: "Auto-paste canceled after copying.")
        }
        guard !Task.isCancelled,
              ownerMayContinue(commitAuthorization, lease: commitLease) else {
            return .skipped(reason: "Auto-paste canceled after copying.")
        }
        let outcome = await autoPaste(
            target,
            makeCommitPermit(commitAuthorization, lease: commitLease)
        )
        return outcome
    }

    private func makeCommitPermit(
        _ authorization: InsertionCommitAuthorization?,
        lease: InsertionCommitLease?
    ) -> InsertionCommitPermit? {
        guard let authorization, let lease else { return nil }
        return InsertionCommitPermit(authorization: authorization, lease: lease)
    }

    private func ownerMayContinue(
        _ authorization: InsertionCommitAuthorization?,
        lease: InsertionCommitLease?
    ) -> Bool {
        guard let authorization else { return true }
        guard let lease else { return false }
        return authorization.ownerMayContinue(lease)
            && !authorization.cancellationRequested(for: lease)
    }

    private func commitClipboard(
        _ text: String,
        authorization: InsertionCommitAuthorization?,
        lease: InsertionCommitLease?
    ) async throws {
        guard let authorization else {
            try await clipboard.setString(text)
            return
        }
        guard let lease, authorization.acquire(lease) else {
            throw CancellationError()
        }
        do {
            try await clipboard.setString(text)
            authorization.seal(lease)
        } catch {
            // An asynchronous clipboard error cannot prove that the write had
            // no side effect, so this owner is terminal and must not fall back.
            authorization.seal(lease)
            throw error
        }
    }

    /// Cancellation may arrive after a shaped exact-target value reached the
    /// clipboard. Restore canonical recovery from a task that does not inherit
    /// that cancellation, so copied-only output remains safe.
    private func restoreCanonicalClipboard(
        _ canonicalText: String,
        afterAttempting attemptedText: String
    ) async throws {
        guard canonicalText != attemptedText else { return }
        let clipboard = self.clipboard
        try await Task.detached(priority: .userInitiated) {
            try await clipboard.setString(canonicalText)
        }.value
    }
    #endif
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
