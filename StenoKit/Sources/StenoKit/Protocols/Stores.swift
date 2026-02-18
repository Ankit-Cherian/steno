import Foundation

/// Persists and queries transcript history with a 30-day rolling window.
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
    ///   - tier: Cloud model tier for budget management.
    func retry(
        entryID: UUID,
        using cleanupEngine: CleanupEngine,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        tier: CloudModelTier
    ) async throws -> CleanTranscript

    /// Retrieves the most recent transcript entry for paste-last functionality.
    func pasteLast() async throws -> TranscriptEntry?
}

/// Orchestrates text insertion using an ordered chain of transports with target-aware reordering.
public protocol InsertionServiceProtocol: Sendable {
    /// Inserts the given text into the target application using the configured transport chain.
    func insert(text: String, target: AppContext) async -> InsertResult
}
