import Foundation
import StenoKit

public enum BenchmarkEvidenceTier: String, Sendable, Codable, Equatable {
    case smokeFixture = "smokeFixture"
    case releaseSignoff = "releaseSignoff"
}

public struct BenchmarkHardwareProfile: Sendable, Codable, Equatable {
    public var chipClass: AppleSiliconChipClass
    public var memoryGB: Int
    public var modelID: WhisperModelID

    public init(chipClass: AppleSiliconChipClass, memoryGB: Int, modelID: WhisperModelID) {
        self.chipClass = chipClass
        self.memoryGB = memoryGB
        self.modelID = modelID
    }
}

public struct BenchmarkManifest: Sendable, Codable {
    public var schemaVersion: String
    public var benchmarkName: String
    public var evidenceTier: BenchmarkEvidenceTier
    public var hardwareProfile: BenchmarkHardwareProfile?
    public var scoring: ScoringConfiguration
    public var samples: [BenchmarkSample]

    public init(
        schemaVersion: String = "steno-benchmark-manifest/v1",
        benchmarkName: String = "Steno Benchmark",
        evidenceTier: BenchmarkEvidenceTier = .smokeFixture,
        hardwareProfile: BenchmarkHardwareProfile? = nil,
        scoring: ScoringConfiguration = ScoringConfiguration(),
        samples: [BenchmarkSample]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmarkName = benchmarkName
        self.evidenceTier = evidenceTier
        self.hardwareProfile = hardwareProfile
        self.scoring = scoring
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case benchmarkName
        case evidenceTier
        case hardwareProfile
        case scoring
        case samples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "steno-benchmark-manifest/v1"
        benchmarkName = try container.decodeIfPresent(String.self, forKey: .benchmarkName) ?? "Steno Benchmark"
        evidenceTier = try container.decodeIfPresent(BenchmarkEvidenceTier.self, forKey: .evidenceTier) ?? .smokeFixture
        hardwareProfile = try container.decodeIfPresent(BenchmarkHardwareProfile.self, forKey: .hardwareProfile)
        scoring = try container.decodeIfPresent(ScoringConfiguration.self, forKey: .scoring) ?? ScoringConfiguration()
        samples = try container.decode([BenchmarkSample].self, forKey: .samples)
    }
}

public struct ScoringConfiguration: Sendable, Codable {
    public var normalization: NormalizationPolicy

    public init(normalization: NormalizationPolicy = NormalizationPolicy()) {
        self.normalization = normalization
    }
}

public struct NormalizationPolicy: Sendable, Codable {
    public var version: String
    public var lowercase: Bool
    public var collapseWhitespace: Bool
    public var trimWhitespace: Bool
    public var stripPunctuation: Bool
    public var keepApostrophes: Bool

    public init(
        version: String = "steno-normalization-v1",
        lowercase: Bool = true,
        collapseWhitespace: Bool = true,
        trimWhitespace: Bool = true,
        stripPunctuation: Bool = true,
        keepApostrophes: Bool = true
    ) {
        self.version = version
        self.lowercase = lowercase
        self.collapseWhitespace = collapseWhitespace
        self.trimWhitespace = trimWhitespace
        self.stripPunctuation = stripPunctuation
        self.keepApostrophes = keepApostrophes
    }
}

public enum BenchmarkAudioSource: String, Sendable, Codable, Equatable {
    case librispeech
    case syntheticSpeech
    case syntheticSilence
    case syntheticNoise
    case microphone
}

public enum BenchmarkIntentLabel: String, Sendable, Codable, Equatable {
    case repair
    case literal
    case termRecall
    case command
    case noSpeech
    case fillerRemovable
    case fillerMeaningBearing
}

public enum BenchmarkAppContextPreset: String, Sendable, Codable, Equatable {
    case unknown
    case editor
    case terminal
    case ide

    public var appContext: AppContext {
        switch self {
        case .unknown:
            return .unknown
        case .editor:
            return AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
        case .terminal:
            return AppContext(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")
        case .ide:
            return AppContext(
                bundleIdentifier: "com.microsoft.VSCode",
                appName: "Visual Studio Code",
                isIDE: true
            )
        }
    }
}

public struct BenchmarkSample: Sendable, Codable {
    public var id: String
    public var dataset: String
    public var audioPath: String
    public var referenceText: String
    public var languageHint: String?
    public var audioDurationMS: Int?
    public var audioSource: BenchmarkAudioSource?
    public var intentLabels: [BenchmarkIntentLabel]
    public var preservedPhrases: [String]
    public var appContextPreset: BenchmarkAppContextPreset?

    public init(
        id: String,
        dataset: String,
        audioPath: String,
        referenceText: String,
        languageHint: String? = nil,
        audioDurationMS: Int? = nil,
        audioSource: BenchmarkAudioSource? = nil,
        intentLabels: [BenchmarkIntentLabel] = [],
        preservedPhrases: [String] = [],
        appContextPreset: BenchmarkAppContextPreset? = nil
    ) {
        self.id = id
        self.dataset = dataset
        self.audioPath = audioPath
        self.referenceText = referenceText
        self.languageHint = languageHint
        self.audioDurationMS = audioDurationMS
        self.audioSource = audioSource
        self.intentLabels = intentLabels
        self.preservedPhrases = preservedPhrases
        self.appContextPreset = appContextPreset
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dataset
        case audioPath
        case referenceText
        case languageHint
        case audioDurationMS
        case audioSource
        case intentLabels
        case preservedPhrases
        case appContextPreset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        dataset = try container.decode(String.self, forKey: .dataset)
        audioPath = try container.decode(String.self, forKey: .audioPath)
        referenceText = try container.decode(String.self, forKey: .referenceText)
        languageHint = try container.decodeIfPresent(String.self, forKey: .languageHint)
        audioDurationMS = try container.decodeIfPresent(Int.self, forKey: .audioDurationMS)
        audioSource = try container.decodeIfPresent(BenchmarkAudioSource.self, forKey: .audioSource)
        intentLabels = try container.decodeIfPresent([BenchmarkIntentLabel].self, forKey: .intentLabels) ?? []
        preservedPhrases = try container.decodeIfPresent([String].self, forKey: .preservedPhrases) ?? []
        appContextPreset = try container.decodeIfPresent(BenchmarkAppContextPreset.self, forKey: .appContextPreset)
    }
}

public struct BenchmarkLexiconFile: Sendable, Codable {
    public var schemaVersion: String
    public var entries: [BenchmarkLexiconEntry]

    public init(
        schemaVersion: String = "steno-lexicon-v1",
        entries: [BenchmarkLexiconEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

public struct BenchmarkLexiconEntry: Sendable, Codable {
    public var term: String
    public var preferred: String
    public var bundleID: String?
    public var phoneticRecovery: PhoneticRecoveryPolicy?

    public init(
        term: String,
        preferred: String,
        bundleID: String? = nil,
        phoneticRecovery: PhoneticRecoveryPolicy? = nil
    ) {
        self.term = term
        self.preferred = preferred
        self.bundleID = bundleID
        self.phoneticRecovery = phoneticRecovery
    }

    public var stenoEntry: LexiconEntry {
        if let bundleID, !bundleID.isEmpty {
            return LexiconEntry(
                term: term,
                preferred: preferred,
                scope: .app(bundleID: bundleID),
                phoneticRecovery: phoneticRecovery ?? .off
            )
        }
        return LexiconEntry(
            term: term,
            preferred: preferred,
            scope: .global,
            phoneticRecovery: phoneticRecovery ?? .off
        )
    }
}

public enum BenchmarkSampleStatus: String, Sendable, Codable {
    case success
    case failed
    case skipped
}

public struct BenchmarkRuntimeMetadata: Sendable, Codable {
    public var generatedAt: Date
    public var hostOSVersion: String
    public var toolVersion: String

    public init(
        generatedAt: Date = Date(),
        hostOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        toolVersion: String = "steno-benchmark-cli/v1"
    ) {
        self.generatedAt = generatedAt
        self.hostOSVersion = hostOSVersion
        self.toolVersion = toolVersion
    }
}

public struct BenchmarkWhisperConfiguration: Sendable, Codable {
    public var whisperCLIPath: String
    public var modelPath: String
    public var additionalArguments: [String]

    public init(
        whisperCLIPath: String,
        modelPath: String,
        additionalArguments: [String] = []
    ) {
        self.whisperCLIPath = whisperCLIPath
        self.modelPath = modelPath
        self.additionalArguments = additionalArguments
    }
}

public struct BenchmarkTextQualityMetrics: Sendable, Codable {
    public var wer: Double
    public var cer: Double
    public var wordEdits: Int
    public var wordReferenceCount: Int
    public var charEdits: Int
    public var charReferenceCount: Int

    public init(
        wer: Double,
        cer: Double,
        wordEdits: Int,
        wordReferenceCount: Int,
        charEdits: Int,
        charReferenceCount: Int
    ) {
        self.wer = wer
        self.cer = cer
        self.wordEdits = wordEdits
        self.wordReferenceCount = wordReferenceCount
        self.charEdits = charEdits
        self.charReferenceCount = charReferenceCount
    }
}

public struct RawEngineSampleResult: Sendable, Codable {
    public var id: String
    public var dataset: String
    public var audioPath: String
    public var referenceText: String
    public var hypothesisText: String?
    public var languageHint: String?
    public var status: BenchmarkSampleStatus
    public var errorMessage: String?
    public var elapsedMS: Int
    public var audioDurationMS: Int?
    public var rtf: Double?
    public var metrics: BenchmarkTextQualityMetrics?

    public init(
        id: String,
        dataset: String,
        audioPath: String,
        referenceText: String,
        hypothesisText: String?,
        languageHint: String?,
        status: BenchmarkSampleStatus,
        errorMessage: String?,
        elapsedMS: Int,
        audioDurationMS: Int?,
        rtf: Double?,
        metrics: BenchmarkTextQualityMetrics?
    ) {
        self.id = id
        self.dataset = dataset
        self.audioPath = audioPath
        self.referenceText = referenceText
        self.hypothesisText = hypothesisText
        self.languageHint = languageHint
        self.status = status
        self.errorMessage = errorMessage
        self.elapsedMS = elapsedMS
        self.audioDurationMS = audioDurationMS
        self.rtf = rtf
        self.metrics = metrics
    }
}

public struct RawEngineAggregate: Sendable, Codable {
    public var totalSamples: Int
    public var succeeded: Int
    public var failed: Int
    public var failureRate: Double
    public var wer: Double?
    public var cer: Double?
    public var meanLatencyMS: Double?
    public var p50LatencyMS: Double?
    public var p90LatencyMS: Double?
    public var p99LatencyMS: Double?
    public var meanRTF: Double?

    public init(
        totalSamples: Int,
        succeeded: Int,
        failed: Int,
        failureRate: Double,
        wer: Double?,
        cer: Double?,
        meanLatencyMS: Double?,
        p50LatencyMS: Double?,
        p90LatencyMS: Double?,
        p99LatencyMS: Double?,
        meanRTF: Double?
    ) {
        self.totalSamples = totalSamples
        self.succeeded = succeeded
        self.failed = failed
        self.failureRate = failureRate
        self.wer = wer
        self.cer = cer
        self.meanLatencyMS = meanLatencyMS
        self.p50LatencyMS = p50LatencyMS
        self.p90LatencyMS = p90LatencyMS
        self.p99LatencyMS = p99LatencyMS
        self.meanRTF = meanRTF
    }
}

public struct RawEngineOutput: Sendable, Codable {
    public var schemaVersion: String
    public var benchmarkName: String
    public var evidenceTier: BenchmarkEvidenceTier
    public var hardwareProfile: BenchmarkHardwareProfile?
    public var runtime: BenchmarkRuntimeMetadata
    public var manifestSchemaVersion: String
    public var normalizationPolicy: NormalizationPolicy
    public var whisperConfiguration: BenchmarkWhisperConfiguration
    public var summary: RawEngineAggregate
    public var datasetBreakdown: [String: RawEngineAggregate]
    public var samples: [RawEngineSampleResult]

    public init(
        schemaVersion: String = "steno-raw-engine-results/v1",
        benchmarkName: String,
        evidenceTier: BenchmarkEvidenceTier = .smokeFixture,
        hardwareProfile: BenchmarkHardwareProfile? = nil,
        runtime: BenchmarkRuntimeMetadata = BenchmarkRuntimeMetadata(),
        manifestSchemaVersion: String,
        normalizationPolicy: NormalizationPolicy,
        whisperConfiguration: BenchmarkWhisperConfiguration,
        summary: RawEngineAggregate,
        datasetBreakdown: [String: RawEngineAggregate],
        samples: [RawEngineSampleResult]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmarkName = benchmarkName
        self.evidenceTier = evidenceTier
        self.hardwareProfile = hardwareProfile
        self.runtime = runtime
        self.manifestSchemaVersion = manifestSchemaVersion
        self.normalizationPolicy = normalizationPolicy
        self.whisperConfiguration = whisperConfiguration
        self.summary = summary
        self.datasetBreakdown = datasetBreakdown
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case benchmarkName
        case evidenceTier
        case hardwareProfile
        case runtime
        case manifestSchemaVersion
        case normalizationPolicy
        case whisperConfiguration
        case summary
        case datasetBreakdown
        case samples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "steno-raw-engine-results/v1"
        benchmarkName = try container.decode(String.self, forKey: .benchmarkName)
        evidenceTier = try container.decodeIfPresent(BenchmarkEvidenceTier.self, forKey: .evidenceTier) ?? .smokeFixture
        hardwareProfile = try container.decodeIfPresent(BenchmarkHardwareProfile.self, forKey: .hardwareProfile)
        runtime = try container.decodeIfPresent(BenchmarkRuntimeMetadata.self, forKey: .runtime) ?? BenchmarkRuntimeMetadata()
        manifestSchemaVersion = try container.decode(String.self, forKey: .manifestSchemaVersion)
        normalizationPolicy = try container.decode(NormalizationPolicy.self, forKey: .normalizationPolicy)
        whisperConfiguration = try container.decode(BenchmarkWhisperConfiguration.self, forKey: .whisperConfiguration)
        summary = try container.decode(RawEngineAggregate.self, forKey: .summary)
        datasetBreakdown = try container.decodeIfPresent([String: RawEngineAggregate].self, forKey: .datasetBreakdown) ?? [:]
        samples = try container.decodeIfPresent([RawEngineSampleResult].self, forKey: .samples) ?? []
    }
}

public enum PipelineOutcome: String, Sendable, Codable {
    case improved
    case unchanged
    case regressed
    case unscored
}

public struct PipelineSampleDelta: Sendable, Codable {
    public var werDelta: Double
    public var cerDelta: Double

    public init(werDelta: Double, cerDelta: Double) {
        self.werDelta = werDelta
        self.cerDelta = cerDelta
    }
}

public struct PipelineCoordinatorObservation: Sendable, Codable, Equatable {
    public var timingBreakdownMS: PipelineCoordinatorTimingBreakdown?
    public var iteration: Int
    public var latencyMS: Int?
    public var status: BenchmarkSampleStatus
    public var insertResult: InsertResult?
    public var errorMessage: String?

    public init(
        timingBreakdownMS: PipelineCoordinatorTimingBreakdown? = nil,
        iteration: Int,
        latencyMS: Int?,
        status: BenchmarkSampleStatus,
        insertResult: InsertResult?,
        errorMessage: String?
    ) {
        self.timingBreakdownMS = timingBreakdownMS
        self.iteration = iteration
        self.latencyMS = latencyMS
        self.status = status
        self.insertResult = insertResult
        self.errorMessage = errorMessage
    }
}

public struct PipelineCoordinatorTimingBreakdown: Sendable, Codable, Equatable {
    public var transcriptionMS: Int?
    public var cleanupMS: Int?
    public var insertionMS: Int?
    public var historyMS: Int?

    public init(
        transcriptionMS: Int? = nil,
        cleanupMS: Int? = nil,
        insertionMS: Int? = nil,
        historyMS: Int? = nil
    ) {
        self.transcriptionMS = transcriptionMS
        self.cleanupMS = cleanupMS
        self.insertionMS = insertionMS
        self.historyMS = historyMS
    }
}

public struct PipelineSampleResult: Sendable, Codable {
    public var id: String
    public var dataset: String
    public var referenceText: String
    public var rawText: String?
    public var cleanedText: String?
    public var status: BenchmarkSampleStatus
    public var errorMessage: String?
    public var edits: [TranscriptEdit]
    public var removedFillers: [String]
    public var rawMetrics: BenchmarkTextQualityMetrics?
    public var cleanedMetrics: BenchmarkTextQualityMetrics?
    public var delta: PipelineSampleDelta?
    public var outcome: PipelineOutcome
    public var coordinatorObservations: [PipelineCoordinatorObservation]

    public init(
        id: String,
        dataset: String,
        referenceText: String,
        rawText: String?,
        cleanedText: String?,
        status: BenchmarkSampleStatus,
        errorMessage: String?,
        edits: [TranscriptEdit],
        removedFillers: [String],
        rawMetrics: BenchmarkTextQualityMetrics?,
        cleanedMetrics: BenchmarkTextQualityMetrics?,
        delta: PipelineSampleDelta?,
        outcome: PipelineOutcome,
        coordinatorObservations: [PipelineCoordinatorObservation] = []
    ) {
        self.id = id
        self.dataset = dataset
        self.referenceText = referenceText
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.status = status
        self.errorMessage = errorMessage
        self.edits = edits
        self.removedFillers = removedFillers
        self.rawMetrics = rawMetrics
        self.cleanedMetrics = cleanedMetrics
        self.delta = delta
        self.outcome = outcome
        self.coordinatorObservations = coordinatorObservations
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dataset
        case referenceText
        case rawText
        case cleanedText
        case status
        case errorMessage
        case edits
        case removedFillers
        case rawMetrics
        case cleanedMetrics
        case delta
        case outcome
        case coordinatorObservations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        dataset = try container.decode(String.self, forKey: .dataset)
        referenceText = try container.decode(String.self, forKey: .referenceText)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        cleanedText = try container.decodeIfPresent(String.self, forKey: .cleanedText)
        status = try container.decode(BenchmarkSampleStatus.self, forKey: .status)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        edits = try container.decodeIfPresent([TranscriptEdit].self, forKey: .edits) ?? []
        removedFillers = try container.decodeIfPresent([String].self, forKey: .removedFillers) ?? []
        rawMetrics = try container.decodeIfPresent(BenchmarkTextQualityMetrics.self, forKey: .rawMetrics)
        cleanedMetrics = try container.decodeIfPresent(BenchmarkTextQualityMetrics.self, forKey: .cleanedMetrics)
        delta = try container.decodeIfPresent(PipelineSampleDelta.self, forKey: .delta)
        outcome = try container.decodeIfPresent(PipelineOutcome.self, forKey: .outcome) ?? .unscored
        coordinatorObservations = try container.decodeIfPresent([PipelineCoordinatorObservation].self, forKey: .coordinatorObservations) ?? []
    }
}

public struct PipelineLexiconSummary: Sendable, Codable {
    public var totalAppliedEdits: Int
    public var editsMatchingReference: Int
    public var editsNotMatchingReference: Int
    public var referenceMatchAccuracy: Double?

    public init(
        totalAppliedEdits: Int,
        editsMatchingReference: Int,
        editsNotMatchingReference: Int,
        referenceMatchAccuracy: Double?
    ) {
        self.totalAppliedEdits = totalAppliedEdits
        self.editsMatchingReference = editsMatchingReference
        self.editsNotMatchingReference = editsNotMatchingReference
        self.referenceMatchAccuracy = referenceMatchAccuracy
    }
}

public struct PipelineFillerImpactSummary: Sendable, Codable {
    public var samplesWithFillerRemovals: Int
    public var totalRemovedFillers: Int
    public var rawWEROnFillerSamples: Double?
    public var cleanedWEROnFillerSamples: Double?
    public var deltaWEROnFillerSamples: Double?
    public var improved: Int
    public var unchanged: Int
    public var regressed: Int

    public init(
        samplesWithFillerRemovals: Int,
        totalRemovedFillers: Int,
        rawWEROnFillerSamples: Double?,
        cleanedWEROnFillerSamples: Double?,
        deltaWEROnFillerSamples: Double?,
        improved: Int,
        unchanged: Int,
        regressed: Int
    ) {
        self.samplesWithFillerRemovals = samplesWithFillerRemovals
        self.totalRemovedFillers = totalRemovedFillers
        self.rawWEROnFillerSamples = rawWEROnFillerSamples
        self.cleanedWEROnFillerSamples = cleanedWEROnFillerSamples
        self.deltaWEROnFillerSamples = deltaWEROnFillerSamples
        self.improved = improved
        self.unchanged = unchanged
        self.regressed = regressed
    }
}

public struct PipelineAggregate: Sendable, Codable {
    public var totalSamples: Int
    public var scoredSamples: Int
    public var rawWER: Double?
    public var rawCER: Double?
    public var cleanedWER: Double?
    public var cleanedCER: Double?
    public var werDelta: Double?
    public var cerDelta: Double?
    public var improved: Int
    public var unchanged: Int
    public var regressed: Int
    public var unscored: Int
    public var termRecallAccuracy: Double?
    public var repairMarkerPreservationRate: Double?
    public var repairResolutionRate: Double?
    public var repairExactMatchRate: Double?
    public var unintendedRewriteRate: Double?
    public var literalRepairPhrasePreservationRate: Double?
    public var punctuationArtifactRate: Double?
    public var commandPassthroughAccuracy: Double?
    public var commandPassthroughCoverageRate: Double?
    public var noSpeechFalseInsertRate: Double?
    public var p50LatencyMS: Double?
    public var p90LatencyMS: Double?
    public var p99LatencyMS: Double?
    public var lexicon: PipelineLexiconSummary
    public var fillerImpact: PipelineFillerImpactSummary

    public init(
        totalSamples: Int,
        scoredSamples: Int,
        rawWER: Double?,
        rawCER: Double?,
        cleanedWER: Double?,
        cleanedCER: Double?,
        werDelta: Double?,
        cerDelta: Double?,
        improved: Int,
        unchanged: Int,
        regressed: Int,
        unscored: Int,
        termRecallAccuracy: Double? = nil,
        repairMarkerPreservationRate: Double? = nil,
        repairResolutionRate: Double? = nil,
        repairExactMatchRate: Double? = nil,
        unintendedRewriteRate: Double? = nil,
        literalRepairPhrasePreservationRate: Double? = nil,
        punctuationArtifactRate: Double? = nil,
        commandPassthroughAccuracy: Double? = nil,
        commandPassthroughCoverageRate: Double? = nil,
        noSpeechFalseInsertRate: Double? = nil,
        p50LatencyMS: Double? = nil,
        p90LatencyMS: Double? = nil,
        p99LatencyMS: Double? = nil,
        lexicon: PipelineLexiconSummary,
        fillerImpact: PipelineFillerImpactSummary
    ) {
        self.totalSamples = totalSamples
        self.scoredSamples = scoredSamples
        self.rawWER = rawWER
        self.rawCER = rawCER
        self.cleanedWER = cleanedWER
        self.cleanedCER = cleanedCER
        self.werDelta = werDelta
        self.cerDelta = cerDelta
        self.improved = improved
        self.unchanged = unchanged
        self.regressed = regressed
        self.unscored = unscored
        self.termRecallAccuracy = termRecallAccuracy
        self.repairMarkerPreservationRate = repairMarkerPreservationRate
        self.repairResolutionRate = repairResolutionRate
        self.repairExactMatchRate = repairExactMatchRate
        self.unintendedRewriteRate = unintendedRewriteRate
        self.literalRepairPhrasePreservationRate = literalRepairPhrasePreservationRate
        self.punctuationArtifactRate = punctuationArtifactRate
        self.commandPassthroughAccuracy = commandPassthroughAccuracy
        self.commandPassthroughCoverageRate = commandPassthroughCoverageRate
        self.noSpeechFalseInsertRate = noSpeechFalseInsertRate
        self.p50LatencyMS = p50LatencyMS
        self.p90LatencyMS = p90LatencyMS
        self.p99LatencyMS = p99LatencyMS
        self.lexicon = lexicon
        self.fillerImpact = fillerImpact
    }

    enum CodingKeys: String, CodingKey {
        case totalSamples
        case scoredSamples
        case rawWER
        case rawCER
        case cleanedWER
        case cleanedCER
        case werDelta
        case cerDelta
        case improved
        case unchanged
        case regressed
        case unscored
        case termRecallAccuracy
        case repairMarkerPreservationRate
        case repairResolutionRate
        case repairExactMatchRate
        case unintendedRewriteRate
        case literalRepairPhrasePreservationRate
        case punctuationArtifactRate
        case commandPassthroughAccuracy
        case commandPassthroughCoverageRate
        case noSpeechFalseInsertRate
        case p50LatencyMS
        case p90LatencyMS
        case p99LatencyMS
        case lexicon
        case fillerImpact
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalSamples = try container.decode(Int.self, forKey: .totalSamples)
        scoredSamples = try container.decode(Int.self, forKey: .scoredSamples)
        rawWER = try container.decodeIfPresent(Double.self, forKey: .rawWER)
        rawCER = try container.decodeIfPresent(Double.self, forKey: .rawCER)
        cleanedWER = try container.decodeIfPresent(Double.self, forKey: .cleanedWER)
        cleanedCER = try container.decodeIfPresent(Double.self, forKey: .cleanedCER)
        werDelta = try container.decodeIfPresent(Double.self, forKey: .werDelta)
        cerDelta = try container.decodeIfPresent(Double.self, forKey: .cerDelta)
        improved = try container.decode(Int.self, forKey: .improved)
        unchanged = try container.decode(Int.self, forKey: .unchanged)
        regressed = try container.decode(Int.self, forKey: .regressed)
        unscored = try container.decode(Int.self, forKey: .unscored)
        termRecallAccuracy = try container.decodeIfPresent(Double.self, forKey: .termRecallAccuracy)
        repairMarkerPreservationRate = try container.decodeIfPresent(Double.self, forKey: .repairMarkerPreservationRate)
        repairResolutionRate = try container.decodeIfPresent(Double.self, forKey: .repairResolutionRate)
        repairExactMatchRate = try container.decodeIfPresent(Double.self, forKey: .repairExactMatchRate)
        unintendedRewriteRate = try container.decodeIfPresent(Double.self, forKey: .unintendedRewriteRate)
        literalRepairPhrasePreservationRate = try container.decodeIfPresent(Double.self, forKey: .literalRepairPhrasePreservationRate)
        punctuationArtifactRate = try container.decodeIfPresent(Double.self, forKey: .punctuationArtifactRate)
        commandPassthroughAccuracy = try container.decodeIfPresent(Double.self, forKey: .commandPassthroughAccuracy)
        commandPassthroughCoverageRate = try container.decodeIfPresent(Double.self, forKey: .commandPassthroughCoverageRate)
        noSpeechFalseInsertRate = try container.decodeIfPresent(Double.self, forKey: .noSpeechFalseInsertRate)
        p50LatencyMS = try container.decodeIfPresent(Double.self, forKey: .p50LatencyMS)
        p90LatencyMS = try container.decodeIfPresent(Double.self, forKey: .p90LatencyMS)
        p99LatencyMS = try container.decodeIfPresent(Double.self, forKey: .p99LatencyMS)
        lexicon = try container.decode(PipelineLexiconSummary.self, forKey: .lexicon)
        fillerImpact = try container.decode(PipelineFillerImpactSummary.self, forKey: .fillerImpact)
    }
}

public struct PipelineOutput: Sendable, Codable {
    public var schemaVersion: String
    public var benchmarkName: String
    public var evidenceTier: BenchmarkEvidenceTier
    public var hardwareProfile: BenchmarkHardwareProfile?
    public var runtime: BenchmarkRuntimeMetadata
    public var profile: StyleProfile
    public var lexiconEntryCount: Int
    public var normalizationPolicy: NormalizationPolicy
    public var summary: PipelineAggregate
    public var samples: [PipelineSampleResult]

    public init(
        schemaVersion: String = "steno-pipeline-results/v1",
        benchmarkName: String,
        evidenceTier: BenchmarkEvidenceTier = .smokeFixture,
        hardwareProfile: BenchmarkHardwareProfile? = nil,
        runtime: BenchmarkRuntimeMetadata = BenchmarkRuntimeMetadata(),
        profile: StyleProfile,
        lexiconEntryCount: Int,
        normalizationPolicy: NormalizationPolicy,
        summary: PipelineAggregate,
        samples: [PipelineSampleResult]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmarkName = benchmarkName
        self.evidenceTier = evidenceTier
        self.hardwareProfile = hardwareProfile
        self.runtime = runtime
        self.profile = profile
        self.lexiconEntryCount = lexiconEntryCount
        self.normalizationPolicy = normalizationPolicy
        self.summary = summary
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case benchmarkName
        case evidenceTier
        case hardwareProfile
        case runtime
        case profile
        case lexiconEntryCount
        case normalizationPolicy
        case summary
        case samples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "steno-pipeline-results/v1"
        benchmarkName = try container.decode(String.self, forKey: .benchmarkName)
        evidenceTier = try container.decodeIfPresent(BenchmarkEvidenceTier.self, forKey: .evidenceTier) ?? .smokeFixture
        hardwareProfile = try container.decodeIfPresent(BenchmarkHardwareProfile.self, forKey: .hardwareProfile)
        runtime = try container.decodeIfPresent(BenchmarkRuntimeMetadata.self, forKey: .runtime) ?? BenchmarkRuntimeMetadata()
        profile = try container.decode(StyleProfile.self, forKey: .profile)
        lexiconEntryCount = try container.decodeIfPresent(Int.self, forKey: .lexiconEntryCount) ?? 0
        normalizationPolicy = try container.decode(NormalizationPolicy.self, forKey: .normalizationPolicy)
        summary = try container.decode(PipelineAggregate.self, forKey: .summary)
        samples = try container.decodeIfPresent([PipelineSampleResult].self, forKey: .samples) ?? []
    }
}

public struct MacSanityChecklist: Sendable, Codable {
    public struct Item: Sendable, Codable {
        public var id: String
        public var title: String
        public var status: String
        public var notes: String?

        public init(id: String, title: String, status: String = "pending", notes: String? = nil) {
            self.id = id
            self.title = title
            self.status = status
            self.notes = notes
        }
    }

    public var schemaVersion: String
    public var generatedAt: Date
    public var appBuildSHA: String
    public var macOSVersion: String
    public var overallStatus: String
    public var items: [Item]

    public init(
        schemaVersion: String = "steno-mac-sanity/v1",
        generatedAt: Date = Date(),
        appBuildSHA: String = "fill-in-commit-sha",
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        overallStatus: String = "pending",
        items: [Item]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.appBuildSHA = appBuildSHA
        self.macOSVersion = macOSVersion
        self.overallStatus = overallStatus
        self.items = items
    }
}
