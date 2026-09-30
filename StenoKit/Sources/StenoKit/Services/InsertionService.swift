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
            insertionGuard: nil,
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
            insertionGuard: nil,
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
            insertionGuard: nil,
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
            insertionGuard: nil,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: commitAuthorization
        )
    }

    /// Without an exact editor target, `insertionGuard` may refuse the
    /// insertion before any side effect; a refusal copies the recovery text.
    /// It never changes the transport order.
    public func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult {
        await insertUsingAvailableTarget(
            text: text,
            target: target,
            editorTarget: editorTarget,
            insertionGuard: editorTarget == nil ? insertionGuard : nil,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: commitAuthorization
        )
    }
    #endif

    private func insertUsingAvailableTarget(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
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
                        insertionGuard: insertionGuard,
                        exactTargetText: text,
                        commitAuthorization: commitAuthorization,
                        commitLease: commitLease
                    )
                    let committedText = outcome.skippedReason == nil ? text : clipboardRecoveryText
                    return InsertResult(
                        status: .copiedOnly,
                        method: .clipboardPaste,
                        insertedText: committedText,
                        errorMessage: outcome.skippedReason,
                        pasteAttempted: outcome == .attempted ? true : nil
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
                        insertionGuard: insertionGuard,
                        commitAuthorization: commitAuthorization,
                        commitLease: commitLease
                    )
                } else if let direct = transport as? DirectTypingInsertionTransport {
                    try await direct.insert(
                        text: text,
                        target: target,
                        insertionGuard: insertionGuard,
                        commitAuthorization: commitAuthorization,
                        commitLease: commitLease
                    )
                } else {
                    if let insertionGuard,
                       case .refuse(let reason) = insertionGuard.evaluate(for: target) {
                        throw MacInsertionError.insertionRefused(reason)
                    }
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
                   case .insertionRefused(let reason) = macError {
                    return await refusedResult(
                        reason: reason,
                        text: text,
                        clipboardRecoveryText: clipboardRecoveryText,
                        commitAuthorization: commitAuthorization
                    )
                }
                #endif
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

    #if os(macOS)
    /// A refusal happens before any side effect, so no other transport may
    /// try. The final text goes to the clipboard, where the user recovers it.
    private func refusedResult(
        reason: EditorTargetUnavailableReason,
        text: String,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization?
    ) async -> InsertResult {
        let message = InsertionTargetGuard.refusalMessage(for: reason)
        guard let clipboardTransport = transports.lazy
            .compactMap({ $0 as? ClipboardInsertionTransport }).first else {
            return InsertResult(
                status: .failed,
                method: .none,
                insertedText: text,
                errorMessage: message
            )
        }
        do {
            try await clipboardTransport.copyForRecovery(
                clipboardRecoveryText,
                commitAuthorization: commitAuthorization,
                commitLease: commitAuthorization.map { _ in InsertionCommitLease() }
            )
        } catch is CancellationError {
            return Self.cancelledResult(text: text)
        } catch {
            return InsertResult(
                status: .failed,
                method: .clipboardPaste,
                insertedText: text,
                errorMessage: "\(message) \(error.localizedDescription)"
            )
        }
        return InsertResult(
            status: .copiedOnly,
            method: .clipboardPaste,
            insertedText: clipboardRecoveryText,
            errorMessage: message
        )
    }
    #endif

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
        // Terminals mishandle synthetic typing, and remote-desktop clients may
        // forward only the key code of a Unicode typing event, so both paste.
        let pastesFirst = target.isRemoteDesktop
            || Self.terminalClipboardFirstBundleIDs.contains(target.bundleIdentifier.lowercased())
        guard pastesFirst else {
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

/// A copy of every item on the clipboard, taken before an auto-paste write so
/// the user's own content can be put back afterwards.
public struct ClipboardRestorePoint: Sendable, Equatable {
    public struct Representation: Sendable, Equatable {
        public var type: String
        public var data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public struct Item: Sendable, Equatable {
        public var representations: [Representation]

        public init(representations: [Representation]) {
            self.representations = representations
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}

/// A clipboard that auto-paste can borrow: it snapshots the user's content,
/// writes the dictation marked as transient, exposes the change count for the
/// check right before the paste keystroke, and restores the snapshot only if
/// nothing else has written since.
public protocol RestorableClipboardService: ClipboardService {
    func makeRestorePoint() async -> ClipboardRestorePoint
    /// Returns the change count produced by this write.
    func setTransientString(_ text: String) async throws -> Int
    func currentChangeCount() -> Int
    @discardableResult
    func restore(_ point: ClipboardRestorePoint, ifChangeCountIs changeCount: Int) async -> Bool
}

/// What an auto-paste action needs from the clipboard transport.
struct AutoPasteRequest: Sendable {
    let target: AppContext
    #if os(macOS)
    let editorTarget: EditorTargetHandle?
    /// Checked after activation, before the keystroke, when there is no
    /// exact editor target.
    let insertionGuard: InsertionTargetGuard?
    #endif
    let commitPermit: InsertionCommitPermit?
    /// Checked immediately before the paste keystroke. False means another
    /// write replaced the dictation, so pasting would insert something else.
    let clipboardStillHoldsText: @Sendable () -> Bool
}

public struct ClipboardInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .clipboardPaste
    static let defaultRestoreDelay: Duration = .milliseconds(1_500)
    static let clipboardChangedReason = "Clipboard changed before auto-paste; nothing was pasted."

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
    private let pasteAction: (@Sendable (AutoPasteRequest) async -> AutoPasteOutcome)?
    private let restoreDelay: Duration

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
        pasteAction = nil
        restoreDelay = Self.defaultRestoreDelay
    }

    /// Uses one paste action for both generic and exact-target pastes, so the
    /// action can check the clipboard right before the keystroke.
    init(
        clipboard: ClipboardService,
        restoreDelay: Duration = Self.defaultRestoreDelay,
        pasteAction: @escaping @Sendable (AutoPasteRequest) async -> AutoPasteOutcome
    ) {
        self.clipboard = clipboard
        autoPaste = nil
        #if os(macOS)
        exactTargetAutoPaste = nil
        #endif
        self.pasteAction = pasteAction
        self.restoreDelay = restoreDelay
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
            insertionGuard: nil,
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
            insertionGuard: nil,
            exactTargetText: exactTargetText,
            commitAuthorization: nil,
            commitLease: nil
        )
    }

    func insertAndReturnOutcome(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
        exactTargetText: String,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) async throws -> AutoPasteOutcome {
        try Task.checkCancellation()
        guard commitAuthorization?.canStartNewCommit != false else {
            throw CancellationError()
        }

        let supportsExactPaste = pasteAction != nil || exactTargetAutoPaste != nil
        if let editorTarget, supportsExactPaste {
            if case .failure(let reason) = await editorTarget.revalidate() {
                _ = try await commitClipboard(
                    text,
                    authorization: commitAuthorization,
                    lease: commitLease
                )
                return .skipped(reason: Self.exactTargetSkipReason(reason))
            }

            let pasteWrite = try await commitClipboardForAutoPaste(
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
            let permit = makeCommitPermit(commitAuthorization, lease: commitLease)
            let outcome: AutoPasteOutcome
            if let pasteAction {
                outcome = await pasteAction(AutoPasteRequest(
                    target: target,
                    editorTarget: editorTarget,
                    insertionGuard: nil,
                    commitPermit: permit,
                    clipboardStillHoldsText: pasteWrite.stillHoldsText
                ))
            } else if let exactTargetAutoPaste {
                outcome = await exactTargetAutoPaste(target, editorTarget, permit)
            } else {
                outcome = .skipped(reason: "Exact-target auto-paste is unavailable; final text was copied.")
            }
            if outcome.skippedReason != nil, text != exactTargetText,
               outcome.skippedReason != Self.clipboardChangedReason {
                try await restoreCanonicalClipboard(text, afterAttempting: exactTargetText)
            }
            if outcome == .attempted {
                scheduleRestore(after: pasteWrite)
            }
            return outcome
        }

        // A captured editor handle changes the safety contract: generic app
        // activation cannot prove that the same field and selection still own
        // the paste. Keep the authoritative final on the clipboard, but never
        // route it through the legacy callback when exact paste support is not
        // configured.
        if editorTarget != nil {
            _ = try await commitClipboard(
                text,
                authorization: commitAuthorization,
                lease: commitLease
            )
            return .skipped(reason: "Exact-target auto-paste is unavailable; final text was copied.")
        }

        guard pasteAction != nil || autoPaste != nil else {
            _ = try await commitClipboard(
                text,
                authorization: commitAuthorization,
                lease: commitLease
            )
            return .skipped(reason: "Auto-paste callback not configured.")
        }

        let pasteWrite = try await commitClipboardForAutoPaste(
            text,
            authorization: commitAuthorization,
            lease: commitLease
        )

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
        let permit = makeCommitPermit(commitAuthorization, lease: commitLease)
        let outcome: AutoPasteOutcome
        if let pasteAction {
            outcome = await pasteAction(AutoPasteRequest(
                target: target,
                editorTarget: nil,
                insertionGuard: insertionGuard,
                commitPermit: permit,
                clipboardStillHoldsText: pasteWrite.stillHoldsText
            ))
        } else if let autoPaste {
            // A callback can't check after activating, so check before it.
            if let insertionGuard, case .refuse(let reason) = insertionGuard.evaluate(for: target) {
                return .skipped(reason: InsertionTargetGuard.refusalMessage(for: reason))
            }
            guard pasteWrite.stillHoldsText() else {
                return .skipped(reason: Self.clipboardChangedReason)
            }
            outcome = await autoPaste(target, permit)
        } else {
            outcome = .skipped(reason: "Auto-paste callback not configured.")
        }
        if outcome == .attempted {
            scheduleRestore(after: pasteWrite)
        }
        return outcome
    }

    static func exactTargetSkipReason(_ reason: EditorTargetUnavailableReason) -> String {
        reason == .timedOut
            ? "The app didn't respond in time—final text copied."
            : "Target changed—final text copied."
    }

    /// Copies the final text without pasting, for an insertion that was
    /// refused before any side effect.
    func copyForRecovery(
        _ text: String,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) async throws {
        try Task.checkCancellation()
        guard commitAuthorization?.canStartNewCommit != false else {
            throw CancellationError()
        }
        try await commitClipboard(text, authorization: commitAuthorization, lease: commitLease)
    }

    /// The dictation written for an auto-paste, plus what is needed to put the
    /// user's previous clipboard back once the paste has been sent.
    private struct AutoPasteClipboardWrite: Sendable {
        let clipboard: (any RestorableClipboardService)?
        let restorePoint: ClipboardRestorePoint?
        let changeCount: Int?

        var stillHoldsText: @Sendable () -> Bool {
            guard let clipboard, let changeCount else { return { true } }
            return { clipboard.currentChangeCount() == changeCount }
        }
    }

    /// Restores only after a sent paste, and only while the clipboard still
    /// holds Steno's write. A copy-only result keeps the dictation there,
    /// because that is how the user recovers it.
    private func scheduleRestore(after write: AutoPasteClipboardWrite) {
        guard let clipboard = write.clipboard,
              let restorePoint = write.restorePoint,
              !restorePoint.items.isEmpty,
              let changeCount = write.changeCount else { return }
        let delay = restoreDelay
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            await clipboard.restore(restorePoint, ifChangeCountIs: changeCount)
        }
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

    @discardableResult
    private func commitClipboard(
        _ text: String,
        authorization: InsertionCommitAuthorization?,
        lease: InsertionCommitLease?
    ) async throws -> Int? {
        let clipboard = self.clipboard
        return try await commitClipboardWrite(authorization: authorization, lease: lease) {
            try await clipboard.setString(text)
            return nil
        }
    }

    private func commitClipboardForAutoPaste(
        _ text: String,
        authorization: InsertionCommitAuthorization?,
        lease: InsertionCommitLease?
    ) async throws -> AutoPasteClipboardWrite {
        guard let restorable = clipboard as? any RestorableClipboardService else {
            try await commitClipboard(text, authorization: authorization, lease: lease)
            return AutoPasteClipboardWrite(clipboard: nil, restorePoint: nil, changeCount: nil)
        }
        let restorePoint = await restorable.makeRestorePoint()
        let changeCount = try await commitClipboardWrite(authorization: authorization, lease: lease) {
            try await restorable.setTransientString(text)
        }
        return AutoPasteClipboardWrite(
            clipboard: restorable,
            restorePoint: restorePoint,
            changeCount: changeCount
        )
    }

    private func commitClipboardWrite<Value>(
        authorization: InsertionCommitAuthorization?,
        lease: InsertionCommitLease?,
        _ write: () async throws -> Value
    ) async throws -> Value {
        guard let authorization else {
            return try await write()
        }
        guard let lease, authorization.acquire(lease) else {
            throw CancellationError()
        }
        do {
            let value = try await write()
            authorization.seal(lease)
            return value
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

public enum MacClipboardError: Error, LocalizedError {
    case writeFailed

    public var errorDescription: String? {
        "The clipboard did not accept the transcript."
    }
}

public actor MacClipboardService: RestorableClipboardService {
    /// Clipboard managers skip items carrying this marker
    /// (see nspasteboard.org).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    public init() {}

    public func setString(_ text: String) async throws {
        try Task.checkCancellation()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func makeRestorePoint() -> ClipboardRestorePoint {
        let items = NSPasteboard.general.pasteboardItems ?? []
        return ClipboardRestorePoint(items: items.map { item in
            ClipboardRestorePoint.Item(representations: item.types.compactMap { type in
                item.data(forType: type).map {
                    ClipboardRestorePoint.Representation(type: type.rawValue, data: $0)
                }
            })
        })
    }

    public func setTransientString(_ text: String) async throws -> Int {
        try Task.checkCancellation()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        guard pasteboard.writeObjects([item]) else {
            throw MacClipboardError.writeFailed
        }
        return pasteboard.changeCount
    }

    public nonisolated func currentChangeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    @discardableResult
    public func restore(_ point: ClipboardRestorePoint, ifChangeCountIs changeCount: Int) -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        let items = point.items.compactMap { snapshot -> NSPasteboardItem? in
            guard !snapshot.representations.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.type)
                )
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }
}
#endif
