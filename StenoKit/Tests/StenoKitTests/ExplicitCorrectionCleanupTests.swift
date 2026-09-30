import Foundation
import Testing
@testable import StenoKit

/// Confidence values the recognizer produces: unknown, low, typical, and high.
private let confidenceLevels: [Double?] = [nil, 0.6, typicalDictationConfidence, 0.95]

@Test("Saved corrections apply at every recognizer confidence", arguments: confidenceLevels)
func savedCorrectionsApplyAtEveryConfidence(confidence: Double?) async throws {
    let inserted = try await dictateThroughCoordinator(
        "i told him to open stenoh yesterday",
        confidence: confidence
    )

    #expect(inserted == "I told him to open Steno yesterday")
}

@Test("Corrections that merge words apply in short dictations", arguments: confidenceLevels)
func mergingCorrectionsApplyInShortDictations(confidence: Double?) async throws {
    #expect(try await dictateThroughCoordinator("open steno kit", confidence: confidence) == "Open StenoKit")
    #expect(try await dictateThroughCoordinator("open steno kit now", confidence: confidence) == "Open StenoKit now")
    #expect(try await dictateThroughCoordinator("stenoh", confidence: confidence) == "Steno")
}

@Test("Casing-only corrections apply through the coordinator", arguments: confidenceLevels)
func casingOnlyCorrectionsApplyThroughCoordinator(confidence: Double?) async throws {
    let entries = defaultVocabularyEntries + [LexiconEntry(term: "github", preferred: "GitHub", scope: .global)]

    #expect(
        try await dictateThroughCoordinator(
            "I pushed the branch to github yesterday.",
            confidence: confidence,
            entries: entries
        ) == "I pushed the branch to GitHub yesterday."
    )
    #expect(
        try await dictateThroughCoordinator(
            "I pushed the branch to git hub yesterday.",
            confidence: confidence,
            entries: entries
        ) == "I pushed the branch to GitHub yesterday."
    )
}

@Test("Spoken corrections apply at every recognizer confidence", arguments: confidenceLevels)
func spokenCorrectionsApplyAtEveryConfidence(confidence: Double?) async throws {
    let examples = [
        ("Send it to John, scratch that, Jane.", "Send it to Jane."),
        ("Never mind. Call Jane.", "Call Jane."),
        ("Call Bob, never mind, call Jane.", "Call Jane."),
        ("I said Bob, I mean, Jane.", "I said Jane."),
    ]

    for (spoken, expected) in examples {
        #expect(try await dictateThroughCoordinator(spoken, confidence: confidence) == expected)
    }
}

@Test("Paragraph capitalization survives typical confidence alongside a correction")
func paragraphCapitalizationSurvivesTypicalConfidence() async throws {
    #expect(try await dictateThroughCoordinator("hey stenoh open the editor") == "Hey Steno open the editor")
}

@Test("Ordinary sentences that mention correction phrases are left alone at typical confidence")
func literalCorrectionPhrasesStayLiteral() async throws {
    let literal = [
        "I actually think we should ship on Friday.",
        "Actually, I'd like to keep the old design.",
        "No, we did not approve the budget.",
        "No. We did not approve the budget.",
        "Never mind the noise, the fix works.",
        "I mean it, the deadline is real.",
        "What do you mean by that?",
        "I mean, it is fine, but not great.",
        "Tell Bob, scratch that, tell Alice to send the invoice.",
        "Send it to John, I mean, Jane.",
        "Send the file to Bob, scratch that, Jane Smith.",
        "Book the room for Monday, scratch that, Tuesday.",
        "Set the alarm for six, never mind, set it for seven.",
        "Rename the file to draft, never mind, rename it to final.",
        "The meeting is at noon, scratch that, at one.",
        "Add milk, scratch that, add oat milk.",
        "Add milk. Scratch that. Add oat milk.",
        "Please erase that whiteboard, Sam.",
        "You should delete that, Sam.",
        "Delete that, Sam.",
        "We wrote scratch that on the board, Jane.",
        "The command is delete that, Jane.",
        "Please type scratch that literally.",
        "I never mind doing the dishes.",
    ]

    for sentence in literal {
        #expect(try await dictateThroughCoordinator(sentence) == sentence)
    }

    #expect(try await dictateThroughCoordinator("Ask Sam, never mind, ask Priya.") == "Ask Priya.")
    #expect(try await dictateThroughCoordinator("Call Bob, delete that, Jane.") == "Call Jane.")
}

@Test("Default cleanup preserves meaning at every recognizer confidence", arguments: confidenceLevels)
func defaultCleanupPreservesMeaning(confidence: Double?) async throws {
    let sentences = [
        "No, I did not approve the budget.",
        "There is no reason to wait.",
        "I don't disagree with that.",
        "It's not that I can't do it, I just won't.",
        "We can't ship until the tests pass.",
        "Don't delete the backup, never.",
        "Set the timer for 15 minutes and preheat to 350 degrees.",
        "The file is 2.5 GB and the limit is 500 MB.",
        "Transfer $1,200 to savings on the 3rd.",
        "What kind of car is that?",
        "He is the kind of person who helps.",
        "It was like a dream, you know.",
        "I think, um, this should, you know, ship today.",
    ]

    for sentence in sentences {
        #expect(try await dictateThroughCoordinator(sentence, confidence: confidence) == sentence)
    }
}

@Test("Explicit vocabulary is not scored against the unedited text")
func explicitVocabularyIsNotScored() async throws {
    let engine = RuleBasedCleanupEngine()
    let lexicon = PersonalLexicon(entries: defaultVocabularyEntries)

    let cleaned = try await engine.cleanup(
        raw: dictatedTranscript("open stenoh", confidence: 0.98),
        profile: defaultStyleProfile,
        lexicon: lexicon
    )

    #expect(cleaned.text == "Open Steno")
    #expect(cleaned.edits.contains(TranscriptEdit(kind: .lexiconCorrection, from: "stenoh", to: "Steno")))
}
