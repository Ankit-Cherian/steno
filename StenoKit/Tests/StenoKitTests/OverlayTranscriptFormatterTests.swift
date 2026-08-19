import Testing
@testable import StenoKit

@Suite("Overlay transcript formatting")
struct OverlayTranscriptFormatterTests {
    @Test
    func testPreservesShortStableAndDraftText() {
        let result = OverlayTranscriptFormatter.presentation(
            stablePrefix: "The stable words",
            revisableTail: "may change"
        )

        #expect(result.stablePrefix == "The stable words")
        #expect(result.revisableTail == "may change")
    }

    @Test
    func testTrimsDisplayOnlyWhitespace() {
        let result = OverlayTranscriptFormatter.presentation(
            stablePrefix: "\n  The stable words   ",
            revisableTail: "  may change\n"
        )

        #expect(result.stablePrefix == "The stable words")
        #expect(result.revisableTail == "may change")
    }

    @Test
    func testBoundsStableTextAtACompleteWordWhenPossible() {
        let text = Array(repeating: "earlier", count: 60).joined(separator: " ")
            + " final complete words"

        let result = OverlayTranscriptFormatter.presentation(
            stablePrefix: text,
            revisableTail: ""
        )

        #expect(result.stablePrefix.count <= OverlayTranscriptFormatter.maximumStableGraphemes)
        #expect(!result.stablePrefix.hasPrefix("arlier"))
        #expect(result.stablePrefix.hasSuffix("final complete words"))
    }

    @Test
    func testBoundsUnbrokenTextAtAGraphemeBoundary() {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 300)

        let result = OverlayTranscriptFormatter.presentation(
            stablePrefix: "",
            revisableTail: text
        )

        #expect(result.revisableTail.count == OverlayTranscriptFormatter.maximumDraftGraphemes)
        #expect(
            result.revisableTail
                == String(repeating: family, count: OverlayTranscriptFormatter.maximumDraftGraphemes)
        )
    }

    @Test
    func testVisibleRenderCadenceIsCappedAtFourPerSecond() {
        #expect(OverlayLiveUpdatePolicy.minimumRenderInterval >= 0.25)
    }
}
