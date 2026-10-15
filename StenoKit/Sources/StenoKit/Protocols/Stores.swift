import Foundation

/// Persists and queries transcript history.
public protocol HistoryStoreProtocol: Sendable {
    /// Appends a new transcript entry to the history.
    func append(entry: TranscriptEntry) async throws

    /// Deletes the entry with the given ID.
    func delete(entryID: UUID) async throws

    /// Returns the most recent entries, up to the specified limit.
    func recent(limit: Int) async -> [TranscriptEntry]

    /// Searches transcript history for entries matching the query string.
    func search(query: String) async -> [TranscriptEntry]

    /// Re-runs cleanup on an existing transcript entry with updated settings.
    ///
    /// - Parameters:
    ///   - entryID: The entry to retry cleanup on.
    ///   - cleanupEngine: The cleanup engine to use.
    ///   - profile: Style profile to apply.
    ///   - lexicon: Personal lexicon for corrections.
    func retry(
        entryID: UUID,
        using cleanupEngine: CleanupEngine,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript
}

/// Persists privacy-preserving per-session usage metrics without transcript text.
public protocol UsageAnalyticsRecording: Sendable {
    func record(event: UsageEvent) async throws
}

/// Orchestrates text insertion using an ordered chain of transports with target-aware reordering.
public protocol InsertionServiceProtocol: Sendable {
    /// Inserts the given text into the target application using the configured transport chain.
    func insert(text: String, target: AppContext) async -> InsertResult

    #if os(macOS)
    /// Inserts only into the exact editor captured for this dictation when a
    /// process-local handle is available. Implementations must revalidate at
    /// each transport's commit point and fail closed on target drift.
    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?
    ) async -> InsertResult

    /// Attempts exact-target transports with `text`, but uses
    /// `clipboardRecoveryText` if the only safe outcome is copied recovery.
    /// Callers that do not distinguish the two payloads should pass `text`.
    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String
    ) async -> InsertResult

    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult

    /// Like the commit-authorized insert, plus a refusal-only target check
    /// for sessions without an exact editor target.
    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult

    /// Like the refusal-checked insert, for text meant for a secure field:
    /// `concealsCopy` marks every copy of it as concealed.
    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization,
        concealsCopy: Bool
    ) async -> InsertResult

    /// Puts `text` on the clipboard without activating any app or sending a
    /// keystroke, for a dictation whose target is no longer in front. The
    /// result is `.copiedOnly` with `reason`, or `.failed` when nothing was copied.
    /// `concealed` marks the copy for a dictation meant for a secure field.
    func copyWithoutInserting(
        text: String,
        reason: InsertionCopyReason,
        concealed: Bool,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult
    #endif
}

public extension InsertionServiceProtocol {
    #if os(macOS)
    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?
    ) async -> InsertResult {
        _ = editorTarget
        return await insert(text: text, target: target)
    }

    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String
    ) async -> InsertResult {
        _ = clipboardRecoveryText
        return await insert(text: text, target: target, editorTarget: editorTarget)
    }


    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult {
        guard commitAuthorization.isAuthorized else {
            return InsertResult(
                status: .failed,
                method: .none,
                insertedText: text,
                errorMessage: "Insertion canceled."
            )
        }
        return await insert(
            text: text,
            target: target,
            editorTarget: editorTarget,
            clipboardRecoveryText: clipboardRecoveryText
        )
    }

    /// Services without refusal support insert as before.
    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult {
        _ = insertionGuard
        return await insert(
            text: text,
            target: target,
            editorTarget: editorTarget,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: commitAuthorization
        )
    }

    /// Services that cannot conceal a copy insert as before.
    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        insertionGuard: InsertionTargetGuard?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization,
        concealsCopy: Bool
    ) async -> InsertResult {
        await insert(
            text: text,
            target: target,
            editorTarget: editorTarget,
            insertionGuard: insertionGuard,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: commitAuthorization
        )
    }

    /// Services without a clipboard path copy nothing.
    func copyWithoutInserting(
        text: String,
        reason: InsertionCopyReason,
        concealed: Bool,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult {
        _ = reason
        _ = concealed
        _ = commitAuthorization
        return InsertResult(
            status: .failed,
            method: .none,
            insertedText: text,
            errorMessage: "No clipboard is available to copy the text."
        )
    }
    #endif
}
