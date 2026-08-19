import Foundation

public struct ProvisionalTranscriptStabilityPolicy: Sendable, Equatable {
    public let minimumAgreementNanos: UInt64
    public let revisableWordHoldback: Int

    public init(
        minimumAgreementNanos: UInt64 = 500_000_000,
        revisableWordHoldback: Int = 2
    ) {
        self.minimumAgreementNanos = minimumAgreementNanos
        self.revisableWordHoldback = max(1, revisableWordHoldback)
    }
}

/// A deterministic, value-semantic reducer for ephemeral live hypotheses.
///
/// The reducer has no clock, task, actor, persistence, or UI dependencies. Its
/// decisions depend exclusively on the supplied events and policy.
public struct ProvisionalTranscriptReducer: Sendable {
    public let session: LiveTranscriptionSession
    public let stabilityPolicy: ProvisionalTranscriptStabilityPolicy
    public private(set) var snapshot: LiveTranscriptionSnapshot

    private var latestNonemptyHypothesis: String?
    private var latestNonemptyHypothesisTime: UInt64?
    private var agreementCandidate: String?
    private var agreementCandidateSince: UInt64?

    public init(
        session: LiveTranscriptionSession,
        stabilityPolicy: ProvisionalTranscriptStabilityPolicy = .init()
    ) {
        self.session = session
        self.stabilityPolicy = stabilityPolicy
        self.snapshot = LiveTranscriptionSnapshot(session: session)
    }

    @discardableResult
    public mutating func reduce(_ event: LiveTranscriptionEvent) -> ProvisionalTranscriptReduction {
        increment(\LiveTranscriptionCounters.receivedEvents)

        if let identityRejection = identityRejection(for: event) {
            return reject(identityRejection)
        }
        if let terminalRejection = terminalRejection() {
            return reject(terminalRejection)
        }
        if let orderingRejection = orderingRejection(for: event) {
            return reject(orderingRejection)
        }

        switch event.kind {
        case .hypothesis:
            return acceptHypothesis(event)
        case .authoritativeFinal:
            return acceptAuthoritativeFinal(event)
        case .cancelled:
            return acceptTerminal(event, phase: .cancelled)
        case .runtimeUnloaded:
            return acceptTerminal(event, phase: .runtimeUnloaded)
        }
    }

    private mutating func acceptHypothesis(
        _ event: LiveTranscriptionEvent
    ) -> ProvisionalTranscriptReduction {
        guard event.speechEvidence == .speechDetected else {
            recordAcceptedOrdering(from: event)
            increment(\LiveTranscriptionCounters.suppressedNoSpeechHypotheses)
            return ProvisionalTranscriptReduction(
                outcome: .suppressedNoSpeechHypothesis,
                snapshot: snapshot
            )
        }

        guard event.fullHypothesisText.contains(where: { !$0.isWhitespace }) else {
            recordAcceptedOrdering(from: event)
            increment(\LiveTranscriptionCounters.suppressedEmptyHypotheses)
            return ProvisionalTranscriptReduction(
                outcome: .suppressedEmptyHypothesis,
                snapshot: snapshot
            )
        }

        let text = event.fullHypothesisText
        guard snapshot.stablePrefix.isEmpty || text.hasPrefix(snapshot.stablePrefix) else {
            return reject(.stablePrefixConflict)
        }

        var stablePrefix = snapshot.stablePrefix
        if let previous = latestNonemptyHypothesis,
           let previousTime = latestNonemptyHypothesisTime {
            let overlap = Self.longestCommonPrefix(previous, text)
            let promotable = Self.holdingBackTrailingWords(
                overlap,
                count: stabilityPolicy.revisableWordHoldback
            )
            stablePrefix = advanceStablePrefixIfEligible(
                current: stablePrefix,
                promotable: promotable,
                previousEventTime: previousTime,
                currentEventTime: event.emittedAtMonotonicNanos
            )
        } else {
            agreementCandidate = nil
            agreementCandidateSince = nil
        }

        latestNonemptyHypothesis = text
        latestNonemptyHypothesisTime = event.emittedAtMonotonicNanos
        increment(\LiveTranscriptionCounters.acceptedHypotheses)

        let tailStart = text.index(text.startIndex, offsetBy: stablePrefix.count)
        replaceSnapshot(
            phase: .active,
            stablePrefix: stablePrefix,
            revisableTail: String(text[tailStart...]),
            authoritativeFinalText: nil,
            event: event
        )

        return ProvisionalTranscriptReduction(outcome: .accepted, snapshot: snapshot)
    }

    private mutating func acceptAuthoritativeFinal(
        _ event: LiveTranscriptionEvent
    ) -> ProvisionalTranscriptReduction {
        increment(\LiveTranscriptionCounters.authoritativeFinalTransitions)
        clearProvisionalWorkingState()
        replaceSnapshot(
            phase: .finalized,
            stablePrefix: "",
            revisableTail: "",
            authoritativeFinalText: event.fullHypothesisText,
            event: event
        )
        return ProvisionalTranscriptReduction(outcome: .accepted, snapshot: snapshot)
    }

    private mutating func acceptTerminal(
        _ event: LiveTranscriptionEvent,
        phase: LiveTranscriptionPhase
    ) -> ProvisionalTranscriptReduction {
        switch phase {
        case .cancelled:
            increment(\LiveTranscriptionCounters.cancellationTransitions)
        case .runtimeUnloaded:
            increment(\LiveTranscriptionCounters.runtimeUnloadTransitions)
        case .active, .finalized:
            break
        }

        clearProvisionalWorkingState()
        replaceSnapshot(
            phase: phase,
            stablePrefix: "",
            revisableTail: "",
            authoritativeFinalText: nil,
            event: event
        )
        return ProvisionalTranscriptReduction(outcome: .accepted, snapshot: snapshot)
    }

    private mutating func advanceStablePrefixIfEligible(
        current: String,
        promotable: String,
        previousEventTime: UInt64,
        currentEventTime: UInt64
    ) -> String {
        guard promotable.count > current.count, promotable.hasPrefix(current) else {
            agreementCandidate = nil
            agreementCandidateSince = nil
            return current
        }

        if let existing = agreementCandidate,
           let existingSince = agreementCandidateSince {
            let sharedCandidate = Self.longestCommonPrefix(existing, promotable)
            if sharedCandidate.count > current.count, sharedCandidate.hasPrefix(current) {
                agreementCandidate = sharedCandidate
                agreementCandidateSince = existingSince
            } else {
                agreementCandidate = promotable
                agreementCandidateSince = previousEventTime
            }
        } else {
            agreementCandidate = promotable
            agreementCandidateSince = previousEventTime
        }

        guard let candidate = agreementCandidate,
              let candidateSince = agreementCandidateSince,
              currentEventTime >= candidateSince,
              currentEventTime - candidateSince >= stabilityPolicy.minimumAgreementNanos else {
            return current
        }

        agreementCandidate = nil
        agreementCandidateSince = nil
        increment(\LiveTranscriptionCounters.stablePrefixPromotions)
        return candidate
    }

    private func identityRejection(
        for event: LiveTranscriptionEvent
    ) -> ProvisionalTranscriptRejectionReason? {
        guard event.sessionID == session.sessionID else {
            return .wrongSession
        }
        guard event.controllerGeneration == session.controllerGeneration else {
            return .wrongControllerGeneration
        }
        guard event.runtimeGeneration == session.runtimeGeneration else {
            return .wrongRuntimeGeneration
        }
        guard event.runtimeIdentity == session.runtimeIdentity else {
            return .wrongRuntimeIdentity
        }
        return nil
    }

    private func terminalRejection() -> ProvisionalTranscriptRejectionReason? {
        switch snapshot.phase {
        case .active:
            return nil
        case .cancelled:
            return .sessionCancelled
        case .finalized:
            return .sessionFinalized
        case .runtimeUnloaded:
            return .runtimeUnloaded
        }
    }

    private func orderingRejection(
        for event: LiveTranscriptionEvent
    ) -> ProvisionalTranscriptRejectionReason? {
        if let lastRevision = snapshot.lastAcceptedRevision {
            if event.revision == lastRevision {
                return .duplicateRevision
            }
            if event.revision < lastRevision {
                return .outOfOrderRevision
            }
        }

        if let watermark = snapshot.decodedAudioWatermark,
           event.decodedAudioWatermark < watermark {
            return .decodedAudioWatermarkRegression
        }

        if let emittedAt = snapshot.emittedAtMonotonicNanos,
           event.emittedAtMonotonicNanos < emittedAt {
            return .monotonicTimestampRegression
        }
        return nil
    }

    private mutating func reject(
        _ reason: ProvisionalTranscriptRejectionReason
    ) -> ProvisionalTranscriptReduction {
        increment(\LiveTranscriptionCounters.rejectedEvents)
        return ProvisionalTranscriptReduction(
            outcome: .rejected(reason),
            snapshot: snapshot
        )
    }

    private mutating func recordAcceptedOrdering(from event: LiveTranscriptionEvent) {
        replaceSnapshot(
            phase: snapshot.phase,
            stablePrefix: snapshot.stablePrefix,
            revisableTail: snapshot.revisableTail,
            authoritativeFinalText: snapshot.authoritativeFinalText,
            event: event
        )
    }

    private mutating func replaceSnapshot(
        phase: LiveTranscriptionPhase,
        stablePrefix: String,
        revisableTail: String,
        authoritativeFinalText: String?,
        event: LiveTranscriptionEvent
    ) {
        snapshot = LiveTranscriptionSnapshot(
            session: session,
            phase: phase,
            stablePrefix: stablePrefix,
            revisableTail: revisableTail,
            authoritativeFinalText: authoritativeFinalText,
            lastAcceptedRevision: event.revision,
            decodedAudioWatermark: event.decodedAudioWatermark,
            emittedAtMonotonicNanos: event.emittedAtMonotonicNanos,
            counters: snapshot.counters
        )
    }

    private mutating func clearProvisionalWorkingState() {
        latestNonemptyHypothesis = nil
        latestNonemptyHypothesisTime = nil
        agreementCandidate = nil
        agreementCandidateSince = nil
    }

    private mutating func increment(
        _ keyPath: WritableKeyPath<LiveTranscriptionCounters, UInt64>
    ) {
        var counters = snapshot.counters
        counters[keyPath: keyPath] += 1
        snapshot = LiveTranscriptionSnapshot(
            session: snapshot.session,
            phase: snapshot.phase,
            stablePrefix: snapshot.stablePrefix,
            revisableTail: snapshot.revisableTail,
            authoritativeFinalText: snapshot.authoritativeFinalText,
            lastAcceptedRevision: snapshot.lastAcceptedRevision,
            decodedAudioWatermark: snapshot.decodedAudioWatermark,
            emittedAtMonotonicNanos: snapshot.emittedAtMonotonicNanos,
            counters: counters
        )
    }

    private static func longestCommonPrefix(_ lhs: String, _ rhs: String) -> String {
        var left = lhs.startIndex
        var right = rhs.startIndex

        while left < lhs.endIndex, right < rhs.endIndex, lhs[left] == rhs[right] {
            left = lhs.index(after: left)
            right = rhs.index(after: right)
        }
        return String(lhs[..<left])
    }

    /// Returns a prefix ending after a complete whitespace-delimited token,
    /// excluding the requested number of newest tokens. Holding back at least
    /// one token prevents a common prefix that ends inside a still-changing word
    /// from being marked stable.
    private static func holdingBackTrailingWords(
        _ text: String,
        count holdback: Int
    ) -> String {
        var tokenEnds: [String.Index] = []
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else {
                break
            }
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            tokenEnds.append(index)
        }

        let retainedTokenCount = tokenEnds.count - holdback
        guard retainedTokenCount > 0 else {
            return ""
        }

        var end = tokenEnds[retainedTokenCount - 1]
        while end < text.endIndex, text[end].isWhitespace {
            end = text.index(after: end)
        }
        return String(text[..<end])
    }
}
