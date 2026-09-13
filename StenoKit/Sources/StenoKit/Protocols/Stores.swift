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

    /// Retrieves the most recent transcript entry for paste-last functionality.
    func pasteLast() async throws -> TranscriptEntry?
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
    #endif
}
