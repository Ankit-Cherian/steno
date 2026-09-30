import Foundation
import Testing
@testable import StenoKit

@Test("Paragraph capitalization keeps words with interior capitals")
func paragraphCapitalizationKeepsInteriorCapitals() async throws {
    for sentence in ["iPhone is ready", "eBay listing is live", "macOS update is out", "iOS 26 ships today"] {
        #expect(try await dictateThroughCoordinator(sentence) == sentence)
    }
    #expect(try await dictateThroughCoordinator("the iPhone is ready") == "The iPhone is ready")
}

@Test("Paragraph capitalization keeps a saved preferred spelling at sentence start")
func paragraphCapitalizationKeepsPreferredSpelling() async throws {
    let entries = defaultVocabularyEntries + [
        LexiconEntry(term: "npm", preferred: "npm", scope: .global),
        LexiconEntry(term: "ifone", preferred: "iPhone", scope: .global),
    ]

    #expect(try await dictateThroughCoordinator("npm install left-pad", entries: entries) == "npm install left-pad")
    #expect(try await dictateThroughCoordinator("ifone is ready", entries: entries) == "iPhone is ready")
    #expect(try await dictateThroughCoordinator("npmx is new", entries: entries) == "Npmx is new")
    #expect(try await dictateThroughCoordinator("hey stenoh", entries: entries) == "Hey Steno")
}
