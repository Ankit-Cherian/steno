import Foundation
import Testing
@testable import StenoKit

@Suite("Provisional transcript reducer")
struct ProvisionalTranscriptReducerTests {
    @Test("Stable prefix advances by overlap and time, then never mutates")
    func stablePrefixIsMonotonic() {
        let session = makeSession(1)
        var reducer = ProvisionalTranscriptReducer(
            session: session,
            stabilityPolicy: .init(
                minimumAgreementNanos: 100,
                revisableWordHoldback: 2
            )
        )

        let hypotheses = [
            "I think this",
            "I think this is",
            "I think this is the",
            "I think this is the safest answer",
        ]

        var previousStable = ""
        for (offset, hypothesis) in hypotheses.enumerated() {
            let result = reducer.reduce(
                event(
                    session: session,
                    revision: UInt64(offset),
                    watermark: UInt64(offset * 160),
                    nanos: UInt64(offset * 100),
                    text: hypothesis
                )
            )

            #expect(result.outcome == .accepted)
            #expect(result.snapshot.stablePrefix.hasPrefix(previousStable))
            #expect(result.snapshot.provisionalText == hypothesis)
            previousStable = result.snapshot.stablePrefix
        }

        #expect(!previousStable.isEmpty)

        let conflict = reducer.reduce(
            event(
                session: session,
                revision: 10,
                watermark: 2_000,
                nanos: 1_000,
                text: "I thought another answer was safer"
            )
        )
        #expect(conflict.outcome == .rejected(.stablePrefixConflict))
        #expect(conflict.snapshot.stablePrefix == previousStable)
        #expect(conflict.snapshot.provisionalText == hypotheses.last)
    }

    @Test("Each accepted hypothesis is a full snapshot independent of a 4 Hz renderer")
    func fullSnapshotsAreNotCadenceThrottled() {
        let session = makeSession(2)
        var reducer = ProvisionalTranscriptReducer(
            session: session,
            stabilityPolicy: .init(minimumAgreementNanos: .max)
        )

        for revision in 0..<40 {
            let text = "full hypothesis revision \(revision)"
            let result = reducer.reduce(
                event(
                    session: session,
                    revision: UInt64(revision),
                    watermark: UInt64(revision * 400),
                    nanos: UInt64(revision * 25_000_000),
                    text: text
                )
            )
            #expect(result.outcome == .accepted)
            #expect(result.snapshot.provisionalText == text)
            #expect(result.snapshot.lastAcceptedRevision == UInt64(revision))
        }

        #expect(reducer.snapshot.counters.acceptedHypotheses == 40)
    }

    @Test("Whitespace hypotheses are suppressed and still advance ordering")
    func silenceAndEmptyHypothesesAreSuppressed() {
        let session = makeSession(3)
        var reducer = ProvisionalTranscriptReducer(session: session)

        for (revision, text) in ["", "   ", "\n\t"].enumerated() {
            let result = reducer.reduce(
                event(
                    session: session,
                    revision: UInt64(revision),
                    watermark: UInt64(revision),
                    nanos: UInt64(revision),
                    text: text
                )
            )
            #expect(result.outcome == .suppressedEmptyHypothesis)
            #expect(result.snapshot.displayText.isEmpty)
        }

        let hallucinationDuringSilence = reducer.reduce(
            event(
                session: session,
                revision: 3,
                watermark: 3,
                nanos: 3,
                text: "Thank you for watching.",
                speechEvidence: .noSpeechDetected
            )
        )
        #expect(hallucinationDuringSilence.outcome == .suppressedNoSpeechHypothesis)
        #expect(hallucinationDuringSilence.snapshot.displayText.isEmpty)

        let unprovedSpeech = reducer.reduce(
            LiveTranscriptionEvent(
                session: session,
                revision: 4,
                decodedAudioWatermark: 4,
                emittedAtMonotonicNanos: 4,
                fullHypothesisText: "Unverified hypothesis."
            )
        )
        #expect(unprovedSpeech.outcome == .suppressedNoSpeechHypothesis)
        #expect(unprovedSpeech.snapshot.displayText.isEmpty)

        let duplicate = reducer.reduce(
            event(session: session, revision: 4, watermark: 5, nanos: 5, text: "hallucination")
        )
        #expect(duplicate.outcome == .rejected(.duplicateRevision))
        #expect(reducer.snapshot.counters.suppressedEmptyHypotheses == 3)
        #expect(reducer.snapshot.counters.suppressedNoSpeechHypotheses == 2)
    }

    @Test("Wrong identity, duplicate, out-of-order, and regressed clocks fail closed")
    func staleAndMalformedOrderingIsRejected() {
        let session = makeSession(4)
        var reducer = ProvisionalTranscriptReducer(session: session)
        _ = reducer.reduce(
            event(session: session, revision: 10, watermark: 100, nanos: 100, text: "one two three")
        )
        let baselineText = reducer.snapshot.provisionalText

        var wrongSession = event(
            session: makeSession(5),
            revision: 11,
            watermark: 101,
            nanos: 101,
            text: "wrong session"
        )
        #expect(reducer.reduce(wrongSession).outcome == .rejected(.wrongSession))

        wrongSession = LiveTranscriptionEvent(
            sessionID: session.sessionID,
            controllerGeneration: testUUID(999),
            runtimeGeneration: session.runtimeGeneration,
            runtimeIdentity: session.runtimeIdentity,
            revision: 11,
            decodedAudioWatermark: 101,
            emittedAtMonotonicNanos: 101,
            fullHypothesisText: "wrong controller"
        )
        #expect(reducer.reduce(wrongSession).outcome == .rejected(.wrongControllerGeneration))

        wrongSession = LiveTranscriptionEvent(
            sessionID: session.sessionID,
            controllerGeneration: session.controllerGeneration,
            runtimeGeneration: session.runtimeGeneration + 1,
            runtimeIdentity: session.runtimeIdentity,
            revision: 11,
            decodedAudioWatermark: 101,
            emittedAtMonotonicNanos: 101,
            fullHypothesisText: "wrong runtime"
        )
        #expect(reducer.reduce(wrongSession).outcome == .rejected(.wrongRuntimeGeneration))

        wrongSession = LiveTranscriptionEvent(
            sessionID: session.sessionID,
            controllerGeneration: session.controllerGeneration,
            runtimeGeneration: session.runtimeGeneration,
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 2,
                runtimeIdentifier: "wrong-runtime",
                modelIdentifier: session.runtimeIdentity.modelIdentifier,
                vadIdentifier: session.runtimeIdentity.vadIdentifier,
                currentASRContextCount: session.runtimeIdentity.currentASRContextCount,
                peakASRContextCount: session.runtimeIdentity.peakASRContextCount
            ),
            revision: 11,
            decodedAudioWatermark: 101,
            emittedAtMonotonicNanos: 101,
            fullHypothesisText: "wrong runtime identity"
        )
        #expect(reducer.reduce(wrongSession).outcome == .rejected(.wrongRuntimeIdentity))

        #expect(
            reducer.reduce(
                event(session: session, revision: 10, watermark: 101, nanos: 101, text: "duplicate")
            ).outcome == .rejected(.duplicateRevision)
        )
        #expect(
            reducer.reduce(
                event(session: session, revision: 9, watermark: 101, nanos: 101, text: "old")
            ).outcome == .rejected(.outOfOrderRevision)
        )
        #expect(
            reducer.reduce(
                event(session: session, revision: 11, watermark: 99, nanos: 101, text: "watermark")
            ).outcome == .rejected(.decodedAudioWatermarkRegression)
        )
        #expect(
            reducer.reduce(
                event(session: session, revision: 11, watermark: 101, nanos: 99, text: "clock")
            ).outcome == .rejected(.monotonicTimestampRegression)
        )
        #expect(reducer.snapshot.provisionalText == baselineText)
    }

    @Test("Authoritative final explicitly replaces provisional state")
    func authoritativeFinalReplacesProvisionalState() {
        let session = makeSession(6)
        var reducer = ProvisionalTranscriptReducer(session: session)
        _ = reducer.reduce(
            event(session: session, revision: 0, watermark: 100, nanos: 100, text: "provisional words")
        )

        let final = reducer.reduce(
            event(
                kind: .authoritativeFinal,
                session: session,
                revision: 1,
                watermark: 200,
                nanos: 200,
                text: "Authoritative final text."
            )
        )

        #expect(final.outcome == .accepted)
        #expect(final.snapshot.phase == .finalized)
        #expect(final.snapshot.stablePrefix.isEmpty)
        #expect(final.snapshot.revisableTail.isEmpty)
        #expect(final.snapshot.authoritativeFinalText == "Authoritative final text.")
        #expect(final.snapshot.displayText == "Authoritative final text.")

        let late = reducer.reduce(
            event(session: session, revision: 2, watermark: 300, nanos: 300, text: "late partial")
        )
        #expect(late.outcome == .rejected(.sessionFinalized))
        #expect(late.snapshot.displayText == "Authoritative final text.")
    }

    @Test("Cancelled and unloaded sessions reject every later event")
    func terminalSessionsRejectLateEvents() {
        let terminalCases: [(LiveTranscriptionEventKind, ProvisionalTranscriptRejectionReason)] = [
            (.cancelled, .sessionCancelled),
            (.runtimeUnloaded, .runtimeUnloaded),
        ]

        for (offset, terminalCase) in terminalCases.enumerated() {
            let session = makeSession(10 + UInt64(offset))
            var reducer = ProvisionalTranscriptReducer(session: session)
            _ = reducer.reduce(
                event(session: session, revision: 0, watermark: 0, nanos: 0, text: "ephemeral")
            )
            let terminal = reducer.reduce(
                event(
                    kind: terminalCase.0,
                    session: session,
                    revision: 1,
                    watermark: 1,
                    nanos: 1,
                    text: "ephemeral"
                )
            )
            #expect(terminal.outcome == .accepted)
            #expect(terminal.snapshot.displayText.isEmpty)

            let late = reducer.reduce(
                event(session: session, revision: 2, watermark: 2, nanos: 2, text: "late")
            )
            #expect(late.outcome == .rejected(terminalCase.1))
            #expect(late.snapshot.displayText.isEmpty)
        }
    }

    @Test("Tail bounding is Unicode grapheme-safe, word-safe, and three-line ready")
    func boundedTailPreservesGraphemesAndWords() {
        let text = "discarded line\ncafé stays whole\nfamily 👨‍👩‍👧‍👦 stays whole\ne\u{301}lan finishes here"
        let bounded = LiveTranscriptionTextBounds.latestCompleteTail(
            text,
            maxGraphemeCount: 48,
            maxLineCount: 3
        )

        #expect(bounded.split(separator: "\n", omittingEmptySubsequences: false).count <= 3)
        #expect(bounded.count <= 48)
        #expect(!bounded.contains("discarded line"))
        #expect(bounded.contains("👨‍👩‍👧‍👦"))
        #expect(bounded.contains("e\u{301}lan"))

        let wordBounded = LiveTranscriptionTextBounds.latestCompleteTail(
            "prefix 👨‍👩‍👧‍👦 complete ending",
            maxGraphemeCount: 15,
            maxLineCount: 3
        )
        #expect(wordBounded == "complete ending")

        let unsplittable = LiveTranscriptionTextBounds.latestCompleteTail(
            "👨‍👩‍👧‍👦supercalifragilistic",
            maxGraphemeCount: 5,
            maxLineCount: 3
        )
        #expect(unsplittable.isEmpty)
    }

    @Test("One thousand deterministic randomized lifecycles preserve reducer invariants")
    func randomizedLifecycleSessions() {
        var random = DeterministicRandom(seed: 0x5EED_CAFE_F00D_BAAD)
        let vocabulary = [
            "alpha", "bravo", "café", "delta", "emoji👩🏽‍💻", "foxtrot",
            "golf", "hotel", "india", "juliet", "kilo", "lima",
        ]

        for sessionIndex in 0..<1_000 {
            let session = makeSession(1_000 + UInt64(sessionIndex))
            var reducer = ProvisionalTranscriptReducer(
                session: session,
                stabilityPolicy: .init(
                    minimumAgreementNanos: UInt64(50 + random.next(200)),
                    revisableWordHoldback: 1 + random.next(3)
                )
            )
            var words: [String] = []
            var previousStable = ""
            let eventCount = 3 + random.next(10)

            for revision in 0..<eventCount {
                words.append(vocabulary[random.next(vocabulary.count)])
                let hypothesis = words.joined(separator: " ")
                let nanos = UInt64(revision * 100)
                let result = reducer.reduce(
                    event(
                        session: session,
                        revision: UInt64(revision),
                        watermark: UInt64(revision * 160),
                        nanos: nanos,
                        text: hypothesis
                    )
                )

                #expect(result.outcome == .accepted)
                #expect(result.snapshot.stablePrefix.hasPrefix(previousStable))
                #expect(result.snapshot.provisionalText == hypothesis)
                previousStable = result.snapshot.stablePrefix
            }

            let terminalRevision = UInt64(eventCount)
            let terminalKind: LiveTranscriptionEventKind = switch random.next(3) {
            case 0: .authoritativeFinal
            case 1: .cancelled
            default: .runtimeUnloaded
            }
            let terminal = reducer.reduce(
                event(
                    kind: terminalKind,
                    session: session,
                    revision: terminalRevision,
                    watermark: terminalRevision * 160,
                    nanos: terminalRevision * 100,
                    text: terminalKind == .authoritativeFinal ? "Canonical final." : ""
                )
            )
            #expect(terminal.outcome == .accepted)
            #expect(terminal.snapshot.phase.isTerminal)

            let late = reducer.reduce(
                event(
                    session: session,
                    revision: terminalRevision + 1,
                    watermark: (terminalRevision + 1) * 160,
                    nanos: (terminalRevision + 1) * 100,
                    text: "must be rejected"
                )
            )
            if case .rejected = late.outcome {
                // Expected terminal rejection.
            } else {
                Issue.record("Session \(sessionIndex) accepted a post-terminal event")
            }
        }
    }

    @Test("Two hundred fifty cancel/restart races isolate generations")
    func cancelRestartIsolation() {
        for iteration in 0..<250 {
            let oldSession = makeSession(10_000 + UInt64(iteration * 2))
            let newSession = makeSession(10_001 + UInt64(iteration * 2))
            var oldReducer = ProvisionalTranscriptReducer(session: oldSession)
            var newReducer = ProvisionalTranscriptReducer(session: newSession)

            _ = oldReducer.reduce(
                event(session: oldSession, revision: 0, watermark: 0, nanos: 0, text: "old words")
            )
            _ = oldReducer.reduce(
                event(
                    kind: .cancelled,
                    session: oldSession,
                    revision: 1,
                    watermark: 1,
                    nanos: 1,
                    text: "old words"
                )
            )

            let lateOld = newReducer.reduce(
                event(session: oldSession, revision: 2, watermark: 2, nanos: 2, text: "late old")
            )
            #expect(lateOld.outcome == .rejected(.wrongSession))
            #expect(newReducer.snapshot.displayText.isEmpty)

            let current = newReducer.reduce(
                event(session: newSession, revision: 0, watermark: 0, nanos: 0, text: "new words")
            )
            #expect(current.outcome == .accepted)
            #expect(current.snapshot.provisionalText == "new words")

            let oldAfterCancel = oldReducer.reduce(
                event(session: oldSession, revision: 2, watermark: 2, nanos: 2, text: "late old")
            )
            #expect(oldAfterCancel.outcome == .rejected(.sessionCancelled))
        }
    }
}

private func event(
    kind: LiveTranscriptionEventKind = .hypothesis,
    session: LiveTranscriptionSession,
    revision: UInt64,
    watermark: UInt64,
    nanos: UInt64,
    text: String,
    speechEvidence: LiveTranscriptionSpeechEvidence = .speechDetected
) -> LiveTranscriptionEvent {
    LiveTranscriptionEvent(
        kind: kind,
        session: session,
        revision: revision,
        decodedAudioWatermark: watermark,
        emittedAtMonotonicNanos: nanos,
        fullHypothesisText: text,
        speechEvidence: speechEvidence
    )
}

private func makeSession(_ value: UInt64) -> LiveTranscriptionSession {
    LiveTranscriptionSession(
        sessionID: testUUID(value * 3),
        controllerGeneration: testUUID(value * 3 + 1),
        runtimeGeneration: value * 3 + 2,
        runtimeIdentity: LiveTranscriptionRuntimeIdentity(
            protocolVersion: 2,
            runtimeIdentifier: "runtime-\(value)",
            modelIdentifier: "model-test",
            vadIdentifier: nil,
            currentASRContextCount: 1,
            peakASRContextCount: 1
        )
    )
}

private func testUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", value))!
}

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(upperBound))
    }
}
