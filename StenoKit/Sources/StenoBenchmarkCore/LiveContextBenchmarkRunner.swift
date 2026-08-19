import CryptoKit
#if os(macOS)
import Darwin
#endif
import Foundation
import StenoKit

public struct LiveContextBenchmarkConfiguration: Sendable {
    public var corpusPath: String
    public var audioFixturePath: String
    public var audioFixtureIsPublic: Bool
    public var declaredSpeechOnsetMS: Int
    public var helperPath: String
    public var whisperCLIPath: String
    public var modelPath: String
    public var vadModelPath: String?
    public var sourceRootPath: String
    public var hostedReceiptPath: String
    public var adversarialReceiptPath: String
    public var threads: Int
    public var language: String
    public var alternatingTrialCount: Int
    public var resourceSoakSessions: Int
    public var idleSampleSeconds: Double
    public var rssCeilingBytes: UInt64
    public var realtimePacing: Bool

    public init(
        corpusPath: String,
        audioFixturePath: String,
        audioFixtureIsPublic: Bool,
        declaredSpeechOnsetMS: Int,
        helperPath: String,
        whisperCLIPath: String,
        modelPath: String,
        vadModelPath: String? = nil,
        sourceRootPath: String,
        hostedReceiptPath: String,
        adversarialReceiptPath: String,
        threads: Int = 8,
        language: String = "en",
        alternatingTrialCount: Int = 10,
        resourceSoakSessions: Int = 500,
        idleSampleSeconds: Double = 60,
        rssCeilingBytes: UInt64 = 2_147_483_648,
        realtimePacing: Bool = true
    ) {
        self.corpusPath = corpusPath
        self.audioFixturePath = audioFixturePath
        self.audioFixtureIsPublic = audioFixtureIsPublic
        self.declaredSpeechOnsetMS = declaredSpeechOnsetMS
        self.helperPath = helperPath
        self.whisperCLIPath = whisperCLIPath
        self.modelPath = modelPath
        self.vadModelPath = vadModelPath
        self.sourceRootPath = sourceRootPath
        self.hostedReceiptPath = hostedReceiptPath
        self.adversarialReceiptPath = adversarialReceiptPath
        self.threads = threads
        self.language = language
        self.alternatingTrialCount = alternatingTrialCount
        self.resourceSoakSessions = resourceSoakSessions
        self.idleSampleSeconds = idleSampleSeconds
        self.rssCeilingBytes = rssCeilingBytes
        self.realtimePacing = realtimePacing
    }
}

public enum LiveContextBenchmarkRunnerError: Error, LocalizedError, Equatable {
    case privateAudioFixtureRejected
    case invalidConfiguration
    case missingInput(String)
    case emptyCorpus
    case helperNotFound
    case canonicalAudioDidNotFinalize
    case invalidEvidenceReceipt(String)

    public var errorDescription: String? {
        switch self {
        case .privateAudioFixtureRejected:
            return "The live-context benchmark only accepts an explicitly declared public, non-user audio fixture."
        case .invalidConfiguration:
            return "The live-context benchmark configuration is invalid."
        case .missingInput(let name):
            return "The live-context benchmark input is missing: \(name)."
        case .emptyCorpus:
            return "The continuation/directive corpus is empty."
        case .helperNotFound:
            return "The retained helper process was not observed."
        case .canonicalAudioDidNotFinalize:
            return "The canonical WAV fixture did not produce a final stream summary."
        case .invalidEvidenceReceipt(let name):
            return "The \(name) evidence receipt is missing, stale, dirty, mismatched, skipped, or incomplete."
        }
    }
}

public enum LiveContextBenchmarkRunner {
    struct EnabledTrial {
        var startMS: Double
        var firstPartialMS: Double?
        var subsequentGapsMS: [Double]
        var finishMS: Double
        var eventCount: Int
        var stablePrefixConflicts: Int
        var stablePrefixFinalConflicts: Int
        var noSpeechFalseDisplays: Int
        var frameSequenceOrOffsetDiscontinuities: Int
        var revisionCount: Int
        var finalizationCount: Int
        var summary: LivePCMStreamSummary
        var pcmSHA256: String
        var canonicalSummary: LivePCMStreamSummary
        var canonicalPCMSHA256: String
        var runtimeIdentity: LiveTranscriptionRuntimeIdentity
        var activeCPUPercent: Double?
    }

    private struct LiveAggregate {
        var startMS: [Double] = []
        var firstPartialMS: [Double] = []
        var subsequentGapsMS: [Double] = []
        var enabledFinishMS: [Double] = []
        var disabledFinishMS: [Double] = []
        var stablePrefixConflicts = 0
        var stablePrefixFinalConflicts = 0
        var noSpeechFalseDisplays = 0
        var revisionCount = 0
        var provisionalSessionCount = 0
        var finalizationCount = 0
        var latePartialsAfterCancellation = 0
        var activeCPUPercentSamples: [Double] = []
        var captureSummary: LivePCMStreamSummary?
        var captureSHA256: String?
        var canonicalCaptureSummary: LivePCMStreamSummary?
        var canonicalCaptureSHA256: String?
        var frameSequenceOrOffsetDiscontinuities = 0
        var runtimeIdentities: Set<LiveTranscriptionRuntimeIdentity> = []
        var enabledTrials: [EnabledTrial] = []
    }

    private struct ReceiptEvidence {
        var hosted: LiveContextHostedReceipt
        var adversarial: AdversarialReceipt
        var helperCrashExpected: Int
        var helperCrashPassed: Int
        var malformedExpected: Int
        var malformedPassed: Int
    }

    private struct AdversarialReceipt: Decodable {
        struct Git: Decodable { var sha: String; var dirty: Bool; var state: String }
        struct Execution: Decodable {
            struct ObservedBackends: Decodable { var cpu: Int; var metal: Int; var unknown: Int }
            var requestedDeviceMode: String
            var backend: String
            var backendEligibleProcessCount: Int
            var attestedProcessCount: Int
            var observedBackends: ObservedBackends
            var productionMetalSmokePerformed: Bool
            var qualification: String
            var matrix: String
        }
        struct Environment: Decodable {
            struct Hardware: Decodable {
                var architecture: String; var chip: String; var logicalProcessorCount: Int
                var memoryBytes: UInt64; var modelIdentifier: String
            }
            struct OperatingSystem: Decodable { var build: String; var name: String; var version: String }
            var hardware: Hardware; var operatingSystem: OperatingSystem
        }
        struct Identity: Decodable {
            var schema: Int; var capabilities: Int; var runtime: String; var model: String; var vad: String
            var helperBinary: String; var helperBinarySHA256: String
        }
        struct Configuration: Decodable {
            struct Audio: Decodable { var channelCount: Int; var encoding: String; var sampleRateHz: Int; var sampleWidthBytes: Int }
            struct Bounds: Decodable {
                var maximumAppendBytes: Int; var maximumAppendSamples: Int; var maximumHypothesisBytes: Int
                var maximumPayloadBytes: Int; var maximumStreamSamples: Int; var maximumStringBytes: Int
                var previewWindowSamples: Int
            }
            struct Timeouts: Decodable {
                var backendAttestation: Double; var defaultFrameRead: Double; var inference: Double
                var loadReady: Double; var networkMonitorStartup: Double; var networkPollInterval: Double
            }
            struct Inference: Decodable {
                var entropyThreshold: Double; var logProbabilityThreshold: Double; var noSpeechThreshold: Double
                var temperature: Double; var temperatureIncrement: Double
            }
            struct Stream: Decodable {
                var beamSize: Int; var bestOf: Int; var flags: Int; var language: String
                var prompt: String?; var suppressNonSpeechTokens: Bool; var suppressRegex: String?
                var threads: Int; var vadEnabled: Bool
            }
            struct VAD: Decodable {
                var maximumSpeechDurationSeconds: String; var minimumSilenceDurationMS: Int
                var minimumSpeechDurationMS: Int; var previewScope: String; var samplesOverlap: Double
                var speechPadMS: Int; var threshold: Double
            }
            var audio: Audio; var bounds: Bounds; var harnessTimeoutsSeconds: Timeouts
            var inferenceThresholds: Inference; var streamRequest: Stream; var vadThresholds: VAD
        }
        struct Manifest: Decodable {
            struct Entry: Decodable { var role: String; var path: String; var sha256: String }
            var algorithm: String; var sha256: String; var entries: [Entry]
        }
        struct ArtifactReference: Decodable { var path: String; var sha256: String }
        struct Artifacts: Decodable {
            var audioFixture: ArtifactReference; var helper: ArtifactReference
            var model: ArtifactReference; var vadModel: ArtifactReference
        }
        struct Count: Decodable { var expected: Int; var passed: Int; var failed: Int; var skipped: Int }
        struct Row: Decodable {
            var category: String
            var durationMS: Double
            var name: String
            var status: String
            var failureReason: String?
            var skipReason: String?
        }
        struct Cases: Decodable {
            var expected: Int; var passed: Int; var failed: Int; var skipped: Int
            var categories: [String: Count]
            var rows: [Row]
            var failureRows: [Row]
            var skipRows: [Row]
        }
        struct Hashes: Decodable {
            var harnessSHA256: String; var helperSourceSHA256: String; var helperBinarySHA256: String
            var modelSHA256: String; var vadModelSHA256: String; var audioSHA256: String; var canarySHA256: String
            var sourceFixtureManifestSHA256: String
        }
        struct Audio: Decodable {
            var expectedSampleCount: Int; var observedSampleCount: Int; var fnv1a64: String
            var channelCount: Int; var sampleWidthBytes: Int; var sampleRateHz: Int
        }
        struct Canary: Decodable { var scannedSurfaceCount: Int; var escapes: Int }
        struct Fallback: Decodable { var performed: Bool; var attempts: Int; var successes: Int }
        struct Network: Decodable {
            var undefinedSymbolScanPerformed: Bool; var prohibitedUndefinedSymbols: [String]
            var runtimeMonitorPerformed: Bool
            var checkedProcessCount: Int
            var ownedProcessCount: Int
            var observedNetworkFileDescriptorCount: Int
            var observedNetworkFDCount: Int
            var continuous: Bool
            var scanCount: Int
            var observationDurationMS: Int
            var minimumScanCountPerProcess: Int
            var pollIntervalMS: Int
        }
        var schemaVersion: Int
        var generatedAt: String
        var git: Git
        var protocolVersions: [Int]
        var execution: Execution
        var environment: Environment
        var identity: Identity
        var configuration: Configuration
        var sourceFixtureManifest: Manifest
        var cases: Cases
        var hashes: Hashes
        var artifacts: Artifacts
        var audio: Audio
        var canary: Canary
        var fallback: Fallback
        var network: Network
    }

    private static let adversarialCaseNamesByCategory: [String: Set<String>] = [
        "compatibility": ["v1 backward compatibility"],
        "protocolValidation": [
            "v2 validation, cross-session, duplicate, and terminal rejection",
            "v2 out-of-order, malformed, and per-append size bounds",
            "v2 shutdown rejects malformed fields and permits active teardown",
        ],
        "terminalPriority": [
            "v2 finish priority and exactly one final",
            "v2 cancellation priority",
            "v2 cancel during finish preserves restart",
        ],
        "speechEvidence": ["v2 decode-scoped Silero speech evidence"],
        "authoritativeIntegrity": ["v2 finish rejects matching count with wrong FNV and emits no final"],
        "parserBounds": ["global oversized frame rejection"],
        "receiptIntegrity": ["CPU attestation cannot qualify as Metal"],
        "lifecycleCrashEOF": [
            "v2 crash after exactly one final",
            "crash before ready", "EOF before ready",
            "crash during before-append", "crash during append", "crash during hypothesis", "crash during finish",
            "EOF during before-append", "EOF during append", "EOF during hypothesis", "EOF during finish",
        ],
    ]

    public static func run(
        configuration: LiveContextBenchmarkConfiguration
    ) async throws -> LiveContextBenchmarkArtifact {
        try validate(configuration)
        let corpus = try LiveContextArtifactIO.loadCorpus(at: configuration.corpusPath)
        guard !corpus.rows.isEmpty else { throw LiveContextBenchmarkRunnerError.emptyCorpus }

        let fallback = CountingFallbackEngine(
            base: WhisperCLITranscriptionEngine(
                config: .init(
                    whisperCLIPath: URL(fileURLWithPath: configuration.whisperCLIPath),
                    modelPath: URL(fileURLWithPath: configuration.modelPath),
                    additionalArguments: cliArguments(configuration)
                )
            )
        )
        let retained = RetainedWhisperTranscriptionEngine(
            configuration: retainedConfiguration(configuration),
            fallback: fallback
        )
        return try await withTaskCancellationHandler {
            do {
                let artifact = try await run(
                    configuration: configuration,
                    corpus: corpus,
                    engine: retained,
                    fallback: fallback
                )
                await retained.shutdown()
                return artifact
            } catch {
                await retained.shutdown()
                throw error
            }
        } onCancel: {
            Task { await retained.shutdown() }
        }
    }

    static func evaluateCorpus(
        _ corpus: ContinuationDirectiveCorpus,
        policy: DictationContinuationPolicy = DictationContinuationPolicy()
    ) -> [CaseSensitiveBenchmarkRow] {
        corpus.rows.map { row in
            let plan = policy.prepareDirective(in: row.input)
            let applied = policy.applyDirective(plan, toCleanedText: row.cleanedText)
            let shaped = policy.shapeInsertionPayload(
                cleanedText: applied,
                context: contextState(row.context, token: row.id),
                protectedTerms: Set(row.context.protectedTerms)
            )
            let expectedDirective = directiveKind(row.expectedDirectiveKind)
            let expectedDecision = caseDecision(row.expectedCaseDecision)
            let directiveCorrect = plan.kind == expectedDirective
                && plan.textForCleanup == row.expectedTextForCleanup
                && applied == row.expectedDirectiveAppliedText
            let continuationCorrect = shaped.caseDecision == expectedDecision
            let boundaryCorrect = shaped.insertedLeadingSpace == row.expectedInsertedLeadingSpace
                && shaped.insertedTrailingSpace == row.expectedInsertedTrailingSpace
            let literalPreserved = row.expectedDirectiveKind != .literalEscape
                || applied == row.expectedDirectiveAppliedText
            return CaseSensitiveBenchmark.row(
                corpusRow: row,
                actualOutput: shaped.text,
                continuationDecisionCorrect: continuationCorrect,
                unintendedLowercaseCount: unintendedLowercaseCount(
                    expected: row.expectedOutput,
                    actual: shaped.text
                ),
                directiveDecisionCorrect: directiveCorrect,
                literalLowercasePreserved: literalPreserved,
                boundarySpacingCorrect: boundaryCorrect
            )
        }
    }

    static func run(
        configuration: LiveContextBenchmarkConfiguration,
        corpus: ContinuationDirectiveCorpus,
        engine: any LiveTranscriptionEngine,
        fallback: CountingFallbackEngine? = nil
    ) async throws -> LiveContextBenchmarkArtifact {
        try validate(configuration)
        var identity = try makeIdentity(configuration: configuration, corpus: corpus)
        let receipts = try loadAndValidateReceipts(configuration: configuration, identity: identity)
        let request = TranscriptionRequest(languageHints: [configuration.language])
        let audioURL = URL(fileURLWithPath: configuration.audioFixturePath)
        let caseRows = evaluateCorpus(corpus)
        var failures: [LiveContextFailureRow] = []
        let skips: [LiveContextFailureRow] = []
        for row in caseRows where row.status != .passed {
            failures.append(.init(id: "corpus:\(row.id)", reasonCode: row.reasonCode ?? "case-sensitive-failure"))
        }

        var aggregate = LiveAggregate()
        var helperPIDs: Set<Int32> = []
        var maximumConcurrentHelperProcessCount = 0
        let helperExecutableName = URL(
            fileURLWithPath: configuration.helperPath
        ).lastPathComponent
        _ = try await engine.transcribe(audioURL: audioURL, request: request)
        let warmHelperPIDs = LiveContextProcessProbe.childProcessIDs(named: helperExecutableName)
        helperPIDs.formUnion(warmHelperPIDs)
        maximumConcurrentHelperProcessCount = max(
            maximumConcurrentHelperProcessCount,
            warmHelperPIDs.count
        )
        for trial in 0..<configuration.alternatingTrialCount {
            if trial.isMultiple(of: 2) {
                let measurement = try await runEnabledTrial(
                    engine: engine,
                    audioURL: audioURL,
                    request: request,
                    speechOnsetMS: configuration.declaredSpeechOnsetMS,
                    realtimePacing: configuration.realtimePacing
                )
                aggregate.startMS.append(measurement.startMS)
                if let first = measurement.firstPartialMS {
                    aggregate.firstPartialMS.append(first)
                    aggregate.provisionalSessionCount += 1
                } else {
                    failures.append(.init(id: "trial:\(trial)", reasonCode: "no-nonempty-provisional"))
                }
                aggregate.subsequentGapsMS += measurement.subsequentGapsMS
                if measurement.subsequentGapsMS.isEmpty {
                    failures.append(.init(id: "trial:\(trial)", reasonCode: "insufficient-subsequent-gap-coverage"))
                }
                aggregate.enabledFinishMS.append(measurement.finishMS)
                aggregate.stablePrefixConflicts += measurement.stablePrefixConflicts
                aggregate.stablePrefixFinalConflicts += measurement.stablePrefixFinalConflicts
                aggregate.noSpeechFalseDisplays += measurement.noSpeechFalseDisplays
                aggregate.revisionCount += measurement.revisionCount
                aggregate.finalizationCount += measurement.finalizationCount
                aggregate.frameSequenceOrOffsetDiscontinuities += measurement.frameSequenceOrOffsetDiscontinuities
                aggregate.activeCPUPercentSamples += measurement.activeCPUPercent.map { [$0] } ?? []
                aggregate.captureSummary = measurement.summary
                aggregate.captureSHA256 = measurement.pcmSHA256
                aggregate.canonicalCaptureSummary = measurement.canonicalSummary
                aggregate.canonicalCaptureSHA256 = measurement.canonicalPCMSHA256
                aggregate.runtimeIdentities.insert(measurement.runtimeIdentity)
                aggregate.enabledTrials.append(measurement)
            } else {
                let started = ContinuousClock.now
                _ = try await engine.transcribe(audioURL: audioURL, request: request)
                aggregate.disabledFinishMS.append(elapsedMS(since: started))
            }
            let observedHelperPIDs = LiveContextProcessProbe.childProcessIDs(
                named: helperExecutableName
            )
            helperPIDs.formUnion(observedHelperPIDs)
            maximumConcurrentHelperProcessCount = max(
                maximumConcurrentHelperProcessCount,
                observedHelperPIDs.count
            )
        }

        if aggregate.runtimeIdentities.count == 1, let runtimeIdentity = aggregate.runtimeIdentities.first {
            identity.liveProtocolVersion = runtimeIdentity.protocolVersion
            identity.liveRuntimeIdentifier = runtimeIdentity.runtimeIdentifier
            identity.liveModelIdentifier = runtimeIdentity.modelIdentifier
            identity.liveVADIdentifier = runtimeIdentity.vadIdentifier
            if runtimeIdentity.protocolVersion != 2
                || runtimeIdentity.modelIdentifier.count != 64
                || (configuration.vadModelPath == nil) != (runtimeIdentity.vadIdentifier == nil) {
                failures.append(.init(id: "live-runtime-identity", reasonCode: "unexpected-runtime-model-vad-identity"))
            }
        } else {
            failures.append(.init(id: "live-runtime-identity", reasonCode: "runtime-identity-changed-across-trials"))
        }

        aggregate.latePartialsAfterCancellation = await measureLatePartialsAfterCancellation(
            engine: engine,
            audioURL: audioURL,
            request: request
        )

        let productionDiagnostic = try await LiveContextProductionCoordinatorBenchmark.run(
            engine: engine,
            publicCanonicalWAVURL: audioURL,
            publicFixtureAttested: configuration.audioFixtureIsPublic,
            alternatingTrialCount: configuration.alternatingTrialCount,
            languageHints: [configuration.language]
        )
        let expectedOrder = (0..<configuration.alternatingTrialCount).map {
            $0.isMultiple(of: 2) ? LiveContextTrialMode.enabled : .disabled
        }
        let expectedFNV = receipts.adversarial.audio.fnv1a64.lowercased()
        if productionDiagnostic.definition != LiveContextProductionCoordinatorBenchmark.definition
            || productionDiagnostic.enabledReadinessDefinition != LiveContextProductionCoordinatorBenchmark.enabledReadinessDefinition
            || productionDiagnostic.trialLivePreviewOrder != expectedOrder.map({ $0 == .enabled })
            || productionDiagnostic.authoritativeFinalOwnershipCount != configuration.alternatingTrialCount
            || productionDiagnostic.insertionCommitCount != configuration.alternatingTrialCount
            || productionDiagnostic.historyAppendCount != configuration.alternatingTrialCount
            || productionDiagnostic.successfulEnabledReadinessCount != configuration.alternatingTrialCount / 2
            || productionDiagnostic.liveFinishAuthoritativeFinalCount != configuration.alternatingTrialCount / 2
            || productionDiagnostic.disabledTranscribeAuthoritativeFinalCount != configuration.alternatingTrialCount / 2
            || productionDiagnostic.coordinatorFallbackCount != 0
            || productionDiagnostic.observedLiveRuntimeIdentities.count != 1
            || productionDiagnostic.observedLiveRuntimeIdentities != aggregate.runtimeIdentities
            || productionDiagnostic.publicFixtureSHA256 != identity.audioFixtureSHA256 {
            failures.append(.init(id: "production-core-diagnostic", reasonCode: "identity-or-count-mismatch"))
        }
        for trial in productionDiagnostic.trials {
            if trial.livePreviewEnabled {
                guard let summary = trial.canonicalPCM else {
                    failures.append(.init(id: "production-core:\(trial.index)", reasonCode: "enabled-summary-missing"))
                    continue
                }
                if Int(summary.sampleCount) != receipts.adversarial.audio.expectedSampleCount
                    || summary.byteCount != summary.sampleCount * UInt64(receipts.adversarial.audio.sampleWidthBytes)
                    || summary.frameCount != aggregate.canonicalCaptureSummary?.frameCount
                    || hexadecimal(summary.fnv1a64) != expectedFNV {
                    failures.append(.init(id: "production-core:\(trial.index)", reasonCode: "independent-audio-oracle-mismatch"))
                }
            } else if trial.canonicalPCM != nil {
                failures.append(.init(id: "production-core:\(trial.index)", reasonCode: "disabled-summary-present"))
            }
        }

        guard let helperPID = LiveContextProcessProbe.childProcessIDs(
            named: helperExecutableName
        ).first else {
            throw LiveContextBenchmarkRunnerError.helperNotFound
        }
        helperPIDs.insert(helperPID)

        let resource = await measureResources(
            configuration: configuration,
            engine: engine,
            audioURL: audioURL,
            request: request,
            helperPID: helperPID,
            helperPIDs: &helperPIDs
        )
        maximumConcurrentHelperProcessCount = max(
            maximumConcurrentHelperProcessCount,
            resource.maximumConcurrentHelperProcessCount
        )
        if resource.peakRSSBytes == nil || resource.idleCPUPercent == nil {
            failures.append(.init(id: "resources", reasonCode: "process-resource-probe-unavailable"))
        }

        let childPIDs = LiveContextProcessProbe.childProcessIDs(
            named: helperExecutableName
        )
        maximumConcurrentHelperProcessCount = max(
            maximumConcurrentHelperProcessCount,
            childPIDs.count
        )
        let runtimeConnections = LiveContextProcessProbe.networkConnectionCount(pid: helperPID)
        let listenerCount = LiveContextProcessProbe.listeningSocketCount(pid: helperPID)
        if runtimeConnections == nil || listenerCount == nil {
            failures.append(.init(id: "network", reasonCode: "runner-network-probe-unavailable"))
        }

        failures += captureParityFailureRows(
            aggregate.enabledTrials,
            expectedAudioSampleCount: receipts.adversarial.audio.expectedSampleCount,
            expectedFNV1A64: expectedFNV
        )
        let summary = aggregate.captureSummary
        let hash = aggregate.captureSHA256
        let fallbackCount = await fallback?.callCount() ?? 0
        let privacyCanaries = LiveContextReceiptManifest.hostedPrivacyCanaries(
            gitSHA: identity.gitSHA
        ) + ["STENO-PUBLIC-PROTOCOL-CANARY-V1"]
        let argumentVectorLeaks = privacyCanaries.reduce(0) { count, sentinel in
            count + LiveContextSentinelScanner.argumentVectorLeakCount(
                sentinel: sentinel,
                arguments: CommandLine.arguments
            )
        }
        let privacy = LiveContextPrivacyEvidence(
            staticNetworkTransportMatches: receipts.adversarial.network.prohibitedUndefinedSymbols.count,
            listeningSocketsObserved: listenerCount,
            runtimeNetworkConnectionsObserved: runtimeConnections,
            canaryProbeCount: receipts.hosted.privacy.provisionalCanaryInjectionCount
                + receipts.hosted.privacy.contextCanaryInjectionCount
                + receipts.hosted.privacy.snippetCanaryInjectionCount
                + receipts.hosted.privacy.scannedSurfaceCount
                + receipts.adversarial.canary.scannedSurfaceCount
                + privacyCanaries.count * CommandLine.arguments.count,
            requestLeaks: receipts.hosted.privacy.requestLeaks,
            cleanupLeaks: receipts.hosted.privacy.cleanupLeaks,
            historyLeaks: receipts.hosted.privacy.historyLeaks,
            insertionLeaks: receipts.hosted.privacy.insertionLeaks,
            clipboardRecoveryLeaks: receipts.hosted.privacy.clipboardRecoveryLeaks,
            analyticsLeaks: receipts.hosted.privacy.analyticsLeaks,
            configuredSnippetTrapCount: receipts.hosted.privacy.configuredSnippetTrapCount,
            snippetTrapActivations: receipts.hosted.privacy.snippetTrapActivations,
            liveCallbackUnexpectedContextLeaks: receipts.hosted.privacy.liveCallbackUnexpectedContextLeaks,
            overlayRetainedTextLeaks: receipts.hosted.privacy.overlayRetainedTextLeaks,
            artifactLeaks: 0,
            argumentVectorLeaks: argumentVectorLeaks,
            staticAuditBoundSourceManifestSHA256: receipts.hosted.staticAudit.boundHostedSourceManifestSHA256,
            featureLogInvocationSourceFindings: receipts.hosted.staticAudit.featureLogInvocationSourceFindings,
            crashMetadataSinkReferenceSourceFindings: receipts.hosted.staticAudit.crashMetadataSinkReferenceSourceFindings,
            ephemeralPersistenceSourceFindings: receipts.hosted.staticAudit.ephemeralPersistenceSourceFindings,
            ephemeralFilenameDiagnosticSourceFindings: receipts.hosted.staticAudit.ephemeralFilenameDiagnosticSourceFindings,
            prohibitedNetworkAPISourceFindings: receipts.hosted.staticAudit.prohibitedNetworkAPISourceFindings,
            secureFieldContextReadRequests: receipts.hosted.privacy.secureFieldContextReadRequests,
            maximumAXUTF16ReadPerSide: receipts.hosted.privacy.maximumAXUTF16ReadPerSide,
            maximumAXGraphemesPerSide: receipts.hosted.privacy.maximumAXGraphemesPerSide,
            maximumAXContextBytes: receipts.hosted.privacy.maximumAXContextBytes
        )
        let helperSourcePath = URL(fileURLWithPath: configuration.sourceRootPath)
            .appendingPathComponent("runtime-helper/steno_whisper_runtime.cpp").path
        let modelInitializationSiteCount = sourceOccurrenceCount(
            "whisper_init_from_file_with_params",
            path: helperSourcePath
        )
        var artifact = LiveContextBenchmarkArtifact(
            generatedAt: Date(),
            identity: identity,
            thresholds: .required,
            expectedCorpusRowCount: corpus.rows.count,
            observedCorpusRowCount: caseRows.count,
            declaredFailureCount: failures.count,
            declaredSkipCount: skips.count,
            failures: failures,
            skips: skips,
            caseSensitiveRows: caseRows,
            latency: .init(
                // The hosted controller timing uses an injected immediate
                // coordinator acknowledgement and excludes native capture
                // startup. It remains receipt diagnostics and cannot satisfy
                // the literal press-to-listening shipping gate.
                listeningAcknowledgement: .summarize([]),
                helperStreamSetup: .summarize(aggregate.startMS),
                firstPartial: .summarize(aggregate.firstPartialMS),
                subsequentPartialGap: .summarize(aggregate.subsequentGapsMS),
                overlayMainActorWork: receipts.hosted.overlayMainActorWork,
                finishToAuthoritativeFinalEnabled: .summarize(aggregate.enabledFinishMS),
                finishToAuthoritativeFinalDisabledControl: .summarize(aggregate.disabledFinishMS),
                // Filled by the retained-engine production coordinator benchmark.
                // Hosted synthetic-engine timings are diagnostics and must not
                // satisfy the shipping stop-to-insertion gate.
                stopToInsertionEnabled: .summarize(productionDiagnostic.enabledStopToAuthoritativeInsertionAndHistoryMS),
                stopToInsertionDisabledControl: .summarize(productionDiagnostic.disabledStopToAuthoritativeInsertionAndHistoryMS),
                maximumVisibleUpdatesPerSecond: maximumBurstUpdatesPerSecond(
                    receipts.hosted.renderedUpdateTimestampsMS
                ),
                alternatingTrialCount: configuration.alternatingTrialCount,
                trialOrder: (0..<configuration.alternatingTrialCount).map {
                    $0.isMultiple(of: 2) ? .enabled : .disabled
                },
                sameConfigurationAcrossTrials: aggregate.runtimeIdentities.count == 1
                    && productionDiagnostic.observedLiveRuntimeIdentities == aggregate.runtimeIdentities,
                coreDiagnosticDefinition: productionDiagnostic.definition,
                coreDiagnosticReadinessDefinition: productionDiagnostic.enabledReadinessDefinition,
                coreDiagnosticConfigurationSHA256: productionDiagnostic.configurationSHA256,
                acceptedSubsequentGapCountByEnabledTrial: aggregate.enabledTrials.map {
                    $0.subsequentGapsMS.count
                }
            ),
            correctness: .init(
                stablePrefixMutations: aggregate.stablePrefixConflicts,
                provisionalSideEffects: receipts.hosted.correctness.provisionalSideEffects,
                duplicateFinalInsertions: receipts.hosted.correctness.duplicateFinalInsertions,
                staleEventsAccepted: receipts.hosted.correctness.staleEventsAccepted,
                stablePrefixConflicts: aggregate.stablePrefixConflicts,
                stablePrefixFinalConflicts: aggregate.stablePrefixFinalConflicts,
                provisionalSessionCount: aggregate.provisionalSessionCount,
                noSpeechFalseDisplays: aggregate.noSpeechFalseDisplays
                    + receipts.hosted.correctness.noSpeechFalseDisplays,
                latePartialsAfterCancellation: aggregate.latePartialsAfterCancellation,
                revisionCount: aggregate.revisionCount,
                finalizationCount: aggregate.finalizationCount
            ),
            capture: .init(
                expectedAudioSampleCount: receipts.adversarial.audio.expectedSampleCount,
                streamedSampleCount: Int(summary?.sampleCount ?? 0),
                canonicalSampleCount: Int(aggregate.canonicalCaptureSummary?.sampleCount ?? 0),
                streamedPCMHash: hash ?? "",
                canonicalPCMHash: aggregate.canonicalCaptureSHA256 ?? "",
                frameSequenceOrOffsetDiscontinuities: aggregate.frameSequenceOrOffsetDiscontinuities,
                expectedFNV1A64: expectedFNV,
                streamedFNV1A64: summary.map { hexadecimal($0.fnv1a64) } ?? "",
                canonicalFNV1A64: aggregate.canonicalCaptureSummary.map { hexadecimal($0.fnv1a64) } ?? "",
                audioFixtureSHA256: identity.audioFixtureSHA256,
                trials: aggregate.enabledTrials.enumerated().map { index, trial in
                    .init(
                        trialIndex: index * 2,
                        expectedSampleCount: receipts.adversarial.audio.expectedSampleCount,
                        streamedSampleCount: Int(trial.summary.sampleCount),
                        canonicalSampleCount: Int(trial.canonicalSummary.sampleCount),
                        expectedFNV1A64: expectedFNV,
                        streamedFNV1A64: hexadecimal(trial.summary.fnv1a64),
                        canonicalFNV1A64: hexadecimal(trial.canonicalSummary.fnv1a64)
                    )
                }
            ),
            resources: .init(
                soakSessionCount: resource.completedSoakSessions,
                peakRSSBytes: resource.peakRSSBytes,
                rssCeilingBytes: configuration.rssCeilingBytes,
                peakGrowthBytes: resource.peakGrowthBytes,
                tailSlopeBytesPerRequest: resource.tailSlopeBytesPerRequest,
                monotonicGrowthObserved: resource.monotonicGrowthObserved,
                sawtoothGrowthObserved: resource.sawtoothGrowthObserved,
                idleCPUPercent: resource.idleCPUPercent,
                idleSampleSeconds: configuration.idleSampleSeconds,
                activeCPUPercentSamples: aggregate.activeCPUPercentSamples,
                maximumQueueDepth: receipts.hosted.maximumQueueDepth,
                coalescedPreviewCount: receipts.hosted.coalescedPreviewCount,
                helperReloadCount: max(0, helperPIDs.count - 1),
                helperFallbackCount: fallbackCount,
                maximumConcurrentHelperProcessCount: maximumConcurrentHelperProcessCount,
                thermalState: LiveContextProcessProbe.thermalState,
                requestedSoakSessionCount: configuration.resourceSoakSessions,
                completedSoakSessionCount: resource.completedSoakSessions,
                observedIdleSampleSeconds: resource.observedIdleSampleSeconds,
                idleObservationCompleted: resource.idleObservationCompleted,
                continuousHelperMonitorPerformed: resource.continuousHelperMonitorPerformed,
                helperProcessObservationCount: resource.helperProcessObservationCount,
                maximumResidentModelCount: maximumConcurrentHelperProcessCount == 1 ? 1 : nil,
                modelInitializationSourceSHA256: identity.helperSourceSHA256,
                modelInitializationSiteCount: modelInitializationSiteCount
            ),
            privacy: privacy,
            lifecycle: .init(
                randomizedSessions: receipts.hosted.lifecycle.randomizedSessions,
                rapidCancelRestartCases: receipts.hosted.lifecycle.rapidCancelRestartCases,
                targetTransitions: receipts.hosted.lifecycle.targetTransitions,
                helperCrashScenariosPassed: receipts.helperCrashPassed,
                helperCrashScenariosExpected: receipts.helperCrashExpected,
                malformedProtocolScenariosPassed: receipts.malformedPassed,
                malformedProtocolScenariosExpected: receipts.malformedExpected,
                authoritativeFinishCalls: receipts.hosted.lifecycle.authoritativeFinishCalls,
                maximumAuthoritativeFinishCallsPerSession: receipts.hosted.lifecycle.maximumAuthoritativeFinishCallsPerSession,
                coordinatorSecondFinalInferenceAttempts: receipts.hosted.lifecycle.coordinatorSecondFinalInferenceAttempts,
                finalInsertionCount: receipts.hosted.lifecycle.finalInsertionCount,
                expectedFinalInsertionCount: receipts.hosted.lifecycle.expectedFinalInsertionCount
            ),
            coreDiagnostics: .init(
                trialOrder: expectedOrder,
                authoritativeFinalOwnershipCount: productionDiagnostic.authoritativeFinalOwnershipCount,
                insertionCommitCount: productionDiagnostic.insertionCommitCount,
                historyAppendCount: productionDiagnostic.historyAppendCount,
                successfulEnabledReadinessCount: productionDiagnostic.successfulEnabledReadinessCount,
                liveFinishAuthoritativeFinalCount: productionDiagnostic.liveFinishAuthoritativeFinalCount,
                disabledTranscribeAuthoritativeFinalCount: productionDiagnostic.disabledTranscribeAuthoritativeFinalCount,
                coordinatorFallbackCount: productionDiagnostic.coordinatorFallbackCount,
                runtimeIdentityCount: productionDiagnostic.observedLiveRuntimeIdentities.count,
                publicFixtureSHA256: productionDiagnostic.publicFixtureSHA256,
                configurationSHA256: productionDiagnostic.configurationSHA256,
                enabledCanonicalSummaries: productionDiagnostic.trials.compactMap { trial in
                    guard let summary = trial.canonicalPCM else { return nil }
                    return .init(
                        sampleCount: summary.sampleCount,
                        byteCount: summary.byteCount,
                        frameCount: summary.frameCount,
                        fnv1a64: hexadecimal(summary.fnv1a64)
                    )
                }
            ),
            nativeShippingEvidence: nil
        )
        let encoded = try LiveContextArtifactIO.encodeArtifact(artifact)
        let canaryLeaks = privacyCanaries.reduce(0) { count, sentinel in
            count + LiveContextSentinelScanner.leakCount(sentinel: sentinel, surfaces: [encoded])
        }
        artifact.privacy.artifactLeaks = canaryLeaks
        artifact.privacy.canaryProbeCount += privacyCanaries.count
        return artifact
    }

    private static func validate(_ configuration: LiveContextBenchmarkConfiguration) throws {
        guard configuration.audioFixtureIsPublic else {
            throw LiveContextBenchmarkRunnerError.privateAudioFixtureRejected
        }
        // Zero is a conservative, fixture-bound onset: latency includes any
        // leading silence instead of relying on a caller-selected later mark.
        guard configuration.declaredSpeechOnsetMS == 0,
              configuration.threads > 0,
              configuration.alternatingTrialCount >= 10,
              configuration.resourceSoakSessions > 0,
              configuration.idleSampleSeconds > 0,
              configuration.rssCeilingBytes > 0 else {
            throw LiveContextBenchmarkRunnerError.invalidConfiguration
        }
        for (name, path) in [
            ("corpus", configuration.corpusPath),
            ("audio fixture", configuration.audioFixturePath),
            ("helper", configuration.helperPath),
            ("whisper CLI", configuration.whisperCLIPath),
            ("model", configuration.modelPath),
            ("source root", configuration.sourceRootPath),
            ("hosted receipt", configuration.hostedReceiptPath),
            ("adversarial receipt", configuration.adversarialReceiptPath),
        ] where !FileManager.default.fileExists(atPath: path) {
            throw LiveContextBenchmarkRunnerError.missingInput(name)
        }
        if let vad = configuration.vadModelPath,
           !FileManager.default.fileExists(atPath: vad) {
            throw LiveContextBenchmarkRunnerError.missingInput("VAD model")
        }
    }

    private static func loadAndValidateReceipts(
        configuration: LiveContextBenchmarkConfiguration,
        identity: LiveContextBenchmarkIdentity,
        now: Date = Date()
    ) throws -> ReceiptEvidence {
        let decoder = JSONDecoder()
        guard let hostedData = try? Data(contentsOf: URL(fileURLWithPath: configuration.hostedReceiptPath)),
              receiptJSONIsStrictAndPrivate(hostedData, kind: .hosted),
              let hosted = try? decoder.decode(LiveContextHostedReceipt.self, from: hostedData),
              let adversarialData = try? Data(contentsOf: URL(fileURLWithPath: configuration.adversarialReceiptPath)),
              receiptJSONIsStrictAndPrivate(adversarialData, kind: .adversarial),
              let adversarial = try? decoder.decode(AdversarialReceipt.self, from: adversarialData) else {
            throw LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")
        }
        let hostedCanaryHashes = LiveContextReceiptManifest.hostedPrivacyCanaries(
            gitSHA: identity.gitSHA
        ).map { sha256(Data($0.utf8)) }
        guard hosted.schemaVersion == LiveContextHostedReceipt.currentSchemaVersion,
              receiptIsCurrent(hosted.generatedAt, now: now),
              hosted.gitSHA == identity.gitSHA,
              !hosted.treeIsDirty,
              hosted.sourceManifestSHA256 == (try? LiveContextReceiptManifest.hostedSourceSHA256(
                  sourceRootPath: configuration.sourceRootPath
              )),
              hosted.failureCount == hosted.failures.count,
              hosted.skipCount == hosted.skips.count,
              hosted.failureCount == 0,
              hosted.skipCount == 0,
              hosted.failures.isEmpty,
              hosted.skips.isEmpty,
              hosted.scope == LiveContextHostedReceipt.Scope(),
              hosted.thresholds == LiveContextHostedReceipt.Thresholds(),
              let hostedAttestation = hosted.wrapperAttestation,
              hostedAttestation.testIdentifier == "StenoTests.LiveContextHostedEvidenceTests.produceHostedEvidence",
              hostedAttestation.networkObservationDefinition == "50ms-lsof-polling-hosted-xctest-pid-and-descendants-transient-fds-between-polls-not-observed",
              hostedAttestation.resultBundleScanDefinition == "raw-xcresult-plus-exported-diagnostics-attachments-and-decoded-test-summary-all-derived-deterministic-canaries-scan",
              hostedAttestation.hostedTestProcessID > 0,
              hostedAttestation.observationStartUnixMilliseconds > 0,
              hostedAttestation.observationEndUnixMilliseconds
                  >= hostedAttestation.observationStartUnixMilliseconds,
              hostedAttestation.networkMonitorPerformed,
              hostedAttestation.networkPollIntervalMilliseconds == 50,
              hostedAttestation.networkScanCount > 0,
              hostedAttestation.networkObservationDurationMilliseconds
                  == Int(
                      hostedAttestation.observationEndUnixMilliseconds
                          - hostedAttestation.observationStartUnixMilliseconds
                  ),
              hostedAttestation.maximumObservedProcessTreeCount >= 1,
              hostedAttestation.observedNetworkFileDescriptorCount == 0,
              hostedAttestation.resultBundleScanPerformed,
              hostedAttestation.resultBundleScannedFileCount > 0,
              hostedAttestation.resultBundleCanaryFindings == 0,
              isSHA256(hostedAttestation.resultBundleManifestSHA256),
              hostedAttestation.attestationIdentitySHA256
                  == LiveContextReceiptManifest.hostedWrapperAttestationSHA256(
                      hostedAttestation
                  ),
              hosted.environment.hardwareModelIdentifier.isEmpty == false,
              hosted.environment.operatingSystemVersion.isEmpty == false,
              hosted.environment.architecture.isEmpty == false,
              hosted.environment.trialCount == configuration.alternatingTrialCount,
              hosted.environment.language == configuration.language,
              hosted.environment.transcriptionEngineScope == "production-coordinator-with-injected-synthetic-live-engine",
              hosted.environment.modelRuntimeApplicability == "not-applicable-hosted-synthetic-scope",
              hosted.environment.runtimeNetworkEvidenceOwner == "hosted-wrapper-50ms-process-tree-lsof-plus-runner-adversarial-receipt",
              hosted.environment.systemLogEvidenceApplicability == "not-observed-hosted-static-source-audit-only",
              hosted.environment.crashDiagnosticEvidenceApplicability == "not-observed-hosted-static-source-audit-only",
              hosted.environment.modelPathIdentity == "not-applicable",
              hosted.environment.modelSHA256Identity == "not-applicable",
              hosted.environment.runtimeIdentity == "injected-synthetic-live-engine",
              hosted.environment.helperIdentity == "not-applicable",
              hosted.environment.modelRuntimeReasonCode == "hosted-synthetic-engine-does-not-load-production-model-or-helper",
              hosted.environmentIdentitySHA256 == LiveContextReceiptManifest.hostedEnvironmentSHA256(
                  hosted.environment
              ),
              hosted.syntheticCoordinatorListeningAcknowledgementDefinition == "production-dictation-controller-entry-through-injected-immediate-coordinator-capture-acknowledgement-to-nonactivating-panel-order-return-diagnostic-only",
              hosted.overlayMainActorDefinition == "production-overlay-mainactor-render-start-to-render-complete",
              hosted.syntheticCoordinatorStopToInsertionDefinition == "production-session-coordinator-capture-stop-call-to-injected-synthetic-engine-insertion-complete-diagnostic-only",
              validReceiptDistribution(
                  hosted.syntheticCoordinatorListeningAcknowledgementDiagnostic,
                  minimumCount: 5
              ),
              validReceiptDistribution(hosted.overlayMainActorWork, minimumCount: 5),
              (hosted.syntheticCoordinatorListeningAcknowledgementDiagnostic.p95MS
                  ?? .infinity)
                  <= hosted.thresholds.syntheticCoordinatorListeningDiagnosticP95MS,
              (hosted.overlayMainActorWork.p99MS ?? .infinity)
                  <= hosted.thresholds.overlayMainActorP99MS,
              validReceiptDistribution(
                  hosted.syntheticCoordinatorStopToInsertionEnabledDiagnostic,
                  minimumCount: 5
              ),
              validReceiptDistribution(
                  hosted.syntheticCoordinatorStopToInsertionDisabledControlDiagnostic,
                  minimumCount: 5
              ),
              hosted.renderedUpdateTimestampsMS.count >= 2,
              hosted.renderedUpdateTimestampsMS.allSatisfy({ $0.isFinite && $0 >= 0 }),
              maximumBurstUpdatesPerSecond(hosted.renderedUpdateTimestampsMS)
                  <= hosted.thresholds.maximumVisibleUpdatesPerSecond,
              hosted.overlayMainActorWork.count == hosted.renderedPreviewCount,
              hosted.acceptedPreviewCount > hosted.renderedPreviewCount,
              hosted.renderedPreviewCount == hosted.renderedUpdateTimestampsMS.count,
              hosted.maximumQueueDepth > 0,
              hosted.coalescedPreviewCount > 0,
              hosted.acceptedPreviewCount == hosted.renderedPreviewCount + hosted.coalescedPreviewCount,
              hosted.trialOrder == (0..<configuration.alternatingTrialCount).map({
                  $0.isMultiple(of: 2) ? .enabled : .disabled
              }),
              hosted.configurationIdentitySHA256 == LiveContextReceiptManifest.hostedConfigurationSHA256(
                  gitSHA: identity.gitSHA,
                  sourceManifestSHA256: hosted.sourceManifestSHA256,
                  language: configuration.language,
                  trialCount: configuration.alternatingTrialCount
              ),
              hosted.lifecycle.randomizedSessions >= 1_000,
              hosted.lifecycle.rapidCancelRestartCases >= 250,
              hosted.lifecycle.targetTransitions >= 10_000,
              hosted.lifecycle.authoritativeFinishCalls > 0,
              hosted.lifecycle.maximumAuthoritativeFinishCallsPerSession == 1,
              hosted.lifecycle.coordinatorSecondFinalInferenceAttempts == 0,
              hosted.lifecycle.expectedFinalInsertionCount > 0,
              hosted.lifecycle.finalInsertionCount == hosted.lifecycle.expectedFinalInsertionCount,
              hosted.noSpeechDisplayDefinition == "production-session-coordinator-live-snapshot-through-production-overlay-preview-rendered-observer",
              hosted.correctness.provisionalSideEffects == 0,
              hosted.correctness.duplicateFinalInsertions == 0,
              hosted.correctness.staleEventsAccepted == 0,
              hosted.correctness.speechPreviewRenderedControlCount > 0,
              hosted.correctness.noSpeechFalseDisplays == 0,
              hostedCanaryHashes.count == 4,
              hosted.privacy.canaryDerivationDefinition
                  == LiveContextReceiptManifest.hostedPrivacyCanaryDerivationDefinition,
              hosted.privacy.baseCanarySHA256 == hostedCanaryHashes[0],
              hosted.privacy.provisionalCanarySHA256 == hostedCanaryHashes[1],
              hosted.privacy.contextCanarySHA256 == hostedCanaryHashes[2],
              hosted.privacy.snippetExpansionCanarySHA256 == hostedCanaryHashes[3],
              hosted.privacy.provisionalCanaryInjectionCount > 0,
              hosted.privacy.contextCanaryInjectionCount > 0,
              hosted.privacy.snippetCanaryInjectionCount > 0,
              hosted.privacy.scannedSurfaceCount > 0,
              hosted.privacy.configuredSnippetTrapCount > 0,
              hosted.privacy.snippetTrapActivations == 0,
              hosted.privacy.liveCallbackProvisionalObservations > 0,
              hosted.privacy.liveCallbackUnexpectedContextLeaks == 0,
              hosted.privacy.unavailableCallbackObservations > 0,
              hosted.privacy.overlayRetainedTextLeaks == 0,
              hosted.privacy.injectedURLProtocolSelfTestHits == 1,
              hosted.privacy.injectedURLProtocolProductionPathHits == 0,
              hosted.privacy.secureFieldContextReadRequests == 0,
              hosted.privacy.maximumAXUTF16ReadPerSide > 0,
              hosted.privacy.maximumAXUTF16ReadPerSide <= 512,
              hosted.privacy.maximumAXGraphemesPerSide > 0,
              hosted.privacy.maximumAXGraphemesPerSide <= 256,
              hosted.privacy.maximumAXContextBytes > 0,
              hosted.privacy.maximumAXContextBytes <= 8 * 1_024,
              hostedPrivacyLeakCount(hosted.privacy) == 0,
              hosted.staticAudit.boundHostedSourceManifestSHA256 == hosted.sourceManifestSHA256,
              hosted.staticAudit.scopeDefinition == "static-findings-scan-hosted-production-relative-paths-only-evidence-files-hash-bound-only",
              hosted.staticAudit.auditedFileCount == LiveContextReceiptManifest.hostedProductionRelativePaths.count,
              hosted.staticAudit.featureLogInvocationSourceAuditPerformed,
              hosted.staticAudit.featureLogInvocationSourceFindings == 0,
              hosted.staticAudit.crashMetadataSinkReferenceSourceAuditPerformed,
              hosted.staticAudit.crashMetadataSinkReferenceSourceFindings == 0,
              hosted.staticAudit.ephemeralPersistenceSourceAuditPerformed,
              hosted.staticAudit.ephemeralPersistenceSourceFindings == 0,
              hosted.staticAudit.ephemeralFilenameDiagnosticSourceAuditPerformed,
              hosted.staticAudit.ephemeralFilenameDiagnosticSourceFindings == 0,
              hosted.staticAudit.prohibitedNetworkAPISourceAuditPerformed,
              hosted.staticAudit.prohibitedNetworkAPISourceFindings == 0 else {
            throw LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")
        }

        let requiredCategories = ["authoritativeIntegrity", "compatibility", "protocolValidation", "terminalPriority", "speechEvidence", "parserBounds", "receiptIntegrity", "lifecycleCrashEOF"]
        let manifestEntries = Dictionary(
            uniqueKeysWithValues: adversarial.sourceFixtureManifest.entries.map { ($0.role, $0) }
        )
        let expectedManifestRoles = ["audioFixture", "harnessSource", "helperBinary", "helperSource", "vadModel", "whisperModel"]
        let repository = URL(fileURLWithPath: configuration.sourceRootPath)
        let helperSourcePath = repository.appendingPathComponent("runtime-helper/steno_whisper_runtime.cpp").path
        let harnessPath = repository.appendingPathComponent("scripts/test-whisper-runtime-helper-v2.py").path
        let manifestPath: (String) -> String = { path in
            let root = repository.standardizedFileURL.path + "/"
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            return standardized.hasPrefix(root) ? String(standardized.dropFirst(root.count)) : standardized
        }
        let canonicalManifestHash = canonicalJSONSHA256(
            adversarial.sourceFixtureManifest.entries.map {
                ["path": $0.path, "role": $0.role, "sha256": $0.sha256]
            }
        )
        guard adversarial.schemaVersion == 2,
              receiptIsCurrent(adversarial.generatedAt, now: now),
              adversarial.git.sha == identity.gitSHA,
              adversarial.git.state == (adversarial.git.dirty ? "dirty" : "clean"),
              !adversarial.git.dirty,
              adversarial.protocolVersions.contains(2),
              adversarial.execution.requestedDeviceMode == "default",
              adversarial.execution.productionMetalSmokePerformed,
              adversarial.execution.backend == "observed-metal",
              adversarial.execution.qualification == "qualifying-production-metal",
              adversarial.execution.matrix == "full-adversarial",
              adversarial.execution.backendEligibleProcessCount > 0,
              adversarial.execution.backendEligibleProcessCount <= 10_000,
              adversarial.execution.attestedProcessCount > 0,
              adversarial.execution.attestedProcessCount <= 10_000,
              adversarial.execution.attestedProcessCount == adversarial.execution.backendEligibleProcessCount,
              adversarial.execution.observedBackends.cpu == 0,
              adversarial.execution.observedBackends.unknown == 0,
              adversarial.execution.observedBackends.metal == adversarial.execution.attestedProcessCount,
              adversarial.identity.schema > 0,
              adversarial.identity.capabilities > 0,
              !adversarial.identity.runtime.isEmpty,
              !adversarial.identity.model.isEmpty,
              adversarial.identity.helperBinary == identity.runtimeIdentity,
              adversarial.identity.helperBinarySHA256 == identity.runtimeSHA256,
              !adversarial.environment.hardware.architecture.isEmpty,
              !adversarial.environment.hardware.chip.isEmpty,
              adversarial.environment.hardware.logicalProcessorCount > 0,
              adversarial.environment.hardware.memoryBytes > 0,
              !adversarial.environment.hardware.modelIdentifier.isEmpty,
              adversarial.environment.operatingSystem.name == "macOS",
              !adversarial.environment.operatingSystem.version.isEmpty,
              !adversarial.environment.operatingSystem.build.isEmpty,
              adversarial.configuration.audio.channelCount == 1,
              adversarial.configuration.audio.encoding == "signed-integer-little-endian",
              adversarial.configuration.audio.sampleRateHz == 16_000,
              adversarial.configuration.audio.sampleWidthBytes == 2,
              adversarial.configuration.bounds.maximumAppendBytes == 32_768,
              adversarial.configuration.bounds.maximumAppendSamples == 16_384,
              adversarial.configuration.bounds.maximumHypothesisBytes == 1_048_576,
              adversarial.configuration.bounds.maximumPayloadBytes == 67_108_864,
              adversarial.configuration.bounds.maximumStreamSamples == 691_200_000,
              adversarial.configuration.bounds.maximumStringBytes == 1_048_576,
              adversarial.configuration.bounds.previewWindowSamples == 192_000,
              adversarial.configuration.harnessTimeoutsSeconds.backendAttestation == 2,
              adversarial.configuration.harnessTimeoutsSeconds.defaultFrameRead == 5,
              adversarial.configuration.harnessTimeoutsSeconds.inference == 30,
              adversarial.configuration.harnessTimeoutsSeconds.loadReady == 15,
              adversarial.configuration.harnessTimeoutsSeconds.networkMonitorStartup == 3,
              adversarial.configuration.harnessTimeoutsSeconds.networkPollInterval == 0.05,
              adversarial.configuration.inferenceThresholds.entropyThreshold == 2.4,
              adversarial.configuration.inferenceThresholds.logProbabilityThreshold == -1,
              adversarial.configuration.inferenceThresholds.noSpeechThreshold == 0.6,
              adversarial.configuration.inferenceThresholds.temperature == 0,
              adversarial.configuration.inferenceThresholds.temperatureIncrement == 0.2,
              adversarial.configuration.streamRequest.beamSize == 1,
              adversarial.configuration.streamRequest.bestOf == 1,
              adversarial.configuration.streamRequest.flags == 3,
              adversarial.configuration.streamRequest.language == configuration.language,
              adversarial.configuration.streamRequest.threads == configuration.threads,
              adversarial.configuration.streamRequest.vadEnabled == (configuration.vadModelPath != nil),
              adversarial.configuration.streamRequest.suppressNonSpeechTokens,
              adversarial.configuration.streamRequest.prompt == nil,
              adversarial.configuration.streamRequest.suppressRegex == nil,
              adversarial.configuration.vadThresholds.maximumSpeechDurationSeconds == "FLT_MAX",
              adversarial.configuration.vadThresholds.minimumSilenceDurationMS == 100,
              adversarial.configuration.vadThresholds.minimumSpeechDurationMS == 250,
              adversarial.configuration.vadThresholds.previewScope == "newly-accepted-audio-since-prior-admitted-decode",
              adversarial.configuration.vadThresholds.samplesOverlap == 0.1,
              adversarial.configuration.vadThresholds.speechPadMS == 30,
              adversarial.configuration.vadThresholds.threshold == 0.5,
              adversarial.sourceFixtureManifest.algorithm == "sha256-canonical-json-v1",
              adversarial.sourceFixtureManifest.entries.map(\.role) == expectedManifestRoles,
              manifestEntries.count == expectedManifestRoles.count,
              adversarial.sourceFixtureManifest.sha256 == canonicalManifestHash,
              adversarial.hashes.sourceFixtureManifestSHA256 == canonicalManifestHash,
              adversarial.cases.expected == 22,
              adversarial.cases.passed == adversarial.cases.expected,
              adversarial.cases.failed == 0,
              adversarial.cases.skipped == 0,
              adversarial.cases.failureRows.isEmpty,
              adversarial.cases.skipRows.isEmpty,
              adversarial.cases.rows.count == adversarial.cases.expected,
              Set(adversarial.cases.rows.map(\.name)) == Set(adversarialCaseNamesByCategory.values.flatMap { $0 }),
              adversarial.cases.rows.allSatisfy({ row in
                  row.status == "passed" && row.failureReason == nil && row.skipReason == nil
                      && row.durationMS.isFinite && row.durationMS >= 0
                      && adversarialCaseNamesByCategory[row.category]?.contains(row.name) == true
              }),
              requiredCategories.allSatisfy({ category in
                  guard let count = adversarial.cases.categories[category] else { return false }
                  let rowCount = adversarial.cases.rows.count { $0.category == category }
                  return count.expected == rowCount && count.passed == count.expected
                      && count.failed == 0 && count.skipped == 0
              }),
              adversarial.hashes.helperBinarySHA256 == identity.runtimeSHA256,
              adversarial.hashes.helperSourceSHA256 == sha256File(helperSourcePath),
              adversarial.hashes.harnessSHA256 == sha256File(harnessPath),
              adversarial.hashes.modelSHA256 == identity.modelSHA256,
              adversarial.hashes.vadModelSHA256 == identity.vadModelSHA256,
              adversarial.hashes.audioSHA256 == sha256File(configuration.audioFixturePath),
              [adversarial.hashes.harnessSHA256, adversarial.hashes.helperSourceSHA256,
               adversarial.hashes.canarySHA256].allSatisfy(isSHA256),
              adversarial.hashes.canarySHA256 == sha256(Data("STENO-PUBLIC-PROTOCOL-CANARY-V1".utf8)),
              adversarial.audio.expectedSampleCount > 0,
              adversarial.audio.observedSampleCount == adversarial.audio.expectedSampleCount,
              adversarial.audio.channelCount == 1,
              adversarial.audio.sampleWidthBytes == 2,
              adversarial.audio.sampleRateHz == 16_000,
              UInt64(adversarial.audio.fnv1a64, radix: 16) != nil,
              adversarial.audio.fnv1a64.count == 16,
              manifestEntries["audioFixture"]?.path == manifestPath(configuration.audioFixturePath),
              manifestEntries["audioFixture"]?.sha256 == adversarial.hashes.audioSHA256,
              manifestEntries["harnessSource"]?.path == manifestPath(harnessPath),
              manifestEntries["harnessSource"]?.sha256 == adversarial.hashes.harnessSHA256,
              manifestEntries["helperBinary"]?.path == manifestPath(configuration.helperPath),
              manifestEntries["helperBinary"]?.sha256 == adversarial.hashes.helperBinarySHA256,
              manifestEntries["helperSource"]?.path == manifestPath(helperSourcePath),
              manifestEntries["helperSource"]?.sha256 == adversarial.hashes.helperSourceSHA256,
              manifestEntries["whisperModel"]?.path == URL(fileURLWithPath: configuration.modelPath).standardizedFileURL.path,
              manifestEntries["whisperModel"]?.sha256 == adversarial.hashes.modelSHA256,
              manifestEntries["vadModel"]?.path == configuration.vadModelPath.map({
                  URL(fileURLWithPath: $0).standardizedFileURL.path
              }),
              manifestEntries["vadModel"]?.sha256 == adversarial.hashes.vadModelSHA256,
              adversarial.artifacts.audioFixture.path == manifestEntries["audioFixture"]?.path,
              adversarial.artifacts.audioFixture.sha256 == adversarial.hashes.audioSHA256,
              adversarial.artifacts.helper.path == manifestEntries["helperBinary"]?.path,
              adversarial.artifacts.helper.sha256 == adversarial.hashes.helperBinarySHA256,
              adversarial.artifacts.model.path == manifestEntries["whisperModel"]?.path,
              adversarial.artifacts.model.sha256 == adversarial.hashes.modelSHA256,
              adversarial.artifacts.vadModel.path == manifestEntries["vadModel"]?.path,
              adversarial.artifacts.vadModel.sha256 == adversarial.hashes.vadModelSHA256,
              adversarial.canary.scannedSurfaceCount > 0,
              adversarial.canary.escapes == 0,
              !adversarial.fallback.performed,
              adversarial.fallback.attempts == 0,
              adversarial.fallback.successes == 0,
              adversarial.network.undefinedSymbolScanPerformed,
              adversarial.network.runtimeMonitorPerformed,
              adversarial.network.continuous,
              adversarial.network.checkedProcessCount > 0,
              adversarial.network.ownedProcessCount <= 10_000,
              adversarial.network.checkedProcessCount == adversarial.network.ownedProcessCount,
              adversarial.execution.backendEligibleProcessCount <= adversarial.network.ownedProcessCount,
              adversarial.network.minimumScanCountPerProcess >= 2,
              adversarial.network.minimumScanCountPerProcess <= 100_000,
              adversarial.network.scanCount >= adversarial.network.ownedProcessCount
                  * adversarial.network.minimumScanCountPerProcess,
              adversarial.network.pollIntervalMS == 50,
              adversarial.network.observationDurationMS >= adversarial.network.pollIntervalMS
                  * (adversarial.network.minimumScanCountPerProcess - 1),
              adversarial.network.observedNetworkFileDescriptorCount == 0,
              adversarial.network.observedNetworkFDCount == adversarial.network.observedNetworkFileDescriptorCount,
              adversarial.network.prohibitedUndefinedSymbols.isEmpty else {
            throw LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("adversarial")
        }
        let crash = adversarial.cases.categories["lifecycleCrashEOF"]!
        let malformedCategories = ["protocolValidation", "terminalPriority", "parserBounds"]
        let malformedExpected = malformedCategories.compactMap { adversarial.cases.categories[$0]?.expected }.reduce(0, +)
        let malformedPassed = malformedCategories.compactMap { adversarial.cases.categories[$0]?.passed }.reduce(0, +)
        return ReceiptEvidence(
            hosted: hosted,
            adversarial: adversarial,
            helperCrashExpected: crash.expected,
            helperCrashPassed: crash.passed,
            malformedExpected: malformedExpected,
            malformedPassed: malformedPassed
        )
    }

    static func validateEvidenceReceipts(
        configuration: LiveContextBenchmarkConfiguration,
        identity: LiveContextBenchmarkIdentity,
        now: Date = Date()
    ) throws {
        _ = try loadAndValidateReceipts(configuration: configuration, identity: identity, now: now)
    }

    static func adversarialReceiptSchemaDecodes(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        return receiptJSONIsStrictAndPrivate(data, kind: .adversarial)
            && (try? JSONDecoder().decode(AdversarialReceipt.self, from: data)) != nil
    }

    static func adversarialReceiptQualificationFailures(at path: String) -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              receiptJSONIsStrictAndPrivate(data, kind: .adversarial),
              let receipt = try? JSONDecoder().decode(AdversarialReceipt.self, from: data) else {
            return ["unsupported-adversarial-receipt-schema"]
        }
        var failures: [String] = []
        if receipt.git.dirty || receipt.git.state != "clean" { failures.append("dirty-git-tree") }
        if receipt.execution.requestedDeviceMode != "default"
            || receipt.execution.backend != "observed-metal"
            || receipt.execution.qualification != "qualifying-production-metal"
            || !receipt.execution.productionMetalSmokePerformed {
            failures.append("non-metal-backend")
        }
        if receipt.cases.expected != 22
            || Set(receipt.cases.rows.map(\.name))
                != Set(adversarialCaseNamesByCategory.values.flatMap { $0 }) {
            failures.append("adversarial-catalog-mismatch")
        }
        return failures
    }

    static func captureParityFailureRows(
        _ trials: [EnabledTrial],
        expectedAudioSampleCount: Int,
        expectedFNV1A64: String? = nil
    ) -> [LiveContextFailureRow] {
        var failures: [LiveContextFailureRow] = []
        for (index, trial) in trials.enumerated() {
            if trial.summary.sampleCount != trial.canonicalSummary.sampleCount {
                failures.append(.init(id: "capture-parity:\(index)", reasonCode: "sample-count-mismatch"))
            }
            if trial.pcmSHA256 != trial.canonicalPCMSHA256 {
                failures.append(.init(id: "capture-parity:\(index)", reasonCode: "pcm-hash-mismatch"))
            }
            if Int(trial.canonicalSummary.sampleCount) != expectedAudioSampleCount {
                failures.append(.init(id: "capture-parity:\(index)", reasonCode: "receipt-canonical-sample-count-mismatch"))
            }
            if let expectedFNV1A64,
               hexadecimal(trial.summary.fnv1a64) != expectedFNV1A64
                || hexadecimal(trial.canonicalSummary.fnv1a64) != expectedFNV1A64 {
                failures.append(.init(id: "capture-parity:\(index)", reasonCode: "receipt-fnv-mismatch"))
            }
        }
        if Set(trials.map { $0.canonicalSummary.sampleCount }).count > 1 {
            failures.append(.init(id: "capture-parity:all", reasonCode: "canonical-sample-count-varied-across-trials"))
        }
        if Set(trials.map(\.canonicalPCMSHA256)).count > 1 {
            failures.append(.init(id: "capture-parity:all", reasonCode: "canonical-pcm-hash-varied-across-trials"))
        }
        return failures
    }

    private enum ReceiptKind { case hosted, adversarial }

    private static func receiptJSONIsStrictAndPrivate(_ data: Data, kind: ReceiptKind) -> Bool {
        let genericPrivacyIsValid = (try? LiveContextArtifactIO.validatePrivacy(of: data)) == true
        if case .hosted = kind, !genericPrivacyIsValid { return false }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              rawReceiptStringsAreSafe(root) else { return false }
        switch kind {
        case .hosted: return strictHostedReceipt(root)
        case .adversarial: return strictAdversarialReceipt(root)
        }
    }

    private static func rawReceiptStringsAreSafe(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary.allSatisfy { rawReceiptStringsAreSafe($0.value) }
        }
        if let array = value as? [Any] {
            return array.allSatisfy(rawReceiptStringsAreSafe)
        }
        guard let string = value as? String else { return true }
        let lowered = string.lowercased()
        return !lowered.contains("steno-live-context-hosted-canary")
            && !lowered.contains("steno-live-context-canary")
            && !lowered.contains("steno-public-protocol-canary")
    }

    private static func hasExactKeys(_ dictionary: [String: Any], _ keys: Set<String>) -> Bool {
        Set(dictionary.keys) == keys
    }

    private static func object(_ dictionary: [String: Any], _ key: String) -> [String: Any]? {
        dictionary[key] as? [String: Any]
    }

    private static func objects(_ dictionary: [String: Any], _ key: String) -> [[String: Any]]? {
        dictionary[key] as? [[String: Any]]
    }

    private static func strictDistribution(_ value: Any?) -> Bool {
        guard let dictionary = value as? [String: Any] else { return false }
        return hasExactKeys(dictionary, ["samplesMS", "count", "p50MS", "p95MS", "p99MS"])
    }

    private static func strictHostedReceipt(_ root: [String: Any]) -> Bool {
        guard hasExactKeys(root, [
            "schemaVersion", "generatedAt", "gitSHA", "treeIsDirty", "sourceManifestSHA256",
            "failureCount", "skipCount", "failures", "skips", "scope", "thresholds",
            "wrapperAttestation", "environment",
            "environmentIdentitySHA256",
            "syntheticCoordinatorListeningAcknowledgementDefinition",
            "syntheticCoordinatorListeningAcknowledgementDiagnostic",
            "overlayMainActorDefinition", "overlayMainActorWork", "renderedUpdateTimestampsMS",
            "syntheticCoordinatorStopToInsertionDefinition",
            "syntheticCoordinatorStopToInsertionEnabledDiagnostic",
            "syntheticCoordinatorStopToInsertionDisabledControlDiagnostic",
            "acceptedPreviewCount", "renderedPreviewCount", "maximumQueueDepth", "coalescedPreviewCount",
            "trialOrder", "configurationIdentitySHA256",
            "lifecycle", "noSpeechDisplayDefinition", "correctness", "privacy", "staticAudit",
        ]),
        let failures = objects(root, "failures"),
        failures.allSatisfy({ hasExactKeys($0, ["id", "reasonCode"]) }),
        let skips = objects(root, "skips"),
        skips.allSatisfy({ hasExactKeys($0, ["id", "reasonCode"]) }),
        let scope = object(root, "scope"),
        hasExactKeys(scope, [
            "evidenceClassification", "canQualifyShippingAlone", "thresholdEvidenceOwner",
            "audioSampleEvidenceOwner", "modelRuntimeEvidenceOwner", "runtimeNetworkEvidenceOwner",
            "expectedAudioSampleCount", "observedAudioSampleCount", "audioSampleCountReasonCode",
        ]),
        let thresholds = object(root, "thresholds"),
        hasExactKeys(thresholds, [
            "syntheticCoordinatorListeningDiagnosticP95MS", "overlayMainActorP99MS",
            "maximumVisibleUpdatesPerSecond",
        ]),
        let wrapperAttestation = object(root, "wrapperAttestation"),
        hasExactKeys(wrapperAttestation, [
            "testIdentifier", "networkObservationDefinition", "resultBundleScanDefinition",
            "hostedTestProcessID", "observationStartUnixMilliseconds",
            "observationEndUnixMilliseconds", "networkMonitorPerformed",
            "networkPollIntervalMilliseconds", "networkScanCount",
            "networkObservationDurationMilliseconds", "maximumObservedProcessTreeCount",
            "observedNetworkFileDescriptorCount", "resultBundleScanPerformed",
            "resultBundleScannedFileCount", "resultBundleCanaryFindings",
            "resultBundleManifestSHA256", "attestationIdentitySHA256",
        ]),
        let environment = object(root, "environment"),
        hasExactKeys(environment, [
            "hardwareModelIdentifier", "operatingSystemVersion", "architecture",
            "trialCount", "language", "transcriptionEngineScope", "modelRuntimeApplicability",
            "runtimeNetworkEvidenceOwner", "systemLogEvidenceApplicability",
            "crashDiagnosticEvidenceApplicability", "modelPathIdentity",
            "modelSHA256Identity", "runtimeIdentity", "helperIdentity", "modelRuntimeReasonCode",
        ]),
        strictDistribution(root["syntheticCoordinatorListeningAcknowledgementDiagnostic"]),
        strictDistribution(root["overlayMainActorWork"]),
        strictDistribution(root["syntheticCoordinatorStopToInsertionEnabledDiagnostic"]),
        strictDistribution(root["syntheticCoordinatorStopToInsertionDisabledControlDiagnostic"]),
        let lifecycle = object(root, "lifecycle"),
        hasExactKeys(lifecycle, ["randomizedSessions", "rapidCancelRestartCases", "targetTransitions", "authoritativeFinishCalls", "maximumAuthoritativeFinishCallsPerSession", "coordinatorSecondFinalInferenceAttempts", "finalInsertionCount", "expectedFinalInsertionCount"]),
        let correctness = object(root, "correctness"),
        hasExactKeys(correctness, ["provisionalSideEffects", "duplicateFinalInsertions", "staleEventsAccepted", "speechPreviewRenderedControlCount", "noSpeechFalseDisplays"]),
        let privacy = object(root, "privacy"),
        let staticAudit = object(root, "staticAudit") else { return false }
        return hasExactKeys(privacy, [
            "canaryDerivationDefinition", "baseCanarySHA256", "provisionalCanarySHA256",
            "contextCanarySHA256", "snippetExpansionCanarySHA256",
            "provisionalCanaryInjectionCount", "contextCanaryInjectionCount",
            "snippetCanaryInjectionCount", "scannedSurfaceCount", "requestLeaks",
            "cleanupLeaks", "historyLeaks", "insertionLeaks", "clipboardRecoveryLeaks",
            "analyticsLeaks", "configuredSnippetTrapCount", "snippetTrapActivations",
            "liveCallbackProvisionalObservations", "liveCallbackUnexpectedContextLeaks",
            "unavailableCallbackObservations", "overlayRetainedTextLeaks",
            "injectedURLProtocolSelfTestHits", "injectedURLProtocolProductionPathHits",
            "secureFieldContextReadRequests", "maximumAXUTF16ReadPerSide",
            "maximumAXGraphemesPerSide", "maximumAXContextBytes",
        ]) && hasExactKeys(staticAudit, [
            "boundHostedSourceManifestSHA256", "scopeDefinition", "auditedFileCount",
            "featureLogInvocationSourceAuditPerformed", "featureLogInvocationSourceFindings",
            "crashMetadataSinkReferenceSourceAuditPerformed", "crashMetadataSinkReferenceSourceFindings",
            "ephemeralPersistenceSourceAuditPerformed", "ephemeralPersistenceSourceFindings",
            "ephemeralFilenameDiagnosticSourceAuditPerformed", "ephemeralFilenameDiagnosticSourceFindings",
            "prohibitedNetworkAPISourceAuditPerformed", "prohibitedNetworkAPISourceFindings",
        ])
    }

    private static func strictAdversarialReceipt(_ root: [String: Any]) -> Bool {
        guard hasExactKeys(root, ["schemaVersion", "generatedAt", "git", "protocolVersions", "execution", "environment", "identity", "configuration", "sourceFixtureManifest", "cases", "hashes", "artifacts", "audio", "canary", "fallback", "network"]),
              let git = object(root, "git"), hasExactKeys(git, ["sha", "dirty", "state"]),
              let execution = object(root, "execution"), hasExactKeys(execution, ["requestedDeviceMode", "backend", "backendEligibleProcessCount", "attestedProcessCount", "observedBackends", "productionMetalSmokePerformed", "qualification", "matrix"]),
              let observedBackends = object(execution, "observedBackends"), hasExactKeys(observedBackends, ["cpu", "metal", "unknown"]),
              let environment = object(root, "environment"), hasExactKeys(environment, ["hardware", "operatingSystem"]),
              let hardware = object(environment, "hardware"), hasExactKeys(hardware, ["architecture", "chip", "logicalProcessorCount", "memoryBytes", "modelIdentifier"]),
              let operatingSystem = object(environment, "operatingSystem"), hasExactKeys(operatingSystem, ["build", "name", "version"]),
              let identity = object(root, "identity"), hasExactKeys(identity, ["schema", "capabilities", "runtime", "model", "vad", "helperBinary", "helperBinarySHA256"]),
              let configuration = object(root, "configuration"), hasExactKeys(configuration, ["audio", "bounds", "harnessTimeoutsSeconds", "inferenceThresholds", "streamRequest", "vadThresholds"]),
              let configurationAudio = object(configuration, "audio"), hasExactKeys(configurationAudio, ["channelCount", "encoding", "sampleRateHz", "sampleWidthBytes"]),
              let bounds = object(configuration, "bounds"), hasExactKeys(bounds, ["maximumAppendBytes", "maximumAppendSamples", "maximumHypothesisBytes", "maximumPayloadBytes", "maximumStreamSamples", "maximumStringBytes", "previewWindowSamples"]),
              let timeouts = object(configuration, "harnessTimeoutsSeconds"), hasExactKeys(timeouts, ["backendAttestation", "defaultFrameRead", "inference", "loadReady", "networkMonitorStartup", "networkPollInterval"]),
              let inference = object(configuration, "inferenceThresholds"), hasExactKeys(inference, ["entropyThreshold", "logProbabilityThreshold", "noSpeechThreshold", "temperature", "temperatureIncrement"]),
              let stream = object(configuration, "streamRequest"), hasExactKeys(stream, ["beamSize", "bestOf", "flags", "language", "prompt", "suppressNonSpeechTokens", "suppressRegex", "threads", "vadEnabled"]),
              let vad = object(configuration, "vadThresholds"), hasExactKeys(vad, ["maximumSpeechDurationSeconds", "minimumSilenceDurationMS", "minimumSpeechDurationMS", "previewScope", "samplesOverlap", "speechPadMS", "threshold"]),
              let manifest = object(root, "sourceFixtureManifest"), hasExactKeys(manifest, ["algorithm", "sha256", "entries"]),
              let manifestEntries = objects(manifest, "entries"), manifestEntries.allSatisfy({ hasExactKeys($0, ["role", "path", "sha256"]) }),
              let cases = object(root, "cases"), hasExactKeys(cases, ["expected", "passed", "failed", "skipped", "categories", "failureRows", "skipRows", "rows"]),
              let categories = object(cases, "categories"), Set(categories.keys) == Set(adversarialCaseNamesByCategory.keys),
              categories.values.allSatisfy({ value in
                  guard let count = value as? [String: Any] else { return false }
                  return hasExactKeys(count, ["expected", "passed", "failed", "skipped"])
              }),
              let rows = objects(cases, "rows"), rows.allSatisfy({ hasExactKeys($0, ["category", "durationMS", "name", "status", "failureReason", "skipReason"]) }),
              let failureRows = objects(cases, "failureRows"), failureRows.allSatisfy({ hasExactKeys($0, ["category", "durationMS", "name", "status", "failureReason", "skipReason"]) }),
              let skipRows = objects(cases, "skipRows"), skipRows.allSatisfy({ hasExactKeys($0, ["category", "durationMS", "name", "status", "failureReason", "skipReason"]) }),
              let hashes = object(root, "hashes"), hasExactKeys(hashes, ["harnessSHA256", "helperSourceSHA256", "helperBinarySHA256", "modelSHA256", "vadModelSHA256", "audioSHA256", "canarySHA256", "sourceFixtureManifestSHA256"]),
              let artifacts = object(root, "artifacts"), hasExactKeys(artifacts, ["audioFixture", "helper", "model", "vadModel"]),
              artifacts.values.allSatisfy({ value in
                  guard let reference = value as? [String: Any] else { return false }
                  return hasExactKeys(reference, ["path", "sha256"])
              }),
              let audio = object(root, "audio"), hasExactKeys(audio, ["expectedSampleCount", "observedSampleCount", "channelCount", "sampleWidthBytes", "sampleRateHz", "fnv1a64"]),
              let canary = object(root, "canary"), hasExactKeys(canary, ["scannedSurfaceCount", "escapes"]),
              let fallback = object(root, "fallback"), hasExactKeys(fallback, ["performed", "attempts", "successes"]),
              let network = object(root, "network") else { return false }
        return hasExactKeys(network, ["undefinedSymbolScanPerformed", "prohibitedUndefinedSymbols", "runtimeMonitorPerformed", "checkedProcessCount", "ownedProcessCount", "observedNetworkFileDescriptorCount", "observedNetworkFDCount", "continuous", "scanCount", "observationDurationMS", "minimumScanCountPerProcess", "pollIntervalMS"])
    }

    private static func validReceiptDistribution(_ distribution: LiveLatencyDistribution, minimumCount: Int) -> Bool {
        guard distribution.count >= minimumCount,
              distribution.count == distribution.samplesMS.count,
              distribution.samplesMS.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        return distribution == .summarize(distribution.samplesMS)
    }

    private static func hostedPrivacyLeakCount(_ privacy: LiveContextHostedReceipt.Privacy) -> Int {
        [privacy.requestLeaks, privacy.cleanupLeaks, privacy.historyLeaks,
         privacy.insertionLeaks, privacy.clipboardRecoveryLeaks, privacy.analyticsLeaks,
         privacy.snippetTrapActivations, privacy.liveCallbackUnexpectedContextLeaks,
         privacy.overlayRetainedTextLeaks,
         privacy.secureFieldContextReadRequests].reduce(0, +)
    }

    private static func receiptIsCurrent(_ value: String, now: Date) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        return age.isFinite && age >= 0 && age <= 86_400
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hexadecimal(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    private static func sourceOccurrenceCount(_ needle: String, path: String) -> Int {
        guard !needle.isEmpty,
              let source = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        var count = 0
        var searchRange = source.startIndex..<source.endIndex
        while let range = source.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<source.endIndex
        }
        return count
    }

    static func canonicalJSONSHA256(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return sha256(data)
    }


    static func runEnabledTrial(
        engine: any LiveTranscriptionEngine,
        audioURL: URL,
        request: TranscriptionRequest,
        speechOnsetMS: Int,
        realtimePacing: Bool
    ) async throws -> EnabledTrial {
        let sessionID = UUID()
        let generation = UUID()
        let started = ContinuousClock.now
        let session = try await engine.startLiveTranscription(
            sessionID: sessionID,
            controllerGeneration: generation,
            request: request
        )
        let startMS = elapsedMS(since: started)
        do {
        let streamer = try CanonicalWAVFrameStreamer(
            sessionID: sessionID,
            audioURL: audioURL,
            maximumFrameBytes: 8_000,
            maximumFramesPerPoll: 8
        )
        var poll = try await streamer.finalize(sessionID: sessionID)
        var finalSummary: LivePCMStreamSummary?
        var pcmHasher = SHA256()
        var reducer = ProvisionalTranscriptReducer(session: session)
        var previousStable = ""
        var stableConflicts = 0
        var firstPartial: Double?
        var lastPartialTime: Double?
        var gaps: [Double] = []
        var eventCount = 0
        var noSpeechFalseDisplays = 0
        var frameSequenceOrOffsetDiscontinuities = 0
        var expectedFrameSequence: UInt64 = 0
        var expectedSampleOffset: UInt64 = 0
        var observedFrameCount: UInt64 = 0
        var revision: UInt64 = 0
        var hasherUsageBefore = LiveContextProcessProbe.currentHelperUsage()

        while true {
          for frame in poll.frames {
            if frame.sequenceNumber != expectedFrameSequence
                || frame.sampleOffset != expectedSampleOffset {
                frameSequenceOrOffsetDiscontinuities += 1
            }
            expectedFrameSequence = frame.sequenceNumber &+ 1
            expectedSampleOffset = frame.sampleOffset &+ UInt64(frame.sampleCount)
            observedFrameCount &+= 1
            pcmHasher.update(data: frame.pcmS16LE)
            if realtimePacing {
                let frameEndMS = Double(frame.sampleOffset + UInt64(frame.sampleCount)) / 16
                let remaining = frameEndMS - elapsedMS(since: started)
                if remaining > 0 { try await Task.sleep(for: .milliseconds(remaining)) }
            }
            try await engine.appendLiveAudio(frame, session: session)
            guard frame.sampleOffset + UInt64(frame.sampleCount) >= UInt64(speechOnsetMS * 16) else {
                continue
            }
            revision &+= 1
            let rawEvent = try await engine.requestLiveHypothesis(
                session: session,
                revision: revision,
                decodedAudioWatermark: frame.sampleOffset + UInt64(frame.sampleCount)
            )
            let evidence = rawEvent.speechEvidence
            let event = LiveTranscriptionEvent(
                kind: rawEvent.kind,
                session: rawEvent.session,
                revision: rawEvent.revision,
                decodedAudioWatermark: rawEvent.decodedAudioWatermark,
                emittedAtMonotonicNanos: rawEvent.emittedAtMonotonicNanos,
                fullHypothesisText: rawEvent.fullHypothesisText,
                speechEvidence: evidence
            )
            let reduction = reducer.reduce(event)
            if evidence != .speechDetected,
               case .accepted = reduction.outcome,
               !reduction.snapshot.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                noSpeechFalseDisplays += 1
            }
            guard case .accepted = reduction.outcome else { continue }
            eventCount += 1
            let nowMS = elapsedMS(since: started)
            if !event.fullHypothesisText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if firstPartial == nil {
                    firstPartial = max(0, nowMS - Double(speechOnsetMS))
                } else if let lastPartialTime {
                    gaps.append(nowMS - lastPartialTime)
                }
                lastPartialTime = nowMS
            }
            let stable = reduction.snapshot.stablePrefix
            if !previousStable.isEmpty && !stable.hasPrefix(previousStable) {
                stableConflicts += 1
            }
            previousStable = stable
          }
          if case .finalized(let summary) = poll.state {
              finalSummary = summary
              break
          }
          poll = try await streamer.drain(sessionID: sessionID)
          if poll.frames.isEmpty, case .draining = poll.state {
              throw LiveContextBenchmarkRunnerError.canonicalAudioDidNotFinalize
          }
        }
        guard let summary = finalSummary else {
            throw LiveContextBenchmarkRunnerError.canonicalAudioDidNotFinalize
        }
        if summary.frameCount != observedFrameCount {
            frameSequenceOrOffsetDiscontinuities += 1
        }
        if summary.sampleCount != expectedSampleOffset {
            frameSequenceOrOffsetDiscontinuities += 1
        }
        let pcmHash = pcmHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let canonicalCapture = try await canonicalCaptureEvidence(audioURL: audioURL)

        let finishStarted = ContinuousClock.now
        let final = try await engine.finishLiveTranscription(
            session: session,
            canonicalAudioURL: audioURL,
            streamSummary: summary,
            request: request
        )
        let finishMS = elapsedMS(since: finishStarted)
        let stableFinalConflict = !previousStable.isEmpty && !final.text.hasPrefix(previousStable) ? 1 : 0
        let finalEvent = LiveTranscriptionEvent(
            kind: .authoritativeFinal,
            session: session,
            revision: revision &+ 1,
            decodedAudioWatermark: summary.sampleCount,
            emittedAtMonotonicNanos: DispatchTime.now().uptimeNanoseconds,
            fullHypothesisText: final.text
        )
        let finalReduction = reducer.reduce(finalEvent)
        let usageAfter = LiveContextProcessProbe.currentHelperUsage()
        let activeCPU = LiveContextProcessProbe.cpuPercent(
            before: hasherUsageBefore,
            after: usageAfter,
            elapsedMS: elapsedMS(since: started)
        )
        hasherUsageBefore = nil
        return EnabledTrial(
            startMS: startMS,
            firstPartialMS: firstPartial,
            subsequentGapsMS: gaps,
            finishMS: finishMS,
            eventCount: eventCount,
            stablePrefixConflicts: stableConflicts,
            stablePrefixFinalConflicts: stableFinalConflict,
            noSpeechFalseDisplays: noSpeechFalseDisplays,
            frameSequenceOrOffsetDiscontinuities: frameSequenceOrOffsetDiscontinuities,
            revisionCount: eventCount,
            finalizationCount: {
                if case .accepted = finalReduction.outcome { return 1 }
                return 0
            }(),
            summary: summary,
            pcmSHA256: pcmHash,
            canonicalSummary: canonicalCapture.summary,
            canonicalPCMSHA256: canonicalCapture.sha256,
            runtimeIdentity: session.runtimeIdentity,
            activeCPUPercent: activeCPU
        )
        } catch {
            await engine.cancelLiveTranscription(session: session)
            throw error
        }
    }

    private static func canonicalCaptureEvidence(
        audioURL: URL
    ) async throws -> (summary: LivePCMStreamSummary, sha256: String) {
        let sessionID = UUID()
        let streamer = try CanonicalWAVFrameStreamer(
            sessionID: sessionID,
            audioURL: audioURL,
            maximumFrameBytes: 31_744,
            maximumFramesPerPoll: 3
        )
        var poll = try await streamer.finalize(sessionID: sessionID)
        var hasher = SHA256()
        while true {
            for frame in poll.frames { hasher.update(data: frame.pcmS16LE) }
            if case .finalized(let summary) = poll.state {
                return (
                    summary,
                    hasher.finalize().map { String(format: "%02x", $0) }.joined()
                )
            }
            poll = try await streamer.drain(sessionID: sessionID)
            if poll.frames.isEmpty, case .draining = poll.state {
                throw LiveContextBenchmarkRunnerError.canonicalAudioDidNotFinalize
            }
        }
    }

    private static func measureLatePartialsAfterCancellation(
        engine: any LiveTranscriptionEngine,
        audioURL: URL,
        request: TranscriptionRequest
    ) async -> Int {
        let id = UUID()
        do {
            let session = try await engine.startLiveTranscription(
                sessionID: id,
                controllerGeneration: UUID(),
                request: request
            )
            let streamer = try CanonicalWAVFrameStreamer(sessionID: id, audioURL: audioURL)
            let poll = try await streamer.finalize(sessionID: id)
            let first = poll.frames.first
            if let first { try await engine.appendLiveAudio(first, session: session) }
            await engine.cancelLiveTranscription(session: session)
            do {
                _ = try await engine.requestLiveHypothesis(
                    session: session,
                    revision: 1,
                    decodedAudioWatermark: UInt64(first?.sampleCount ?? 0)
                )
                return 1
            } catch {
                return 0
            }
        } catch {
            return 1
        }
    }

    private struct ResourceMeasurement {
        var completedSoakSessions: Int
        var peakRSSBytes: UInt64?
        var peakGrowthBytes: Int64?
        var tailSlopeBytesPerRequest: Double?
        var monotonicGrowthObserved: Bool?
        var sawtoothGrowthObserved: Bool?
        var idleCPUPercent: Double?
        var maximumConcurrentHelperProcessCount: Int
        var observedIdleSampleSeconds: Double
        var idleObservationCompleted: Bool
        var helperProcessObservationCount: Int
        var continuousHelperMonitorPerformed: Bool
    }

    private struct HelperMonitorEvidence: Sendable {
        var processIDs: Set<Int32>
        var observationCount: Int
        var maximumConcurrentProcessCount: Int
        var maximumGapMS: Double
    }

    private static func measureResources(
        configuration: LiveContextBenchmarkConfiguration,
        engine: any LiveTranscriptionEngine,
        audioURL: URL,
        request: TranscriptionRequest,
        helperPID: Int32,
        helperPIDs: inout Set<Int32>
    ) async -> ResourceMeasurement {
        let helperName = URL(fileURLWithPath: configuration.helperPath).lastPathComponent
        let monitorTask = Task<HelperMonitorEvidence, Never> {
            var processIDs: Set<Int32> = []
            var observationCount = 0
            var maximumConcurrentProcessCount = 0
            var previousNanos: UInt64?
            var maximumGapMS = 0.0
            while !Task.isCancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                if let previousNanos {
                    maximumGapMS = max(maximumGapMS, Double(now - previousNanos) / 1_000_000)
                }
                previousNanos = now
                let observed = LiveContextProcessProbe.childProcessIDs(named: helperName)
                processIDs.formUnion(observed)
                maximumConcurrentProcessCount = max(maximumConcurrentProcessCount, observed.count)
                observationCount += 1
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    break
                }
            }
            return .init(
                processIDs: processIDs,
                observationCount: observationCount,
                maximumConcurrentProcessCount: maximumConcurrentProcessCount,
                maximumGapMS: maximumGapMS
            )
        }
        var values: [(Int, UInt64)] = []
        var completed = 0
        var maximumConcurrentHelperProcessCount = 0
        var helperProcessObservationCount = 0
        for index in 1...configuration.resourceSoakSessions {
            do {
                try await runLiveSoakSession(engine: engine, audioURL: audioURL, request: request)
                completed = index
            } catch {
                break
            }
            if index == 1 || index.isMultiple(of: 25) || index == configuration.resourceSoakSessions,
               let usage = LiveContextProcessProbe.resourceUsage(pid: helperPID) {
                values.append((index, usage.residentBytes))
            }
            let observedHelperPIDs = LiveContextProcessProbe.childProcessIDs(
                named: URL(fileURLWithPath: configuration.helperPath).lastPathComponent
            )
            helperPIDs.formUnion(observedHelperPIDs)
            maximumConcurrentHelperProcessCount = max(
                maximumConcurrentHelperProcessCount,
                observedHelperPIDs.count
            )
            if observedHelperPIDs.count == 1 { helperProcessObservationCount += 1 }
        }
        let peak = values.map(\.1).max()
        let growth = values.first.flatMap { first in
            peak.map { Int64(clamping: $0) - Int64(clamping: first.1) }
        }
        let tail = Array(values.suffix(max(2, values.count / 3)))
        let slope = regressionSlope(tail)
        let monotonic = values.count >= 3 ? zip(values, values.dropFirst()).allSatisfy { $1.1 > $0.1 } : nil
        let sawtooth = values.count >= 5 ? detectUnboundedSawtooth(values) : nil
        let idleStarted = ContinuousClock.now
        let idle = await LiveContextProcessProbe.idleCPUPercent(
            pid: helperPID,
            seconds: configuration.idleSampleSeconds
        )
        let observedIdleSampleSeconds = elapsedMS(since: idleStarted) / 1_000
        monitorTask.cancel()
        let monitor = await monitorTask.value
        helperPIDs.formUnion(monitor.processIDs)
        maximumConcurrentHelperProcessCount = max(
            maximumConcurrentHelperProcessCount,
            monitor.maximumConcurrentProcessCount
        )
        return ResourceMeasurement(
            completedSoakSessions: completed,
            peakRSSBytes: peak,
            peakGrowthBytes: growth,
            tailSlopeBytesPerRequest: slope,
            monotonicGrowthObserved: monotonic,
            sawtoothGrowthObserved: sawtooth,
            idleCPUPercent: idle,
            maximumConcurrentHelperProcessCount: maximumConcurrentHelperProcessCount,
            observedIdleSampleSeconds: observedIdleSampleSeconds,
            idleObservationCompleted: idle != nil
                && observedIdleSampleSeconds >= configuration.idleSampleSeconds,
            helperProcessObservationCount: max(
                helperProcessObservationCount,
                monitor.observationCount
            ),
            continuousHelperMonitorPerformed: monitor.observationCount >= 2
                && monitor.maximumGapMS <= 250
        )
    }

    private static func runLiveSoakSession(
        engine: any LiveTranscriptionEngine,
        audioURL: URL,
        request: TranscriptionRequest
    ) async throws {
        let id = UUID()
        let session = try await engine.startLiveTranscription(
            sessionID: id,
            controllerGeneration: UUID(),
            request: request
        )
        do {
            let streamer = try CanonicalWAVFrameStreamer(
                sessionID: id,
                audioURL: audioURL,
                maximumFrameBytes: 31_744,
                maximumFramesPerPoll: 4
            )
            var poll = try await streamer.finalize(sessionID: id)
            while true {
                for frame in poll.frames { try await engine.appendLiveAudio(frame, session: session) }
                if case .finalized(let summary) = poll.state {
                    _ = try await engine.finishLiveTranscription(
                        session: session,
                        canonicalAudioURL: audioURL,
                        streamSummary: summary,
                        request: request
                    )
                    return
                }
                poll = try await streamer.drain(sessionID: id)
                if poll.frames.isEmpty, case .draining = poll.state {
                    throw LiveContextBenchmarkRunnerError.canonicalAudioDidNotFinalize
                }
            }
        } catch {
            await engine.cancelLiveTranscription(session: session)
            throw error
        }
    }

    private static func makeIdentity(
        configuration: LiveContextBenchmarkConfiguration,
        corpus: ContinuationDirectiveCorpus
    ) throws -> LiveContextBenchmarkIdentity {
        guard let audioHash = sha256File(configuration.audioFixturePath),
              let modelHash = sha256File(configuration.modelPath),
              let helperHash = sha256File(configuration.helperPath),
              let hostedReceiptHash = sha256File(configuration.hostedReceiptPath),
              let adversarialReceiptHash = sha256File(configuration.adversarialReceiptPath),
              let hostedSourceHash = try? LiveContextReceiptManifest.hostedSourceSHA256(
                  sourceRootPath: configuration.sourceRootPath
              ),
              let helperSourceHash = sha256File(
                  URL(fileURLWithPath: configuration.sourceRootPath)
                      .appendingPathComponent("runtime-helper/steno_whisper_runtime.cpp").path
              ),
              let adversarialHarnessHash = sha256File(
                  URL(fileURLWithPath: configuration.sourceRootPath)
                      .appendingPathComponent("scripts/test-whisper-runtime-helper-v2.py").path
              ) else {
            throw LiveContextBenchmarkRunnerError.invalidConfiguration
        }
        let corpusHash = try corpus.sha256()
        let vadHash = configuration.vadModelPath.flatMap(sha256File) ?? "none"
        let manifestMaterial = [
            audioHash, corpusHash, modelHash, helperHash, vadHash,
            hostedReceiptHash, adversarialReceiptHash,
            String(configuration.threads), String(configuration.declaredSpeechOnsetMS),
            String(configuration.alternatingTrialCount), String(configuration.resourceSoakSessions),
            configuration.language, String(configuration.realtimePacing),
            String(configuration.idleSampleSeconds), String(configuration.rssCeilingBytes),
            String(LiveContextBenchmarkThresholds.required.listeningAcknowledgementP95MS),
            String(LiveContextBenchmarkThresholds.required.firstPartialP50MS),
            String(LiveContextBenchmarkThresholds.required.firstPartialP95MS),
            String(LiveContextBenchmarkThresholds.required.firstPartialP99MS),
            String(LiveContextBenchmarkThresholds.required.subsequentPartialGapP95MS),
            String(LiveContextBenchmarkThresholds.required.visibleUpdatesPerSecond),
            String(LiveContextBenchmarkThresholds.required.overlayMainActorP99MS),
            String(LiveContextBenchmarkThresholds.required.stopToInsertionP95MS),
            String(LiveContextBenchmarkThresholds.required.maximumStopToInsertionRegressionRatio),
            String(LiveContextBenchmarkThresholds.required.maximumIdleCPUPercent),
            String(LiveContextBenchmarkThresholds.required.minimumIdleSampleSeconds),
            String(LiveContextBenchmarkThresholds.required.maximumPeakGrowthBytes),
            String(LiveContextBenchmarkThresholds.required.maximumTailSlopeBytesPerRequest),
        ].joined(separator: "\u{0}")
        let manifestHash = SHA256.hash(data: Data(manifestMaterial.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let git = LiveContextProcessProbe.gitIdentity(root: configuration.sourceRootPath)
        return LiveContextBenchmarkIdentity(
            gitSHA: git.sha ?? "",
            treeIsDirty: git.dirty ?? true,
            manifestSHA256: manifestHash,
            corpusSHA256: corpusHash,
            modelSHA256: modelHash,
            audioFixtureSHA256: audioHash,
            modelIdentity: URL(fileURLWithPath: configuration.modelPath).lastPathComponent,
            modelPathPolicy: configuration.modelPath.hasPrefix(configuration.sourceRootPath)
                ? .repositoryRelative : .approvedExternalRedacted,
            vadModelSHA256: configuration.vadModelPath.flatMap(sha256File),
            threadCount: configuration.threads,
            language: configuration.language,
            realtimePacing: configuration.realtimePacing,
            runtimeSHA256: helperHash,
            runtimeIdentity: URL(fileURLWithPath: configuration.helperPath).lastPathComponent,
            liveProtocolVersion: 0,
            liveRuntimeIdentifier: "pending",
            liveModelIdentifier: "pending",
            hostedReceiptSHA256: hostedReceiptHash,
            adversarialReceiptSHA256: adversarialReceiptHash,
            hostedSourceManifestSHA256: hostedSourceHash,
            helperSourceSHA256: helperSourceHash,
            adversarialHarnessSHA256: adversarialHarnessHash,
            hardware: LiveContextProcessProbe.hardware,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            powerState: LiveContextProcessProbe.powerState
        )
    }

    private static func retainedConfiguration(
        _ configuration: LiveContextBenchmarkConfiguration
    ) -> RetainedWhisperTranscriptionConfiguration {
        .init(
            helperExecutableURL: URL(fileURLWithPath: configuration.helperPath),
            modelPath: URL(fileURLWithPath: configuration.modelPath),
            threadCount: configuration.threads,
            vadModelPath: configuration.vadModelPath.map(URL.init(fileURLWithPath:)),
            suppressNonSpeechTokens: true,
            suppressRegex: nil
        )
    }

    private static func cliArguments(_ configuration: LiveContextBenchmarkConfiguration) -> [String] {
        var arguments = ["-t", String(configuration.threads), "--suppress-nst"]
        if let vad = configuration.vadModelPath {
            arguments += ["--vad", "--vad-model", vad]
        }
        return arguments
    }

    private static func contextState(
        _ fixture: ContinuationCorpusContext,
        token: String
    ) -> ContinuationContextState {
        switch fixture.availability {
        case .unavailable: return .unavailable
        case .drifted: return .drifted
        case .validated:
            return .validated(.init(
                targetIdentityToken: token,
                leadingText: fixture.leadingText,
                trailingText: fixture.trailingText,
                boundaryStyle: {
                    switch fixture.boundaryStyle {
                    case .usesInterwordSpacing: return .usesInterwordSpacing
                    case .doesNotUseInterwordSpacing: return .doesNotUseInterwordSpacing
                    case .unknown: return .unknown
                    }
                }(),
                allowsAutomaticContinuation: fixture.allowsAutomaticContinuation
            ))
        }
    }

    private static func directiveKind(_ value: ContinuationCorpusDirectiveKind) -> DictationLowercaseDirectiveKind {
        switch value { case .none: .none; case .lowercase: .lowercase; case .literalEscape: .literalEscape }
    }

    private static func caseDecision(_ value: ContinuationCorpusCaseDecision) -> ContinuationCaseDecision {
        switch value {
        case .notConsidered: .notConsidered
        case .preservedSentenceStart: .preservedSentenceStart
        case .preservedUnsafeOpening: .preservedUnsafeOpening
        case .lowercasedOrdinaryOpening: .lowercasedOrdinaryOpening
        }
    }

    private static func unintendedLowercaseCount(expected: String, actual: String) -> Int {
        var count = 0
        for (expectedCharacter, actualCharacter) in zip(expected, actual) {
            let expectedString = String(expectedCharacter)
            let actualString = String(actualCharacter)
            if expectedString.lowercased() == actualString,
               expectedString.uppercased() == expectedString,
               expectedCharacter != actualCharacter {
                count += 1
            }
        }
        return count
    }

    private static func sha256File(_ path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func regressionSlope(_ values: [(Int, UInt64)]) -> Double? {
        guard values.count >= 2 else { return nil }
        let xs = values.map { Double($0.0) }
        let ys = values.map { Double($0.1) }
        let xMean = xs.reduce(0, +) / Double(xs.count)
        let yMean = ys.reduce(0, +) / Double(ys.count)
        let denominator = xs.reduce(0) { $0 + pow($1 - xMean, 2) }
        guard denominator > 0 else { return nil }
        return zip(xs, ys).reduce(0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) } / denominator
    }

    private static func detectUnboundedSawtooth(_ values: [(Int, UInt64)]) -> Bool {
        guard let first = values.first?.1, let last = values.last?.1 else { return true }
        let increases = zip(values, values.dropFirst()).filter { $1.1 > $0.1 }.count
        let decreases = zip(values, values.dropFirst()).filter { $1.1 < $0.1 }.count
        return increases > 0 && decreases > 0 && last > first
    }

    static func elapsedMS(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func maximumBurstUpdatesPerSecond(_ timestampsMS: [Double]) -> Double {
        guard timestampsMS.count >= 2 else { return 0 }
        return zip(timestampsMS, timestampsMS.dropFirst()).reduce(0) { maximum, pair in
            let gap = pair.1 - pair.0
            guard gap > 0, gap.isFinite else { return .infinity }
            return max(maximum, 1_000 / gap)
        }
    }
}

actor CountingFallbackEngine: TranscriptionEngine {
    private let base: any TranscriptionEngine
    private var calls = 0

    init(base: any TranscriptionEngine) { self.base = base }

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        calls += 1
        return try await base.transcribe(audioURL: audioURL, request: request)
    }

    func shutdown() async { await base.shutdown() }
    func unloadRetainedResources() async { await base.unloadRetainedResources() }
    func callCount() -> Int { calls }
}

private enum LiveContextProcessProbe {
    struct Usage {
        var residentBytes: UInt64
        var cpuNanoseconds: UInt64
    }

    static var hardware: String {
        run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static var powerState: String {
        let output = run("/usr/bin/pmset", ["-g", "batt"]).output
        if output.localizedCaseInsensitiveContains("AC Power") { return "ac-power" }
        if output.localizedCaseInsensitiveContains("Battery Power") { return "battery-power" }
        return "unknown"
    }

    static func gitIdentity(root: String) -> (sha: String?, dirty: Bool?) {
        let sha = run("/usr/bin/git", ["-C", root, "rev-parse", "HEAD"])
        let status = run("/usr/bin/git", ["-C", root, "status", "--porcelain", "--untracked-files=all"])
        return (
            sha.status == 0 ? sha.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            status.status == 0 ? !status.output.isEmpty : nil
        )
    }

    static func childProcessIDs(named name: String) -> [Int32] {
        let children = run("/usr/bin/pgrep", ["-P", String(ProcessInfo.processInfo.processIdentifier)])
        guard children.status == 0 else { return [] }
        return children.output.split(whereSeparator: \ .isNewline).compactMap { Int32($0) }.filter { pid in
            let command = run("/bin/ps", ["-p", String(pid), "-o", "comm="]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: command).lastPathComponent == name
        }
    }

    static func currentHelperUsage() -> Usage? {
        let children = run("/usr/bin/pgrep", ["-P", String(ProcessInfo.processInfo.processIdentifier)])
        guard children.status == 0,
              let pid = children.output.split(whereSeparator: \ .isNewline).compactMap({ Int32($0) }).first
        else { return nil }
        return resourceUsage(pid: pid)
    }

    static func resourceUsage(pid: Int32) -> Usage? {
#if os(macOS)
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard status == 0 else { return nil }
        return Usage(
            residentBytes: info.ri_resident_size,
            cpuNanoseconds: info.ri_user_time &+ info.ri_system_time
        )
#else
        _ = pid
        return nil
#endif
    }

    static func cpuPercent(before: Usage?, after: Usage?, elapsedMS: Double) -> Double? {
        guard let before, let after, elapsedMS > 0, after.cpuNanoseconds >= before.cpuNanoseconds else { return nil }
        return Double(after.cpuNanoseconds - before.cpuNanoseconds) / (elapsedMS * 1_000_000) * 100
    }

    static func idleCPUPercent(pid: Int32, seconds: Double) async -> Double? {
        guard let before = resourceUsage(pid: pid) else { return nil }
        let started = ContinuousClock.now
        try? await Task.sleep(for: .seconds(seconds))
        return cpuPercent(
            before: before,
            after: resourceUsage(pid: pid),
            elapsedMS: LiveContextBenchmarkRunner.elapsedMS(since: started)
        )
    }

    static func networkConnectionCount(pid: Int32) -> Int? {
        lsofCount(pid: pid, extra: ["-i"])
    }

    static func listeningSocketCount(pid: Int32) -> Int? {
        lsofCount(pid: pid, extra: ["-iTCP", "-sTCP:LISTEN"])
    }

    private static func lsofCount(pid: Int32, extra: [String]) -> Int? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return nil }
        let result = run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid)] + extra)
        guard result.status == 0 || result.status == 1 else { return nil }
        return max(0, result.output.split(whereSeparator: \ .isNewline).count - (result.status == 0 ? 1 : 0))
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }
}
