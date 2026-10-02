import Foundation
import Testing
@testable import StenoKit

private func profile(_ policy: FillerPolicy, _ structure: StructureMode = .natural) -> StyleProfile {
    StyleProfile(
        name: "Filler",
        tone: .natural,
        structureMode: structure,
        fillerPolicy: policy,
        commandPolicy: .transform
    )
}

private func clean(
    _ text: String,
    _ policy: FillerPolicy = .aggressive,
    structure: StructureMode = .natural,
    confidence: Double? = typicalDictationConfidence
) async throws -> String {
    try await RuleBasedCleanupEngine().cleanup(
        raw: dictatedTranscript(text, confidence: confidence),
        profile: profile(policy, structure),
        lexicon: PersonalLexicon(entries: [])
    ).text
}

// MARK: - Speed

@Test("Aggressive cleanup of a 10,000-character dictation stays far below the quadratic cost")
func aggressiveCleanupIsLinear() async throws {
    let unit = "So I was thinking um that we should look at the deployment plan and uh figure out what is basically left to do before the release. "
    let text = String(repeating: unit, count: 77)
    #expect(text.count >= 10_000)

    // Best of several runs, so other tests running in parallel don't decide the result. The
    // quadratic version took about a second on a fast machine, where this takes a few
    // milliseconds. The bound leaves room for a slow, busy machine.
    var fastest = Duration.seconds(60)
    var cleaned = ""
    for _ in 0..<5 {
        let start = ContinuousClock.now
        cleaned = try await clean(text, structure: .paragraph)
        fastest = min(fastest, ContinuousClock.now - start)
    }

    #expect(fastest < .milliseconds(500), "took \(fastest)")
    #expect(cleaned.contains(" um ") == false)
    #expect(cleaned.contains(" uh ") == false)
    #expect(cleaned.contains("basically") == false)
}

@Test("The ranker's edit penalty matches a full word-level Levenshtein table")
func rankerEditPenaltyMatchesFullTable() {
    func fullTable(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    var generator = SplitMix64(seed: 0x5EED)
    let vocabulary = ["a", "b", "c", "d", "e"]
    let ranker = LocalCleanupRanker()
    for _ in 0..<400 {
        let rawWords = (0..<Int.random(in: 1...40, using: &generator)).map { _ in vocabulary.randomElement(using: &generator)! }
        var candidateWords = rawWords
        for _ in 0..<Int.random(in: 0...8, using: &generator) {
            let operation = Int.random(in: 0...2, using: &generator)
            if operation == 1 || candidateWords.isEmpty {
                candidateWords.insert(vocabulary.randomElement(using: &generator)!, at: Int.random(in: 0...candidateWords.count, using: &generator))
            } else if operation == 0 {
                candidateWords.remove(at: Int.random(in: 0..<candidateWords.count, using: &generator))
            } else {
                candidateWords[Int.random(in: 0..<candidateWords.count, using: &generator)] = vocabulary.randomElement(using: &generator)!
            }
        }
        let score = ranker.scoreCandidate(
            rawText: rawWords.joined(separator: " "),
            candidate: CleanupCandidate(text: candidateWords.joined(separator: " "), appliedEdits: [], removedFillers: [], rulePathID: "x"),
            profile: profile(.balanced)
        )
        let expected = min(Double(fullTable(rawWords, candidateWords)) / Double(rawWords.count), 1)
        #expect(abs(score.editDistancePenalty - expected) < 1e-12, "\(rawWords) -> \(candidateWords)")
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - The recognizer's filler forms

// Recognizer output (small.en, production arguments) for a conversational recording.
private let recordedConversation =
    "I feel like we're just like down to like the wire. Um, I tried on dresses yesterday. That was exciting. So, yeah. Um, yeah. Um, my dress."

@Test("Aggressive removes fillers written with a capital and a comma at the start of a sentence")
func aggressiveRemovesSentenceInitialFillers() async throws {
    #expect(try await clean(recordedConversation)
        == "I feel like we're just like down to like the wire. I tried on dresses yesterday. That was exciting. So, yeah. Yeah. My dress.")
    #expect(try await clean("Um, I think we should ship.") == "I think we should ship.")
    #expect(try await clean("Call me later. Uh. Thanks.") == "Call me later. Thanks.")
    #expect(try await clean("Call me later. Um.") == "Call me later.")
    #expect(try await clean("It works. Basically, we ship on Friday.") == "It works. We ship on Friday.")
    #expect(try await clean("Um, iPhone sales are up.") == "iPhone sales are up.")
}

@Test("A dictation of only fillers is emptied under Aggressive and treated as no speech")
func aggressiveEmptiesFillerOnlyDictation() async throws {
    #expect(try await clean("Um, uh.") == "")
    #expect(try await clean("Uh.") == "")
    #expect(try await clean("Um, uh.", confidence: nil) == "")

    let inserted = try await dictateThroughCoordinator("Um, uh.", profile: profile(.aggressive, .paragraph))
    #expect(inserted == nil)
}

@Test("Minimal and Balanced keep the recognizer's fillers")
func minimalAndBalancedKeepRecognizerFillers() async throws {
    for policy in [FillerPolicy.minimal, .balanced] {
        #expect(try await clean("Um, uh.", policy) == "Um, uh.")
        #expect(try await clean(recordedConversation, policy) == recordedConversation)
        #expect(try await clean("I think, um, this should, you know, ship today.", policy)
            == "I think, um, this should, you know, ship today.")
    }
    let inserted = try await dictateThroughCoordinator("Um, uh.", profile: profile(.balanced, .paragraph))
    #expect(inserted == "Um, uh.")
}

@Test("Aggressive still keeps literal and quoted fillers")
func aggressiveKeepsLiteralFillers() async throws {
    #expect(try await clean("The word um is a filler.") == "The word um is a filler.")
    #expect(try await clean("She said \"Um, no.\" and left.") == "She said \"Um, no.\" and left.")
    #expect(try await clean("I think, um, this should, you know, ship today.")
        == "I think this should, you know, ship today.")
}

// MARK: - "kind of" and "sort of"

@Test("Aggressive keeps \"kind of\" and \"sort of\" where they mean \"type of\"")
func aggressiveKeepsTypeOfReading() async throws {
    let kept = [
        "What kind of car is that?",
        "What sort of plan is this?",
        "He is the kind of person who helps.",
        "Which kind of coffee do you want?",
        "That kind of thing happens.",
        "This sort of problem is common.",
        "It was some kind of error.",
        "Is there any sort of discount?",
        "It's a kind of magic.",
        "We need a different kind of approach.",
        "Those kind of meetings run long.",
    ]
    for text in kept {
        #expect(try await clean(text) == text)
        #expect(try await clean(text, structure: .paragraph) == text)
    }
}

@Test("Aggressive still removes \"kind of\" and \"sort of\" used as hedges")
func aggressiveRemovesHedges() async throws {
    #expect(try await clean("it's kind of unstable") == "it's unstable")
    #expect(try await clean("It's kind of unstable.") == "It's unstable.")
    #expect(try await clean("I sort of agree with you.") == "I agree with you.")
    #expect(try await clean("The build is kind of slow, sort of.") == "The build is slow.")
    #expect(try await clean("Kind of weird, right?") == "Weird, right?")
}

@Test("Minimal and Balanced keep \"kind of\" hedges")
func minimalAndBalancedKeepHedges() async throws {
    for policy in [FillerPolicy.minimal, .balanced] {
        #expect(try await clean("It's kind of unstable.", policy) == "It's kind of unstable.")
        #expect(try await clean("What kind of car is that?", policy) == "What kind of car is that?")
    }
}
