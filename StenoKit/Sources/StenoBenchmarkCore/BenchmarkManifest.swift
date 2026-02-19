import Foundation
import StenoKit

public struct BenchmarkManifest: Sendable, Codable {
    public var schemaVersion: String
    public var benchmarkName: String
    public var scoring: ScoringConfiguration
    public var samples: [BenchmarkSample]

    public init(
        schemaVersion: String = "steno-benchmark-manifest/v1",
        benchmarkName: String = "Steno Benchmark",
        scoring: ScoringConfiguration = ScoringConfiguration(),
        samples: [BenchmarkSample]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmarkName = benchmarkName
        self.scoring = scoring
        self.samples = samples
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

public struct BenchmarkSample: Sendable, Codable {
    public var id: String
    public var dataset: String
    public var audioPath: String
    public var referenceText: String
    public var languageHint: String?
    public var audioDurationMS: Int?

    public init(
        id: String,
        dataset: String,
        audioPath: String,
        referenceText: String,
        languageHint: String? = nil,
        audioDurationMS: Int? = nil
    ) {
        self.id = id
        self.dataset = dataset
        self.audioPath = audioPath
        self.referenceText = referenceText
        self.languageHint = languageHint
        self.audioDurationMS = audioDurationMS
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

    public init(term: String, preferred: String, bundleID: String? = nil) {
        self.term = term
        self.preferred = preferred
        self.bundleID = bundleID
    }

    public var stenoEntry: LexiconEntry {
        if let bundleID, !bundleID.isEmpty {
            return LexiconEntry(term: term, preferred: preferred, scope: .app(bundleID: bundleID))
        }
        return LexiconEntry(term: term, preferred: preferred, scope: .global)
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
        self.runtime = runtime
        self.manifestSchemaVersion = manifestSchemaVersion
        self.normalizationPolicy = normalizationPolicy
        self.whisperConfiguration = whisperConfiguration
        self.summary = summary
        self.datasetBreakdown = datasetBreakdown
        self.samples = samples
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
        outcome: PipelineOutcome
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
        self.lexicon = lexicon
        self.fillerImpact = fillerImpact
    }
}

public struct PipelineOutput: Sendable, Codable {
    public var schemaVersion: String
    public var benchmarkName: String
    public var runtime: BenchmarkRuntimeMetadata
    public var profile: StyleProfile
    public var lexiconEntryCount: Int
    public var normalizationPolicy: NormalizationPolicy
    public var summary: PipelineAggregate
    public var samples: [PipelineSampleResult]

    public init(
        schemaVersion: String = "steno-pipeline-results/v1",
        benchmarkName: String,
        runtime: BenchmarkRuntimeMetadata = BenchmarkRuntimeMetadata(),
        profile: StyleProfile,
        lexiconEntryCount: Int,
        normalizationPolicy: NormalizationPolicy,
        summary: PipelineAggregate,
        samples: [PipelineSampleResult]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmarkName = benchmarkName
        self.runtime = runtime
        self.profile = profile
        self.lexiconEntryCount = lexiconEntryCount
        self.normalizationPolicy = normalizationPolicy
        self.summary = summary
        self.samples = samples
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
