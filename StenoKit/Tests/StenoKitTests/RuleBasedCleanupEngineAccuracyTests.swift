import Testing
@testable import StenoKit

@Test("Balanced filler policy preserves meaning-bearing like in noun phrase")
func balancedPolicyPreservesLikeInNounPhrase() async throws {
    let cleaned = try await runLocalCleanup(
        text: "From the respect paid her on all sides she seemed like a queen.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "From the respect paid her on all sides she seemed like a queen.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("like") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves like before determiner")
func balancedPolicyPreservesLikeBeforeDeterminer() async throws {
    let cleaned = try await runLocalCleanup(
        text: "Two innocent babies like that.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "Two innocent babies like that.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("like") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves like as verb complement")
func balancedPolicyPreservesLikeAsVerbComplement() async throws {
    let cleaned = try await runLocalCleanup(
        text: "The twin brother did something she didn't like and she turned his picture to the wall.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "The twin brother did something she didn't like and she turned his picture to the wall.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("like") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves multiple meaning-bearing like occurrences")
func balancedPolicyPreservesMultipleMeaningBearingLikes() async throws {
    let cleaned = try await runLocalCleanup(
        text: "I'd like to see what this lovely furniture looks like without such quantities of dust all over it.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I'd like to see what this lovely furniture looks like without such quantities of dust all over it.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("like") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves ambiguous interjectional like")
func balancedPolicyPreservesInterjectionalLike() async throws {
    let raw = "Like, we should head out now."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves ambiguous um and uh tokens")
func balancedPolicyPreservesUmAndUh() async throws {
    let raw = "Um I think uh this should stay clear."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves punctuated um and uh tokens")
func balancedPolicyPreservesPunctuatedUmAndUh() async throws {
    let raw = "Um, I think, uh, this should ship today."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves punctuation-delimited filler-like phrases")
func balancedPolicyPreservesDelimitedFillerLikePhrases() async throws {
    let examples = [
        "Um, I think we should schedule the meeting.",
        "The report is, uh, almost finished.",
        "We need to, you know, think about this.",
        "I think, um, this should, you know, ship today.",
        "The show, Um, Actually, won an award.",
        "Um, I Love You is the title of the song.",
        "The title is, You Know, printed in blue.",
        "The dictionary lists, um, as an interjection.",
        "The identifier, um, is reserved.",
        "The variable, uh, is named output.",
        "The phrase is \"foo, um, bar\".",
        "The quote was \"we need to, you know, think\".",
        "Um, The Musical premiered yesterday.",
        "I think, um, you know, this is risky.",
        "We should, uh, you know, wait.",
        "First paragraph.\n\nI think, um, this is second.",
        "Keep\tthis spacing, uh, intact.",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
    }
}

@Test("Balanced filler cleanup preserves normal commas before pronouns")
func balancedPolicyPreservesNormalCommasBeforePronouns() async throws {
    let examples = [
        "my Mac, it keeps the capture hot.",
        "programmatically, you can wire this through the coordinator.",
        "the code, he said, was ready.",
        "open it, that tab has the trace.",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
    }
}

@Test("Balanced filler policy preserves an unrelated clause comma and source text")
func balancedFillerPolicyPreservesUnrelatedClauseComma() async throws {
    let raw = "Um, if the service fails, we should preserve the recording."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced candidate generation does not infer lexical filler intent")
func balancedCandidateGenerationDoesNotInferLexicalFillerIntent() async throws {
    let examples = [
        "i mean this is basically ready.",
        "The title: You Know, Nothing.",
        "Label—You Know—A Memoir.",
    ]

    for example in examples {
        let candidates = try await runGeneratedCandidates(
            text: example,
            fillerPolicy: .balanced
        )

        #expect(candidates.allSatisfy { candidate in
            candidate.removedFillers.isEmpty
                && candidate.appliedEdits.contains(where: { $0.kind == .fillerRemoval }) == false
        })
    }
}

@Test("Aggressive candidate generation may emit aggressive filler removals")
func aggressiveCandidateGenerationMayEmitAggressiveFillerRemovals() async throws {
    let candidates = try await runGeneratedCandidates(
        text: "i mean this is basically ready.",
        fillerPolicy: .aggressive
    )

    #expect(candidates.contains { candidate in
        candidate.removedFillers.contains("i mean")
            || candidate.removedFillers.contains("basically")
    })
}

@Test("Aggressive filler policy is explicit and preserves source casing")
func aggressiveFillerPolicyPreservesSourceCasing() async throws {
    let cleaned = try await runLocalCleanup(
        text: "um eBay is down.",
        fillerPolicy: .aggressive
    )

    #expect(cleaned.text == "eBay is down.")
    #expect(cleaned.removedFillers == ["um"])
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }))
}

@Test("Aggressive filler policy preserves explicit literal and title frames")
func aggressiveFillerPolicyPreservesLiteralFrames() async throws {
    let examples = [
        "Um, Actually is a television show.",
        "The show, Um, Actually, won an award.",
        "The word, um, is a hesitation marker.",
        "The dictionary lists, um, as an interjection.",
        "The glossary defines, uh, as a hesitation.",
        "The test expects, um, exactly.",
        "The identifier, um, is reserved.",
        "The variable, uh, is named output.",
        "She wrote um in the transcript.",
        "The string contains um here.",
        "The value is um in this field.",
        "The source contains sort of literally.",
        "The source contains kind of literally.",
        "The source contains basically literally.",
        "The note records uh verbatim.",
        "The caption includes um as written.",
        "The phrase, you know, appears twice.",
        "The title, You Know, won an award.",
        "The title is, You Know, printed in blue.",
        "The title is I Mean It.",
        "The word, like, is common.",
        "The phrase is \"foo, um, bar\".",
        "The quote was \"we need to, you know, think\".",
        "Um, I Love You is the title of the song.",
        "Um, The Musical premiered yesterday.",
        "Say I mean literally.",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .aggressive)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
    }
}

@Test("Aggressive filler cleanup preserves formatting outside the local edit")
func aggressiveFillerCleanupPreservesUnrelatedFormatting() async throws {
    let raw = "First paragraph.\n\nI think, um, this is second.\nKeep\tthis spacing."
    let cleaned = try await runLocalCleanup(text: raw, fillerPolicy: .aggressive)

    #expect(cleaned.text == "First paragraph.\n\nI think this is second.\nKeep\tthis spacing.")
    #expect(cleaned.removedFillers == ["um"])
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }))
}

@Test("Aggressive filler literal cues do not cross line boundaries")
func aggressiveFillerLiteralCuesStayWithinTheCurrentLine() async throws {
    let raw = "Header\tvalue\nThe report is,\tuh,\talmost finished.\nTail\tkept"
    let cleaned = try await runLocalCleanup(text: raw, fillerPolicy: .aggressive)

    #expect(cleaned.text == "Header\tvalue\nThe report is almost finished.\nTail\tkept")
    #expect(cleaned.removedFillers == ["uh"])
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }))
}

@Test("Aggressive filler cleanup removes adjacent repeats atomically")
func aggressiveFillerCleanupRemovesAdjacentRepeatsAtomically() async throws {
    let examples = [
        ("I think, um, um, this is risky.", "I think this is risky."),
        ("I think, uh, uh, uh, this is risky.", "I think this is risky."),
        ("It is, basically, basically, ready.", "It is ready."),
        ("This is, kind of, kind of, ready.", "This is ready."),
    ]

    for (raw, expected) in examples {
        let cleaned = try await runLocalCleanup(text: raw, fillerPolicy: .aggressive)

        #expect(cleaned.text == expected)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }))
    }
}

@Test("Aggressive filler cleanup owns punctuation at its local edit boundary")
func aggressiveFillerCleanupOwnsLocalPunctuation() async throws {
    let examples = [
        ("I think, um this is risky.", "I think this is risky."),
        ("This is, kind of ready.", "This is ready."),
        ("Wait, um! Are we ready.", "Wait! Are we ready."),
    ]

    for (raw, expected) in examples {
        let cleaned = try await runLocalCleanup(text: raw, fillerPolicy: .aggressive)

        #expect(cleaned.text == expected)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }))
    }
}

@Test("Balanced cleanup does not select aggressive filler removals")
func balancedCleanupDoesNotSelectAggressiveFillerRemovals() async throws {
    let cleaned = try await runLocalCleanup(
        text: "i mean this is basically ready.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "i mean this is basically ready.")
    #expect(cleaned.removedFillers.isEmpty)
}

@Test("Balanced filler policy preserves source casing after a leading um token")
func balancedFillerPolicyPreservesSourceCasingAfterLeadingUm() async throws {
    let raw = "um this should start clean."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves lowercase domain components")
func balancedFillerPolicyPreservesLowercaseDomainComponents() async throws {
    let raw = "um visit example.com for details."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves lowercase text after an abbreviation")
func balancedFillerPolicyPreservesLowercaseTextAfterAbbreviation() async throws {
    let raw = "um the value is e.g. experimental."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves parenthetical abbreviations and source text")
func balancedFillerPolicyPreservesParentheticalAbbreviations() async throws {
    let examples = [
        "um use (e.g. experimental) values.",
        "um follow the U.S. policy.",
        "um use v1.2 beta.",
        "um measure 3.14 meters.",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
    }
}

@Test("Balanced filler policy preserves sentence-boundary punctuation")
func balancedFillerPolicyPreservesSentenceBoundaryPunctuation() async throws {
    let raw = "This is. um, okay."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves comma-surrounded you know")
func balancedFillerPolicyPreservesCommaSurroundedYouKnow() async throws {
    let raw = "Make it clear, you know, make it useful."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves comma-question source punctuation")
func balancedFillerPolicyPreservesCommaQuestionSourcePunctuation() async throws {
    let raw = "Wait, um? Are we ready."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves you know before determiner")
func balancedPolicyPreservesYouKnowBeforeDeterminer() async throws {
    let cleaned = try await runLocalCleanup(
        text: "I think you know the answer to that question.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I think you know the answer to that question.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves you know before pronoun")
func balancedPolicyPreservesYouKnowBeforePronoun() async throws {
    let cleaned = try await runLocalCleanup(
        text: "I told him you know he was right about everything.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I told him you know he was right about everything.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves you know before wh word")
func balancedPolicyPreservesYouKnowBeforeWhWord() async throws {
    let cleaned = try await runLocalCleanup(
        text: "She explained you know what happened at the meeting.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "She explained you know what happened at the meeting.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves you know before if")
func balancedPolicyPreservesYouKnowBeforeIf() async throws {
    let cleaned = try await runLocalCleanup(
        text: "I think you know if we should ship this today.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I think you know if we should ship this today.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves ambiguous unpunctuated sentence-final you know")
func balancedPolicyPreservesUnpunctuatedSentenceFinalYouKnow() async throws {
    let cleaned = try await runLocalCleanup(
        text: "The team was ready you know.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "The team was ready you know.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves punctuation-delimited sentence-final you know")
func balancedPolicyPreservesDelimitedSentenceFinalYouKnow() async throws {
    let raw = "The team was ready, you know."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves ambiguous unpunctuated you know insertion")
func balancedPolicyPreservesAmbiguousUnpunctuatedYouKnowInsertion() async throws {
    let cleaned = try await runLocalCleanup(
        text: "The report was you know solid and everyone agreed with the findings.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "The report was you know solid and everyone agreed with the findings.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves um and contextual you know")
func balancedPolicyPreservesUmAndContextualYouKnow() async throws {
    let raw = "Um I think you know she was the best candidate for the position."
    let cleaned = try await runLocalCleanup(
        text: raw,
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == raw)
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
}

@Test("Balanced filler policy preserves fixed phrases around you know")
func balancedPolicyPreservesFixedPhrasesAroundYouKnow() async throws {
    let examples = [
        "I'll let you know.",
        "As you know, this is risky.",
        "Everything you know about this matters.",
        "Everything you know in that file matters.",
        "Do you know?",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
    }
}

@Test("Balanced filler policy preserves semantic direct-object uses of you know")
func balancedPolicyPreservesSemanticDirectObjectYouKnow() async throws {
    let examples = [
        "I believe you know Swift very well.",
        "I think you know Steno already.",
        "I know you know macOS shortcuts.",
        "I'm sure you know Swift well.",
        "I suspect you know Swift well.",
        "I know that you know Swift well.",
        "Only you know why.",
        "People you know matter.",
        "You know Swift.",
        "I said that you know.",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
    }
}

@Test("Balanced filler policy preserves titles and literal text containing you know")
func balancedPolicyPreservesTitlesAndLiteralYouKnowText() async throws {
    let examples = [
        "The title is You Know Nothing.",
        "The title is You Know Better.",
        "The result is you know nothing.",
        "The text is you know Swift.",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
    }
}

@Test("Balanced filler policy preserves punctuation-delimited literal and title phrases")
func balancedPolicyPreservesDelimitedLiteralFillerPhrases() async throws {
    let examples = [
        "The title, You Know, won an award.",
        "The phrase, you know, appears twice.",
        "The words, you know, are literal.",
        "The song, You Know, charted yesterday.",
        "The phrase: you know, is common.",
        "The words: you know; belong here.",
        "The title: You Know, Nothing.",
        "Label—You Know—A Memoir.",
        "Um, Actually is a television show.",
        "The word, um, is a hesitation marker.",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
    }
}

@Test("Balanced filler policy preserves source casing and dotted sentence boundaries")
func balancedPolicyPreservesSourceCasingAndDottedSentenceBoundaries() async throws {
    let examples = [
        "um eBay is down.",
        "um iPhone is ready.",
        "um macOS is ready.",
        "um npm is installed.",
        "um done. eBay works.",
        "um i moved to the U.S. she stayed home.",
        "um i moved to the A.B. she stayed home.",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval }) == false)
    }
}

@Test("Cleanup does not apply dangerous common-word lexicon entries in ordinary prose")
func cleanupDoesNotApplyDangerousCommonWordLexiconEntriesInOrdinaryProse() async throws {
    let lexicon = PersonalLexicon(entries: [
        .init(term: "cloud", preferred: "Nimbus", scope: .global)
    ])
    let examples = [
        "stored in the cloud",
        "cloud storage",
        "upload it to the cloud",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(
            text: example,
            fillerPolicy: .balanced,
            lexicon: lexicon
        )

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .lexiconCorrection }) == false)
    }
}

private func runLocalCleanup(
    text: String,
    fillerPolicy: FillerPolicy,
    lexicon: PersonalLexicon = PersonalLexicon(entries: [])
) async throws -> CleanTranscript {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Accuracy Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: fillerPolicy,
        commandPolicy: .passthrough
    )

    return try await engine.cleanup(
        raw: RawTranscript(text: text),
        profile: profile,
        lexicon: lexicon
    )
}

private func runGeneratedCandidates(
    text: String,
    fillerPolicy: FillerPolicy
) async throws -> [CleanupCandidate] {
    let generator = RuleBasedCleanupCandidateGenerator()
    let profile = StyleProfile(
        name: "Candidate Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: fillerPolicy,
        commandPolicy: .passthrough
    )

    return try await generator.generateCandidates(
        raw: RawTranscript(text: text),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )
}
