import CryptoKit
import Foundation

public enum ContinuationCorpusDirectiveKind: String, Sendable, Codable, Equatable {
    case none
    case lowercase
    case literalEscape
}

public enum ContinuationCorpusCaseDecision: String, Sendable, Codable, Equatable {
    case notConsidered
    case preservedSentenceStart
    case preservedUnsafeOpening
    case lowercasedOrdinaryOpening
}

public enum ContinuationCorpusBoundaryStyle: String, Sendable, Codable, Equatable {
    case usesInterwordSpacing
    case doesNotUseInterwordSpacing
    case unknown
}

public enum ContinuationCorpusContextAvailability: String, Sendable, Codable, Equatable {
    case unavailable
    case drifted
    case validated
}

public struct ContinuationCorpusContext: Sendable, Codable, Equatable {
    public var availability: ContinuationCorpusContextAvailability
    public var leadingText: String
    public var trailingText: String
    public var boundaryStyle: ContinuationCorpusBoundaryStyle
    public var allowsAutomaticContinuation: Bool
    public var protectedTerms: [String]

    public init(
        availability: ContinuationCorpusContextAvailability = .unavailable,
        leadingText: String = "",
        trailingText: String = "",
        boundaryStyle: ContinuationCorpusBoundaryStyle = .unknown,
        allowsAutomaticContinuation: Bool = false,
        protectedTerms: [String] = []
    ) {
        self.availability = availability
        self.leadingText = leadingText
        self.trailingText = trailingText
        self.boundaryStyle = boundaryStyle
        self.allowsAutomaticContinuation = allowsAutomaticContinuation
        self.protectedTerms = protectedTerms
    }
}

public struct ContinuationDirectiveCorpus: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = "steno-continuation-corpus/v1"

    public struct Row: Sendable, Codable, Equatable {
        public var id: String
        public var input: String
        public var expectedOutput: String
        public var category: String
        public var cleanedText: String
        public var context: ContinuationCorpusContext
        public var expectedDirectiveKind: ContinuationCorpusDirectiveKind
        public var expectedTextForCleanup: String
        public var expectedDirectiveAppliedText: String
        public var expectedCaseDecision: ContinuationCorpusCaseDecision
        public var expectedInsertedLeadingSpace: Bool
        public var expectedInsertedTrailingSpace: Bool

        public init(
            id: String,
            input: String,
            expectedOutput: String,
            category: String,
            cleanedText: String? = nil,
            context: ContinuationCorpusContext = ContinuationCorpusContext(),
            expectedDirectiveKind: ContinuationCorpusDirectiveKind = .none,
            expectedTextForCleanup: String? = nil,
            expectedDirectiveAppliedText: String? = nil,
            expectedCaseDecision: ContinuationCorpusCaseDecision = .notConsidered,
            expectedInsertedLeadingSpace: Bool = false,
            expectedInsertedTrailingSpace: Bool = false
        ) {
            self.id = id
            self.input = input
            self.expectedOutput = expectedOutput
            self.category = category
            self.cleanedText = cleanedText ?? input
            self.context = context
            self.expectedDirectiveKind = expectedDirectiveKind
            self.expectedTextForCleanup = expectedTextForCleanup ?? input
            self.expectedDirectiveAppliedText = expectedDirectiveAppliedText ?? expectedOutput
            self.expectedCaseDecision = expectedCaseDecision
            self.expectedInsertedLeadingSpace = expectedInsertedLeadingSpace
            self.expectedInsertedTrailingSpace = expectedInsertedTrailingSpace
        }
    }

    public var schemaVersion: String
    public var rows: [Row]

    public init(schemaVersion: String = currentSchemaVersion, rows: [Row]) {
        self.schemaVersion = schemaVersion
        self.rows = rows
    }

    public func sha256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return LiveContextHash.sha256(try encoder.encode(self))
    }
}

public extension ContinuationDirectiveCorpus {
    static var frozenAcceptanceCorpus: Self {
        let midSentence = ContinuationCorpusContext(
            availability: .validated,
            leadingText: "hello",
            trailingText: "",
            boundaryStyle: .usesInterwordSpacing,
            allowsAutomaticContinuation: true
        )
        return Self(rows: [
            .init(id: "directive-basic", input: "lowercase This works", expectedOutput: "this works", category: "directive", cleanedText: "This works", expectedDirectiveKind: .lowercase, expectedTextForCleanup: "This works", expectedDirectiveAppliedText: "this works"),
            .init(id: "directive-case-insensitive", input: "LOWERCASE This works", expectedOutput: "this works", category: "directive", cleanedText: "This works", expectedDirectiveKind: .lowercase, expectedTextForCleanup: "This works", expectedDirectiveAppliedText: "this works"),
            .init(id: "literal-escape", input: "literal lowercase This", expectedOutput: "lowercase This", category: "literal-escape", cleanedText: "lowercase This", expectedDirectiveKind: .literalEscape, expectedTextForCleanup: "lowercase This", expectedDirectiveAppliedText: "lowercase This"),
            .init(id: "lowercase-alone", input: "lowercase", expectedOutput: "lowercase", category: "reserved-boundary", expectedDirectiveAppliedText: "lowercase"),
            .init(id: "the-word-lowercase", input: "the word lowercase", expectedOutput: "the word lowercase", category: "literal-preservation", expectedDirectiveAppliedText: "the word lowercase"),
            .init(id: "use-lowercase", input: "use lowercase", expectedOutput: "use lowercase", category: "literal-preservation", expectedDirectiveAppliedText: "use lowercase"),
            .init(id: "embedded-lowercase", input: "Please lowercase This", expectedOutput: "Please lowercase This", category: "reserved-boundary", expectedDirectiveAppliedText: "Please lowercase This"),
            .init(id: "quoted-lowercase", input: "\"lowercase This\"", expectedOutput: "\"lowercase This\"", category: "quoted-code", expectedDirectiveAppliedText: "\"lowercase This\""),
            .init(id: "mid-sentence-continuation", input: "This works", expectedOutput: " this works", category: "continuation", cleanedText: "This works", context: midSentence, expectedTextForCleanup: "This works", expectedDirectiveAppliedText: "This works", expectedCaseDecision: .lowercasedOrdinaryOpening, expectedInsertedLeadingSpace: true),
            .init(id: "sentence-boundary", input: "This works", expectedOutput: " This works", category: "continuation", cleanedText: "This works", context: .init(availability: .validated, leadingText: "Done.", boundaryStyle: .usesInterwordSpacing, allowsAutomaticContinuation: true), expectedTextForCleanup: "This works", expectedDirectiveAppliedText: "This works", expectedCaseDecision: .preservedSentenceStart, expectedInsertedLeadingSpace: true),
            .init(id: "context-unavailable", input: "This works", expectedOutput: "This works", category: "fail-closed-context", context: .init(availability: .unavailable), expectedDirectiveAppliedText: "This works"),
            .init(id: "context-drifted", input: "This works", expectedOutput: "This works", category: "fail-closed-context", context: .init(availability: .drifted), expectedDirectiveAppliedText: "This works"),
            .init(id: "protected-opening", input: "Apple ships", expectedOutput: " Apple ships", category: "protected-term", cleanedText: "Apple ships", context: .init(availability: .validated, leadingText: "today", boundaryStyle: .usesInterwordSpacing, allowsAutomaticContinuation: true, protectedTerms: ["Apple"]), expectedTextForCleanup: "Apple ships", expectedDirectiveAppliedText: "Apple ships", expectedCaseDecision: .preservedUnsafeOpening, expectedInsertedLeadingSpace: true),
            .init(id: "boundary-spacing", input: "This works", expectedOutput: "this works ", category: "spacing", cleanedText: "This works", context: .init(availability: .validated, leadingText: "hello ", trailingText: "world", boundaryStyle: .usesInterwordSpacing, allowsAutomaticContinuation: true), expectedTextForCleanup: "This works", expectedDirectiveAppliedText: "This works", expectedCaseDecision: .lowercasedOrdinaryOpening, expectedInsertedTrailingSpace: true),
        ])
    }
}

public enum CaseSensitiveRowStatus: String, Sendable, Codable, Equatable {
    case passed
    case failed
    case skipped
}

public struct CaseSensitiveBenchmarkRow: Sendable, Codable, Equatable {
    public var id: String
    public var category: String
    public var expectedSHA256: String
    public var actualSHA256: String?
    public var status: CaseSensitiveRowStatus
    public var reasonCode: String?
    public var continuationDecisionCorrect: Bool
    public var unintendedLowercaseCount: Int
    public var directiveDecisionCorrect: Bool
    public var literalLowercasePreserved: Bool
    public var boundarySpacingCorrect: Bool

    public init(
        id: String,
        category: String,
        expectedSHA256: String,
        actualSHA256: String?,
        status: CaseSensitiveRowStatus,
        reasonCode: String? = nil,
        continuationDecisionCorrect: Bool,
        unintendedLowercaseCount: Int,
        directiveDecisionCorrect: Bool,
        literalLowercasePreserved: Bool,
        boundarySpacingCorrect: Bool
    ) {
        self.id = id
        self.category = category
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.status = status
        self.reasonCode = reasonCode
        self.continuationDecisionCorrect = continuationDecisionCorrect
        self.unintendedLowercaseCount = unintendedLowercaseCount
        self.directiveDecisionCorrect = directiveDecisionCorrect
        self.literalLowercasePreserved = literalLowercasePreserved
        self.boundarySpacingCorrect = boundarySpacingCorrect
    }
}

public enum CaseSensitiveBenchmark {
    public static func row(
        corpusRow: ContinuationDirectiveCorpus.Row,
        actualOutput: String?,
        continuationDecisionCorrect: Bool,
        unintendedLowercaseCount: Int,
        directiveDecisionCorrect: Bool,
        literalLowercasePreserved: Bool,
        boundarySpacingCorrect: Bool,
        skippedReason: String? = nil
    ) -> CaseSensitiveBenchmarkRow {
        let expectedHash = LiveContextHash.sha256(Data(corpusRow.expectedOutput.utf8))
        let actualHash = actualOutput.map { LiveContextHash.sha256(Data($0.utf8)) }
        let exactMatch = actualOutput == corpusRow.expectedOutput
        let status: CaseSensitiveRowStatus
        let reasonCode: String?
        if let skippedReason {
            status = .skipped
            reasonCode = skippedReason
        } else if exactMatch,
                  continuationDecisionCorrect,
                  unintendedLowercaseCount == 0,
                  directiveDecisionCorrect,
                  literalLowercasePreserved,
                  boundarySpacingCorrect {
            status = .passed
            reasonCode = nil
        } else {
            status = .failed
            reasonCode = "case-sensitive-contract-mismatch"
        }
        return CaseSensitiveBenchmarkRow(
            id: corpusRow.id,
            category: corpusRow.category,
            expectedSHA256: expectedHash,
            actualSHA256: actualHash,
            status: status,
            reasonCode: reasonCode,
            continuationDecisionCorrect: continuationDecisionCorrect,
            unintendedLowercaseCount: unintendedLowercaseCount,
            directiveDecisionCorrect: directiveDecisionCorrect,
            literalLowercasePreserved: literalLowercasePreserved,
            boundarySpacingCorrect: boundarySpacingCorrect
        )
    }
}

public struct LiveLatencyDistribution: Sendable, Codable, Equatable {
    public var samplesMS: [Double]
    public var count: Int
    public var p50MS: Double?
    public var p95MS: Double?
    public var p99MS: Double?

    public init(samplesMS: [Double], count: Int, p50MS: Double?, p95MS: Double?, p99MS: Double?) {
        self.samplesMS = samplesMS
        self.count = count
        self.p50MS = p50MS
        self.p95MS = p95MS
        self.p99MS = p99MS
    }

    public static func summarize(_ samplesMS: [Double]) -> Self {
        Self(
            samplesMS: samplesMS,
            count: samplesMS.count,
            p50MS: percentile(samplesMS, 0.50),
            p95MS: percentile(samplesMS, 0.95),
            p99MS: percentile(samplesMS, 0.99)
        )
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int(ceil(percentile * Double(sorted.count))) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

public struct LiveContextBenchmarkIdentity: Sendable, Codable, Equatable {
    public enum ModelPathPolicy: String, Sendable, Codable, Equatable {
        case repositoryRelative
        case approvedExternalRedacted
    }

    public var gitSHA: String
    public var treeIsDirty: Bool
    public var manifestSHA256: String
    public var corpusSHA256: String
    public var modelSHA256: String
    public var audioFixtureSHA256: String
    public var modelIdentity: String
    public var modelPathPolicy: ModelPathPolicy
    public var vadModelSHA256: String?
    public var threadCount: Int
    public var language: String
    public var realtimePacing: Bool
    public var runtimeSHA256: String
    public var runtimeIdentity: String
    public var liveProtocolVersion: UInt16
    public var liveRuntimeIdentifier: String
    public var liveModelIdentifier: String
    public var liveVADIdentifier: String?
    public var hostedReceiptSHA256: String
    public var adversarialReceiptSHA256: String
    public var hostedSourceManifestSHA256: String
    public var helperSourceSHA256: String
    public var adversarialHarnessSHA256: String
    public var hardware: String
    public var operatingSystem: String
    public var powerState: String

    public init(
        gitSHA: String,
        treeIsDirty: Bool,
        manifestSHA256: String,
        corpusSHA256: String,
        modelSHA256: String,
        audioFixtureSHA256: String,
        modelIdentity: String,
        modelPathPolicy: ModelPathPolicy,
        vadModelSHA256: String? = nil,
        threadCount: Int,
        language: String,
        realtimePacing: Bool,
        runtimeSHA256: String,
        runtimeIdentity: String,
        liveProtocolVersion: UInt16,
        liveRuntimeIdentifier: String,
        liveModelIdentifier: String,
        liveVADIdentifier: String? = nil,
        hostedReceiptSHA256: String,
        adversarialReceiptSHA256: String,
        hostedSourceManifestSHA256: String,
        helperSourceSHA256: String,
        adversarialHarnessSHA256: String,
        hardware: String,
        operatingSystem: String,
        powerState: String
    ) {
        self.gitSHA = gitSHA
        self.treeIsDirty = treeIsDirty
        self.manifestSHA256 = manifestSHA256
        self.corpusSHA256 = corpusSHA256
        self.modelSHA256 = modelSHA256
        self.audioFixtureSHA256 = audioFixtureSHA256
        self.modelIdentity = modelIdentity
        self.modelPathPolicy = modelPathPolicy
        self.vadModelSHA256 = vadModelSHA256
        self.threadCount = threadCount
        self.language = language
        self.realtimePacing = realtimePacing
        self.runtimeSHA256 = runtimeSHA256
        self.runtimeIdentity = runtimeIdentity
        self.liveProtocolVersion = liveProtocolVersion
        self.liveRuntimeIdentifier = liveRuntimeIdentifier
        self.liveModelIdentifier = liveModelIdentifier
        self.liveVADIdentifier = liveVADIdentifier
        self.hostedReceiptSHA256 = hostedReceiptSHA256
        self.adversarialReceiptSHA256 = adversarialReceiptSHA256
        self.hostedSourceManifestSHA256 = hostedSourceManifestSHA256
        self.helperSourceSHA256 = helperSourceSHA256
        self.adversarialHarnessSHA256 = adversarialHarnessSHA256
        self.hardware = hardware
        self.operatingSystem = operatingSystem
        self.powerState = powerState
    }
}

public struct LiveContextBenchmarkThresholds: Sendable, Codable, Equatable {
    public var listeningAcknowledgementP95MS: Double
    public var firstPartialP50MS: Double
    public var firstPartialP95MS: Double
    public var firstPartialP99MS: Double
    public var subsequentPartialGapP95MS: Double
    public var visibleUpdatesPerSecond: Double
    public var overlayMainActorP99MS: Double
    public var stopToInsertionP95MS: Double
    public var maximumStopToInsertionRegressionRatio: Double
    public var maximumIdleCPUPercent: Double
    public var minimumIdleSampleSeconds: Double
    public var maximumPeakGrowthBytes: Int64
    public var maximumTailSlopeBytesPerRequest: Double

    public init(
        listeningAcknowledgementP95MS: Double = 100,
        firstPartialP50MS: Double = 500,
        firstPartialP95MS: Double = 900,
        firstPartialP99MS: Double = 1_500,
        subsequentPartialGapP95MS: Double = 350,
        visibleUpdatesPerSecond: Double = 4,
        overlayMainActorP99MS: Double = 8,
        stopToInsertionP95MS: Double = 700,
        maximumStopToInsertionRegressionRatio: Double = 0.10,
        maximumIdleCPUPercent: Double = 0.1,
        minimumIdleSampleSeconds: Double = 60,
        maximumPeakGrowthBytes: Int64 = 128 * 1024 * 1024,
        maximumTailSlopeBytesPerRequest: Double = 32 * 1024
    ) {
        self.listeningAcknowledgementP95MS = listeningAcknowledgementP95MS
        self.firstPartialP50MS = firstPartialP50MS
        self.firstPartialP95MS = firstPartialP95MS
        self.firstPartialP99MS = firstPartialP99MS
        self.subsequentPartialGapP95MS = subsequentPartialGapP95MS
        self.visibleUpdatesPerSecond = visibleUpdatesPerSecond
        self.overlayMainActorP99MS = overlayMainActorP99MS
        self.stopToInsertionP95MS = stopToInsertionP95MS
        self.maximumStopToInsertionRegressionRatio = maximumStopToInsertionRegressionRatio
        self.maximumIdleCPUPercent = maximumIdleCPUPercent
        self.minimumIdleSampleSeconds = minimumIdleSampleSeconds
        self.maximumPeakGrowthBytes = maximumPeakGrowthBytes
        self.maximumTailSlopeBytesPerRequest = maximumTailSlopeBytesPerRequest
    }

    public static let required = Self()
}

public enum LiveContextTrialMode: String, Sendable, Codable, Equatable {
    case enabled
    case disabled
}

public struct LiveContextLatencyEvidence: Sendable, Codable, Equatable {
    public var listeningAcknowledgement: LiveLatencyDistribution
    public var helperStreamSetup: LiveLatencyDistribution
    public var firstPartial: LiveLatencyDistribution
    public var subsequentPartialGap: LiveLatencyDistribution
    public var overlayMainActorWork: LiveLatencyDistribution
    public var finishToAuthoritativeFinalEnabled: LiveLatencyDistribution
    public var finishToAuthoritativeFinalDisabledControl: LiveLatencyDistribution
    public var stopToInsertionEnabled: LiveLatencyDistribution
    public var stopToInsertionDisabledControl: LiveLatencyDistribution
    public var maximumVisibleUpdatesPerSecond: Double
    public var alternatingTrialCount: Int
    public var trialOrder: [LiveContextTrialMode]
    public var sameConfigurationAcrossTrials: Bool
    public var coreDiagnosticDefinition: String?
    public var coreDiagnosticReadinessDefinition: String?
    public var coreDiagnosticConfigurationSHA256: String?
    public var acceptedSubsequentGapCountByEnabledTrial: [Int]

    public init(
        listeningAcknowledgement: LiveLatencyDistribution,
        helperStreamSetup: LiveLatencyDistribution,
        firstPartial: LiveLatencyDistribution,
        subsequentPartialGap: LiveLatencyDistribution,
        overlayMainActorWork: LiveLatencyDistribution,
        finishToAuthoritativeFinalEnabled: LiveLatencyDistribution,
        finishToAuthoritativeFinalDisabledControl: LiveLatencyDistribution,
        stopToInsertionEnabled: LiveLatencyDistribution,
        stopToInsertionDisabledControl: LiveLatencyDistribution,
        maximumVisibleUpdatesPerSecond: Double,
        alternatingTrialCount: Int,
        trialOrder: [LiveContextTrialMode],
        sameConfigurationAcrossTrials: Bool,
        coreDiagnosticDefinition: String? = nil,
        coreDiagnosticReadinessDefinition: String? = nil,
        coreDiagnosticConfigurationSHA256: String? = nil,
        acceptedSubsequentGapCountByEnabledTrial: [Int] = []
    ) {
        self.listeningAcknowledgement = listeningAcknowledgement
        self.helperStreamSetup = helperStreamSetup
        self.firstPartial = firstPartial
        self.subsequentPartialGap = subsequentPartialGap
        self.overlayMainActorWork = overlayMainActorWork
        self.finishToAuthoritativeFinalEnabled = finishToAuthoritativeFinalEnabled
        self.finishToAuthoritativeFinalDisabledControl = finishToAuthoritativeFinalDisabledControl
        self.stopToInsertionEnabled = stopToInsertionEnabled
        self.stopToInsertionDisabledControl = stopToInsertionDisabledControl
        self.maximumVisibleUpdatesPerSecond = maximumVisibleUpdatesPerSecond
        self.alternatingTrialCount = alternatingTrialCount
        self.trialOrder = trialOrder
        self.sameConfigurationAcrossTrials = sameConfigurationAcrossTrials
        self.coreDiagnosticDefinition = coreDiagnosticDefinition
        self.coreDiagnosticReadinessDefinition = coreDiagnosticReadinessDefinition
        self.coreDiagnosticConfigurationSHA256 = coreDiagnosticConfigurationSHA256
        self.acceptedSubsequentGapCountByEnabledTrial = acceptedSubsequentGapCountByEnabledTrial
    }
}

public struct LiveContextNativeShippingEvidence: Sendable, Codable, Equatable {
    public static let requiredScope = "native-macaudiocapture-listening-through-real-target-insertion"
    public static let listeningDefinition = "physical-press-entry-to-native-capture-listening-acknowledgement"
    public static let stopDefinition = "native-capture-stop-entry-to-real-target-insertion-commit"

    public var scope: String
    public var listeningDefinition: String
    public var stopToInsertionDefinition: String
    public var listeningAcknowledgement: LiveLatencyDistribution
    public var stopToInsertionEnabled: LiveLatencyDistribution
    public var stopToInsertionDisabledControl: LiveLatencyDistribution
    public var trialOrder: [LiveContextTrialMode]
    public var configurationIdentitySHA256: String

    public init(scope: String, listeningDefinition: String, stopToInsertionDefinition: String, listeningAcknowledgement: LiveLatencyDistribution, stopToInsertionEnabled: LiveLatencyDistribution, stopToInsertionDisabledControl: LiveLatencyDistribution, trialOrder: [LiveContextTrialMode], configurationIdentitySHA256: String) {
        self.scope = scope
        self.listeningDefinition = listeningDefinition
        self.stopToInsertionDefinition = stopToInsertionDefinition
        self.listeningAcknowledgement = listeningAcknowledgement
        self.stopToInsertionEnabled = stopToInsertionEnabled
        self.stopToInsertionDisabledControl = stopToInsertionDisabledControl
        self.trialOrder = trialOrder
        self.configurationIdentitySHA256 = configurationIdentitySHA256
    }
}

public struct LiveContextPCMIdentity: Sendable, Codable, Equatable {
    public var sampleCount: UInt64
    public var byteCount: UInt64
    public var frameCount: UInt64
    public var fnv1a64: String

    public init(sampleCount: UInt64, byteCount: UInt64, frameCount: UInt64, fnv1a64: String) {
        self.sampleCount = sampleCount
        self.byteCount = byteCount
        self.frameCount = frameCount
        self.fnv1a64 = fnv1a64
    }
}

public struct LiveContextCoreDiagnosticEvidence: Sendable, Codable, Equatable {
    public var trialOrder: [LiveContextTrialMode]
    public var authoritativeFinalOwnershipCount: Int
    public var insertionCommitCount: Int
    public var historyAppendCount: Int
    public var successfulEnabledReadinessCount: Int
    public var liveFinishAuthoritativeFinalCount: Int
    public var disabledTranscribeAuthoritativeFinalCount: Int
    public var coordinatorFallbackCount: Int
    public var runtimeIdentityCount: Int
    public var publicFixtureSHA256: String
    public var configurationSHA256: String
    public var enabledCanonicalSummaries: [LiveContextPCMIdentity]

    public init(trialOrder: [LiveContextTrialMode], authoritativeFinalOwnershipCount: Int, insertionCommitCount: Int, historyAppendCount: Int, successfulEnabledReadinessCount: Int, liveFinishAuthoritativeFinalCount: Int, disabledTranscribeAuthoritativeFinalCount: Int, coordinatorFallbackCount: Int, runtimeIdentityCount: Int, publicFixtureSHA256: String, configurationSHA256: String, enabledCanonicalSummaries: [LiveContextPCMIdentity]) {
        self.trialOrder = trialOrder
        self.authoritativeFinalOwnershipCount = authoritativeFinalOwnershipCount
        self.insertionCommitCount = insertionCommitCount
        self.historyAppendCount = historyAppendCount
        self.successfulEnabledReadinessCount = successfulEnabledReadinessCount
        self.liveFinishAuthoritativeFinalCount = liveFinishAuthoritativeFinalCount
        self.disabledTranscribeAuthoritativeFinalCount = disabledTranscribeAuthoritativeFinalCount
        self.coordinatorFallbackCount = coordinatorFallbackCount
        self.runtimeIdentityCount = runtimeIdentityCount
        self.publicFixtureSHA256 = publicFixtureSHA256
        self.configurationSHA256 = configurationSHA256
        self.enabledCanonicalSummaries = enabledCanonicalSummaries
    }
}

public struct LiveContextCaptureTrialEvidence: Sendable, Codable, Equatable {
    public var trialIndex: Int
    public var expectedSampleCount: Int
    public var streamedSampleCount: Int
    public var canonicalSampleCount: Int
    public var expectedFNV1A64: String
    public var streamedFNV1A64: String
    public var canonicalFNV1A64: String

    public init(trialIndex: Int, expectedSampleCount: Int, streamedSampleCount: Int, canonicalSampleCount: Int, expectedFNV1A64: String, streamedFNV1A64: String, canonicalFNV1A64: String) {
        self.trialIndex = trialIndex
        self.expectedSampleCount = expectedSampleCount
        self.streamedSampleCount = streamedSampleCount
        self.canonicalSampleCount = canonicalSampleCount
        self.expectedFNV1A64 = expectedFNV1A64
        self.streamedFNV1A64 = streamedFNV1A64
        self.canonicalFNV1A64 = canonicalFNV1A64
    }
}

public struct LiveContextCorrectnessEvidence: Sendable, Codable, Equatable {
    public var stablePrefixMutations: Int
    public var provisionalSideEffects: Int
    public var duplicateFinalInsertions: Int
    public var staleEventsAccepted: Int
    public var stablePrefixConflicts: Int
    public var stablePrefixFinalConflicts: Int
    public var provisionalSessionCount: Int
    public var noSpeechFalseDisplays: Int
    public var latePartialsAfterCancellation: Int
    public var revisionCount: Int
    public var finalizationCount: Int

    public init(stablePrefixMutations: Int, provisionalSideEffects: Int, duplicateFinalInsertions: Int, staleEventsAccepted: Int, stablePrefixConflicts: Int, stablePrefixFinalConflicts: Int, provisionalSessionCount: Int, noSpeechFalseDisplays: Int, latePartialsAfterCancellation: Int, revisionCount: Int, finalizationCount: Int) {
        self.stablePrefixMutations = stablePrefixMutations
        self.provisionalSideEffects = provisionalSideEffects
        self.duplicateFinalInsertions = duplicateFinalInsertions
        self.staleEventsAccepted = staleEventsAccepted
        self.stablePrefixConflicts = stablePrefixConflicts
        self.stablePrefixFinalConflicts = stablePrefixFinalConflicts
        self.provisionalSessionCount = provisionalSessionCount
        self.noSpeechFalseDisplays = noSpeechFalseDisplays
        self.latePartialsAfterCancellation = latePartialsAfterCancellation
        self.revisionCount = revisionCount
        self.finalizationCount = finalizationCount
    }
}

public struct LiveContextCaptureEvidence: Sendable, Codable, Equatable {
    public var expectedAudioSampleCount: Int
    public var streamedSampleCount: Int
    public var canonicalSampleCount: Int
    public var streamedPCMHash: String
    public var canonicalPCMHash: String
    public var frameSequenceOrOffsetDiscontinuities: Int
    public var expectedFNV1A64: String
    public var streamedFNV1A64: String
    public var canonicalFNV1A64: String
    public var audioFixtureSHA256: String
    public var trials: [LiveContextCaptureTrialEvidence]

    public init(expectedAudioSampleCount: Int, streamedSampleCount: Int, canonicalSampleCount: Int, streamedPCMHash: String, canonicalPCMHash: String, frameSequenceOrOffsetDiscontinuities: Int, expectedFNV1A64: String = "", streamedFNV1A64: String = "", canonicalFNV1A64: String = "", audioFixtureSHA256: String = "", trials: [LiveContextCaptureTrialEvidence] = []) {
        self.expectedAudioSampleCount = expectedAudioSampleCount
        self.streamedSampleCount = streamedSampleCount
        self.canonicalSampleCount = canonicalSampleCount
        self.streamedPCMHash = streamedPCMHash
        self.canonicalPCMHash = canonicalPCMHash
        self.frameSequenceOrOffsetDiscontinuities = frameSequenceOrOffsetDiscontinuities
        self.expectedFNV1A64 = expectedFNV1A64
        self.streamedFNV1A64 = streamedFNV1A64
        self.canonicalFNV1A64 = canonicalFNV1A64
        self.audioFixtureSHA256 = audioFixtureSHA256
        self.trials = trials
    }
}

public struct LiveContextResourceEvidence: Sendable, Codable, Equatable {
    public var soakSessionCount: Int
    public var peakRSSBytes: UInt64?
    public var rssCeilingBytes: UInt64
    public var peakGrowthBytes: Int64?
    public var tailSlopeBytesPerRequest: Double?
    public var monotonicGrowthObserved: Bool?
    public var sawtoothGrowthObserved: Bool?
    public var idleCPUPercent: Double?
    public var idleSampleSeconds: Double
    public var activeCPUPercentSamples: [Double]
    public var maximumQueueDepth: Int
    public var coalescedPreviewCount: Int
    public var helperReloadCount: Int
    public var helperFallbackCount: Int
    public var maximumConcurrentHelperProcessCount: Int?
    public var thermalState: String?
    public var requestedSoakSessionCount: Int
    public var completedSoakSessionCount: Int
    public var observedIdleSampleSeconds: Double
    public var idleObservationCompleted: Bool
    public var continuousHelperMonitorPerformed: Bool
    public var helperProcessObservationCount: Int
    public var maximumResidentModelCount: Int?
    public var modelInitializationSourceSHA256: String
    public var modelInitializationSiteCount: Int

    public init(soakSessionCount: Int, peakRSSBytes: UInt64?, rssCeilingBytes: UInt64, peakGrowthBytes: Int64?, tailSlopeBytesPerRequest: Double?, monotonicGrowthObserved: Bool?, sawtoothGrowthObserved: Bool?, idleCPUPercent: Double?, idleSampleSeconds: Double, activeCPUPercentSamples: [Double], maximumQueueDepth: Int, coalescedPreviewCount: Int, helperReloadCount: Int, helperFallbackCount: Int, maximumConcurrentHelperProcessCount: Int?, thermalState: String?, requestedSoakSessionCount: Int? = nil, completedSoakSessionCount: Int? = nil, observedIdleSampleSeconds: Double? = nil, idleObservationCompleted: Bool = true, continuousHelperMonitorPerformed: Bool = false, helperProcessObservationCount: Int = 0, maximumResidentModelCount: Int? = nil, modelInitializationSourceSHA256: String = "", modelInitializationSiteCount: Int = 0) {
        self.soakSessionCount = soakSessionCount
        self.peakRSSBytes = peakRSSBytes
        self.rssCeilingBytes = rssCeilingBytes
        self.peakGrowthBytes = peakGrowthBytes
        self.tailSlopeBytesPerRequest = tailSlopeBytesPerRequest
        self.monotonicGrowthObserved = monotonicGrowthObserved
        self.sawtoothGrowthObserved = sawtoothGrowthObserved
        self.idleCPUPercent = idleCPUPercent
        self.idleSampleSeconds = idleSampleSeconds
        self.activeCPUPercentSamples = activeCPUPercentSamples
        self.maximumQueueDepth = maximumQueueDepth
        self.coalescedPreviewCount = coalescedPreviewCount
        self.helperReloadCount = helperReloadCount
        self.helperFallbackCount = helperFallbackCount
        self.maximumConcurrentHelperProcessCount = maximumConcurrentHelperProcessCount
        self.thermalState = thermalState
        self.requestedSoakSessionCount = requestedSoakSessionCount ?? soakSessionCount
        self.completedSoakSessionCount = completedSoakSessionCount ?? soakSessionCount
        self.observedIdleSampleSeconds = observedIdleSampleSeconds ?? idleSampleSeconds
        self.idleObservationCompleted = idleObservationCompleted
        self.continuousHelperMonitorPerformed = continuousHelperMonitorPerformed
        self.helperProcessObservationCount = helperProcessObservationCount
        self.maximumResidentModelCount = maximumResidentModelCount
        self.modelInitializationSourceSHA256 = modelInitializationSourceSHA256
        self.modelInitializationSiteCount = modelInitializationSiteCount
    }
}

public struct LiveContextPrivacyEvidence: Sendable, Codable, Equatable {
    public var staticNetworkTransportMatches: Int?
    public var listeningSocketsObserved: Int?
    public var runtimeNetworkConnectionsObserved: Int?
    public var canaryProbeCount: Int
    public var requestLeaks: Int
    public var cleanupLeaks: Int
    public var historyLeaks: Int
    public var insertionLeaks: Int
    public var clipboardRecoveryLeaks: Int
    public var analyticsLeaks: Int
    public var configuredSnippetTrapCount: Int
    public var snippetTrapActivations: Int
    public var liveCallbackUnexpectedContextLeaks: Int
    public var overlayRetainedTextLeaks: Int
    public var artifactLeaks: Int
    public var argumentVectorLeaks: Int
    public var staticAuditBoundSourceManifestSHA256: String
    public var featureLogInvocationSourceFindings: Int
    public var crashMetadataSinkReferenceSourceFindings: Int
    public var ephemeralPersistenceSourceFindings: Int
    public var ephemeralFilenameDiagnosticSourceFindings: Int
    public var prohibitedNetworkAPISourceFindings: Int
    public var secureFieldContextReadRequests: Int
    public var maximumAXUTF16ReadPerSide: Int
    public var maximumAXGraphemesPerSide: Int
    public var maximumAXContextBytes: Int

    public init(staticNetworkTransportMatches: Int?, listeningSocketsObserved: Int?, runtimeNetworkConnectionsObserved: Int?, canaryProbeCount: Int, requestLeaks: Int, cleanupLeaks: Int, historyLeaks: Int, insertionLeaks: Int, clipboardRecoveryLeaks: Int, analyticsLeaks: Int, configuredSnippetTrapCount: Int, snippetTrapActivations: Int, liveCallbackUnexpectedContextLeaks: Int, overlayRetainedTextLeaks: Int, artifactLeaks: Int, argumentVectorLeaks: Int, staticAuditBoundSourceManifestSHA256: String, featureLogInvocationSourceFindings: Int, crashMetadataSinkReferenceSourceFindings: Int, ephemeralPersistenceSourceFindings: Int, ephemeralFilenameDiagnosticSourceFindings: Int, prohibitedNetworkAPISourceFindings: Int, secureFieldContextReadRequests: Int, maximumAXUTF16ReadPerSide: Int, maximumAXGraphemesPerSide: Int, maximumAXContextBytes: Int) {
        self.staticNetworkTransportMatches = staticNetworkTransportMatches
        self.listeningSocketsObserved = listeningSocketsObserved
        self.runtimeNetworkConnectionsObserved = runtimeNetworkConnectionsObserved
        self.canaryProbeCount = canaryProbeCount
        self.requestLeaks = requestLeaks
        self.cleanupLeaks = cleanupLeaks
        self.historyLeaks = historyLeaks
        self.insertionLeaks = insertionLeaks
        self.clipboardRecoveryLeaks = clipboardRecoveryLeaks
        self.analyticsLeaks = analyticsLeaks
        self.configuredSnippetTrapCount = configuredSnippetTrapCount
        self.snippetTrapActivations = snippetTrapActivations
        self.liveCallbackUnexpectedContextLeaks = liveCallbackUnexpectedContextLeaks
        self.overlayRetainedTextLeaks = overlayRetainedTextLeaks
        self.artifactLeaks = artifactLeaks
        self.argumentVectorLeaks = argumentVectorLeaks
        self.staticAuditBoundSourceManifestSHA256 = staticAuditBoundSourceManifestSHA256
        self.featureLogInvocationSourceFindings = featureLogInvocationSourceFindings
        self.crashMetadataSinkReferenceSourceFindings = crashMetadataSinkReferenceSourceFindings
        self.ephemeralPersistenceSourceFindings = ephemeralPersistenceSourceFindings
        self.ephemeralFilenameDiagnosticSourceFindings = ephemeralFilenameDiagnosticSourceFindings
        self.prohibitedNetworkAPISourceFindings = prohibitedNetworkAPISourceFindings
        self.secureFieldContextReadRequests = secureFieldContextReadRequests
        self.maximumAXUTF16ReadPerSide = maximumAXUTF16ReadPerSide
        self.maximumAXGraphemesPerSide = maximumAXGraphemesPerSide
        self.maximumAXContextBytes = maximumAXContextBytes
    }
}

public enum LiveContextSentinelScanner {
    /// Counts exact UTF-8 sentinel occurrences without retaining the inspected payloads.
    public static func leakCount(sentinel: String, surfaces: [Data]) -> Int {
        let needle = Array(sentinel.utf8)
        guard !needle.isEmpty else { return surfaces.isEmpty ? 0 : .max }
        return surfaces.reduce(into: 0) { total, data in
            let bytes = Array(data)
            guard bytes.count >= needle.count else { return }
            for offset in 0...(bytes.count - needle.count) {
                if bytes[offset..<(offset + needle.count)].elementsEqual(needle) {
                    total += 1
                }
            }
        }
    }

    public static func argumentVectorLeakCount(sentinel: String, arguments: [String]) -> Int {
        leakCount(sentinel: sentinel, surfaces: arguments.map { Data($0.utf8) })
    }
}

public struct LiveContextLifecycleEvidence: Sendable, Codable, Equatable {
    public var randomizedSessions: Int
    public var rapidCancelRestartCases: Int
    public var targetTransitions: Int
    public var helperCrashScenariosPassed: Int
    public var helperCrashScenariosExpected: Int
    public var malformedProtocolScenariosPassed: Int
    public var malformedProtocolScenariosExpected: Int
    public var authoritativeFinishCalls: Int
    public var maximumAuthoritativeFinishCallsPerSession: Int
    public var coordinatorSecondFinalInferenceAttempts: Int
    public var finalInsertionCount: Int
    public var expectedFinalInsertionCount: Int

    public init(randomizedSessions: Int, rapidCancelRestartCases: Int, targetTransitions: Int, helperCrashScenariosPassed: Int, helperCrashScenariosExpected: Int, malformedProtocolScenariosPassed: Int, malformedProtocolScenariosExpected: Int, authoritativeFinishCalls: Int, maximumAuthoritativeFinishCallsPerSession: Int, coordinatorSecondFinalInferenceAttempts: Int, finalInsertionCount: Int, expectedFinalInsertionCount: Int) {
        self.randomizedSessions = randomizedSessions
        self.rapidCancelRestartCases = rapidCancelRestartCases
        self.targetTransitions = targetTransitions
        self.helperCrashScenariosPassed = helperCrashScenariosPassed
        self.helperCrashScenariosExpected = helperCrashScenariosExpected
        self.malformedProtocolScenariosPassed = malformedProtocolScenariosPassed
        self.malformedProtocolScenariosExpected = malformedProtocolScenariosExpected
        self.authoritativeFinishCalls = authoritativeFinishCalls
        self.maximumAuthoritativeFinishCallsPerSession = maximumAuthoritativeFinishCallsPerSession
        self.coordinatorSecondFinalInferenceAttempts = coordinatorSecondFinalInferenceAttempts
        self.finalInsertionCount = finalInsertionCount
        self.expectedFinalInsertionCount = expectedFinalInsertionCount
    }
}

public struct LiveContextFailureRow: Sendable, Codable, Equatable {
    public var id: String
    public var reasonCode: String

    public init(id: String, reasonCode: String) {
        self.id = id
        self.reasonCode = reasonCode
    }
}

public struct LiveContextBenchmarkArtifact: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = "steno-live-context-benchmark/v5"

    public var schemaVersion: String
    public var generatedAt: Date
    public var identity: LiveContextBenchmarkIdentity
    public var thresholds: LiveContextBenchmarkThresholds
    public var expectedCorpusRowCount: Int
    public var observedCorpusRowCount: Int
    public var declaredFailureCount: Int
    public var declaredSkipCount: Int
    public var failures: [LiveContextFailureRow]
    public var skips: [LiveContextFailureRow]
    public var caseSensitiveRows: [CaseSensitiveBenchmarkRow]
    public var latency: LiveContextLatencyEvidence
    public var correctness: LiveContextCorrectnessEvidence
    public var capture: LiveContextCaptureEvidence
    public var resources: LiveContextResourceEvidence
    public var privacy: LiveContextPrivacyEvidence
    public var lifecycle: LiveContextLifecycleEvidence
    public var coreDiagnostics: LiveContextCoreDiagnosticEvidence?
    public var nativeShippingEvidence: LiveContextNativeShippingEvidence?

    public init(schemaVersion: String = currentSchemaVersion, generatedAt: Date, identity: LiveContextBenchmarkIdentity, thresholds: LiveContextBenchmarkThresholds, expectedCorpusRowCount: Int, observedCorpusRowCount: Int, declaredFailureCount: Int, declaredSkipCount: Int, failures: [LiveContextFailureRow], skips: [LiveContextFailureRow], caseSensitiveRows: [CaseSensitiveBenchmarkRow], latency: LiveContextLatencyEvidence, correctness: LiveContextCorrectnessEvidence, capture: LiveContextCaptureEvidence, resources: LiveContextResourceEvidence, privacy: LiveContextPrivacyEvidence, lifecycle: LiveContextLifecycleEvidence, coreDiagnostics: LiveContextCoreDiagnosticEvidence? = nil, nativeShippingEvidence: LiveContextNativeShippingEvidence? = nil) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.identity = identity
        self.thresholds = thresholds
        self.expectedCorpusRowCount = expectedCorpusRowCount
        self.observedCorpusRowCount = observedCorpusRowCount
        self.declaredFailureCount = declaredFailureCount
        self.declaredSkipCount = declaredSkipCount
        self.failures = failures
        self.skips = skips
        self.caseSensitiveRows = caseSensitiveRows
        self.latency = latency
        self.correctness = correctness
        self.capture = capture
        self.resources = resources
        self.privacy = privacy
        self.lifecycle = lifecycle
        self.coreDiagnostics = coreDiagnostics
        self.nativeShippingEvidence = nativeShippingEvidence
    }
}

public struct LiveContextValidationResult: Sendable, Equatable {
    public var failures: [String]
    public var accepted: Bool { failures.isEmpty }

    public init(failures: [String]) {
        self.failures = failures
    }
}

public struct LiveContextExpectedIdentity: Sendable, Equatable {
    public var gitSHA: String
    public var manifestSHA256: String
    public var modelSHA256: String
    public var runtimeSHA256: String
    public var expectedCorpusRowCount: Int
    public var vadModelSHA256: String?
    public var threadCount: Int
    public var hostedReceiptSHA256: String
    public var adversarialReceiptSHA256: String
    public var audioFixtureSHA256: String
    public var hostedSourceManifestSHA256: String
    public var helperSourceSHA256: String
    public var adversarialHarnessSHA256: String
    public var language: String

    public init(gitSHA: String, manifestSHA256: String, modelSHA256: String, runtimeSHA256: String, expectedCorpusRowCount: Int, vadModelSHA256: String? = nil, threadCount: Int, hostedReceiptSHA256: String, adversarialReceiptSHA256: String, audioFixtureSHA256: String, hostedSourceManifestSHA256: String, helperSourceSHA256: String, adversarialHarnessSHA256: String, language: String) {
        self.gitSHA = gitSHA
        self.manifestSHA256 = manifestSHA256
        self.modelSHA256 = modelSHA256
        self.runtimeSHA256 = runtimeSHA256
        self.expectedCorpusRowCount = expectedCorpusRowCount
        self.vadModelSHA256 = vadModelSHA256
        self.threadCount = threadCount
        self.hostedReceiptSHA256 = hostedReceiptSHA256
        self.adversarialReceiptSHA256 = adversarialReceiptSHA256
        self.audioFixtureSHA256 = audioFixtureSHA256
        self.hostedSourceManifestSHA256 = hostedSourceManifestSHA256
        self.helperSourceSHA256 = helperSourceSHA256
        self.adversarialHarnessSHA256 = adversarialHarnessSHA256
        self.language = language
    }
}

/// Aggregate-only evidence produced by a hosted macOS controller/overlay harness.
/// Text, editor context, audio paths, prompts, and argument vectors are forbidden.
public struct LiveContextHostedReceipt: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = "steno-live-context-hosted-receipt/v5"

    public struct Scope: Sendable, Codable, Equatable {
        public var evidenceClassification: String
        public var canQualifyShippingAlone: Bool
        public var thresholdEvidenceOwner: String
        public var audioSampleEvidenceOwner: String
        public var modelRuntimeEvidenceOwner: String
        public var runtimeNetworkEvidenceOwner: String
        public var expectedAudioSampleCount: Int
        public var observedAudioSampleCount: Int
        public var audioSampleCountReasonCode: String

        public init(
            evidenceClassification: String = "scoped-hosted-evidence-input-not-final-benchmark-artifact",
            canQualifyShippingAlone: Bool = false,
            thresholdEvidenceOwner: String = "final-live-context-benchmark-artifact",
            audioSampleEvidenceOwner: String = "retained-engine-runner-and-adversarial-receipt",
            modelRuntimeEvidenceOwner: String = "retained-engine-runner-and-adversarial-receipt",
            runtimeNetworkEvidenceOwner: String = "hosted-wrapper-50ms-process-tree-lsof-plus-runner-adversarial-receipt",
            expectedAudioSampleCount: Int = 0,
            observedAudioSampleCount: Int = 0,
            audioSampleCountReasonCode: String = "not-applicable-hosted-synthetic-engine-no-audio-stream"
        ) {
            self.evidenceClassification = evidenceClassification
            self.canQualifyShippingAlone = canQualifyShippingAlone
            self.thresholdEvidenceOwner = thresholdEvidenceOwner
            self.audioSampleEvidenceOwner = audioSampleEvidenceOwner
            self.modelRuntimeEvidenceOwner = modelRuntimeEvidenceOwner
            self.runtimeNetworkEvidenceOwner = runtimeNetworkEvidenceOwner
            self.expectedAudioSampleCount = expectedAudioSampleCount
            self.observedAudioSampleCount = observedAudioSampleCount
            self.audioSampleCountReasonCode = audioSampleCountReasonCode
        }
    }

    public struct Thresholds: Sendable, Codable, Equatable {
        public var syntheticCoordinatorListeningDiagnosticP95MS: Double
        public var overlayMainActorP99MS: Double
        public var maximumVisibleUpdatesPerSecond: Double

        public init(
            syntheticCoordinatorListeningDiagnosticP95MS: Double = LiveContextBenchmarkThresholds.required.listeningAcknowledgementP95MS,
            overlayMainActorP99MS: Double = LiveContextBenchmarkThresholds.required.overlayMainActorP99MS,
            maximumVisibleUpdatesPerSecond: Double = LiveContextBenchmarkThresholds.required.visibleUpdatesPerSecond
        ) {
            self.syntheticCoordinatorListeningDiagnosticP95MS = syntheticCoordinatorListeningDiagnosticP95MS
            self.overlayMainActorP99MS = overlayMainActorP99MS
            self.maximumVisibleUpdatesPerSecond = maximumVisibleUpdatesPerSecond
        }
    }

    public struct WrapperAttestation: Sendable, Codable, Equatable {
        public var testIdentifier: String
        public var networkObservationDefinition: String
        public var resultBundleScanDefinition: String
        public var hostedTestProcessID: Int32
        public var observationStartUnixMilliseconds: Int64
        public var observationEndUnixMilliseconds: Int64
        public var networkMonitorPerformed: Bool
        public var networkPollIntervalMilliseconds: Int
        public var networkScanCount: Int
        public var networkObservationDurationMilliseconds: Int
        public var maximumObservedProcessTreeCount: Int
        public var observedNetworkFileDescriptorCount: Int
        public var resultBundleScanPerformed: Bool
        public var resultBundleScannedFileCount: Int
        public var resultBundleCanaryFindings: Int
        public var resultBundleManifestSHA256: String
        public var attestationIdentitySHA256: String

        public init(testIdentifier: String, networkObservationDefinition: String, resultBundleScanDefinition: String, hostedTestProcessID: Int32, observationStartUnixMilliseconds: Int64, observationEndUnixMilliseconds: Int64, networkMonitorPerformed: Bool, networkPollIntervalMilliseconds: Int, networkScanCount: Int, networkObservationDurationMilliseconds: Int, maximumObservedProcessTreeCount: Int, observedNetworkFileDescriptorCount: Int, resultBundleScanPerformed: Bool, resultBundleScannedFileCount: Int, resultBundleCanaryFindings: Int, resultBundleManifestSHA256: String, attestationIdentitySHA256: String) {
            self.testIdentifier = testIdentifier
            self.networkObservationDefinition = networkObservationDefinition
            self.resultBundleScanDefinition = resultBundleScanDefinition
            self.hostedTestProcessID = hostedTestProcessID
            self.observationStartUnixMilliseconds = observationStartUnixMilliseconds
            self.observationEndUnixMilliseconds = observationEndUnixMilliseconds
            self.networkMonitorPerformed = networkMonitorPerformed
            self.networkPollIntervalMilliseconds = networkPollIntervalMilliseconds
            self.networkScanCount = networkScanCount
            self.networkObservationDurationMilliseconds = networkObservationDurationMilliseconds
            self.maximumObservedProcessTreeCount = maximumObservedProcessTreeCount
            self.observedNetworkFileDescriptorCount = observedNetworkFileDescriptorCount
            self.resultBundleScanPerformed = resultBundleScanPerformed
            self.resultBundleScannedFileCount = resultBundleScannedFileCount
            self.resultBundleCanaryFindings = resultBundleCanaryFindings
            self.resultBundleManifestSHA256 = resultBundleManifestSHA256
            self.attestationIdentitySHA256 = attestationIdentitySHA256
        }
    }

    /// Exact host/configuration identity for the synthetic hosted scope. The
    /// production model and retained runtime are intentionally not exercised by
    /// this receipt; those identities belong to the adversarial runner.
    public struct Environment: Sendable, Codable, Equatable {
        public var hardwareModelIdentifier: String
        public var operatingSystemVersion: String
        public var architecture: String
        public var trialCount: Int
        public var language: String
        public var transcriptionEngineScope: String
        public var modelRuntimeApplicability: String
        public var runtimeNetworkEvidenceOwner: String
        public var systemLogEvidenceApplicability: String
        public var crashDiagnosticEvidenceApplicability: String
        public var modelPathIdentity: String
        public var modelSHA256Identity: String
        public var runtimeIdentity: String
        public var helperIdentity: String
        public var modelRuntimeReasonCode: String

        public init(hardwareModelIdentifier: String, operatingSystemVersion: String, architecture: String, trialCount: Int, language: String, transcriptionEngineScope: String = "production-coordinator-with-injected-synthetic-live-engine", modelRuntimeApplicability: String = "not-applicable-hosted-synthetic-scope", runtimeNetworkEvidenceOwner: String = "hosted-wrapper-50ms-process-tree-lsof-plus-runner-adversarial-receipt", systemLogEvidenceApplicability: String = "not-observed-hosted-static-source-audit-only", crashDiagnosticEvidenceApplicability: String = "not-observed-hosted-static-source-audit-only", modelPathIdentity: String = "not-applicable", modelSHA256Identity: String = "not-applicable", runtimeIdentity: String = "injected-synthetic-live-engine", helperIdentity: String = "not-applicable", modelRuntimeReasonCode: String = "hosted-synthetic-engine-does-not-load-production-model-or-helper") {
            self.hardwareModelIdentifier = hardwareModelIdentifier
            self.operatingSystemVersion = operatingSystemVersion
            self.architecture = architecture
            self.trialCount = trialCount
            self.language = language
            self.transcriptionEngineScope = transcriptionEngineScope
            self.modelRuntimeApplicability = modelRuntimeApplicability
            self.runtimeNetworkEvidenceOwner = runtimeNetworkEvidenceOwner
            self.systemLogEvidenceApplicability = systemLogEvidenceApplicability
            self.crashDiagnosticEvidenceApplicability = crashDiagnosticEvidenceApplicability
            self.modelPathIdentity = modelPathIdentity
            self.modelSHA256Identity = modelSHA256Identity
            self.runtimeIdentity = runtimeIdentity
            self.helperIdentity = helperIdentity
            self.modelRuntimeReasonCode = modelRuntimeReasonCode
        }
    }

    public struct Lifecycle: Sendable, Codable, Equatable {
        public var randomizedSessions: Int
        public var rapidCancelRestartCases: Int
        public var targetTransitions: Int
        public var authoritativeFinishCalls: Int
        public var maximumAuthoritativeFinishCallsPerSession: Int
        public var coordinatorSecondFinalInferenceAttempts: Int
        public var finalInsertionCount: Int
        public var expectedFinalInsertionCount: Int

        public init(randomizedSessions: Int, rapidCancelRestartCases: Int, targetTransitions: Int, authoritativeFinishCalls: Int, maximumAuthoritativeFinishCallsPerSession: Int, coordinatorSecondFinalInferenceAttempts: Int, finalInsertionCount: Int, expectedFinalInsertionCount: Int) {
            self.randomizedSessions = randomizedSessions
            self.rapidCancelRestartCases = rapidCancelRestartCases
            self.targetTransitions = targetTransitions
            self.authoritativeFinishCalls = authoritativeFinishCalls
            self.maximumAuthoritativeFinishCallsPerSession = maximumAuthoritativeFinishCallsPerSession
            self.coordinatorSecondFinalInferenceAttempts = coordinatorSecondFinalInferenceAttempts
            self.finalInsertionCount = finalInsertionCount
            self.expectedFinalInsertionCount = expectedFinalInsertionCount
        }
    }

    public struct Privacy: Sendable, Codable, Equatable {
        public var canaryDerivationDefinition: String
        public var baseCanarySHA256: String
        public var provisionalCanarySHA256: String
        public var contextCanarySHA256: String
        public var snippetExpansionCanarySHA256: String
        public var provisionalCanaryInjectionCount: Int
        public var contextCanaryInjectionCount: Int
        public var snippetCanaryInjectionCount: Int
        public var scannedSurfaceCount: Int
        public var requestLeaks: Int
        public var cleanupLeaks: Int
        public var historyLeaks: Int
        public var insertionLeaks: Int
        public var clipboardRecoveryLeaks: Int
        public var analyticsLeaks: Int
        public var configuredSnippetTrapCount: Int
        public var snippetTrapActivations: Int
        public var liveCallbackProvisionalObservations: Int
        public var liveCallbackUnexpectedContextLeaks: Int
        public var unavailableCallbackObservations: Int
        public var overlayRetainedTextLeaks: Int
        public var injectedURLProtocolSelfTestHits: Int
        public var injectedURLProtocolProductionPathHits: Int
        public var secureFieldContextReadRequests: Int
        public var maximumAXUTF16ReadPerSide: Int
        public var maximumAXGraphemesPerSide: Int
        public var maximumAXContextBytes: Int

        public init(canaryDerivationDefinition: String, baseCanarySHA256: String, provisionalCanarySHA256: String, contextCanarySHA256: String, snippetExpansionCanarySHA256: String, provisionalCanaryInjectionCount: Int, contextCanaryInjectionCount: Int, snippetCanaryInjectionCount: Int, scannedSurfaceCount: Int, requestLeaks: Int, cleanupLeaks: Int, historyLeaks: Int, insertionLeaks: Int, clipboardRecoveryLeaks: Int, analyticsLeaks: Int, configuredSnippetTrapCount: Int, snippetTrapActivations: Int, liveCallbackProvisionalObservations: Int, liveCallbackUnexpectedContextLeaks: Int, unavailableCallbackObservations: Int, overlayRetainedTextLeaks: Int, injectedURLProtocolSelfTestHits: Int, injectedURLProtocolProductionPathHits: Int, secureFieldContextReadRequests: Int, maximumAXUTF16ReadPerSide: Int, maximumAXGraphemesPerSide: Int, maximumAXContextBytes: Int) {
            self.canaryDerivationDefinition = canaryDerivationDefinition
            self.baseCanarySHA256 = baseCanarySHA256
            self.provisionalCanarySHA256 = provisionalCanarySHA256
            self.contextCanarySHA256 = contextCanarySHA256
            self.snippetExpansionCanarySHA256 = snippetExpansionCanarySHA256
            self.provisionalCanaryInjectionCount = provisionalCanaryInjectionCount
            self.contextCanaryInjectionCount = contextCanaryInjectionCount
            self.snippetCanaryInjectionCount = snippetCanaryInjectionCount
            self.scannedSurfaceCount = scannedSurfaceCount
            self.requestLeaks = requestLeaks
            self.cleanupLeaks = cleanupLeaks
            self.historyLeaks = historyLeaks
            self.insertionLeaks = insertionLeaks
            self.clipboardRecoveryLeaks = clipboardRecoveryLeaks
            self.analyticsLeaks = analyticsLeaks
            self.configuredSnippetTrapCount = configuredSnippetTrapCount
            self.snippetTrapActivations = snippetTrapActivations
            self.liveCallbackProvisionalObservations = liveCallbackProvisionalObservations
            self.liveCallbackUnexpectedContextLeaks = liveCallbackUnexpectedContextLeaks
            self.unavailableCallbackObservations = unavailableCallbackObservations
            self.overlayRetainedTextLeaks = overlayRetainedTextLeaks
            self.injectedURLProtocolSelfTestHits = injectedURLProtocolSelfTestHits
            self.injectedURLProtocolProductionPathHits = injectedURLProtocolProductionPathHits
            self.secureFieldContextReadRequests = secureFieldContextReadRequests
            self.maximumAXUTF16ReadPerSide = maximumAXUTF16ReadPerSide
            self.maximumAXGraphemesPerSide = maximumAXGraphemesPerSide
            self.maximumAXContextBytes = maximumAXContextBytes
        }
    }

    /// Hash-bound static audits cover feature source surfaces that cannot be
    /// intercepted faithfully by a hosted process. They are evidence of scoped
    /// source absence, not a claim that every system log or crash collector was
    /// observed dynamically.
    public struct StaticAudit: Sendable, Codable, Equatable {
        /// Binds the production audit rows and their evidence harness to the
        /// complete hosted manifest. Only `hostedProductionRelativePaths` are
        /// scanned for findings; evidence files are hash-bound, not audited.
        public var boundHostedSourceManifestSHA256: String
        public var scopeDefinition: String
        public var auditedFileCount: Int
        public var featureLogInvocationSourceAuditPerformed: Bool
        public var featureLogInvocationSourceFindings: Int
        public var crashMetadataSinkReferenceSourceAuditPerformed: Bool
        public var crashMetadataSinkReferenceSourceFindings: Int
        public var ephemeralPersistenceSourceAuditPerformed: Bool
        public var ephemeralPersistenceSourceFindings: Int
        public var ephemeralFilenameDiagnosticSourceAuditPerformed: Bool
        public var ephemeralFilenameDiagnosticSourceFindings: Int
        public var prohibitedNetworkAPISourceAuditPerformed: Bool
        public var prohibitedNetworkAPISourceFindings: Int

        public init(boundHostedSourceManifestSHA256: String, scopeDefinition: String = "static-findings-scan-hosted-production-relative-paths-only-evidence-files-hash-bound-only", auditedFileCount: Int, featureLogInvocationSourceAuditPerformed: Bool, featureLogInvocationSourceFindings: Int, crashMetadataSinkReferenceSourceAuditPerformed: Bool, crashMetadataSinkReferenceSourceFindings: Int, ephemeralPersistenceSourceAuditPerformed: Bool, ephemeralPersistenceSourceFindings: Int, ephemeralFilenameDiagnosticSourceAuditPerformed: Bool, ephemeralFilenameDiagnosticSourceFindings: Int, prohibitedNetworkAPISourceAuditPerformed: Bool, prohibitedNetworkAPISourceFindings: Int) {
            self.boundHostedSourceManifestSHA256 = boundHostedSourceManifestSHA256
            self.scopeDefinition = scopeDefinition
            self.auditedFileCount = auditedFileCount
            self.featureLogInvocationSourceAuditPerformed = featureLogInvocationSourceAuditPerformed
            self.featureLogInvocationSourceFindings = featureLogInvocationSourceFindings
            self.crashMetadataSinkReferenceSourceAuditPerformed = crashMetadataSinkReferenceSourceAuditPerformed
            self.crashMetadataSinkReferenceSourceFindings = crashMetadataSinkReferenceSourceFindings
            self.ephemeralPersistenceSourceAuditPerformed = ephemeralPersistenceSourceAuditPerformed
            self.ephemeralPersistenceSourceFindings = ephemeralPersistenceSourceFindings
            self.ephemeralFilenameDiagnosticSourceAuditPerformed = ephemeralFilenameDiagnosticSourceAuditPerformed
            self.ephemeralFilenameDiagnosticSourceFindings = ephemeralFilenameDiagnosticSourceFindings
            self.prohibitedNetworkAPISourceAuditPerformed = prohibitedNetworkAPISourceAuditPerformed
            self.prohibitedNetworkAPISourceFindings = prohibitedNetworkAPISourceFindings
        }
    }

    public struct Correctness: Sendable, Codable, Equatable {
        public var provisionalSideEffects: Int
        public var duplicateFinalInsertions: Int
        public var staleEventsAccepted: Int
        public var speechPreviewRenderedControlCount: Int
        public var noSpeechFalseDisplays: Int

        public init(provisionalSideEffects: Int, duplicateFinalInsertions: Int, staleEventsAccepted: Int, speechPreviewRenderedControlCount: Int, noSpeechFalseDisplays: Int) {
            self.provisionalSideEffects = provisionalSideEffects
            self.duplicateFinalInsertions = duplicateFinalInsertions
            self.staleEventsAccepted = staleEventsAccepted
            self.speechPreviewRenderedControlCount = speechPreviewRenderedControlCount
            self.noSpeechFalseDisplays = noSpeechFalseDisplays
        }
    }

    public var schemaVersion: String
    public var generatedAt: String
    public var gitSHA: String
    public var treeIsDirty: Bool
    public var sourceManifestSHA256: String
    public var failureCount: Int
    public var skipCount: Int
    public var failures: [LiveContextFailureRow]
    public var skips: [LiveContextFailureRow]
    public var scope: Scope
    public var thresholds: Thresholds
    public var wrapperAttestation: WrapperAttestation?
    public var environment: Environment
    public var environmentIdentitySHA256: String
    public var syntheticCoordinatorListeningAcknowledgementDefinition: String
    public var syntheticCoordinatorListeningAcknowledgementDiagnostic: LiveLatencyDistribution
    public var overlayMainActorDefinition: String
    public var overlayMainActorWork: LiveLatencyDistribution
    public var renderedUpdateTimestampsMS: [Double]
    /// Coordinator overhead/correctness diagnostic only. The injected engine
    /// does not qualify these distributions for the shipping latency gate.
    public var syntheticCoordinatorStopToInsertionDefinition: String
    public var syntheticCoordinatorStopToInsertionEnabledDiagnostic: LiveLatencyDistribution
    public var syntheticCoordinatorStopToInsertionDisabledControlDiagnostic: LiveLatencyDistribution
    public var acceptedPreviewCount: Int
    public var renderedPreviewCount: Int
    public var maximumQueueDepth: Int
    public var coalescedPreviewCount: Int
    public var trialOrder: [LiveContextTrialMode]
    public var configurationIdentitySHA256: String
    public var lifecycle: Lifecycle
    public var noSpeechDisplayDefinition: String
    public var correctness: Correctness
    public var privacy: Privacy
    public var staticAudit: StaticAudit

    public init(schemaVersion: String = currentSchemaVersion, generatedAt: String, gitSHA: String, treeIsDirty: Bool, sourceManifestSHA256: String, failureCount: Int, skipCount: Int, failures: [LiveContextFailureRow], skips: [LiveContextFailureRow], scope: Scope = .init(), thresholds: Thresholds = .init(), wrapperAttestation: WrapperAttestation? = nil, environment: Environment, environmentIdentitySHA256: String, syntheticCoordinatorListeningAcknowledgementDefinition: String = "production-dictation-controller-entry-through-injected-immediate-coordinator-capture-acknowledgement-to-nonactivating-panel-order-return-diagnostic-only", syntheticCoordinatorListeningAcknowledgementDiagnostic: LiveLatencyDistribution, overlayMainActorDefinition: String = "production-overlay-accepted-snapshot-to-mainactor-render-complete", overlayMainActorWork: LiveLatencyDistribution, renderedUpdateTimestampsMS: [Double], syntheticCoordinatorStopToInsertionDefinition: String = "production-session-coordinator-capture-stop-call-to-injected-synthetic-engine-insertion-complete-diagnostic-only", syntheticCoordinatorStopToInsertionEnabledDiagnostic: LiveLatencyDistribution, syntheticCoordinatorStopToInsertionDisabledControlDiagnostic: LiveLatencyDistribution, acceptedPreviewCount: Int, renderedPreviewCount: Int, maximumQueueDepth: Int, coalescedPreviewCount: Int, trialOrder: [LiveContextTrialMode], configurationIdentitySHA256: String, lifecycle: Lifecycle, noSpeechDisplayDefinition: String = "production-session-coordinator-live-snapshot-through-production-overlay-preview-rendered-observer", correctness: Correctness, privacy: Privacy, staticAudit: StaticAudit) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.gitSHA = gitSHA
        self.treeIsDirty = treeIsDirty
        self.sourceManifestSHA256 = sourceManifestSHA256
        self.failureCount = failureCount
        self.skipCount = skipCount
        self.failures = failures
        self.skips = skips
        self.scope = scope
        self.thresholds = thresholds
        self.wrapperAttestation = wrapperAttestation
        self.environment = environment
        self.environmentIdentitySHA256 = environmentIdentitySHA256
        self.syntheticCoordinatorListeningAcknowledgementDefinition = syntheticCoordinatorListeningAcknowledgementDefinition
        self.syntheticCoordinatorListeningAcknowledgementDiagnostic = syntheticCoordinatorListeningAcknowledgementDiagnostic
        self.overlayMainActorDefinition = overlayMainActorDefinition
        self.overlayMainActorWork = overlayMainActorWork
        self.renderedUpdateTimestampsMS = renderedUpdateTimestampsMS
        self.syntheticCoordinatorStopToInsertionDefinition = syntheticCoordinatorStopToInsertionDefinition
        self.syntheticCoordinatorStopToInsertionEnabledDiagnostic = syntheticCoordinatorStopToInsertionEnabledDiagnostic
        self.syntheticCoordinatorStopToInsertionDisabledControlDiagnostic = syntheticCoordinatorStopToInsertionDisabledControlDiagnostic
        self.acceptedPreviewCount = acceptedPreviewCount
        self.renderedPreviewCount = renderedPreviewCount
        self.maximumQueueDepth = maximumQueueDepth
        self.coalescedPreviewCount = coalescedPreviewCount
        self.trialOrder = trialOrder
        self.configurationIdentitySHA256 = configurationIdentitySHA256
        self.lifecycle = lifecycle
        self.noSpeechDisplayDefinition = noSpeechDisplayDefinition
        self.correctness = correctness
        self.privacy = privacy
        self.staticAudit = staticAudit
    }
}

public enum LiveContextReceiptManifest {
    public static let hostedProductionRelativePaths = [
        "Steno/DictationController.swift",
        "StenoKit/Sources/StenoKit/Services/SessionCoordinator.swift",
        "StenoKit/Sources/StenoKit/Services/CanonicalWAVFrameStreamer.swift",
        "StenoKit/Sources/StenoKit/Services/RuleBasedCleanupEngine.swift",
        "StenoKit/Sources/StenoKit/Services/WaveformOverlayPresenter.swift",
        "StenoKit/Sources/StenoKit/Services/ProvisionalTranscriptReducer.swift",
        "StenoKit/Sources/StenoKit/Services/MacEditorTargetHandle.swift",
        "StenoKit/Sources/StenoKit/Services/InsertionService.swift",
        "StenoKit/Sources/StenoKit/Services/InsertionTransports.swift",
        "StenoKit/Sources/StenoKit/Services/MacInsertionTransports.swift",
        "StenoKit/Sources/StenoKit/Services/WhisperCLITranscriptionEngine.swift",
        "StenoKit/Sources/StenoKit/Services/ProcessWhisperRuntimeSession.swift",
        "StenoKit/Sources/StenoKit/Services/RetainedWhisperTranscriptionEngine.swift",
        "StenoKit/Sources/StenoKit/Services/MacAudioCaptureService.swift",
        "StenoKit/Sources/StenoKit/Services/HistoryStore.swift",
        "StenoKit/Sources/StenoKit/Services/UsageAnalyticsStore.swift",
        "StenoKit/Sources/StenoKit/Services/SnippetService.swift",
        "StenoKit/Sources/StenoKit/Services/DictationContinuationPolicy.swift",
        "StenoKit/Sources/StenoKit/Models/EditorTarget.swift",
        "StenoKit/Sources/StenoKit/Models/History.swift",
        "StenoKit/Sources/StenoKit/Models/LiveTranscription.swift",
        "StenoKit/Sources/StenoKit/Models/LivePCM.swift",
        "StenoKit/Sources/StenoKit/Models/Transcripts.swift",
        "StenoKit/Sources/StenoKit/Models/UsageAnalytics.swift",
        "StenoKit/Sources/StenoKit/Protocols/Engines.swift",
        "StenoKit/Sources/StenoKit/Protocols/Stores.swift",
        "StenoKit/Sources/StenoKit/Protocols/UX.swift",
        "StenoKit/Sources/StenoBenchmarkCore/LiveContextProductionCoordinatorBenchmark.swift",
    ]

    public static let hostedEvidenceRelativePaths = [
        "StenoKit/Sources/StenoBenchmarkCore/LiveContextBenchmark.swift",
        "StenoKit/Sources/StenoBenchmarkCore/LiveContextBenchmarkRunner.swift",
        "StenoTests/LiveContextHostedEvidenceTests.swift",
        "StenoTests/DictationControllerLiveContextTests.swift",
        "StenoKit/Tests/StenoKitTests/SessionCoordinatorLiveContextTests.swift",
        "StenoKit/Tests/StenoKitTests/OverlayPresenterPolicyTests.swift",
        "StenoKit/Tests/StenoBenchmarkCoreTests/LiveContextProductionCoordinatorBenchmarkTests.swift",
        "scripts/run-live-context-hosted-evidence.sh",
        "scripts/live-context-hosted-network-monitor.rb",
        "scripts/finalize-live-context-hosted-receipt.rb",
    ]

    public static let hostedRelativePaths = hostedProductionRelativePaths + hostedEvidenceRelativePaths

    public static func hostedSourceSHA256(sourceRootPath: String) throws -> String {
        var rows: [String] = []
        for relativePath in hostedRelativePaths {
            let url = URL(fileURLWithPath: sourceRootPath).appendingPathComponent(relativePath)
            let hash = LiveContextHash.sha256(try Data(contentsOf: url))
            rows.append("\(relativePath):\(hash)")
        }
        return LiveContextHash.sha256(Data(rows.joined(separator: "\n").utf8))
    }

    public static func hostedConfigurationSHA256(
        gitSHA: String,
        sourceManifestSHA256: String,
        language: String,
        trialCount: Int
    ) -> String {
        LiveContextHash.sha256(Data([
            gitSHA, sourceManifestSHA256, language, String(trialCount),
            LiveContextHostedReceipt.currentSchemaVersion,
            "live-preview-enabled-disabled-only",
            "randomized-sessions=1000",
            "rapid-cancel-restarts=250",
            "target-transitions=10000",
        ].joined(separator: "\u{0}").utf8))
    }

    public static func hostedCanary(gitSHA: String) -> String {
        let seed = LiveContextHash.sha256(Data([
            "steno-live-context-hosted-canary/v2",
            gitSHA.lowercased(),
        ].joined(separator: "\u{0}").utf8))
        return "STENO-LIVE-CONTEXT-HOSTED-\(seed)"
    }

    public static let hostedPrivacyCanaryDerivationDefinition =
        "git-bound-base-v2-plus-provisional-context-and-snippet-expansion-suffixes-v1"

    /// Ordered deterministic canaries used by the hosted privacy producer.
    /// Callers may derive them transiently from the receipt-bound Git SHA;
    /// generated receipts persist only their SHA-256 identities.
    public static func hostedPrivacyCanaries(gitSHA: String) -> [String] {
        let base = hostedCanary(gitSHA: gitSHA)
        return [
            base,
            base + "-PROVISIONAL",
            base + "-CONTEXT",
            base + "-SNIPPET-EXPANSION",
        ]
    }

    public static func hostedEnvironmentSHA256(
        _ environment: LiveContextHostedReceipt.Environment
    ) -> String {
        LiveContextHash.sha256(Data([
            environment.hardwareModelIdentifier,
            environment.operatingSystemVersion,
            environment.architecture,
            String(environment.trialCount),
            environment.language,
            environment.transcriptionEngineScope,
            environment.modelRuntimeApplicability,
            environment.runtimeNetworkEvidenceOwner,
            environment.systemLogEvidenceApplicability,
            environment.crashDiagnosticEvidenceApplicability,
            environment.modelPathIdentity,
            environment.modelSHA256Identity,
            environment.runtimeIdentity,
            environment.helperIdentity,
            environment.modelRuntimeReasonCode,
        ].joined(separator: "\u{0}").utf8))
    }

    public static func hostedWrapperAttestationSHA256(
        _ attestation: LiveContextHostedReceipt.WrapperAttestation
    ) -> String {
        LiveContextHash.sha256(Data([
            attestation.testIdentifier,
            attestation.networkObservationDefinition,
            attestation.resultBundleScanDefinition,
            String(attestation.hostedTestProcessID),
            String(attestation.observationStartUnixMilliseconds),
            String(attestation.observationEndUnixMilliseconds),
            String(attestation.networkMonitorPerformed),
            String(attestation.networkPollIntervalMilliseconds),
            String(attestation.networkScanCount),
            String(attestation.networkObservationDurationMilliseconds),
            String(attestation.maximumObservedProcessTreeCount),
            String(attestation.observedNetworkFileDescriptorCount),
            String(attestation.resultBundleScanPerformed),
            String(attestation.resultBundleScannedFileCount),
            String(attestation.resultBundleCanaryFindings),
            attestation.resultBundleManifestSHA256,
        ].joined(separator: "\u{0}").utf8))
    }
}

public enum LiveContextArtifactIO {
    public static func loadArtifact(at path: String) throws -> LiveContextBenchmarkArtifact {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard try validatePrivacy(of: data) else {
            throw LiveContextArtifactIOError.privacyValidationFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let artifact = try decoder.decode(LiveContextBenchmarkArtifact.self, from: data)
        guard artifactCanariesAreAbsent(data, gitSHA: artifact.identity.gitSHA) else {
            throw LiveContextArtifactIOError.privacyValidationFailed
        }
        return artifact
    }

    public static func loadCorpus(at path: String) throws -> ContinuationDirectiveCorpus {
        try JSONDecoder().decode(ContinuationDirectiveCorpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public static func encodeCorpus(_ corpus: ContinuationDirectiveCorpus) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(corpus)
    }

    public static func encodeArtifact(_ artifact: LiveContextBenchmarkArtifact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        guard try validatePrivacy(of: data),
              artifactCanariesAreAbsent(data, gitSHA: artifact.identity.gitSHA) else {
            throw LiveContextArtifactIOError.privacyValidationFailed
        }
        return data
    }

    private static func artifactCanariesAreAbsent(_ data: Data, gitSHA: String) -> Bool {
        let sentinels = LiveContextReceiptManifest.hostedPrivacyCanaries(gitSHA: gitSHA)
            + ["STENO-PUBLIC-PROTOCOL-CANARY-V1"]
        return !sentinels.contains(where: { data.range(of: Data($0.utf8)) != nil })
    }

    public static func validatePrivacy(of data: Data) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        let prohibitedKeys: Set<String> = [
            "rawtext", "cleanedtext", "insertedtext", "referencetext", "hypothesistext",
            "transcript", "context", "appcontext", "prompt", "vocabulary", "audiopath",
            "modelpath", "vadmodelpath", "helperexecutablepath", "arguments", "argv",
            "logmessage", "crashmetadata", "clipboardcontent",
        ]
        func isSafe(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary.allSatisfy { key, nested in
                    !prohibitedKeys.contains(key.lowercased()) && isSafe(nested)
                }
            }
            if let array = value as? [Any] {
                return array.allSatisfy(isSafe)
            }
            if let string = value as? String {
                return !string.hasPrefix("/Users/")
                    && !string.hasPrefix("/private/")
                    && !string.hasPrefix("file://")
            }
            return true
        }
        return isSafe(object)
    }
}

public enum LiveContextArtifactIOError: Error, Equatable {
    case privacyValidationFailed
}

public enum LiveContextBenchmarkValidator {
    public static func validateCaseSensitive(
        artifact: LiveContextBenchmarkArtifact,
        corpus: ContinuationDirectiveCorpus,
        expectedIdentity: LiveContextExpectedIdentity? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = 86_400
    ) -> LiveContextValidationResult {
        var failures = commonFailures(artifact: artifact, corpus: corpus, expectedIdentity: expectedIdentity, now: now, maximumAge: maximumAge)
        guard corpus.schemaVersion == ContinuationDirectiveCorpus.currentSchemaVersion else {
            failures.append("unsupported-corpus-schema")
            return .init(failures: unique(failures))
        }
        guard !corpus.rows.isEmpty else {
            failures.append("empty-corpus")
            return .init(failures: unique(failures))
        }

        let corpusIDs = corpus.rows.map(\.id)
        if Set(corpusIDs).count != corpusIDs.count || corpus.rows.contains(where: {
            $0.id.isEmpty || $0.input.isEmpty || $0.expectedOutput.isEmpty || $0.category.isEmpty
        }) {
            failures.append("invalid-corpus-identities")
        }
        let resultIDs = artifact.caseSensitiveRows.map(\.id)
        if Set(resultIDs).count != resultIDs.count {
            failures.append("duplicate-case-sensitive-results")
        }
        if Set(resultIDs) != Set(corpusIDs) || artifact.caseSensitiveRows.count != corpus.rows.count {
            failures.append("missing-case-sensitive-results")
        }

        let results = Dictionary(artifact.caseSensitiveRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for corpusRow in corpus.rows {
            guard let row = results[corpusRow.id] else { continue }
            let expectedHash = LiveContextHash.sha256(Data(corpusRow.expectedOutput.utf8))
            if row.category != corpusRow.category || row.expectedSHA256 != expectedHash {
                failures.append("case-sensitive-result-identity-mismatch")
            }
            if row.status != .passed || row.reasonCode != nil || row.actualSHA256 != expectedHash {
                failures.append("case-sensitive-row-not-passed")
            }
            if !row.continuationDecisionCorrect || row.unintendedLowercaseCount != 0
                || !row.directiveDecisionCorrect || !row.literalLowercasePreserved
                || !row.boundarySpacingCorrect {
                failures.append("case-sensitive-contract-failed")
            }
        }
        if artifact.declaredSkipCount != artifact.skips.count || !artifact.skips.isEmpty
            || artifact.caseSensitiveRows.contains(where: { $0.status == .skipped }) {
            failures.append("skipped-evidence")
        }
        if artifact.declaredFailureCount != artifact.failures.count || !artifact.failures.isEmpty
            || artifact.caseSensitiveRows.contains(where: { $0.status == .failed }) {
            failures.append("reported-failures")
        }
        return .init(failures: unique(failures))
    }

    public static func validateLive(
        artifact: LiveContextBenchmarkArtifact,
        corpus: ContinuationDirectiveCorpus,
        expectedIdentity: LiveContextExpectedIdentity? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = 86_400
    ) -> LiveContextValidationResult {
        validateLiveEvidence(
            artifact: artifact,
            corpus: corpus,
            expectedIdentity: expectedIdentity,
            now: now,
            maximumAge: maximumAge,
            requireNativeShippingEvidence: true
        )
    }

    public static func validateLiveCoreDiagnostics(
        artifact: LiveContextBenchmarkArtifact,
        corpus: ContinuationDirectiveCorpus,
        expectedIdentity: LiveContextExpectedIdentity? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = 86_400
    ) -> LiveContextValidationResult {
        validateLiveEvidence(
            artifact: artifact,
            corpus: corpus,
            expectedIdentity: expectedIdentity,
            now: now,
            maximumAge: maximumAge,
            requireNativeShippingEvidence: false
        )
    }

    private static func validateLiveEvidence(
        artifact: LiveContextBenchmarkArtifact,
        corpus: ContinuationDirectiveCorpus,
        expectedIdentity: LiveContextExpectedIdentity?,
        now: Date,
        maximumAge: TimeInterval,
        requireNativeShippingEvidence: Bool
    ) -> LiveContextValidationResult {
        var failures = validateCaseSensitive(artifact: artifact, corpus: corpus, expectedIdentity: expectedIdentity, now: now, maximumAge: maximumAge).failures
        let required = LiveContextBenchmarkThresholds.required
        if artifact.thresholds != required { failures.append("threshold-contract-mismatch") }

        let distributions: [(String, LiveLatencyDistribution)] = [
            ("helper-stream-setup", artifact.latency.helperStreamSetup),
            ("first-partial", artifact.latency.firstPartial),
            ("subsequent-gap", artifact.latency.subsequentPartialGap),
            ("overlay-main-actor", artifact.latency.overlayMainActorWork),
            ("final-enabled", artifact.latency.finishToAuthoritativeFinalEnabled),
            ("final-disabled", artifact.latency.finishToAuthoritativeFinalDisabledControl),
        ]
        for (name, distribution) in distributions {
            if !valid(distribution) { failures.append("invalid-latency-distribution:\(name)") }
        }
        if exceeds(artifact.latency.firstPartial.p50MS, required.firstPartialP50MS) { failures.append("first-partial-p50") }
        if exceeds(artifact.latency.firstPartial.p95MS, required.firstPartialP95MS) { failures.append("first-partial-p95") }
        if exceeds(artifact.latency.firstPartial.p99MS, required.firstPartialP99MS) { failures.append("first-partial-p99") }
        if exceeds(artifact.latency.subsequentPartialGap.p95MS, required.subsequentPartialGapP95MS) { failures.append("subsequent-gap-p95") }
        if exceeds(artifact.latency.overlayMainActorWork.p99MS, required.overlayMainActorP99MS) { failures.append("overlay-main-actor-p99") }
        if exceeds(artifact.latency.finishToAuthoritativeFinalEnabled.p95MS, 2_000) { failures.append("finish-to-final-hard-limit") }
        if !artifact.latency.maximumVisibleUpdatesPerSecond.isFinite || artifact.latency.maximumVisibleUpdatesPerSecond > required.visibleUpdatesPerSecond { failures.append("visible-update-cadence") }
        let expectedOrder = (0..<artifact.latency.alternatingTrialCount).map {
            $0.isMultiple(of: 2) ? LiveContextTrialMode.enabled : .disabled
        }
        if artifact.latency.alternatingTrialCount < 10
            || artifact.latency.trialOrder != expectedOrder
            || artifact.latency.trialOrder.filter({ $0 == .enabled }).count < 5
            || artifact.latency.trialOrder.filter({ $0 == .disabled }).count < 5
            || artifact.latency.firstPartial.count < 5
            || artifact.latency.finishToAuthoritativeFinalEnabled.count < 5
            || artifact.latency.finishToAuthoritativeFinalDisabledControl.count < 5
            || !artifact.latency.sameConfigurationAcrossTrials {
            failures.append("alternating-control-trials")
        }
        let enabledTrialCount = artifact.latency.trialOrder.filter({ $0 == .enabled }).count
        if artifact.latency.subsequentPartialGap.count < enabledTrialCount
            || artifact.latency.acceptedSubsequentGapCountByEnabledTrial.count != enabledTrialCount
            || artifact.latency.acceptedSubsequentGapCountByEnabledTrial.contains(where: { $0 < 1 }) {
            failures.append("insufficient-subsequent-gap-coverage")
        }
        if artifact.latency.coreDiagnosticDefinition != LiveContextProductionCoordinatorBenchmark.definition
            || artifact.latency.coreDiagnosticReadinessDefinition != LiveContextProductionCoordinatorBenchmark.enabledReadinessDefinition
            || artifact.latency.coreDiagnosticConfigurationSHA256.map(isSHA256) != true {
            failures.append("core-diagnostic-definition-mismatch")
        }
        if let diagnostic = artifact.coreDiagnostics {
            let enabledCount = expectedOrder.filter({ $0 == .enabled }).count
            let disabledCount = expectedOrder.filter({ $0 == .disabled }).count
            if diagnostic.trialOrder != expectedOrder
                || diagnostic.authoritativeFinalOwnershipCount != expectedOrder.count
                || diagnostic.insertionCommitCount != expectedOrder.count
                || diagnostic.historyAppendCount != expectedOrder.count
                || diagnostic.successfulEnabledReadinessCount != enabledCount
                || diagnostic.liveFinishAuthoritativeFinalCount != enabledCount
                || diagnostic.disabledTranscribeAuthoritativeFinalCount != disabledCount
                || diagnostic.coordinatorFallbackCount != 0
                || diagnostic.runtimeIdentityCount != 1
                || diagnostic.publicFixtureSHA256 != artifact.identity.audioFixtureSHA256
                || diagnostic.configurationSHA256 != artifact.latency.coreDiagnosticConfigurationSHA256
                || diagnostic.enabledCanonicalSummaries.count != enabledCount {
                failures.append("production-core-diagnostic-gate")
            }
        } else {
            failures.append("production-core-diagnostic-required")
        }
        if requireNativeShippingEvidence {
            // No independent native producer/receipt is part of this schema.
            // Keep the shipping gate structurally closed: an optional block in
            // the aggregate artifact is never self-attesting shipping proof.
            failures.append("native-listening-evidence-required")
            failures.append("native-stop-to-insertion-evidence-required")
            if let native = artifact.nativeShippingEvidence,
               native.scope != LiveContextNativeShippingEvidence.requiredScope
                || native.listeningDefinition != LiveContextNativeShippingEvidence.listeningDefinition
                || native.stopToInsertionDefinition != LiveContextNativeShippingEvidence.stopDefinition
                || native.trialOrder != expectedOrder
                || !isSHA256(native.configurationIdentitySHA256) {
                failures.append("native-shipping-evidence-mislabeled")
            }
        }

        let correctness = artifact.correctness
        if correctness.stablePrefixMutations != 0 || correctness.provisionalSideEffects != 0
            || correctness.duplicateFinalInsertions != 0 || correctness.staleEventsAccepted != 0
            || correctness.stablePrefixConflicts != 0
            || correctness.noSpeechFalseDisplays != 0
            || correctness.latePartialsAfterCancellation != 0 {
            failures.append("correctness-regression")
        }
        if correctness.provisionalSessionCount <= 0 || correctness.revisionCount <= 0
            || correctness.finalizationCount != correctness.provisionalSessionCount {
            failures.append("preview-convergence-not-proven")
        }

        let capture = artifact.capture
        if capture.expectedAudioSampleCount <= 0
            || capture.streamedSampleCount != capture.expectedAudioSampleCount
            || capture.canonicalSampleCount != capture.expectedAudioSampleCount
            || !isSHA256(capture.streamedPCMHash) || capture.streamedPCMHash != capture.canonicalPCMHash
            || capture.frameSequenceOrOffsetDiscontinuities != 0 {
            failures.append("capture-parity")
        }
        let expectedFNV = capture.expectedFNV1A64
        if expectedFNV.count != 16 || UInt64(expectedFNV, radix: 16) == nil
            || capture.streamedFNV1A64 != expectedFNV
            || capture.canonicalFNV1A64 != expectedFNV
            || capture.audioFixtureSHA256 != artifact.identity.audioFixtureSHA256
            || capture.trials.count < 5
            || capture.trials.contains(where: {
                $0.expectedSampleCount != capture.expectedAudioSampleCount
                    || $0.streamedSampleCount != $0.expectedSampleCount
                    || $0.canonicalSampleCount != $0.expectedSampleCount
                    || $0.expectedFNV1A64 != expectedFNV
                    || $0.streamedFNV1A64 != expectedFNV
                    || $0.canonicalFNV1A64 != expectedFNV
            }) {
            failures.append("capture-fnv-parity")
        }
        if let diagnostic = artifact.coreDiagnostics {
            let frameCounts = Set(diagnostic.enabledCanonicalSummaries.map(\.frameCount))
            if diagnostic.enabledCanonicalSummaries.contains(where: {
                Int($0.sampleCount) != capture.expectedAudioSampleCount
                    || $0.byteCount != $0.sampleCount * 2
                    || $0.frameCount == 0
                    || $0.fnv1a64 != expectedFNV
            }) || frameCounts.count != 1 {
                failures.append("production-core-capture-parity")
            }
        }

        let resources = artifact.resources
        if resources.soakSessionCount < 500
            || resources.requestedSoakSessionCount < 500
            || resources.completedSoakSessionCount != resources.requestedSoakSessionCount
            || resources.soakSessionCount != resources.completedSoakSessionCount
            || (resources.peakRSSBytes ?? 0) == 0 || resources.rssCeilingBytes != 2_147_483_648
            || (resources.peakRSSBytes ?? .max) > resources.rssCeilingBytes
            || (resources.peakGrowthBytes ?? .max) > required.maximumPeakGrowthBytes
            || resources.tailSlopeBytesPerRequest?.isFinite != true
            || (resources.tailSlopeBytesPerRequest ?? .infinity) > required.maximumTailSlopeBytesPerRequest
            || resources.monotonicGrowthObserved != false || resources.sawtoothGrowthObserved != false
            || resources.idleCPUPercent?.isFinite != true || (resources.idleCPUPercent ?? -.infinity) < 0
            || (resources.idleCPUPercent ?? .infinity) > required.maximumIdleCPUPercent
            || !resources.idleSampleSeconds.isFinite
            || resources.idleSampleSeconds < required.minimumIdleSampleSeconds
            || !resources.observedIdleSampleSeconds.isFinite
            || resources.observedIdleSampleSeconds < required.minimumIdleSampleSeconds
            || !resources.idleObservationCompleted
            || resources.maximumConcurrentHelperProcessCount != 1
            || !resources.continuousHelperMonitorPerformed
            || resources.helperProcessObservationCount < resources.requestedSoakSessionCount
            || resources.maximumResidentModelCount != 1
            || resources.modelInitializationSourceSHA256 != artifact.identity.helperSourceSHA256
            || resources.modelInitializationSiteCount != 1
            || resources.thermalState?.isEmpty != false
            || resources.activeCPUPercentSamples.isEmpty || !finiteNonnegative(resources.activeCPUPercentSamples)
            || resources.maximumQueueDepth <= 0 || resources.coalescedPreviewCount <= 0
            || resources.helperReloadCount != 0 || resources.helperFallbackCount != 0 {
            failures.append("resource-gate")
        }

        let privacy = artifact.privacy
        let requiredProbeCounts = [privacy.staticNetworkTransportMatches, privacy.listeningSocketsObserved,
            privacy.runtimeNetworkConnectionsObserved]
        let leakCounts = [privacy.requestLeaks, privacy.cleanupLeaks,
            privacy.historyLeaks, privacy.insertionLeaks, privacy.clipboardRecoveryLeaks,
            privacy.analyticsLeaks, privacy.snippetTrapActivations,
            privacy.liveCallbackUnexpectedContextLeaks, privacy.overlayRetainedTextLeaks,
            privacy.artifactLeaks,
            privacy.argumentVectorLeaks, privacy.featureLogInvocationSourceFindings,
            privacy.crashMetadataSinkReferenceSourceFindings,
            privacy.ephemeralPersistenceSourceFindings,
            privacy.ephemeralFilenameDiagnosticSourceFindings,
            privacy.prohibitedNetworkAPISourceFindings, privacy.secureFieldContextReadRequests]
        if requiredProbeCounts.contains(where: { $0 == nil || $0 != 0 })
            || privacy.canaryProbeCount <= 0 || privacy.configuredSnippetTrapCount <= 0
            || leakCounts.contains(where: { $0 != 0 })
            || !isSHA256(privacy.staticAuditBoundSourceManifestSHA256)
            || privacy.staticAuditBoundSourceManifestSHA256 != artifact.identity.hostedSourceManifestSHA256
            || privacy.maximumAXUTF16ReadPerSide > 512 || privacy.maximumAXUTF16ReadPerSide <= 0
            || privacy.maximumAXGraphemesPerSide > 256 || privacy.maximumAXGraphemesPerSide <= 0
            || privacy.maximumAXContextBytes > 8_192 || privacy.maximumAXContextBytes <= 0 {
            failures.append("privacy-gate")
        }

        let lifecycle = artifact.lifecycle
        if lifecycle.randomizedSessions < 1_000 || lifecycle.rapidCancelRestartCases < 250
            || lifecycle.targetTransitions < 10_000
            || lifecycle.helperCrashScenariosExpected <= 0
            || lifecycle.helperCrashScenariosPassed != lifecycle.helperCrashScenariosExpected
            || lifecycle.malformedProtocolScenariosExpected <= 0
            || lifecycle.malformedProtocolScenariosPassed != lifecycle.malformedProtocolScenariosExpected
            || lifecycle.authoritativeFinishCalls <= 0
            || lifecycle.maximumAuthoritativeFinishCallsPerSession != 1
            || lifecycle.coordinatorSecondFinalInferenceAttempts != 0
            || lifecycle.expectedFinalInsertionCount <= 0
            || lifecycle.finalInsertionCount != lifecycle.expectedFinalInsertionCount {
            failures.append("lifecycle-gate")
        }
        return .init(failures: unique(failures))
    }

    private static func commonFailures(artifact: LiveContextBenchmarkArtifact, corpus: ContinuationDirectiveCorpus, expectedIdentity: LiveContextExpectedIdentity?, now: Date, maximumAge: TimeInterval) -> [String] {
        var failures: [String] = []
        if artifact.schemaVersion != LiveContextBenchmarkArtifact.currentSchemaVersion { failures.append("unsupported-artifact-schema") }
        let age = now.timeIntervalSince(artifact.generatedAt)
        if !age.isFinite || age < 0 || maximumAge <= 0 || age > maximumAge { failures.append("stale-artifact") }
        if artifact.identity.treeIsDirty { failures.append("dirty-git-tree") }
        if !isGitSHA(artifact.identity.gitSHA) || !isSHA256(artifact.identity.manifestSHA256)
            || !isSHA256(artifact.identity.corpusSHA256) || !isSHA256(artifact.identity.modelSHA256)
            || !isSHA256(artifact.identity.runtimeSHA256) || artifact.identity.modelIdentity.isEmpty
            || artifact.identity.runtimeIdentity.isEmpty || artifact.identity.threadCount <= 0
            || artifact.identity.language.isEmpty || !artifact.identity.realtimePacing
            || artifact.identity.liveProtocolVersion != 2
            || artifact.identity.liveRuntimeIdentifier.isEmpty
            || !isSHA256(artifact.identity.liveModelIdentifier)
            || (artifact.identity.liveVADIdentifier != nil && !isSHA256(artifact.identity.liveVADIdentifier ?? ""))
            || !isSHA256(artifact.identity.hostedReceiptSHA256)
            || !isSHA256(artifact.identity.adversarialReceiptSHA256)
            || !isSHA256(artifact.identity.audioFixtureSHA256)
            || !isSHA256(artifact.identity.hostedSourceManifestSHA256)
            || !isSHA256(artifact.identity.helperSourceSHA256)
            || !isSHA256(artifact.identity.adversarialHarnessSHA256)
            || artifact.identity.hardware.isEmpty || artifact.identity.operatingSystem.isEmpty
            || artifact.identity.powerState.isEmpty
            || (artifact.identity.vadModelSHA256 != nil && !isSHA256(artifact.identity.vadModelSHA256 ?? "")) {
            failures.append("missing-or-invalid-identity")
        }
        if artifact.identity.modelIdentity.contains("/") || artifact.identity.modelIdentity.contains("\\") {
            failures.append("model-path-not-redacted")
        }
        if let expectedIdentity {
            if artifact.identity.gitSHA != expectedIdentity.gitSHA { failures.append("git-sha-mismatch") }
            if artifact.identity.manifestSHA256 != expectedIdentity.manifestSHA256 { failures.append("manifest-hash-mismatch") }
            if artifact.identity.modelSHA256 != expectedIdentity.modelSHA256 { failures.append("wrong-model") }
            if artifact.identity.runtimeSHA256 != expectedIdentity.runtimeSHA256 { failures.append("runtime-hash-mismatch") }
            if artifact.identity.vadModelSHA256 != expectedIdentity.vadModelSHA256 { failures.append("vad-model-hash-mismatch") }
            if artifact.identity.threadCount != expectedIdentity.threadCount || expectedIdentity.threadCount <= 0 {
                failures.append("thread-count-mismatch")
            }
            if artifact.identity.language != expectedIdentity.language || expectedIdentity.language.isEmpty {
                failures.append("language-mismatch")
            }
            if artifact.identity.hostedReceiptSHA256 != expectedIdentity.hostedReceiptSHA256 {
                failures.append("hosted-receipt-hash-mismatch")
            }
            if artifact.identity.adversarialReceiptSHA256 != expectedIdentity.adversarialReceiptSHA256 {
                failures.append("adversarial-receipt-hash-mismatch")
            }
            if artifact.identity.audioFixtureSHA256 != expectedIdentity.audioFixtureSHA256 {
                failures.append("audio-fixture-hash-mismatch")
            }
            if artifact.identity.hostedSourceManifestSHA256 != expectedIdentity.hostedSourceManifestSHA256 {
                failures.append("hosted-source-manifest-hash-mismatch")
            }
            if artifact.identity.helperSourceSHA256 != expectedIdentity.helperSourceSHA256 {
                failures.append("helper-source-hash-mismatch")
            }
            if artifact.identity.adversarialHarnessSHA256 != expectedIdentity.adversarialHarnessSHA256 {
                failures.append("adversarial-harness-hash-mismatch")
            }
            if expectedIdentity.expectedCorpusRowCount <= 0
                || artifact.expectedCorpusRowCount != expectedIdentity.expectedCorpusRowCount {
                failures.append("expected-corpus-row-count-mismatch")
            }
        }
        if let corpusHash = try? corpus.sha256() {
            if corpusHash != artifact.identity.corpusSHA256 { failures.append("corpus-hash-mismatch") }
        } else {
            failures.append("corpus-hash-unavailable")
        }
        if artifact.expectedCorpusRowCount <= 0 || artifact.observedCorpusRowCount <= 0
            || artifact.expectedCorpusRowCount != artifact.observedCorpusRowCount {
            failures.append("corpus-row-count-mismatch")
        }
        if artifact.declaredFailureCount < 0 || artifact.declaredSkipCount < 0
            || artifact.declaredFailureCount != artifact.failures.count
            || artifact.declaredSkipCount != artifact.skips.count
            || artifact.failures.contains(where: { $0.id.isEmpty || $0.reasonCode.isEmpty })
            || artifact.skips.contains(where: { $0.id.isEmpty || $0.reasonCode.isEmpty }) {
            failures.append("failure-row-accounting")
        }
        if let encoded = try? JSONEncoder().encode(artifact) {
            let sentinels = LiveContextReceiptManifest.hostedPrivacyCanaries(
                gitSHA: artifact.identity.gitSHA
            ) + ["STENO-PUBLIC-PROTOCOL-CANARY-V1"]
            if sentinels.contains(where: { encoded.range(of: Data($0.utf8)) != nil }) {
                failures.append("raw-artifact-canary-leak")
            }
        } else {
            failures.append("artifact-encoding-unavailable")
        }
        return failures
    }

    private static func valid(_ distribution: LiveLatencyDistribution) -> Bool {
        guard distribution.count > 0, distribution.count == distribution.samplesMS.count,
              finiteNonnegative(distribution.samplesMS) else { return false }
        let computed = LiveLatencyDistribution.summarize(distribution.samplesMS)
        return equal(distribution.p50MS, computed.p50MS)
            && equal(distribution.p95MS, computed.p95MS)
            && equal(distribution.p99MS, computed.p99MS)
    }

    private static func finiteNonnegative(_ values: [Double]) -> Bool {
        values.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    private static func equal(_ lhs: Double?, _ rhs: Double?) -> Bool {
        guard let lhs, let rhs, lhs.isFinite, rhs.isFinite else { return false }
        return abs(lhs - rhs) <= 0.000_001
    }

    private static func exceeds(_ value: Double?, _ threshold: Double) -> Bool {
        guard let value, value.isFinite else { return true }
        return value > threshold
    }

    private static func isGitSHA(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func unique(_ failures: [String]) -> [String] {
        var seen: Set<String> = []
        return failures.filter { seen.insert($0).inserted }
    }
}

private enum LiveContextHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
