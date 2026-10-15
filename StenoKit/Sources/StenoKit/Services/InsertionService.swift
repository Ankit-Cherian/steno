import Foundation

public enum AutoPasteOutcome: Sendable, Equatable {
    public struct Skip: Sendable, Equatable {
        public var message: String
        public var cause: InsertionCopyReason
        /// The text left on the clipboard is marked concealed.
        public var copiedConcealed: Bool

        public init(message: String, cause: InsertionCopyReason, copiedConcealed: Bool = false) {
            self.message = message
            self.cause = cause
            self.copiedConcealed = copiedConcealed
        }
    }

    case attempted
    case skipped(Skip)

    /// A paste that was not sent; the text stays on the clipboard.
    public static func skipped(
        reason: String,
        cause: InsertionCopyReason = .other,
        copiedConcealed: Bool = false
    ) -> AutoPasteOutcome {
        .skipped(Skip(message: reason, cause: cause, copiedConcealed: copiedConcealed))
    }

    public var skippedReason: String? {
        guard case .skipped(let skip) = self else { return nil }
        return skip.message
    }

    public var skippedCause: InsertionCopyReason? {
        guard case .skipped(let skip) = self else { return nil }
        return skip.cause
    }

    public var copiedConcealed: Bool {
        guard case .skipped(let skip) = self else { return false }
        return skip.copiedConcealed
    }
}

public struct InsertionService: InsertionServiceProtocol, Sendable {
    private static let terminalClipboardFirstBundleIDs: Set<String> = [
        "dev.warp.warp-stable",
        "com.apple.terminal",
        "com.googlecode.iterm2"
    ]

    private let transports: [any InsertionTransport]
    #if os(macOS)
    private let ownAppTextFocus: OwnAppTextFocus
    #endif

    public init(transports: [any InsertionTransport]) {
        #if os(macOS)
        self.init(transports: transports, ownAppTextFocus: .live)
        #else
        self.transports = transports
        #endif
    }

    #if os(macOS)
    init(transports: [any InsertionTransport], ownAppTextFocus: OwnAppTextFocus) {
        self.transports = transports
        self.ownAppTextFocus = ownAppTextFocus
    }
    #endif

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
        await insert(
            text: text,
            target: target,
            editorTarget: editorTarget,
            insertionGuard: insertionGuard,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: commitAuthorization,
            concealsCopy: false
        )
    }

    /// `concealsCopy` marks every copy of the text as concealed, for text
    /// that was meant for a secure field.
    public func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization,
        concealsCopy: Bool
    ) async -> InsertResult {
        await insertUsingAvailableTarget(
            text: text,
            target: target,
            editorTarget: editorTarget,
            insertionGuard: editorTarget == nil ? insertionGuard : nil,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: commitAuthorization,
            concealsCopy: concealsCopy
        )
    }

    public func copyWithoutInserting(
        text: String,
        reason: InsertionCopyReason,
        concealed: Bool,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult {
        await InsertionTrace.run(hasTarget: false) {
            await refusedResult(
                message: Self.copyMessage(for: reason),
            copyReason: reason,
                concealsCopy: concealed || reason == .secureField,
                text: text,
                clipboardRecoveryText: text,
                commitAuthorization: commitAuthorization
            )
        }
    }

    private static func copyMessage(for reason: InsertionCopyReason) -> String {
        switch reason {
        case .appChanged: ClipboardInsertionTransport.anotherAppInFrontReason
        case .secureField: InsertionTargetGuard.refusalMessage(for: .secureOrProtectedElement)
        default: InsertionTargetGuard.refusalMessage(for: .targetChanged)
        }
    }
    #endif

    private func insertUsingAvailableTarget(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization?,
        concealsCopy: Bool = false
    ) async -> InsertResult {
        await InsertionTrace.run(hasTarget: true) {
            await insertThroughTransports(
                text: text,
                target: target,
                editorTarget: editorTarget,
                insertionGuard: insertionGuard,
                clipboardRecoveryText: clipboardRecoveryText,
                commitAuthorization: commitAuthorization,
                concealsCopy: concealsCopy
            )
        }
    }

    private func insertThroughTransports(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization?,
        concealsCopy: Bool = false
    ) async -> InsertResult {
        #if os(macOS)
        // Started from Steno's own window with no text field focused, typing or
        // pasting would only sound the alert. Copy before any transport runs.
        // This is an ordinary copy, not a problem, so a success carries no message.
        let ownFocusStartedAt = InsertionTrace.now()
        if await ownAppTextFocus.refusesInsertion(into: target) {
            InsertionTrace.note("own window has no text field", since: ownFocusStartedAt)
            return await refusedResult(
                message: "No text field was selected.",
                reportsMessageWhenCopied: false,
                copyReason: .noTextField,
                concealsCopy: concealsCopy,
                text: text,
                clipboardRecoveryText: clipboardRecoveryText,
                commitAuthorization: commitAuthorization
            )
        }
        #endif

        var failures: [String] = []

        for transport in prioritizedTransports(
            for: target,
            prefersExactSelection: editorTarget != nil
        ) {
            let transportStartedAt = InsertionTrace.now()
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
                        commitLease: commitLease,
                        concealed: concealsCopy
                    )
                    InsertionTrace.note(
                        "clipboardPaste " + (outcome.skippedCause.map { "skipped \($0.rawValue)" } ?? "sent"),
                        since: transportStartedAt
                    )
                    let committedText = outcome.skippedReason == nil ? text : clipboardRecoveryText
                    return InsertResult(
                        status: .copiedOnly,
                        method: .clipboardPaste,
                        insertedText: committedText,
                        errorMessage: outcome.skippedReason,
                        pasteAttempted: outcome == .attempted ? true : nil,
                        copyReason: outcome.skippedCause,
                        copyIsConcealed: outcome.copiedConcealed || concealsCopy ? true : nil
                    )
                } catch is CancellationError {
                    return Self.cancelledResult(text: text)
                } catch {
                    InsertionTrace.note(
                        "clipboardPaste failed \(InsertionTrace.describe(error))",
                        since: transportStartedAt
                    )
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
                InsertionTrace.note("\(transport.method.rawValue) ok", since: transportStartedAt)
                let status: InsertionStatus = transport.method == .clipboardPaste ? .copiedOnly : .inserted
                return InsertResult(status: status, method: transport.method, insertedText: text)
            } catch is CancellationError {
                return Self.cancelledResult(text: text)
            } catch {
                InsertionTrace.note(
                    "\(transport.method.rawValue) failed \(InsertionTrace.describe(error))",
                    since: transportStartedAt
                )
                guard !Task.isCancelled else {
                    return Self.cancelledResult(text: text)
                }
                #if os(macOS)
                if let macError = error as? MacInsertionError,
                   case .insertionRefused(let reason) = macError {
                    return await refusedResult(
                        message: InsertionTargetGuard.refusalMessage(for: reason),
                        copyReason: InsertionCopyReason(reason),
                        concealsCopy: concealsCopy || reason == .secureOrProtectedElement,
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
    /// `message` explains a failure; a successful copy carries it only when
    /// `reportsMessageWhenCopied` is true. Text refused at a secure field is
    /// copied as concealed, since it is most likely a password.
    private func refusedResult(
        message: String,
        reportsMessageWhenCopied: Bool = true,
        copyReason: InsertionCopyReason,
        concealsCopy: Bool = false,
        text: String,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization?
    ) async -> InsertResult {
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
                concealed: concealsCopy,
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
            errorMessage: reportsMessageWhenCopied ? message : nil,
            copyReason: copyReason,
            copyIsConcealed: concealsCopy ? true : nil
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

    /// Markers (see nspasteboard.org) for content that must not outlive its
    /// owner's control: a password, a short-lived item, or one generated for
    /// the moment. A password manager clears such content itself, but only
    /// while the clipboard still holds its own write.
    public static let privateContentTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ]

    /// True when any item carries one of `privateContentTypes`. Such content
    /// is never put back after an auto-paste.
    public var holdsPrivateContent: Bool {
        items.contains { item in
            item.representations.contains { Self.privateContentTypes.contains($0.type) }
        }
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

/// Steno's own latest auto-paste write that has not been restored yet, with
/// the user's clipboard it is waiting to put back. A paste that starts while
/// this write is still on the clipboard borrows that earlier restore point
/// instead of treating Steno's own marked write as private content.
private final class PendingClipboardRestore: @unchecked Sendable {
    private struct Entry {
        let changeCount: Int
        let restorePoint: ClipboardRestorePoint?
    }

    private let lock = NSLock()
    private var entry: Entry?

    /// The restore point carried by the pending write, if `changeCount` is
    /// exactly that write. `.some(nil)` means Steno's write is on the
    /// clipboard but the content under it is not to be put back.
    func restorePoint(forWriteAt changeCount: Int) -> ClipboardRestorePoint?? {
        lock.withLock {
            guard let entry, entry.changeCount == changeCount else { return nil }
            return .some(entry.restorePoint)
        }
    }

    func record(changeCount: Int, restorePoint: ClipboardRestorePoint?) {
        lock.withLock { entry = Entry(changeCount: changeCount, restorePoint: restorePoint) }
    }

    func clear(ifChangeCountIs changeCount: Int) {
        lock.withLock {
            if entry?.changeCount == changeCount { entry = nil }
        }
    }
}

public struct ClipboardInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .clipboardPaste
    static let defaultRestoreDelay: Duration = .milliseconds(1_500)
    static let clipboardChangedReason = "Clipboard changed before auto-paste; nothing was pasted."
    static let anotherAppInFrontReason = "Another app was in front—final text copied."

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
    private let pendingRestore = PendingClipboardRestore()

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
        commitLease: InsertionCommitLease?,
        concealed: Bool = false
    ) async throws -> AutoPasteOutcome {
        try Task.checkCancellation()
        guard commitAuthorization?.canStartNewCommit != false else {
            throw CancellationError()
        }

        let supportsExactPaste = pasteAction != nil || exactTargetAutoPaste != nil
        if let editorTarget, supportsExactPaste {
            let revalidationStartedAt = InsertionTrace.now()
            let revalidation = await editorTarget.revalidate()
            InsertionTrace.note("revalidate \(InsertionTrace.describe(revalidation))", since: revalidationStartedAt)
            if case .failure(let reason) = revalidation {
                let concealsCopy = concealed || reason == .secureOrProtectedElement
                _ = try await commitClipboard(
                    text,
                    concealed: concealsCopy,
                    authorization: commitAuthorization,
                    lease: commitLease
                )
                return .skipped(
                    reason: Self.exactTargetSkipReason(reason),
                    cause: InsertionCopyReason(reason),
                    copiedConcealed: concealsCopy
                )
            }

            let pasteWrite = try await commitClipboardForAutoPaste(
                exactTargetText,
                restoresPreviousClipboard: !target.isRemoteDesktop,
                concealed: concealed,
                authorization: commitAuthorization,
                lease: commitLease
            )
            guard !Task.isCancelled,
                  ownerMayContinue(commitAuthorization, lease: commitLease) else {
                try await restoreCanonicalClipboard(text, afterAttempting: exactTargetText, concealed: concealed)
                return .skipped(reason: "Auto-paste canceled after copying.")
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                try await restoreCanonicalClipboard(text, afterAttempting: exactTargetText, concealed: concealed)
                return .skipped(reason: "Auto-paste canceled after copying.")
            }
            guard !Task.isCancelled,
                  ownerMayContinue(commitAuthorization, lease: commitLease) else {
                try await restoreCanonicalClipboard(text, afterAttempting: exactTargetText, concealed: concealed)
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
            if outcome.copiedConcealed, !concealed {
                try await concealAfterRefusedPaste(text, write: pasteWrite)
            } else if outcome.skippedReason != nil, text != exactTargetText,
               outcome.skippedCause != .clipboardChanged {
                try await restoreCanonicalClipboard(text, afterAttempting: exactTargetText, concealed: concealed)
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
                concealed: concealed,
                authorization: commitAuthorization,
                lease: commitLease
            )
            return .skipped(reason: "Exact-target auto-paste is unavailable; final text was copied.")
        }

        // A secure field is refused before the dictation reaches the clipboard
        // for a paste: the only write is the concealed copy the user recovers.
        if let insertionGuard, case .refuse(.secureOrProtectedElement) = insertionGuard.evaluate(for: target) {
            _ = try await commitClipboard(
                text,
                concealed: true,
                authorization: commitAuthorization,
                lease: commitLease
            )
            return .skipped(
                reason: InsertionTargetGuard.refusalMessage(for: .secureOrProtectedElement),
                cause: .secureField,
                copiedConcealed: true
            )
        }

        guard pasteAction != nil || autoPaste != nil else {
            _ = try await commitClipboard(
                text,
                concealed: concealed,
                authorization: commitAuthorization,
                lease: commitLease
            )
            return .skipped(reason: "Auto-paste callback not configured.")
        }

        let pasteWrite = try await commitClipboardForAutoPaste(
            text,
            restoresPreviousClipboard: !target.isRemoteDesktop,
            concealed: concealed,
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
                outcome = .skipped(
                    reason: InsertionTargetGuard.refusalMessage(for: reason),
                    cause: InsertionCopyReason(reason),
                    copiedConcealed: reason == .secureOrProtectedElement
                )
            } else if !pasteWrite.stillHoldsText() {
                return .skipped(reason: Self.clipboardChangedReason, cause: .clipboardChanged)
            } else {
                outcome = await autoPaste(target, permit)
            }
        } else {
            outcome = .skipped(reason: "Auto-paste callback not configured.")
        }
        if outcome.copiedConcealed, !concealed {
            try await concealAfterRefusedPaste(text, write: pasteWrite)
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
    /// refused before any side effect. `concealed` marks the copy so
    /// clipboard managers leave it out.
    func copyForRecovery(
        _ text: String,
        concealed: Bool = false,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) async throws {
        try Task.checkCancellation()
        guard commitAuthorization?.canStartNewCommit != false else {
            throw CancellationError()
        }
        try await commitClipboard(
            text,
            concealed: concealed,
            authorization: commitAuthorization,
            lease: commitLease
        )
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
        let pendingRestore = pendingRestore
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            await clipboard.restore(restorePoint, ifChangeCountIs: changeCount)
            pendingRestore.clear(ifChangeCountIs: changeCount)
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
        concealed: Bool = false,
        authorization: InsertionCommitAuthorization?,
        lease: InsertionCommitLease?
    ) async throws -> Int? {
        let clipboard = self.clipboard
        return try await commitClipboardWrite(authorization: authorization, lease: lease) {
            if concealed {
                try await clipboard.setConcealedString(text)
            } else {
                try await clipboard.setString(text)
            }
            return nil
        }
    }

    /// `restoresPreviousClipboard` is false for remote-desktop and virtual
    /// machine clients: they read the clipboard only when the remote side
    /// pastes, which can happen after a restore, so the transcript stays.
    private func commitClipboardForAutoPaste(
        _ text: String,
        restoresPreviousClipboard: Bool,
        concealed: Bool = false,
        authorization: InsertionCommitAuthorization?,
        lease: InsertionCommitLease?
    ) async throws -> AutoPasteClipboardWrite {
        guard let restorable = clipboard as? any RestorableClipboardService else {
            try await commitClipboard(text, concealed: concealed, authorization: authorization, lease: lease)
            return AutoPasteClipboardWrite(clipboard: nil, restorePoint: nil, changeCount: nil)
        }
        // Private content, such as a password a manager will clear itself, is
        // not put back: restoring it would outlive that clear. The dictation
        // stays on the clipboard instead.
        let snapshotStartedAt = InsertionTrace.now()
        let countBeforeSnapshot = restorable.currentChangeCount()
        let snapshot = restoresPreviousClipboard ? await restorable.makeRestorePoint() : nil
        InsertionTrace.note("clipboard snapshot \(snapshot?.items.count ?? 0) items", since: snapshotStartedAt)
        var restorePoint = snapshot?.holdsPrivateContent == false ? snapshot : nil
        // The clipboard may still hold Steno's own write from an earlier paste
        // whose restore has not run. Its change count identifies it (an
        // external private item has another one), and the user's clipboard
        // is the earlier restore point, which this paste now carries.
        if snapshot != nil,
           restorable.currentChangeCount() == countBeforeSnapshot,
           let earlier = pendingRestore.restorePoint(forWriteAt: countBeforeSnapshot) {
            restorePoint = earlier
        }
        let writeStartedAt = InsertionTrace.now()
        let changeCount = try await commitClipboardWrite(authorization: authorization, lease: lease) {
            if concealed {
                // A concealed write is marked for clipboard managers like a transient one.
                try await restorable.setConcealedString(text)
                return restorable.currentChangeCount()
            }
            return try await restorable.setTransientString(text)
        }
        InsertionTrace.note("clipboard write", since: writeStartedAt)
        pendingRestore.record(changeCount: changeCount, restorePoint: restorePoint)
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

    /// A field that turned secure after the paste write refuses the paste. The copy the user
    /// recovers is then written again as concealed, so the clipboard does not keep the paste
    /// write. A clipboard that changed since then is left alone.
    private func concealAfterRefusedPaste(_ text: String, write: AutoPasteClipboardWrite) async throws {
        guard write.stillHoldsText() else { return }
        let clipboard = self.clipboard
        try await Task.detached(priority: .userInitiated) {
            try await clipboard.setConcealedString(text)
        }.value
        if let changeCount = write.changeCount {
            pendingRestore.clear(ifChangeCountIs: changeCount)
        }
    }

    /// Cancellation may arrive after a shaped exact-target value reached the
    /// clipboard. Restore canonical recovery from a task that does not inherit
    /// that cancellation, so copied-only output remains safe.
    private func restoreCanonicalClipboard(
        _ canonicalText: String,
        afterAttempting attemptedText: String,
        concealed: Bool = false
    ) async throws {
        guard canonicalText != attemptedText else { return }
        let clipboard = self.clipboard
        try await Task.detached(priority: .userInitiated) {
            if concealed {
                try await clipboard.setConcealedString(canonicalText)
            } else {
                try await clipboard.setString(canonicalText)
            }
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
    /// Marks content such as a password that clipboard managers must not
    /// record or show (see nspasteboard.org).
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    public init() {}

    public func setString(_ text: String) async throws {
        try Task.checkCancellation()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func setConcealedString(_ text: String) async throws {
        try Task.checkCancellation()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.concealedType)
        guard pasteboard.writeObjects([item]) else {
            throw MacClipboardError.writeFailed
        }
    }

    public func makeRestorePoint() -> ClipboardRestorePoint {
        let items = NSPasteboard.general.pasteboardItems ?? []
        return ClipboardRestorePoint(items: items.map { item in
            // A private item is never restored, so only its marker is kept;
            // its content is not copied.
            let markers = item.types.filter {
                ClipboardRestorePoint.privateContentTypes.contains($0.rawValue)
            }
            if !markers.isEmpty {
                return ClipboardRestorePoint.Item(representations: markers.map {
                    ClipboardRestorePoint.Representation(type: $0.rawValue, data: Data())
                })
            }
            return ClipboardRestorePoint.Item(representations: item.types.compactMap { type in
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
