import Foundation

/// Content-free identity acknowledged by the retained local runtime.
///
/// Tokens are opaque within the app process. They identify the helper instance
/// and the canonical model/VAD configuration without exposing filesystem paths.
/// This type intentionally does not conform to `Codable`.
public struct LiveTranscriptionRuntimeIdentity: Sendable, Equatable, Hashable {
    public let protocolVersion: UInt16
    public let runtimeIdentifier: String
    public let modelIdentifier: String
    public let vadIdentifier: String?
    public let currentASRContextCount: UInt32
    public let peakASRContextCount: UInt32

    public init(
        protocolVersion: UInt16,
        runtimeIdentifier: String,
        modelIdentifier: String,
        vadIdentifier: String?,
        currentASRContextCount: UInt32,
        peakASRContextCount: UInt32
    ) {
        self.protocolVersion = protocolVersion
        self.runtimeIdentifier = runtimeIdentifier
        self.modelIdentifier = modelIdentifier
        self.vadIdentifier = vadIdentifier
        self.currentASRContextCount = currentASRContextCount
        self.peakASRContextCount = peakASRContextCount
    }

    static let pending = LiveTranscriptionRuntimeIdentity(
        protocolVersion: 0,
        runtimeIdentifier: "pending",
        modelIdentifier: "pending",
        vadIdentifier: nil,
        currentASRContextCount: 0,
        peakASRContextCount: 0
    )
}

/// Ephemeral identity for one live-transcription session.
///
/// This type intentionally does not conform to `Codable`. Live hypotheses and
/// their identity are process-local coordination data and must not enter
/// persistence by convenience.
public struct LiveTranscriptionSession: Sendable, Equatable, Hashable {
    public let sessionID: SessionID
    public let controllerGeneration: UUID
    public let runtimeGeneration: UInt64
    public let runtimeIdentity: LiveTranscriptionRuntimeIdentity

    public init(
        sessionID: SessionID,
        controllerGeneration: UUID,
        runtimeGeneration: UInt64,
        runtimeIdentity: LiveTranscriptionRuntimeIdentity
    ) {
        self.sessionID = sessionID
        self.controllerGeneration = controllerGeneration
        self.runtimeGeneration = runtimeGeneration
        self.runtimeIdentity = runtimeIdentity
    }
}

public enum LiveTranscriptionEventKind: Sendable, Equatable {
    case hypothesis
    case authoritativeFinal
    case cancelled
    case runtimeUnloaded
}

/// Content-free local speech evidence associated with a provisional decode.
public enum LiveTranscriptionSpeechEvidence: Sendable, Equatable {
    case speechDetected
    case noSpeechDetected
    case unknown
}

/// A full replacement hypothesis or an explicit lifecycle transition.
///
/// `fullHypothesisText` is never a delta. Consumers must not concatenate event
/// text. For terminal cancellation and unload events, producers should pass the
/// last full hypothesis or an empty string; the reducer discards it.
public struct LiveTranscriptionEvent: Sendable, Equatable {
    public let kind: LiveTranscriptionEventKind
    public let sessionID: SessionID
    public let controllerGeneration: UUID
    public let runtimeGeneration: UInt64
    public let runtimeIdentity: LiveTranscriptionRuntimeIdentity
    public let revision: UInt64
    public let decodedAudioWatermark: UInt64
    public let emittedAtMonotonicNanos: UInt64
    public let fullHypothesisText: String
    public let speechEvidence: LiveTranscriptionSpeechEvidence

    public var session: LiveTranscriptionSession {
        LiveTranscriptionSession(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            runtimeGeneration: runtimeGeneration,
            runtimeIdentity: runtimeIdentity
        )
    }

    public init(
        kind: LiveTranscriptionEventKind = .hypothesis,
        sessionID: SessionID,
        controllerGeneration: UUID,
        runtimeGeneration: UInt64,
        runtimeIdentity: LiveTranscriptionRuntimeIdentity,
        revision: UInt64,
        decodedAudioWatermark: UInt64,
        emittedAtMonotonicNanos: UInt64,
        fullHypothesisText: String,
        speechEvidence: LiveTranscriptionSpeechEvidence = .unknown
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.controllerGeneration = controllerGeneration
        self.runtimeGeneration = runtimeGeneration
        self.runtimeIdentity = runtimeIdentity
        self.revision = revision
        self.decodedAudioWatermark = decodedAudioWatermark
        self.emittedAtMonotonicNanos = emittedAtMonotonicNanos
        self.fullHypothesisText = fullHypothesisText
        self.speechEvidence = speechEvidence
    }

    public init(
        kind: LiveTranscriptionEventKind = .hypothesis,
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64,
        emittedAtMonotonicNanos: UInt64,
        fullHypothesisText: String,
        speechEvidence: LiveTranscriptionSpeechEvidence = .unknown
    ) {
        self.init(
            kind: kind,
            sessionID: session.sessionID,
            controllerGeneration: session.controllerGeneration,
            runtimeGeneration: session.runtimeGeneration,
            runtimeIdentity: session.runtimeIdentity,
            revision: revision,
            decodedAudioWatermark: decodedAudioWatermark,
            emittedAtMonotonicNanos: emittedAtMonotonicNanos,
            fullHypothesisText: fullHypothesisText,
            speechEvidence: speechEvidence
        )
    }
}

public enum LiveTranscriptionPhase: Sendable, Equatable {
    case active
    case finalized
    case cancelled
    case runtimeUnloaded

    public var isTerminal: Bool {
        self != .active
    }
}

/// Content-free lifecycle and stability telemetry.
public struct LiveTranscriptionCounters: Sendable, Equatable {
    public internal(set) var receivedEvents: UInt64
    public internal(set) var acceptedHypotheses: UInt64
    public internal(set) var rejectedEvents: UInt64
    public internal(set) var suppressedEmptyHypotheses: UInt64
    public internal(set) var suppressedNoSpeechHypotheses: UInt64
    public internal(set) var stablePrefixPromotions: UInt64
    public internal(set) var continuityWindowResets: UInt64
    public internal(set) var authoritativeFinalTransitions: UInt64
    public internal(set) var cancellationTransitions: UInt64
    public internal(set) var runtimeUnloadTransitions: UInt64

    public init(
        receivedEvents: UInt64 = 0,
        acceptedHypotheses: UInt64 = 0,
        rejectedEvents: UInt64 = 0,
        suppressedEmptyHypotheses: UInt64 = 0,
        suppressedNoSpeechHypotheses: UInt64 = 0,
        stablePrefixPromotions: UInt64 = 0,
        continuityWindowResets: UInt64 = 0,
        authoritativeFinalTransitions: UInt64 = 0,
        cancellationTransitions: UInt64 = 0,
        runtimeUnloadTransitions: UInt64 = 0
    ) {
        self.receivedEvents = receivedEvents
        self.acceptedHypotheses = acceptedHypotheses
        self.rejectedEvents = rejectedEvents
        self.suppressedEmptyHypotheses = suppressedEmptyHypotheses
        self.suppressedNoSpeechHypotheses = suppressedNoSpeechHypotheses
        self.stablePrefixPromotions = stablePrefixPromotions
        self.continuityWindowResets = continuityWindowResets
        self.authoritativeFinalTransitions = authoritativeFinalTransitions
        self.cancellationTransitions = cancellationTransitions
        self.runtimeUnloadTransitions = runtimeUnloadTransitions
    }
}

/// Immutable, full UI state after one reducer decision.
///
/// During `.active`, `stablePrefix + revisableTail` is always exactly one
/// accepted full hypothesis. A final result is stored separately so replacing
/// provisional state cannot be mistaken for another partial revision.
public struct LiveTranscriptionSnapshot: Sendable, Equatable {
    public let session: LiveTranscriptionSession
    public let phase: LiveTranscriptionPhase
    public let stablePrefix: String
    public let revisableTail: String
    public let authoritativeFinalText: String?
    public let lastAcceptedRevision: UInt64?
    public let decodedAudioWatermark: UInt64?
    public let emittedAtMonotonicNanos: UInt64?
    /// Increments when a bounded rolling decoder starts a new provisional
    /// display window without ending the live runtime session.
    public let continuityEpoch: UInt64
    public let counters: LiveTranscriptionCounters

    public var provisionalText: String {
        stablePrefix + revisableTail
    }

    public var displayText: String {
        authoritativeFinalText ?? provisionalText
    }

    public func boundedRevisableTail(
        maxGraphemeCount: Int,
        maxLineCount: Int = 3
    ) -> String {
        LiveTranscriptionTextBounds.latestCompleteTail(
            revisableTail,
            maxGraphemeCount: maxGraphemeCount,
            maxLineCount: maxLineCount
        )
    }

    public init(
        session: LiveTranscriptionSession,
        phase: LiveTranscriptionPhase = .active,
        stablePrefix: String = "",
        revisableTail: String = "",
        authoritativeFinalText: String? = nil,
        lastAcceptedRevision: UInt64? = nil,
        decodedAudioWatermark: UInt64? = nil,
        emittedAtMonotonicNanos: UInt64? = nil,
        continuityEpoch: UInt64 = 0,
        counters: LiveTranscriptionCounters = LiveTranscriptionCounters()
    ) {
        self.session = session
        self.phase = phase
        self.stablePrefix = stablePrefix
        self.revisableTail = revisableTail
        self.authoritativeFinalText = authoritativeFinalText
        self.lastAcceptedRevision = lastAcceptedRevision
        self.decodedAudioWatermark = decodedAudioWatermark
        self.emittedAtMonotonicNanos = emittedAtMonotonicNanos
        self.continuityEpoch = continuityEpoch
        self.counters = counters
    }
}

/// Grapheme-safe display bounding that keeps the newest complete words and
/// explicit lines. Visual wrapping remains the overlay's responsibility.
public enum LiveTranscriptionTextBounds {
    public static func latestCompleteTail(
        _ text: String,
        maxGraphemeCount: Int,
        maxLineCount: Int = 3
    ) -> String {
        guard maxGraphemeCount > 0, maxLineCount > 0, !text.isEmpty else {
            return ""
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var bounded = lines.count > maxLineCount
            ? lines.suffix(maxLineCount).joined(separator: "\n")
            : text

        guard bounded.count > maxGraphemeCount else {
            return bounded
        }

        let proposedStart = bounded.index(
            bounded.endIndex,
            offsetBy: -maxGraphemeCount
        )

        if proposedStart == bounded.startIndex {
            return bounded
        }

        let characterBefore = bounded[bounded.index(before: proposedStart)]
        if characterBefore.isWhitespace {
            bounded = String(bounded[proposedStart...])
            return droppingLeadingWhitespace(from: bounded)
        }

        var boundary = proposedStart
        while boundary < bounded.endIndex, !bounded[boundary].isWhitespace {
            boundary = bounded.index(after: boundary)
        }
        while boundary < bounded.endIndex, bounded[boundary].isWhitespace {
            boundary = bounded.index(after: boundary)
        }

        guard boundary < bounded.endIndex else {
            // A single overlong word cannot be represented without splitting it.
            return ""
        }
        return String(bounded[boundary...])
    }

    private static func droppingLeadingWhitespace(from text: String) -> String {
        guard let firstContent = text.firstIndex(where: { !$0.isWhitespace }) else {
            return ""
        }
        return String(text[firstContent...])
    }
}

public enum ProvisionalTranscriptRejectionReason: Sendable, Equatable {
    case wrongSession
    case wrongControllerGeneration
    case wrongRuntimeGeneration
    case wrongRuntimeIdentity
    case duplicateRevision
    case outOfOrderRevision
    case decodedAudioWatermarkRegression
    case monotonicTimestampRegression
    case stablePrefixConflict
    case sessionCancelled
    case sessionFinalized
    case runtimeUnloaded
}

public enum ProvisionalTranscriptReductionOutcome: Sendable, Equatable {
    case accepted
    case suppressedEmptyHypothesis
    case suppressedNoSpeechHypothesis
    case rejected(ProvisionalTranscriptRejectionReason)
}

public struct ProvisionalTranscriptReduction: Sendable, Equatable {
    public let outcome: ProvisionalTranscriptReductionOutcome
    public let snapshot: LiveTranscriptionSnapshot

    public init(
        outcome: ProvisionalTranscriptReductionOutcome,
        snapshot: LiveTranscriptionSnapshot
    ) {
        self.outcome = outcome
        self.snapshot = snapshot
    }
}
