import CryptoKit
#if os(macOS)
import Darwin
#endif
import Foundation
import StenoKit

public enum WarmRuntimeBenchmarkRunner {
    public static func run(
        manifest: BenchmarkManifest,
        configuration: WarmRuntimeBenchmarkConfiguration
    ) async throws -> WarmRuntimeBenchmarkArtifact {
        guard !manifest.samples.isEmpty else {
            throw WarmRuntimeBenchmarkError.emptyManifest
        }
        guard configuration.comparisonIterations > 0,
              configuration.coordinatorIterations > 0,
              configuration.repeatabilityIterations > 0,
              configuration.resourceIterations >= 100
        else {
            throw WarmRuntimeBenchmarkError.invalidIterationCount
        }

        let cases = await benchmarkCases(manifest: manifest, configuration: configuration)
        let cliArguments = whisperCLIArguments(configuration: configuration)
        let cliConfiguration = BenchmarkWhisperConfiguration(
            whisperCLIPath: configuration.whisperCLIPath,
            modelPath: configuration.modelPath,
            additionalArguments: cliArguments,
            defaultLanguageHint: configuration.language
        )
        let identity = BenchmarkArtifactIdentity.capture(
            manifest: manifest,
            manifestPath: configuration.manifestPath,
            whisperConfiguration: cliConfiguration
        )
        let cli = WhisperCLITranscriptionEngine(
            config: .init(
                whisperCLIPath: URL(fileURLWithPath: configuration.whisperCLIPath),
                modelPath: URL(fileURLWithPath: configuration.modelPath),
                additionalArguments: cliArguments
            )
        )
        let retained = RetainedWhisperTranscriptionEngine(
            configuration: retainedConfiguration(configuration),
            fallback: cli
        )

        do {
            let artifact = try await run(
                manifest: manifest,
                configuration: configuration,
                cases: cases,
                cli: cli,
                retained: retained,
                identity: identity
            )
            await retained.shutdown()
            return artifact
        } catch {
            await retained.shutdown()
            throw error
        }
    }

    private static func run(
        manifest: BenchmarkManifest,
        configuration: WarmRuntimeBenchmarkConfiguration,
        cases: [WarmRuntimeBenchmarkCase],
        cli: WhisperCLITranscriptionEngine,
        retained: RetainedWhisperTranscriptionEngine,
        identity: BenchmarkArtifactIdentity
    ) async throws -> WarmRuntimeBenchmarkArtifact {
        emitProgress("cli-comparison")
        var cliTimings: [Double] = []
        var cliDurations: [Int?] = []
        var cliTranscripts: [RawTranscript] = []

        for index in 0..<configuration.comparisonIterations {
            let benchmarkCase = cases[index % cases.count]
            let measurement = try await measure {
                try await cli.transcribe(
                    audioURL: benchmarkCase.audioURL,
                    request: benchmarkCase.request
                )
            }
            cliTimings.append(measurement.elapsedMS)
            cliDurations.append(benchmarkCase.audioDurationMS)
            cliTranscripts.append(measurement.value)
        }

        emitProgress("retained-cold-load")
        let coldCase = cases[0]
        let modelLoadMeasurement = try await measure {
            try await retained.prepareRetainedResources()
        }
        let coldInferenceMeasurement = try await measure {
            try await retained.transcribe(audioURL: coldCase.audioURL, request: coldCase.request)
        }

        emitProgress("retained-comparison")
        guard WarmRuntimeProcessSampler.childProcessID(
            named: URL(fileURLWithPath: configuration.helperPath).lastPathComponent
        ) != nil else {
            throw WarmRuntimeBenchmarkError.helperProcessNotFound
        }
        var warmTimings: [Double] = []
        var warmDurations: [Int?] = []
        var warmTranscripts: [RawTranscript] = []

        for index in 0..<configuration.comparisonIterations {
            let benchmarkCase = cases[index % cases.count]
            let measurement = try await measure {
                try await retained.transcribe(
                    audioURL: benchmarkCase.audioURL,
                    request: benchmarkCase.request
                )
            }
            warmTimings.append(measurement.elapsedMS)
            warmDurations.append(benchmarkCase.audioDurationMS)
            warmTranscripts.append(measurement.value)
        }

        emitProgress("retained-resource-series")
        await retained.unloadRetainedResources()
        _ = try await retained.transcribe(audioURL: coldCase.audioURL, request: coldCase.request)
        guard let helperPID = WarmRuntimeProcessSampler.childProcessID(
            named: URL(fileURLWithPath: configuration.helperPath).lastPathComponent
        ) else {
            throw WarmRuntimeBenchmarkError.helperProcessNotFound
        }
        var checkpointTargets: Set<Int> = [1, 10, 50, 100, configuration.resourceIterations]
        if configuration.resourceCheckpointInterval <= configuration.resourceIterations {
            for requestIndex in stride(
                from: configuration.resourceCheckpointInterval,
                through: configuration.resourceIterations,
                by: configuration.resourceCheckpointInterval
            ) {
                checkpointTargets.insert(requestIndex)
            }
        }
        let firstUsage = WarmRuntimeProcessSampler.resourceUsage(pid: helperPID)
        var checkpoints: [WarmRuntimeResourceCheckpoint] = [
            WarmRuntimeResourceCheckpoint(
                requestIndex: 1,
                residentBytes: firstUsage?.residentBytes,
                physicalFootprintBytes: firstUsage?.physicalFootprintBytes
            )
        ]
        var totalRetainedRequests = 1
        while totalRetainedRequests < configuration.resourceIterations {
            _ = try await retained.transcribe(
                audioURL: coldCase.audioURL,
                request: coldCase.request
            )
            totalRetainedRequests += 1
            appendCheckpointIfNeeded(
                requestIndex: totalRetainedRequests,
                targets: checkpointTargets,
                helperPID: helperPID,
                checkpoints: &checkpoints
            )
        }

        emitProgress("idle-sample")
        let idleSample = await WarmRuntimeProcessSampler.idleSample(
            pid: helperPID,
            seconds: configuration.idleSampleSeconds
        )
        let networkListenersObserved = WarmRuntimeProcessSampler.hasNetworkSocket(pid: helperPID)

        emitProgress("repeatability")
        var retainedIdenticalAudioRepetitions: [RawTranscript] = []
        retainedIdenticalAudioRepetitions.reserveCapacity(configuration.repeatabilityIterations)
        for _ in 0..<configuration.repeatabilityIterations {
            retainedIdenticalAudioRepetitions.append(
                try await retained.transcribe(
                    audioURL: coldCase.audioURL,
                    request: coldCase.request
                )
            )
        }

        var cliIdenticalAudioRepetitions: [RawTranscript] = []
        cliIdenticalAudioRepetitions.reserveCapacity(configuration.repeatabilityIterations)
        for _ in 0..<configuration.repeatabilityIterations {
            cliIdenticalAudioRepetitions.append(
                try await cli.transcribe(
                    audioURL: coldCase.audioURL,
                    request: coldCase.request
                )
            )
        }
        let cliRepeatability = try WarmRuntimeRepeatabilitySummary.measure(
            reference: cliTranscripts[0],
            repetitions: cliIdenticalAudioRepetitions
        )
        let retainedRepeatability = try WarmRuntimeRepeatabilitySummary.measure(
            reference: cliTranscripts[0],
            repetitions: retainedIdenticalAudioRepetitions
        )

        emitProgress("coordinator-proxy")
        let coordinatorProxy = try await WarmRuntimeCoordinatorProxy.runComparison(
            cases: cases,
            cli: cli,
            retained: retained,
            configuration: configuration
        )

        emitProgress("cancellation")
        let cancellation = await measureCancellation(
            retained: retained,
            benchmarkCase: cases[0],
            delayMS: configuration.cancellationDelayMS
        )
        emitProgress("model-switch")
        let switchBaselinePID = try await prepareSwitchBaselineIfNeeded(
            retained: retained,
            configuration: configuration
        )
        let modelSwitch = try await measureModelSwitchIfRequested(
            retained: retained,
            existingHelperPID: switchBaselinePID ?? helperPID,
            configuration: configuration,
            benchmarkCase: cases[0]
        )

        emitProgress("artifact-validation")
        let configurationSummary = configurationSummary(
            configuration: configuration,
            identity: identity
        )
        return WarmRuntimeBenchmarkArtifact(
            identity: identity,
            configuration: configurationSummary,
            sampleCount: manifest.samples.count,
            cli: WarmRuntimeDistribution.summarize(
                milliseconds: cliTimings,
                audioDurationMilliseconds: cliDurations
            ),
            retainedModelLoad: WarmRuntimeDistribution.summarize(
                milliseconds: [modelLoadMeasurement.elapsedMS],
                audioDurationMilliseconds: [nil]
            ),
            retainedColdInference: WarmRuntimeDistribution.summarize(
                milliseconds: [coldInferenceMeasurement.elapsedMS],
                audioDurationMilliseconds: [coldCase.audioDurationMS]
            ),
            retainedWarm: WarmRuntimeDistribution.summarize(
                milliseconds: warmTimings,
                audioDurationMilliseconds: warmDurations
            ),
            coordinatorProxy: coordinatorProxy,
            parity: WarmRuntimeParitySummary.compare(
                baseline: cliTranscripts,
                retained: warmTranscripts
            ),
            cliRepeatability: cliRepeatability,
            retainedRepeatability: retainedRepeatability,
            resources: WarmRuntimeResourceSummary.analyze(
                checkpoints: checkpoints,
                idleCPUPercent: idleSample?.cpuPercent,
                idleSampleSeconds: configuration.idleSampleSeconds,
                postIdleResidentBytes: idleSample?.after.residentBytes,
                postIdlePhysicalFootprintBytes: idleSample?.after.physicalFootprintBytes
            ),
            cancellation: cancellation,
            modelSwitch: modelSwitch,
            networkListenersObserved: networkListenersObserved
        )
    }

    private static func emitProgress(_ phase: String) {
        let message = Data("warm-runtime phase: \(phase)\n".utf8)
        try? FileHandle.standardError.write(contentsOf: message)
    }

    private static func benchmarkCases(
        manifest: BenchmarkManifest,
        configuration: WarmRuntimeBenchmarkConfiguration
    ) async -> [WarmRuntimeBenchmarkCase] {
        let manifestURL = URL(fileURLWithPath: configuration.manifestPath)
        let manifestDirectory = manifestURL.hasDirectoryPath
            ? manifestURL
            : manifestURL.deletingLastPathComponent()
        let lexiconService = PersonalLexiconService(entries: configuration.lexicon.entries)
        var cases: [WarmRuntimeBenchmarkCase] = []
        cases.reserveCapacity(manifest.samples.count)

        for sample in manifest.samples {
            let appContext = sample.appContextPreset?.appContext ?? .unknown
            let hotTerms = await lexiconService.hotTerms(for: appContext, limit: 8)
            let audioURL = sample.audioPath.hasPrefix("/")
                ? URL(fileURLWithPath: sample.audioPath)
                : manifestDirectory.appendingPathComponent(sample.audioPath)
            cases.append(
                WarmRuntimeBenchmarkCase(
                    audioURL: audioURL,
                    audioDurationMS: sample.audioDurationMS,
                    appContext: appContext,
                    request: TranscriptionRequest(
                        languageHints: [sample.languageHint ?? configuration.language],
                        appContext: appContext,
                        hotTerms: hotTerms
                    )
                )
            )
        }
        return cases
    }

    private static func whisperCLIArguments(
        configuration: WarmRuntimeBenchmarkConfiguration
    ) -> [String] {
        var arguments = [
            "-t", String(configuration.threads),
            "--beam-size", String(configuration.beamSize),
            "--best-of", String(configuration.bestOf),
        ]
        if configuration.suppressNonSpeechTokens {
            arguments.append("--suppress-nst")
        }
        if let suppressRegex = configuration.suppressRegex,
           !suppressRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--suppress-regex", suppressRegex])
        }
        if let vadModelPath = configuration.vadModelPath {
            arguments.append(contentsOf: ["--vad", "--vad-model", vadModelPath])
        }
        return arguments
    }

    private static func retainedConfiguration(
        _ configuration: WarmRuntimeBenchmarkConfiguration,
        modelPath: String? = nil,
        vadModelPath: String? = nil
    ) -> RetainedWhisperTranscriptionConfiguration {
        RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: URL(fileURLWithPath: configuration.helperPath),
            modelPath: URL(fileURLWithPath: modelPath ?? configuration.modelPath),
            threadCount: configuration.threads,
            vadModelPath: (vadModelPath ?? configuration.vadModelPath).map(URL.init(fileURLWithPath:)),
            suppressNonSpeechTokens: configuration.suppressNonSpeechTokens,
            suppressRegex: configuration.suppressRegex,
            beamSize: configuration.beamSize,
            bestOf: configuration.bestOf
        )
    }

    private static func appendCheckpointIfNeeded(
        requestIndex: Int,
        targets: Set<Int>,
        helperPID: Int32,
        checkpoints: inout [WarmRuntimeResourceCheckpoint]
    ) {
        guard targets.contains(requestIndex),
              !checkpoints.contains(where: { $0.requestIndex == requestIndex })
        else { return }
        let usage = WarmRuntimeProcessSampler.resourceUsage(pid: helperPID)
        checkpoints.append(
            WarmRuntimeResourceCheckpoint(
                requestIndex: requestIndex,
                residentBytes: usage?.residentBytes,
                physicalFootprintBytes: usage?.physicalFootprintBytes
            )
        )
    }

    private static func measureModelSwitchIfRequested(
        retained: RetainedWhisperTranscriptionEngine,
        existingHelperPID: Int32,
        configuration: WarmRuntimeBenchmarkConfiguration,
        benchmarkCase: WarmRuntimeBenchmarkCase
    ) async throws -> WarmRuntimeModelSwitchSummary? {
        guard configuration.switchModelPath != nil || configuration.switchVADModelPath != nil else {
            return nil
        }
        let nextConfiguration = retainedConfiguration(
            configuration,
            modelPath: configuration.switchModelPath,
            vadModelPath: configuration.switchVADModelPath
        )
        await retained.updateConfiguration(nextConfiguration)
        let reloadMeasurement = try await measure {
            try await retained.prepareRetainedResources()
        }
        let firstInferenceMeasurement = try await measure {
            try await retained.transcribe(
                audioURL: benchmarkCase.audioURL,
                request: benchmarkCase.request
            )
        }
        let newPID = WarmRuntimeProcessSampler.childProcessID(
            named: URL(fileURLWithPath: configuration.helperPath).lastPathComponent
        )
        let switchIdentity = WarmRuntimeSwitchIdentity.resolve(
            currentModelSHA256: sha256File(at: configuration.modelPath),
            currentVADModelSHA256: configuration.vadModelPath.flatMap { sha256File(at: $0) },
            requestedModelSHA256: configuration.switchModelPath.flatMap { sha256File(at: $0) },
            requestedVADModelSHA256: configuration.switchVADModelPath.flatMap { sha256File(at: $0) }
        )
        return WarmRuntimeModelSwitchSummary(
            reloadMS: reloadMeasurement.elapsedMS,
            firstInferenceMS: firstInferenceMeasurement.elapsedMS,
            inferenceSucceeded: true,
            helperProcessReplaced: newPID != nil && newPID != existingHelperPID,
            modelSHA256: switchIdentity.modelSHA256,
            vadModelSHA256: switchIdentity.vadModelSHA256
        )
    }

    private static func prepareSwitchBaselineIfNeeded(
        retained: RetainedWhisperTranscriptionEngine,
        configuration: WarmRuntimeBenchmarkConfiguration
    ) async throws -> Int32? {
        guard configuration.switchModelPath != nil || configuration.switchVADModelPath != nil else {
            return nil
        }
        try await retained.prepareRetainedResources()
        guard let pid = WarmRuntimeProcessSampler.childProcessID(
            named: URL(fileURLWithPath: configuration.helperPath).lastPathComponent
        ) else {
            throw WarmRuntimeBenchmarkError.helperProcessNotFound
        }
        return pid
    }

    private static func measureCancellation(
        retained: RetainedWhisperTranscriptionEngine,
        benchmarkCase: WarmRuntimeBenchmarkCase,
        delayMS: Int
    ) async -> WarmRuntimeCancellationSummary {
        let task = Task {
            try await retained.transcribe(
                audioURL: benchmarkCase.audioURL,
                request: benchmarkCase.request
            )
        }
        if delayMS > 0 {
            try? await Task.sleep(for: .milliseconds(delayMS))
        }
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            return WarmRuntimeCancellationSummary(
                elapsedMS: elapsedMilliseconds(from: cancelledAt, to: .now),
                cancelled: false,
                lateResultObserved: true
            )
        } catch is CancellationError {
            return WarmRuntimeCancellationSummary(
                elapsedMS: elapsedMilliseconds(from: cancelledAt, to: .now),
                cancelled: true,
                lateResultObserved: false
            )
        } catch {
            return WarmRuntimeCancellationSummary(
                elapsedMS: elapsedMilliseconds(from: cancelledAt, to: .now),
                cancelled: false,
                lateResultObserved: false
            )
        }
    }

    private static func configurationSummary(
        configuration: WarmRuntimeBenchmarkConfiguration,
        identity: BenchmarkArtifactIdentity
    ) -> WarmRuntimeConfigurationSummary {
        let helperDigest = sha256File(at: configuration.helperPath)
        struct DigestInput: Codable {
            var model: String?
            var vad: String?
            var helper: String?
            var cli: String?
            var threads: Int
            var language: String
            var vadEnabled: Bool
            var suppressNonSpeechTokens: Bool
            var suppressRegexSHA256: String?
            var profileSHA256: String?
            var lexiconSHA256: String?
            var switchModelSHA256: String?
            var switchVADModelSHA256: String?
            var beamSize: Int
            var bestOf: Int
            var comparisonIterations: Int
            var resourceIterations: Int
            var resourceCheckpointInterval: Int
            var coordinatorIterations: Int
            var repeatabilityIterations: Int
            var cancellationDelayMS: Int
            var idleSampleSeconds: Double
            var modelSwitchRequested: Bool
        }
        let privacyEncoder = JSONEncoder()
        privacyEncoder.outputFormatting = [.sortedKeys]
        let profileDigest = (try? privacyEncoder.encode(configuration.profile)).map(sha256Data)
        let lexiconDigest = (try? privacyEncoder.encode(configuration.lexicon)).map(sha256Data)
        let suppressRegexDigest = configuration.suppressRegex.map { sha256Data(Data($0.utf8)) }
        let switchModelDigest = configuration.switchModelPath.flatMap(sha256File(at:))
        let switchVADDigest = configuration.switchVADModelPath.flatMap(sha256File(at:))
        let modelSwitchRequested = configuration.switchModelPath != nil
            || configuration.switchVADModelPath != nil
        let effectiveSwitchIdentity = modelSwitchRequested
            ? WarmRuntimeSwitchIdentity.resolve(
                currentModelSHA256: identity.modelSHA256,
                currentVADModelSHA256: identity.vadModelSHA256,
                requestedModelSHA256: switchModelDigest,
                requestedVADModelSHA256: switchVADDigest
            )
            : nil
        let digestInput = DigestInput(
            model: identity.modelSHA256,
            vad: identity.vadModelSHA256,
            helper: helperDigest,
            cli: identity.whisperCLISHA256,
            threads: configuration.threads,
            language: normalizedLanguageCategory(configuration.language),
            vadEnabled: configuration.vadModelPath != nil,
            suppressNonSpeechTokens: configuration.suppressNonSpeechTokens,
            suppressRegexSHA256: suppressRegexDigest,
            profileSHA256: profileDigest,
            lexiconSHA256: lexiconDigest,
            switchModelSHA256: effectiveSwitchIdentity?.modelSHA256,
            switchVADModelSHA256: effectiveSwitchIdentity?.vadModelSHA256,
            beamSize: configuration.beamSize,
            bestOf: configuration.bestOf,
            comparisonIterations: configuration.comparisonIterations,
            resourceIterations: configuration.resourceIterations,
            resourceCheckpointInterval: configuration.resourceCheckpointInterval,
            coordinatorIterations: configuration.coordinatorIterations,
            repeatabilityIterations: configuration.repeatabilityIterations,
            cancellationDelayMS: configuration.cancellationDelayMS,
            idleSampleSeconds: configuration.idleSampleSeconds,
            modelSwitchRequested: modelSwitchRequested
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configurationDigest = (try? encoder.encode(digestInput)).map(sha256Data)
        return WarmRuntimeConfigurationSummary(
            configurationSHA256: configurationDigest,
            retainedHelperSHA256: helperDigest,
            switchModelSHA256: effectiveSwitchIdentity?.modelSHA256,
            switchVADModelSHA256: effectiveSwitchIdentity?.vadModelSHA256,
            threads: configuration.threads,
            languageCategory: normalizedLanguageCategory(configuration.language),
            vadEnabled: configuration.vadModelPath != nil,
            suppressNonSpeechTokens: configuration.suppressNonSpeechTokens,
            beamSize: configuration.beamSize,
            bestOf: configuration.bestOf,
            comparisonIterations: configuration.comparisonIterations,
            resourceIterations: configuration.resourceIterations,
            resourceCheckpointInterval: configuration.resourceCheckpointInterval,
            coordinatorIterations: configuration.coordinatorIterations,
            repeatabilityIterations: configuration.repeatabilityIterations,
            cancellationDelayMS: configuration.cancellationDelayMS,
            idleSampleSeconds: configuration.idleSampleSeconds,
            modelSwitchRequested: modelSwitchRequested
        )
    }

    private static func normalizedLanguageCategory(_ raw: String) -> String {
        let candidate = raw.lowercased().split(separator: "-").first.map(String.init) ?? "unknown"
        guard candidate.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil else {
            return "unknown"
        }
        return candidate
    }

    private static func sha256File(at path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func measure<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> (value: Value, elapsedMS: Double) {
        let started = ContinuousClock.now
        let value = try await operation()
        return (value, elapsedMilliseconds(from: started, to: .now))
    }

    fileprivate static func elapsedMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: end).components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}

private struct WarmRuntimeBenchmarkCase: Sendable {
    var audioURL: URL
    var audioDurationMS: Int?
    var appContext: AppContext
    var request: TranscriptionRequest
}

// MARK: - Coordinator proxy

private enum WarmRuntimeCoordinatorProxy {
    static func runComparison(
        cases: [WarmRuntimeBenchmarkCase],
        cli: any TranscriptionEngine,
        retained: any TranscriptionEngine,
        configuration: WarmRuntimeBenchmarkConfiguration
    ) async throws -> WarmRuntimeCoordinatorComparison {
        let cliSummary = try await run(
            cases: cases,
            engine: cli,
            iterations: configuration.coordinatorIterations,
            profile: configuration.profile,
            lexicon: configuration.lexicon
        )
        let retainedSummary = try await run(
            cases: cases,
            engine: retained,
            iterations: configuration.coordinatorIterations,
            profile: configuration.profile,
            lexicon: configuration.lexicon
        )
        return WarmRuntimeCoordinatorComparison(cli: cliSummary, retainedWarm: retainedSummary)
    }

    private static func run(
        cases: [WarmRuntimeBenchmarkCase],
        engine: any TranscriptionEngine,
        iterations: Int,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> WarmRuntimeCoordinatorModeSummary {
        var observations: [WarmCoordinatorObservation] = []
        observations.reserveCapacity(iterations)

        for index in 0..<iterations {
            let benchmarkCase = cases[index % cases.count]
            let captureService = WarmBenchmarkAudioCaptureService(sourceAudioURL: benchmarkCase.audioURL)
            let recorder = WarmCoordinatorTimingRecorder()
            let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("steno-warm-benchmark-history-\(UUID().uuidString).json")
            let insertionService = WarmTimedInsertionService(
                base: InsertionService(
                    transports: [ClosureInsertionTransport(method: .direct) { _, _ in }]
                ),
                recorder: recorder
            )
            let historyStore = WarmTimedHistoryStore(
                base: HistoryStore(
                    storageURL: historyURL,
                    clipboardService: MemoryClipboardService()
                ),
                recorder: recorder
            )
            let coordinator = SessionCoordinator(
                captureService: captureService,
                transcriptionEngine: WarmTimedTranscriptionEngine(base: engine, recorder: recorder),
                cleanupEngine: WarmTimedCleanupEngine(base: RuleBasedCleanupEngine(), recorder: recorder),
                insertionService: insertionService,
                historyStore: historyStore,
                lexiconService: PersonalLexiconService(entries: lexicon.entries),
                styleProfileService: StyleProfileService(globalProfile: profile)
            )

            do {
                let sessionID = try await coordinator.startPressToTalk(appContext: benchmarkCase.appContext)
                let started = ContinuousClock.now
                await recorder.begin(at: started)
                _ = try await coordinator.stopPressToTalk(
                    sessionID: sessionID,
                    languageHints: benchmarkCase.request.languageHints
                )
                await recorder.recordCoordinatorReturn(
                    WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: started, to: .now)
                )
                observations.append(await recorder.snapshot())
            } catch {
                await captureService.cleanup()
                try? FileManager.default.removeItem(at: historyURL)
                throw error
            }

            await captureService.cleanup()
            try? FileManager.default.removeItem(at: historyURL)
        }
        return summarize(observations)
    }

    private static func summarize(
        _ observations: [WarmCoordinatorObservation]
    ) -> WarmRuntimeCoordinatorModeSummary {
        func summarize(_ values: [Double?]) -> WarmRuntimeLatencySummary {
            WarmRuntimeDistribution.summarize(milliseconds: values.compactMap { $0 })
        }

        return WarmRuntimeCoordinatorModeSummary(
            captureCloseToTranscriptionStart: summarize(
                observations.map(\.captureCloseToTranscriptionStartMS)
            ),
            transcription: summarize(observations.map(\.transcriptionMS)),
            cleanup: summarize(observations.map(\.cleanupMS)),
            insertionTransport: summarize(observations.map(\.insertionMS)),
            historyPersistence: summarize(observations.map(\.historyMS)),
            stopToInsertionCompletion: summarize(observations.map(\.stopToInsertionCompletionMS)),
            coordinatorReturn: summarize(observations.map(\.coordinatorReturnMS))
        )
    }
}

private struct WarmCoordinatorObservation: Sendable {
    var captureCloseToTranscriptionStartMS: Double?
    var transcriptionMS: Double?
    var cleanupMS: Double?
    var insertionMS: Double?
    var historyMS: Double?
    var stopToInsertionCompletionMS: Double?
    var coordinatorReturnMS: Double?
}

private actor WarmBenchmarkAudioCaptureService: AudioCaptureService {
    private let sourceAudioURL: URL
    private var temporaryDirectories: [URL] = []

    init(sourceAudioURL: URL) {
        self.sourceAudioURL = sourceAudioURL
    }

    func beginCapture(sessionID: SessionID) async throws {
        _ = sessionID
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        _ = sessionID
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-warm-benchmark-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let copiedURL = directory.appendingPathComponent(sourceAudioURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceAudioURL, to: copiedURL)
        return copiedURL
    }

    func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
    }

    func cleanup() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }
}

private actor WarmCoordinatorTimingRecorder {
    private var origin: ContinuousClock.Instant?
    private var observation = WarmCoordinatorObservation()

    func begin(at origin: ContinuousClock.Instant) {
        self.origin = origin
    }

    func recordTranscription(started: ContinuousClock.Instant, elapsedMS: Double) {
        if let origin {
            observation.captureCloseToTranscriptionStartMS =
                WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: origin, to: started)
        }
        observation.transcriptionMS = elapsedMS
    }

    func recordCleanup(_ elapsedMS: Double) {
        observation.cleanupMS = elapsedMS
    }

    func recordInsertion(ended: ContinuousClock.Instant, elapsedMS: Double) {
        observation.insertionMS = elapsedMS
        if let origin {
            observation.stopToInsertionCompletionMS =
                WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: origin, to: ended)
        }
    }

    func recordHistory(_ elapsedMS: Double) {
        observation.historyMS = elapsedMS
    }

    func recordCoordinatorReturn(_ elapsedMS: Double) {
        observation.coordinatorReturnMS = elapsedMS
    }

    func snapshot() -> WarmCoordinatorObservation {
        observation
    }
}

private struct WarmTimedTranscriptionEngine: TranscriptionEngine {
    let base: any TranscriptionEngine
    let recorder: WarmCoordinatorTimingRecorder

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        let started = ContinuousClock.now
        do {
            let transcript = try await base.transcribe(audioURL: audioURL, request: request)
            await recorder.recordTranscription(
                started: started,
                elapsedMS: WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: started, to: .now)
            )
            return transcript
        } catch {
            await recorder.recordTranscription(
                started: started,
                elapsedMS: WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: started, to: .now)
            )
            throw error
        }
    }
}

private struct WarmTimedCleanupEngine: CleanupEngine {
    let base: any CleanupEngine
    let recorder: WarmCoordinatorTimingRecorder

    func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        let started = ContinuousClock.now
        do {
            let transcript = try await base.cleanup(raw: raw, profile: profile, lexicon: lexicon)
            await recorder.recordCleanup(
                WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: started, to: .now)
            )
            return transcript
        } catch {
            await recorder.recordCleanup(
                WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: started, to: .now)
            )
            throw error
        }
    }
}

private struct WarmTimedInsertionService: InsertionServiceProtocol {
    let base: any InsertionServiceProtocol
    let recorder: WarmCoordinatorTimingRecorder

    func insert(text: String, target: AppContext) async -> InsertResult {
        let started = ContinuousClock.now
        let result = await base.insert(text: text, target: target)
        let ended = ContinuousClock.now
        await recorder.recordInsertion(
            ended: ended,
            elapsedMS: WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: started, to: ended)
        )
        return result
    }
}

private struct WarmTimedHistoryStore: HistoryStoreProtocol {
    let base: any HistoryStoreProtocol
    let recorder: WarmCoordinatorTimingRecorder

    func append(entry: TranscriptEntry) async throws {
        let started = ContinuousClock.now
        do {
            try await base.append(entry: entry)
            await recorder.recordHistory(
                WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: started, to: .now)
            )
        } catch {
            await recorder.recordHistory(
                WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: started, to: .now)
            )
            throw error
        }
    }

    func delete(entryID: UUID) async throws {
        try await base.delete(entryID: entryID)
    }

    func recent(limit: Int) async -> [TranscriptEntry] {
        await base.recent(limit: limit)
    }

    func search(query: String) async -> [TranscriptEntry] {
        await base.search(query: query)
    }

    func retry(
        entryID: UUID,
        using cleanupEngine: CleanupEngine,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        try await base.retry(
            entryID: entryID,
            using: cleanupEngine,
            profile: profile,
            lexicon: lexicon
        )
    }

    func pasteLast() async throws -> TranscriptEntry? {
        try await base.pasteLast()
    }
}

// MARK: - Helper resource and listener sampling

private enum WarmRuntimeProcessSampler {
    struct ResourceUsage {
        var residentBytes: UInt64
        var physicalFootprintBytes: UInt64
        var cpuNanoseconds: UInt64
    }

    struct IdleSample {
        var cpuPercent: Double
        var after: ResourceUsage
    }

    static func childProcessID(named executableName: String) -> Int32? {
        let result = run(
            executable: "/usr/bin/pgrep",
            arguments: ["-P", String(ProcessInfo.processInfo.processIdentifier)]
        )
        guard result.status == 0 else { return nil }
        let candidates = result.output.split(whereSeparator: \.isNewline).compactMap {
            Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for pid in candidates {
            let command = run(
                executable: "/bin/ps",
                arguments: ["-p", String(pid), "-o", "comm="]
            ).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if URL(fileURLWithPath: command).lastPathComponent == executableName {
                return pid
            }
        }
        return nil
    }

    static func resourceUsage(pid: Int32) -> ResourceUsage? {
#if os(macOS)
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard status == 0 else { return nil }
        return ResourceUsage(
            residentBytes: info.ri_resident_size,
            physicalFootprintBytes: info.ri_phys_footprint,
            cpuNanoseconds: info.ri_user_time &+ info.ri_system_time
        )
#else
        _ = pid
        return nil
#endif
    }

    static func idleSample(pid: Int32, seconds: Double) async -> IdleSample? {
        guard let before = resourceUsage(pid: pid) else { return nil }
        let started = ContinuousClock.now
        try? await Task.sleep(for: .seconds(seconds))
        guard let after = resourceUsage(pid: pid) else { return nil }
        let elapsedMS = WarmRuntimeBenchmarkRunner.elapsedMilliseconds(from: started, to: .now)
        guard elapsedMS > 0 else { return nil }
        let cpuDelta = after.cpuNanoseconds >= before.cpuNanoseconds
            ? after.cpuNanoseconds - before.cpuNanoseconds
            : 0
        return IdleSample(
            cpuPercent: (Double(cpuDelta) / (elapsedMS * 1_000_000)) * 100,
            after: after
        )
    }

    static func hasNetworkSocket(pid: Int32) -> Bool? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else {
            return nil
        }
        let result = run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-p", String(pid), "-i"]
        )
        guard result.status == 0 || result.status == 1 else { return nil }
        let lines = result.output.split(whereSeparator: \.isNewline)
        return result.status == 0 && lines.count > 1
    }

    private static func run(executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }
}
