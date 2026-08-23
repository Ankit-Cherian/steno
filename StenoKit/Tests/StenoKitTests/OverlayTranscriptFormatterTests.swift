import Testing
@testable import StenoKit

@Suite("Overlay transcript formatting")
struct OverlayTranscriptFormatterTests {
    @Test
    func preservesAcceptedSpeechAsOnePassage() {
        let provisional = "The stable words may change"

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text == provisional)
        #expect(!result.text.contains("Draft"))
    }

    @Test
    func trimsOnlyOuterDisplayWhitespace() {
        let result = OverlayTranscriptFormatter.presentation(
            provisionalText: "\n  The words flow exactly as spoken.   \n"
        )

        #expect(result.text == "The words flow exactly as spoken.")
    }

    @Test
    func leavesThePassageEmptyUntilSpeechArrives() {
        let result = OverlayTranscriptFormatter.presentation(provisionalText: " \n ")

        #expect(result.text.isEmpty)
    }

    @Test
    func prefersTheLastTwoSentenceRangesWhenThePassageRollsOver() {
        let earlier = String(repeating: "Earlier context keeps accumulating without interruption. ", count: 5)
        let provisional = earlier
            + "This is the sentence that should remain. "
            + "These newest words are still flowing."

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text == "This is the sentence that should remain. These newest words are still flowing.")
        #expect(result.text.count <= OverlayTranscriptFormatter.maximumVisibleGraphemes)
        #expect(provisional.hasSuffix(result.text))
    }

    @Test
    func keepsAtMostTwoSentenceRangesEvenBelowTheGraphemeCeiling() {
        let provisional = "First sentence. Second sentence. Third sentence."

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text == "Second sentence. Third sentence.")
    }

    @Test
    func foundationSentenceRangesKeepClosingQuotesWithTheirSentence() {
        let provisional = "First sentence. “Second stays.” Third stays."

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text == "“Second stays.” Third stays.")
        #expect(provisional.hasSuffix(result.text))
    }

    @Test
    func foundationSentenceRangesDoNotSplitDecimalPoints() {
        let provisional = "Dr. Rivera arrived. The value was 3.14 units. Final result held."

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text == "The value was 3.14 units. Final result held.")
        #expect(provisional.hasSuffix(result.text))
    }

    @Test
    func foundationSentenceRangesRecognizeAnEllipsisMadeOfPeriods() {
        let provisional = "Old thought... Second sentence remains. Third sentence remains."

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text == "Second sentence remains. Third sentence remains.")
        #expect(provisional.hasSuffix(result.text))
    }

    @Test
    func foundationSentenceRangesRecognizeNonASCIIPunctuation() {
        let provisional = "第一句。第二句。第三句。"

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text == "第二句。第三句。")
        #expect(provisional.hasSuffix(result.text))
    }

    @Test
    func usesACompleteSentenceBoundaryWhenTwoSentencesExceedTheBound() {
        let oversizedSentence = String(repeating: "long ", count: 35) + "ends. "
        let newestSentence = "The newest complete sentence remains visible."
        let provisional = "Old sentence. " + oversizedSentence + newestSentence

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text == newestSentence)
        #expect(result.text.count <= OverlayTranscriptFormatter.maximumVisibleGraphemes)
        #expect(provisional.hasSuffix(result.text))
    }

    @Test
    func fallsBackToACompleteWordWhenThereIsNoSentenceBoundary() {
        let provisional = Array(repeating: "earlier", count: 60).joined(separator: " ")
            + " final complete words"

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text.count <= OverlayTranscriptFormatter.maximumVisibleGraphemes)
        #expect(!result.text.hasPrefix("arlier"))
        #expect(result.text.hasSuffix("final complete words"))
        #expect(provisional.hasSuffix(result.text))
    }

    @Test
    func neverSplitsAnExtendedGrapheme() {
        let family = "👨‍👩‍👧‍👦"
        let provisional = String(repeating: family, count: 300)

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text.count == OverlayTranscriptFormatter.maximumVisibleGraphemes)
        #expect(
            result.text
                == String(repeating: family, count: OverlayTranscriptFormatter.maximumVisibleGraphemes)
        )
        #expect(provisional.hasSuffix(result.text))
    }

    @Test
    func adaptiveBudgetRemainsAnExactSuffixBelowTheGlobalCeiling() {
        let provisional = Array(repeating: "earlier", count: 30).joined(separator: " ")
            + " newest words remain visible"

        let result = OverlayTranscriptFormatter.presentation(
            provisionalText: provisional,
            maximumVisibleGraphemes: 42
        )

        #expect(result.text.count <= 42)
        #expect(result.text.hasSuffix("newest words remain visible"))
        #expect(provisional.hasSuffix(result.text))
    }

    @Test
    func newlineBeginsANewSentenceRange() {
        let provisional = String(repeating: "Old material ", count: 20)
            + "ends. First retained line.\nSecond retained line"

        let result = OverlayTranscriptFormatter.presentation(provisionalText: provisional)

        #expect(result.text == "First retained line.\nSecond retained line")
    }

    @Test
    func visibleRenderCadenceIsCappedAtFourPerSecond() {
        #expect(OverlayLiveUpdatePolicy.minimumRenderInterval >= 0.25)
    }
}
