import Foundation

/// Replays, on a saved History entry, the stages live dictation runs after recognition: the
/// spoken lowercase directive, text shortcuts, the IDE slash-command passthrough, cleanup, and the
/// directive again on the cleaned text.
///
/// History stores the recognized text with its directive still in place, before shortcuts were
/// expanded. Entries without a directive store the text after shortcuts were expanded, so
/// shortcuts are expanded again only for directive entries.
enum HistoryCleanupRerun {
    static func clean(
        _ entry: TranscriptEntry,
        using cleanupEngine: CleanupEngine,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        appContext: AppContext,
        snippets: SnippetService?
    ) async throws -> CleanTranscript {
        let policy = DictationContinuationPolicy()
        let plan = policy.prepareDirective(in: entry.rawText)
        if plan.kind != .none,
           directiveWasApplied(plan, toCleanText: entry.originalCleanText ?? entry.cleanText) == false {
            throw HistoryStoreError.directiveCannotBeReplayed
        }

        var text = plan.textForCleanup
        if plan.kind != .none, let snippets {
            text = await snippets.apply(to: text, appContext: appContext)
        }

        var cleaned: CleanTranscript
        if profile.commandPolicy == .passthrough,
           appContext.isIDE,
           text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            cleaned = CleanTranscript(text: text)
        } else {
            cleaned = try await cleanupEngine.cleanup(
                raw: RawTranscript(text: text, durationMS: entry.durationMS),
                profile: profile,
                lexicon: lexicon
            )
        }

        cleaned.text = policy.applyDirective(plan, toCleanedText: cleaned.text)
        if cleaned.text.trimmingCharacters(in: .whitespaces).isEmpty {
            throw HistoryStoreError.rerunLeftNoText
        }
        if plan.kind != .none {
            cleaned.edits.append(TranscriptEdit(kind: .commandTransform, from: entry.rawText, to: cleaned.text))
        }
        return cleaned
    }

    /// Whether live dictation applied the directive that `rawText` starts with. Versions before
    /// spoken directives, and 1.0.0's own re-run, left the directive word in the clean text; such
    /// an entry can't be told apart from a dictation that meant the word, so it is not replayed.
    private static func directiveWasApplied(_ plan: DictationDirectivePlan, toCleanText cleanText: String) -> Bool {
        switch plan.kind {
        case .none:
            return true
        case .lowercase:
            return startsWithWord("lowercase", cleanText) == false
        case .literalEscape:
            return startsWithWord("literal", cleanText) == false && startsWithWord("lowercase", cleanText)
        }
    }

    private static func startsWithWord(_ word: String, _ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.lowercased().hasPrefix(word) else { return false }
        guard let next = trimmed.dropFirst(word.count).first else { return true }
        return next.isLetter == false && next.isNumber == false
    }
}
