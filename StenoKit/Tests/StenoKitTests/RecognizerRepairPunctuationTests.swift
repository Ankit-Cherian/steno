import Foundation
import Testing
@testable import StenoKit

/// Recognizer output for spoken corrections, recorded from the production recognizer settings
/// (small.en, vocabulary prompt, VAD) with the mean token confidence it reported.
private let recordedSpokenCorrections: [(spoken: String, recognized: String, confidence: Double, expected: String)] = [
    ("Send it to John, scratch that, Jane.", "Send it to John, scratch that Jane.", 0.8791, "Send it to Jane."),
    ("Call Bob, never mind, call Jane.", "Call Bob. Never mind. Call Jane.", 0.8904, "Call Jane."),
    ("Never mind. Call Jane.", "Nevermind. Call Jane.", 0.8511, "Call Jane."),
]

@Test("Spoken corrections resolve in the punctuation the recognizer writes")
func spokenCorrectionsResolveInRecognizerPunctuation() async throws {
    for sample in recordedSpokenCorrections {
        for confidence in [sample.confidence, typicalDictationConfidence] {
            let inserted = try await dictateThroughCoordinator(sample.recognized, confidence: confidence)
            #expect(inserted == sample.expected, "\(sample.spoken) recognized as \(sample.recognized)")
        }
    }
}

@Test("Recognizer-style correction punctuation still leaves literal phrases alone")
func recognizerPunctuationKeepsLiteralPhrases() async throws {
    let literal = [
        "Nevermind the cost.",
        "Call Bob. Never mind the cost.",
        "Call Bob. Nevermind, the cost is low.",
        "I never mind. Other people usually do.",
        "Send it to John, scratch that Jane Smith.",
        "Tell Bob, scratch that itch.",
        "Bob scratch that Jane",
        "Call Bob scratch that Jane",
        "Call Bob. Delete that file.",
        "The words, scratch that Jane wrote, were literal.",
    ]

    for sentence in literal {
        #expect(try await dictateThroughCoordinator(sentence) == sentence)
    }
}
