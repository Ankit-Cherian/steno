import Foundation
import StenoKit

/// Where the window reads a dictation's step-by-step record and its word fixes.
@MainActor
enum DictationRecordBridge {
    /// The step-by-step record of a dictation, or nil for dictations saved before it existed.
    static func record(for entry: TranscriptEntry) -> DictationRecord? {
        entry.record
    }

    /// Word fixes made to a dictation, oldest first.
    static func fixes(for entry: TranscriptEntry) -> [WordFix] {
        entry.fixes ?? []
    }

    /// Which occurrence of the selected word this is, so the same word elsewhere is left alone.
    static func occurrence(of word: String, in range: NSRange, text: String) -> Int? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        return WordFixLocator.occurrence(of: word, at: swiftRange, in: text)
    }
}

/// Applies and undoes word fixes on saved dictations. The requirements match
/// `DictationController`'s methods, so the controller conforms as it is.
@MainActor
protocol WordFixing: AnyObject {
    var isAvailable: Bool { get }
    /// `expectingText` is the clean text `occurrence` was counted in; a dictation whose text is
    /// another throws `WordFixError.dictationChanged`.
    func applyWordFix(entryID: UUID, original: String, occurrence: Int, replacement: String,
                      appliesToFuture: Bool, confirmingCommonWord: Bool,
                      expectingText: String?) async throws -> TranscriptEntry
    /// `expectingFixCount` is how many fixes the dictation had when Undo was offered.
    func undoLastWordFix(entryID: UUID, expectingFixCount: Int?) async throws -> TranscriptEntry
    func copyCorrectedText(entryID: UUID) async
}

extension WordFixing {
    func applyWordFix(entryID: UUID, original: String, occurrence: Int, replacement: String,
                      appliesToFuture: Bool, confirmingCommonWord: Bool) async throws -> TranscriptEntry {
        try await applyWordFix(entryID: entryID, original: original, occurrence: occurrence,
                               replacement: replacement, appliesToFuture: appliesToFuture,
                               confirmingCommonWord: confirmingCommonWord, expectingText: nil)
    }

    func undoLastWordFix(entryID: UUID) async throws -> TranscriptEntry {
        try await undoLastWordFix(entryID: entryID, expectingFixCount: nil)
    }
}

extension DictationController: WordFixing {
    var isAvailable: Bool { true }
}

enum WordFixers {
    /// The controller fixes saved dictations; in an isolated preview it fixes the sample entries
    /// in memory only.
    @MainActor
    static func current(for controller: DictationController) -> WordFixing {
        controller
    }
}
