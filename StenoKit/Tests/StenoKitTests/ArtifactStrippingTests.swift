import Foundation
import Testing
@testable import StenoKit

@Test("stripArtifacts removes [Music]")
func stripArtifactsBracketedMusic() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("[Music]") == "")
}

@Test("stripArtifacts removes [Music] but preserves real text")
func stripArtifactsMusicWithText() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("[Music] Hello there") == "Hello there")
}

@Test("stripArtifacts removes [LAUGHTER] case-insensitively")
func stripArtifactsUppercaseLaughter() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("[LAUGHTER]") == "")
}

@Test("stripArtifacts preserves [TODO]")
func stripArtifactsPreservesTodo() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("[TODO]") == "[TODO]")
}

@Test("stripArtifacts preserves (void)")
func stripArtifactsPreservesVoid() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("(void)") == "(void)")
}

@Test("stripArtifacts removes multiple artifacts and preserves text between them")
func stripArtifactsMultipleArtifacts() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("[Applause] Great work [Noise]") == "Great work")
}

@Test("stripArtifacts returns empty for whitespace-only after stripping")
func stripArtifactsWhitespaceOnlyAfterStrip() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("[Music]  [Silence]") == "")
}

@Test("stripArtifacts removes parenthetical artifacts")
func stripArtifactsParenthetical() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("(buzzing) test (applause)") == "test")
}

@Test("stripArtifacts removes [BLANK_AUDIO]")
func stripArtifactsBlankAudio() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("[BLANK_AUDIO]") == "")
}

@Test("stripArtifacts removes [background noise]")
func stripArtifactsBackgroundNoise() {
    #expect(WhisperCLITranscriptionEngine.stripArtifacts("[background noise] hello") == "hello")
}

@Test("stripArtifacts passes through normal text unchanged")
func stripArtifactsNormalText() {
    let text = "This is a normal sentence with no artifacts."
    #expect(WhisperCLITranscriptionEngine.stripArtifacts(text) == text)
}
