import Foundation
import StenoKit

public enum BenchmarkRunnerError: Error, LocalizedError {
    case rawOutputMissingSample(sampleID: String)

    public var errorDescription: String? {
        switch self {
        case .rawOutputMissingSample(let sampleID):
            return "Raw output did not contain sample id: \(sampleID)"
        }
    }
}

public struct RawRunConfiguration: Sendable {
    public var manifestPath: String
    public var whisperConfiguration: BenchmarkWhisperConfiguration
    public var defaultLanguageHint: String?

    public init(
        manifestPath: String,
        whisperConfiguration: BenchmarkWhisperConfiguration,
        defaultLanguageHint: String? = nil
    ) {
        self.manifestPath = manifestPath
        self.whisperConfiguration = whisperConfiguration
        self.defaultLanguageHint = defaultLanguageHint
    }
}

public struct PipelineRunConfiguration: Sendable {
    public var profile: StyleProfile
    public var lexicon: PersonalLexicon
    public var manifestPath: String?

    public init(
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        manifestPath: String? = nil
    ) {
        self.profile = profile
        self.lexicon = lexicon
        self.manifestPath = manifestPath
    }
}

public enum BenchmarkRunner {
    public static func runRaw(
        manifest: BenchmarkManifest,
        configuration: RawRunConfiguration
    ) async -> RawEngineOutput {
        let normalizer = TextNormalizer(policy: manifest.scoring.normalization)
        let engine = WhisperCLITranscriptionEngine(
            config: .init(
                whisperCLIPath: URL(fileURLWithPath: configuration.whisperConfiguration.whisperCLIPath),
                modelPath: URL(fileURLWithPath: configuration.whisperConfiguration.modelPath),
                additionalArguments: configuration.whisperConfiguration.additionalArguments
            )
        )

        var sampleResults: [RawEngineSampleResult] = []
        sampleResults.reserveCapacity(manifest.samples.count)

        let manifestDirectory = URL(fileURLWithPath: configuration.manifestPath).deletingLastPathComponent()

        for sample in manifest.samples {
            let started = Date()
            let audioURL = resolveSampleAudioPath(sample.audioPath, manifestDirectory: manifestDirectory)
            let languageHint = sample.languageHint ?? configuration.defaultLanguageHint

            do {
                let raw = try await engine.transcribe(
                    audioURL: audioURL,
                    request: TranscriptionRequest(
                        languageHints: languageHint.map { [$0] } ?? []
                    )
                )
                let elapsedMS = elapsedMilliseconds(since: started)
                let metrics = BenchmarkScorer.score(
                    reference: sample.referenceText,
                    hypothesis: raw.text,
                    normalizer: normalizer
                )
                sampleResults.append(
                    RawEngineSampleResult(
                        id: sample.id,
                        dataset: sample.dataset,
                        audioPath: sample.audioPath,
                        referenceText: sample.referenceText,
                        hypothesisText: raw.text,
                        languageHint: languageHint,
                        status: .success,
                        errorMessage: nil,
                        elapsedMS: elapsedMS,
                        audioDurationMS: sample.audioDurationMS,
                        rtf: computeRTF(elapsedMS: elapsedMS, audioDurationMS: sample.audioDurationMS),
                        metrics: metrics
                    )
                )
            } catch {
                let elapsedMS = elapsedMilliseconds(since: started)
                sampleResults.append(
                    RawEngineSampleResult(
                        id: sample.id,
                        dataset: sample.dataset,
                        audioPath: sample.audioPath,
                        referenceText: sample.referenceText,
                        hypothesisText: nil,
                        languageHint: languageHint,
                        status: .failed,
                        errorMessage: error.localizedDescription,
                        elapsedMS: elapsedMS,
                        audioDurationMS: sample.audioDurationMS,
                        rtf: computeRTF(elapsedMS: elapsedMS, audioDurationMS: sample.audioDurationMS),
                        metrics: nil
                    )
                )
            }
        }

        return RawEngineOutput(
            benchmarkName: manifest.benchmarkName,
            evidenceTier: manifest.evidenceTier,
            hardwareProfile: manifest.hardwareProfile,
            manifestSchemaVersion: manifest.schemaVersion,
            normalizationPolicy: manifest.scoring.normalization,
            whisperConfiguration: configuration.whisperConfiguration,
            summary: aggregateRaw(sampleResults),
            datasetBreakdown: aggregateRawByDataset(sampleResults),
            samples: sampleResults
        )
    }

    public static func runPipeline(
        manifest: BenchmarkManifest,
        rawOutput: RawEngineOutput,
        configuration: PipelineRunConfiguration
    ) async -> PipelineOutput {
        let normalizer = TextNormalizer(policy: manifest.scoring.normalization)
        let cleanup = RuleBasedCleanupEngine()
        var rawByID: [String: RawEngineSampleResult] = [:]
        for sample in rawOutput.samples {
            rawByID[sample.id] = sample
        }

        let coordinatorLatencies = await measureCoordinatorLatenciesIfNeeded(
            manifest: manifest,
            rawOutput: rawOutput,
            configuration: configuration
        )

        var sampleResults: [PipelineSampleResult] = []
        sampleResults.reserveCapacity(manifest.samples.count)

        for sample in manifest.samples {
            guard let rawSample = rawByID[sample.id] else {
                sampleResults.append(
                    PipelineSampleResult(
                        id: sample.id,
                        dataset: sample.dataset,
                        referenceText: sample.referenceText,
                        rawText: nil,
                        cleanedText: nil,
                        status: .skipped,
                        errorMessage: "Missing raw sample result for id \(sample.id)",
                        edits: [],
                        removedFillers: [],
                        rawMetrics: nil,
                        cleanedMetrics: nil,
                        delta: nil,
                        outcome: .unscored
                    )
                )
                continue
            }

            guard rawSample.status == .success, let rawText = rawSample.hypothesisText else {
                sampleResults.append(
                    PipelineSampleResult(
                        id: sample.id,
                        dataset: sample.dataset,
                        referenceText: sample.referenceText,
                        rawText: rawSample.hypothesisText,
                        cleanedText: nil,
                        status: .skipped,
                        errorMessage: "Raw transcription failed: \(rawSample.errorMessage ?? "no transcript")",
                        edits: [],
                        removedFillers: [],
                        rawMetrics: rawSample.metrics,
                        cleanedMetrics: nil,
                        delta: nil,
                        outcome: .unscored
                    )
                )
                continue
            }

            let rawMetrics = rawSample.metrics
                ?? BenchmarkScorer.score(
                    reference: sample.referenceText,
                    hypothesis: rawText,
                    normalizer: normalizer
                )

            do {
                let cleaned = try await cleanup.cleanup(
                    raw: RawTranscript(text: rawText, durationMS: sample.audioDurationMS ?? 0),
                    profile: configuration.profile,
                    lexicon: configuration.lexicon
                )

                let cleanedMetrics = BenchmarkScorer.score(
                    reference: sample.referenceText,
                    hypothesis: cleaned.text,
                    normalizer: normalizer
                )

                let delta = PipelineSampleDelta(
                    werDelta: cleanedMetrics.wer - rawMetrics.wer,
                    cerDelta: cleanedMetrics.cer - rawMetrics.cer
                )

                sampleResults.append(
                    PipelineSampleResult(
                        id: sample.id,
                        dataset: sample.dataset,
                        referenceText: sample.referenceText,
                        rawText: rawText,
                        cleanedText: cleaned.text,
                        status: .success,
                        errorMessage: nil,
                        edits: cleaned.edits,
                        removedFillers: cleaned.removedFillers,
                        rawMetrics: rawMetrics,
                        cleanedMetrics: cleanedMetrics,
                        delta: delta,
                        outcome: classifyOutcome(raw: rawMetrics, cleaned: cleanedMetrics)
                    )
                )
            } catch {
                sampleResults.append(
                    PipelineSampleResult(
                        id: sample.id,
                        dataset: sample.dataset,
                        referenceText: sample.referenceText,
                        rawText: rawText,
                        cleanedText: nil,
                        status: .failed,
                        errorMessage: error.localizedDescription,
                        edits: [],
                        removedFillers: [],
                        rawMetrics: rawMetrics,
                        cleanedMetrics: nil,
                        delta: nil,
                        outcome: .unscored
                    )
                )
            }
        }

        let summary = aggregatePipeline(
            sampleResults: sampleResults,
            normalizer: normalizer,
            lexicon: configuration.lexicon,
            coordinatorLatencies: coordinatorLatencies
        )

        return PipelineOutput(
            benchmarkName: manifest.benchmarkName,
            evidenceTier: manifest.evidenceTier,
            hardwareProfile: manifest.hardwareProfile,
            profile: configuration.profile,
            lexiconEntryCount: configuration.lexicon.entries.count,
            normalizationPolicy: manifest.scoring.normalization,
            summary: summary,
            samples: sampleResults
        )
    }

    public static func defaultMacSanityChecklist() -> MacSanityChecklist {
        MacSanityChecklist(
            items: [
                .init(id: "hotkey_option_press_to_talk", title: "Option press-to-talk starts/stops recording without stuck state"),
                .init(id: "hotkey_hands_free_toggle", title: "Hands-free global key toggles recording start/stop"),
                .init(id: "insertion_editor_target", title: "Insertion succeeds in a standard text editor target"),
                .init(id: "insertion_terminal_target", title: "Terminal target prefers clipboard paste strategy and inserts text"),
                .init(id: "media_known_playing", title: "Active or likely playback pauses on dictation start and resumes on end"),
                .init(id: "media_unknown_state_safe", title: "Unknown playback state sends no play/pause key event"),
            ]
        )
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func computeRTF(elapsedMS: Int, audioDurationMS: Int?) -> Double? {
        guard let audioDurationMS, audioDurationMS > 0 else { return nil }
        return Double(elapsedMS) / Double(audioDurationMS)
    }

    private static func resolveSampleAudioPath(_ rawPath: String, manifestDirectory: URL) -> URL {
        let url = URL(fileURLWithPath: rawPath)
        if rawPath.hasPrefix("/") {
            return url
        }
        return manifestDirectory.appendingPathComponent(rawPath)
    }

    private static func aggregateRaw(_ samples: [RawEngineSampleResult]) -> RawEngineAggregate {
        let successes = samples.filter { $0.status == .success }
        let failures = samples.filter { $0.status == .failed }
        let latencies = successes.map(\.elapsedMS)
        let rtfs = successes.compactMap(\.rtf)

        var totals = MetricTotals()
        for metrics in successes.compactMap(\.metrics) {
            totals.add(metrics)
        }

        return RawEngineAggregate(
            totalSamples: samples.count,
            succeeded: successes.count,
            failed: failures.count,
            failureRate: samples.isEmpty ? 0 : Double(failures.count) / Double(samples.count),
            wer: totals.wer(),
            cer: totals.cer(),
            meanLatencyMS: BenchmarkScorer.mean(latencies),
            p50LatencyMS: BenchmarkScorer.percentile(latencies, percentile: 0.5),
            p90LatencyMS: BenchmarkScorer.percentile(latencies, percentile: 0.9),
            p99LatencyMS: BenchmarkScorer.percentile(latencies, percentile: 0.99),
            meanRTF: BenchmarkScorer.mean(rtfs)
        )
    }

    private static func aggregateRawByDataset(_ samples: [RawEngineSampleResult]) -> [String: RawEngineAggregate] {
        let grouped = Dictionary(grouping: samples, by: \.dataset)
        var output: [String: RawEngineAggregate] = [:]
        for (dataset, group) in grouped {
            output[dataset] = aggregateRaw(group)
        }
        return output
    }

    private static func classifyOutcome(
        raw: BenchmarkTextQualityMetrics,
        cleaned: BenchmarkTextQualityMetrics,
        epsilon: Double = 1e-9
    ) -> PipelineOutcome {
        if cleaned.wer + epsilon < raw.wer { return .improved }
        if cleaned.wer > raw.wer + epsilon { return .regressed }
        if cleaned.cer + epsilon < raw.cer { return .improved }
        if cleaned.cer > raw.cer + epsilon { return .regressed }
        return .unchanged
    }

    private static func aggregatePipeline(
        sampleResults: [PipelineSampleResult],
        normalizer: TextNormalizer,
        lexicon: PersonalLexicon,
        coordinatorLatencies: [String: Int]
    ) -> PipelineAggregate {
        var rawTotals = MetricTotals()
        var cleanedTotals = MetricTotals()

        var improved = 0
        var unchanged = 0
        var regressed = 0
        var unscored = 0

        var lexiconApplied = 0
        var lexiconReferenceMatches = 0
        var lexiconReferenceMisses = 0

        var fillerSamples = 0
        var fillerRemovedCount = 0
        var fillerRawTotals = MetricTotals()
        var fillerCleanTotals = MetricTotals()
        var fillerImproved = 0
        var fillerUnchanged = 0
        var fillerRegressed = 0

        let normalizedPreferredTerms = Array(
            Set(
                lexicon.entries
                    .map(\.preferred)
                    .map(normalizer.normalize)
                    .filter { !$0.isEmpty }
            )
        )
        var termRelevantSamples = 0
        var termRecoveredSamples = 0
        var repairRelevantSamples = 0
        var repairResolvedSamples = 0
        var unintendedRewriteSamples = 0

        for sample in sampleResults {
            if let rawMetrics = sample.rawMetrics, let cleanedMetrics = sample.cleanedMetrics {
                rawTotals.add(rawMetrics)
                cleanedTotals.add(cleanedMetrics)
            }

            switch sample.outcome {
            case .improved:
                improved += 1
            case .unchanged:
                unchanged += 1
            case .regressed:
                regressed += 1
            case .unscored:
                unscored += 1
            }

            let normalizedReference = normalizer.normalize(sample.referenceText)
            for edit in sample.edits where edit.kind == .lexiconCorrection {
                lexiconApplied += 1
                let normalizedPreferred = normalizer.normalize(edit.to)
                if BenchmarkScorer.containsWholeWordOrPhrase(
                    in: normalizedReference,
                    term: normalizedPreferred
                ) {
                    lexiconReferenceMatches += 1
                } else {
                    lexiconReferenceMisses += 1
                }
            }

            if !sample.removedFillers.isEmpty,
               let rawMetrics = sample.rawMetrics,
               let cleanedMetrics = sample.cleanedMetrics {
                fillerSamples += 1
                fillerRemovedCount += sample.removedFillers.count
                fillerRawTotals.add(rawMetrics)
                fillerCleanTotals.add(cleanedMetrics)

                switch sample.outcome {
                case .improved:
                    fillerImproved += 1
                case .unchanged:
                    fillerUnchanged += 1
                case .regressed:
                    fillerRegressed += 1
                case .unscored:
                    break
                }
            }

            let normalizedCleaned = normalizer.normalize(sample.cleanedText ?? "")
            let normalizedRaw = normalizer.normalize(sample.rawText ?? "")
            let rawHasRepairMarker = containsRepairMarker(sample.rawText ?? "")

            let referenceTerms = normalizedPreferredTerms.filter {
                BenchmarkScorer.containsWholeWordOrPhrase(
                    in: normalizedReference,
                    term: $0
                )
            }
            if referenceTerms.isEmpty == false {
                termRelevantSamples += 1
                let recoveredAllTerms = referenceTerms.allSatisfy {
                    BenchmarkScorer.containsWholeWordOrPhrase(
                        in: normalizedCleaned,
                        term: $0
                    )
                }
                if recoveredAllTerms {
                    termRecoveredSamples += 1
                }
            }

            if rawHasRepairMarker {
                repairRelevantSamples += 1
                let resolvedRepair = sample.edits.contains(where: { $0.kind == .repairResolution })
                    && containsRepairMarker(sample.cleanedText ?? "") == false
                    && sample.outcome != .regressed
                if resolvedRepair {
                    repairResolvedSamples += 1
                }
            }

            if let rawMetrics = sample.rawMetrics,
               let cleanedMetrics = sample.cleanedMetrics,
               normalizedRaw != normalizedCleaned,
               cleanedMetrics.wer > rawMetrics.wer {
                unintendedRewriteSamples += 1
            }
        }

        let rawWER = rawTotals.wer()
        let rawCER = rawTotals.cer()
        let cleanedWER = cleanedTotals.wer()
        let cleanedCER = cleanedTotals.cer()

        let lexiconAccuracy: Double? = lexiconApplied > 0
            ? Double(lexiconReferenceMatches) / Double(lexiconApplied)
            : nil

        let fillerRawWER = fillerRawTotals.wer()
        let fillerCleanWER = fillerCleanTotals.wer()

        let fillerSummary = PipelineFillerImpactSummary(
            samplesWithFillerRemovals: fillerSamples,
            totalRemovedFillers: fillerRemovedCount,
            rawWEROnFillerSamples: fillerRawWER,
            cleanedWEROnFillerSamples: fillerCleanWER,
            deltaWEROnFillerSamples: {
                guard let fillerRawWER, let fillerCleanWER else { return nil }
                return fillerCleanWER - fillerRawWER
            }(),
            improved: fillerImproved,
            unchanged: fillerUnchanged,
            regressed: fillerRegressed
        )

        let lexiconSummary = PipelineLexiconSummary(
            totalAppliedEdits: lexiconApplied,
            editsMatchingReference: lexiconReferenceMatches,
            editsNotMatchingReference: lexiconReferenceMisses,
            referenceMatchAccuracy: lexiconAccuracy
        )

        let termRecallAccuracy = termRelevantSamples > 0
            ? Double(termRecoveredSamples) / Double(termRelevantSamples)
            : nil
        let repairResolutionRate = repairRelevantSamples > 0
            ? Double(repairResolvedSamples) / Double(repairRelevantSamples)
            : nil
        let unintendedRewriteRate = sampleResults.isEmpty == false
            ? Double(unintendedRewriteSamples) / Double(max(sampleResults.count - unscored, 1))
            : nil
        let latencyValues = coordinatorLatencies.values.sorted()
        let p90LatencyMS = latencyValues.isEmpty ? nil : BenchmarkScorer.percentile(latencyValues, percentile: 0.9)
        let p99LatencyMS = latencyValues.isEmpty ? nil : BenchmarkScorer.percentile(latencyValues, percentile: 0.99)

        return PipelineAggregate(
            totalSamples: sampleResults.count,
            scoredSamples: sampleResults.count - unscored,
            rawWER: rawWER,
            rawCER: rawCER,
            cleanedWER: cleanedWER,
            cleanedCER: cleanedCER,
            werDelta: {
                guard let rawWER, let cleanedWER else { return nil }
                return cleanedWER - rawWER
            }(),
            cerDelta: {
                guard let rawCER, let cleanedCER else { return nil }
                return cleanedCER - rawCER
            }(),
            improved: improved,
            unchanged: unchanged,
            regressed: regressed,
            unscored: unscored,
            termRecallAccuracy: termRecallAccuracy,
            repairResolutionRate: repairResolutionRate,
            unintendedRewriteRate: unintendedRewriteRate,
            p90LatencyMS: p90LatencyMS,
            p99LatencyMS: p99LatencyMS,
            lexicon: lexiconSummary,
            fillerImpact: fillerSummary
        )
    }

    private static func measureCoordinatorLatenciesIfNeeded(
        manifest: BenchmarkManifest,
        rawOutput: RawEngineOutput,
        configuration: PipelineRunConfiguration
    ) async -> [String: Int] {
        guard manifest.evidenceTier == .releaseSignoff,
              let manifestPath = configuration.manifestPath else {
            return [:]
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifestDirectory: URL
        if manifestURL.hasDirectoryPath {
            manifestDirectory = manifestURL
        } else {
            manifestDirectory = manifestURL.deletingLastPathComponent()
        }
        var results: [String: Int] = [:]

        for sample in manifest.samples {
            let audioSourceURL = resolveSampleAudioPath(sample.audioPath, manifestDirectory: manifestDirectory)
            let captureService = BenchmarkAudioCaptureService(sourceAudioURL: audioSourceURL)
            let engine = WhisperCLITranscriptionEngine(
                config: .init(
                    whisperCLIPath: URL(fileURLWithPath: rawOutput.whisperConfiguration.whisperCLIPath),
                    modelPath: URL(fileURLWithPath: rawOutput.whisperConfiguration.modelPath),
                    additionalArguments: rawOutput.whisperConfiguration.additionalArguments
                )
            )
            let insertionService = InsertionService(
                transports: [
                    ClosureInsertionTransport(method: .direct) { _, _ in }
                ]
            )
            let historyStore = HistoryStore(
                storageURL: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("benchmark-history-\(UUID().uuidString).json"),
                clipboardService: MemoryClipboardService()
            )
            let coordinator = SessionCoordinator(
                captureService: captureService,
                transcriptionEngine: engine,
                cleanupEngine: RuleBasedCleanupEngine(),
                insertionService: insertionService,
                historyStore: historyStore,
                lexiconService: PersonalLexiconService(entries: configuration.lexicon.entries),
                styleProfileService: StyleProfileService(globalProfile: configuration.profile)
            )

            do {
                let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
                let started = Date()
                _ = try await coordinator.stopPressToTalk(
                    sessionID: sessionID,
                    languageHints: sample.languageHint.map { [$0] } ?? ["en-US"]
                )
                results[sample.id] = elapsedMilliseconds(since: started)
            } catch {
                continue
            }
        }

        return results
    }

    private static func containsRepairMarker(_ text: String) -> Bool {
        let markers = [
            "scratch that",
            "delete that",
            "erase that",
            "never mind",
            "actually",
            "i mean",
            "no,"
        ]

        return markers.contains { marker in
            text.range(of: marker, options: [.caseInsensitive]) != nil
        }
    }
}

private actor BenchmarkAudioCaptureService: AudioCaptureService {
    private let sourceAudioURL: URL

    init(sourceAudioURL: URL) {
        self.sourceAudioURL = sourceAudioURL
    }

    func beginCapture(sessionID: SessionID) async throws {
        _ = sessionID
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        _ = sessionID
        let copiedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("benchmark-audio-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: sourceAudioURL, to: copiedURL)
        return copiedURL
    }

    func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
    }
}
