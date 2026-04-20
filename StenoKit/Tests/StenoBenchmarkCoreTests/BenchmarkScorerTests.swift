import Foundation
import Testing
@testable import StenoBenchmarkCore
@testable import StenoKit

@Test("Scorer normalizes punctuation and case for equivalent text")
func scorerNormalizesEquivalentText() {
    let policy = NormalizationPolicy(
        lowercase: true,
        collapseWhitespace: true,
        trimWhitespace: true,
        stripPunctuation: true,
        keepApostrophes: true
    )
    let normalizer = TextNormalizer(policy: policy)

    let metrics = BenchmarkScorer.score(
        reference: "Hello, WORLD!",
        hypothesis: "hello world",
        normalizer: normalizer
    )

    #expect(metrics.wer == 0)
    #expect(metrics.cer == 0)
}

@Test("Scorer computes WER from token edits")
func scorerComputesWER() {
    let normalizer = TextNormalizer(policy: NormalizationPolicy())
    let metrics = BenchmarkScorer.score(
        reference: "hello world",
        hypothesis: "hello there",
        normalizer: normalizer
    )

    #expect(metrics.wordEdits == 1)
    #expect(metrics.wordReferenceCount == 2)
    #expect(metrics.wer == 0.5)
}

@Test("Percentile helper uses nearest-rank policy")
func percentileHelperNearestRank() {
    let values = [10, 20, 30, 40]

    #expect(BenchmarkScorer.percentile(values, percentile: 0.5) == 20)
    #expect(BenchmarkScorer.percentile(values, percentile: 0.9) == 40)
}

@Test("Pipeline run computes cleaned improvements and lexicon/filler summaries")
func pipelineRunComputesExpectedSummaries() async {
    let manifest = BenchmarkManifest(
        benchmarkName: "Fixture Benchmark",
        samples: [
            .init(
                id: "sample-1",
                dataset: "fixture",
                audioPath: "audio.wav",
                referenceText: "Steno testing"
            )
        ]
    )

    let rawOutput = RawEngineOutput(
        benchmarkName: "Fixture Benchmark",
        manifestSchemaVersion: manifest.schemaVersion,
        normalizationPolicy: manifest.scoring.normalization,
        whisperConfiguration: .init(
            whisperCLIPath: "/tmp/whisper-cli",
            modelPath: "/tmp/model.bin"
        ),
        summary: .init(
            totalSamples: 1,
            succeeded: 1,
            failed: 0,
            failureRate: 0,
            wer: 1,
            cer: 1,
            meanLatencyMS: 100,
            p50LatencyMS: 100,
            p90LatencyMS: 100,
            p99LatencyMS: 100,
            meanRTF: 0.5
        ),
        datasetBreakdown: [:],
        samples: [
            .init(
                id: "sample-1",
                dataset: "fixture",
                audioPath: "audio.wav",
                referenceText: "Steno testing",
                hypothesisText: "um stenoh testing",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 100,
                audioDurationMS: 200,
                rtf: 0.5,
                metrics: nil
            )
        ]
    )

    let profile = StyleProfile(
        name: "benchmark-local",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )
    let lexicon = PersonalLexicon(entries: [.init(term: "stenoh", preferred: "Steno", scope: .global)])

    let output = await BenchmarkRunner.runPipeline(
        manifest: manifest,
        rawOutput: rawOutput,
        configuration: .init(profile: profile, lexicon: lexicon)
    )

    #expect(output.summary.scoredSamples == 1)
    #expect(output.summary.improved == 1)
    #expect(output.summary.regressed == 0)
    #expect(output.summary.lexicon.totalAppliedEdits == 1)
    #expect(output.summary.fillerImpact.samplesWithFillerRemovals == 1)
}

@Test("Pipeline run computes term recovery repair resolution and rewrite metrics")
func pipelineRunComputesAdvancedQualityMetrics() async {
    let manifest = BenchmarkManifest(
        benchmarkName: "Advanced Fixture Benchmark",
        samples: [
            .init(
                id: "sample-1",
                dataset: "fixture",
                audioPath: "audio.wav",
                referenceText: "send it to Jane and ping TURSO",
                intentLabels: [.repair]
            )
        ]
    )

    let rawOutput = RawEngineOutput(
        benchmarkName: "Advanced Fixture Benchmark",
        manifestSchemaVersion: manifest.schemaVersion,
        normalizationPolicy: manifest.scoring.normalization,
        whisperConfiguration: .init(
            whisperCLIPath: "/tmp/whisper-cli",
            modelPath: "/tmp/model.bin"
        ),
        summary: .init(
            totalSamples: 1,
            succeeded: 1,
            failed: 0,
            failureRate: 0,
            wer: 0.5,
            cer: 0.2,
            meanLatencyMS: 720,
            p50LatencyMS: 720,
            p90LatencyMS: 720,
            p99LatencyMS: 720,
            meanRTF: 0.25
        ),
        datasetBreakdown: [:],
        samples: [
            .init(
                id: "sample-1",
                dataset: "fixture",
                audioPath: "audio.wav",
                referenceText: "send it to Jane and ping TURSO",
                hypothesisText: "send it to John scratch that Jane and ping terso",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 720,
                audioDurationMS: 10_000,
                rtf: 0.25,
                metrics: nil
            )
        ]
    )

    let profile = StyleProfile(
        name: "benchmark-local",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )
    let lexicon = PersonalLexicon(entries: [
        .init(term: "TURSO", preferred: "TURSO", scope: .global, phoneticRecovery: .properNounEnglish)
    ])

    let output = await BenchmarkRunner.runPipeline(
        manifest: manifest,
        rawOutput: rawOutput,
        configuration: .init(profile: profile, lexicon: lexicon)
    )

    #expect(output.summary.termRecallAccuracy == 1)
    #expect(output.summary.repairMarkerPreservationRate == 1)
    #expect(output.summary.repairResolutionRate == 1)
    #expect(output.summary.repairExactMatchRate == 1)
    #expect(output.summary.unintendedRewriteRate == 0)
    #expect(output.summary.p90LatencyMS == nil)
    #expect(output.summary.p99LatencyMS == nil)
}

@Test("Pipeline run does not count command passthrough failures as unintended rewrites")
func pipelineRunCommandFailureDoesNotInflateRewriteRate() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("benchmark-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let audioURL = tempDir.appendingPathComponent("command.wav")
    try Data().write(to: audioURL)

    let scriptURL = tempDir.appendingPathComponent("fake-whisper.sh")
    try """
    #!/bin/sh
    output_base=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-of" ]; then
        output_base="$arg"
      fi
      prev="$arg"
    done
    printf "Bill Target.\\n" > "${output_base}.txt"
    exit 0
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: scriptURL.path
    )

    let manifest = BenchmarkManifest(
        benchmarkName: "Command Fixture",
        evidenceTier: .releaseSignoff,
        hardwareProfile: .init(chipClass: .m5Pro, memoryGB: 64, modelID: .largeV3Turbo),
        samples: [
            .init(
                id: "command",
                dataset: "targeted",
                audioPath: "command.wav",
                referenceText: "/build target",
                audioDurationMS: 1_000,
                audioSource: .syntheticSpeech,
                intentLabels: [.command],
                appContextPreset: .ide
            )
        ]
    )

    let rawOutput = RawEngineOutput(
        benchmarkName: "Command Fixture",
        evidenceTier: .releaseSignoff,
        hardwareProfile: .init(chipClass: .m5Pro, memoryGB: 64, modelID: .largeV3Turbo),
        manifestSchemaVersion: manifest.schemaVersion,
        normalizationPolicy: manifest.scoring.normalization,
        whisperConfiguration: .init(
            whisperCLIPath: scriptURL.path,
            modelPath: tempDir.appendingPathComponent("fake-model.bin").path
        ),
        summary: .init(
            totalSamples: 1,
            succeeded: 1,
            failed: 0,
            failureRate: 0,
            wer: 1,
            cer: 1,
            meanLatencyMS: 720,
            p50LatencyMS: 720,
            p90LatencyMS: 720,
            p99LatencyMS: 720,
            meanRTF: 0.25
        ),
        datasetBreakdown: [:],
        samples: [
            .init(
                id: "command",
                dataset: "targeted",
                audioPath: "command.wav",
                referenceText: "/build target",
                hypothesisText: "Build target.",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 720,
                audioDurationMS: 1_000,
                rtf: 0.25,
                metrics: nil
            )
        ]
    )

    let output = await BenchmarkRunner.runPipeline(
        manifest: manifest,
        rawOutput: rawOutput,
        configuration: .init(
            profile: .init(
                name: "benchmark-local",
                tone: .natural,
                structureMode: .natural,
                fillerPolicy: .balanced,
                commandPolicy: .passthrough
            ),
            lexicon: .init(entries: []),
            manifestPath: tempDir.path
        )
    )

    #expect(output.summary.commandPassthroughAccuracy == nil)
    #expect(output.summary.commandPassthroughCoverageRate == 0)
    #expect(output.summary.unintendedRewriteRate == 0)
}

@Test("Pipeline command coverage follows coordinator replay localOnly passthrough")
func pipelineRunCommandCoverageUsesCoordinatorReplayContract() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("benchmark-command-coverage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let audioURL = tempDir.appendingPathComponent("command.wav")
    try Data().write(to: audioURL)

    let scriptURL = tempDir.appendingPathComponent("fake-whisper.sh")
    try """
    #!/bin/sh
    output_base=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-of" ]; then
        output_base="$arg"
      fi
      prev="$arg"
    done
    printf "/build target\\n" > "${output_base}.txt"
    exit 0
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: scriptURL.path
    )

    let manifest = BenchmarkManifest(
        benchmarkName: "Command Coverage Fixture",
        evidenceTier: .releaseSignoff,
        hardwareProfile: .init(chipClass: .m5Pro, memoryGB: 64, modelID: .largeV3Turbo),
        samples: [
            .init(
                id: "command",
                dataset: "targeted",
                audioPath: "command.wav",
                referenceText: "/build target",
                audioDurationMS: 1_000,
                audioSource: .syntheticSpeech,
                intentLabels: [.command],
                appContextPreset: .ide
            )
        ]
    )

    let rawOutput = RawEngineOutput(
        benchmarkName: "Command Coverage Fixture",
        evidenceTier: .releaseSignoff,
        hardwareProfile: .init(chipClass: .m5Pro, memoryGB: 64, modelID: .largeV3Turbo),
        manifestSchemaVersion: manifest.schemaVersion,
        normalizationPolicy: manifest.scoring.normalization,
        whisperConfiguration: .init(
            whisperCLIPath: scriptURL.path,
            modelPath: tempDir.appendingPathComponent("fake-model.bin").path
        ),
        summary: .init(
            totalSamples: 1,
            succeeded: 1,
            failed: 0,
            failureRate: 0,
            wer: 1,
            cer: 1,
            meanLatencyMS: 720,
            p50LatencyMS: 720,
            p90LatencyMS: 720,
            p99LatencyMS: 720,
            meanRTF: 0.25
        ),
        datasetBreakdown: [:],
        samples: [
            .init(
                id: "command",
                dataset: "targeted",
                audioPath: "command.wav",
                referenceText: "/build target",
                hypothesisText: "Build target.",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 720,
                audioDurationMS: 1_000,
                rtf: 0.25,
                metrics: nil
            )
        ]
    )

    let output = await BenchmarkRunner.runPipeline(
        manifest: manifest,
        rawOutput: rawOutput,
        configuration: .init(
            profile: .init(
                name: "benchmark-local",
                tone: .natural,
                structureMode: .natural,
                fillerPolicy: .balanced,
                commandPolicy: .passthrough
            ),
            lexicon: .init(entries: []),
            manifestPath: tempDir.path
        )
    )

    #expect(output.summary.commandPassthroughCoverageRate == 1)
    #expect(output.summary.commandPassthroughAccuracy == 1)
}

@Test("Pipeline run tracks repair detection separately from exact match")
func pipelineRunSeparatesRepairDetectionFromExactMatch() async {
    let manifest = BenchmarkManifest(
        benchmarkName: "Repair Detection Fixture",
        samples: [
            .init(
                id: "repair",
                dataset: "repair-intent",
                audioPath: "repair.wav",
                referenceText: "Call Jane",
                intentLabels: [.repair]
            )
        ]
    )

    let rawOutput = RawEngineOutput(
        benchmarkName: "Repair Detection Fixture",
        manifestSchemaVersion: manifest.schemaVersion,
        normalizationPolicy: manifest.scoring.normalization,
        whisperConfiguration: .init(
            whisperCLIPath: "/tmp/whisper-cli",
            modelPath: "/tmp/model.bin"
        ),
        summary: .init(
            totalSamples: 1,
            succeeded: 1,
            failed: 0,
            failureRate: 0,
            wer: 0.5,
            cer: 0.2,
            meanLatencyMS: 720,
            p50LatencyMS: 720,
            p90LatencyMS: 720,
            p99LatencyMS: 720,
            meanRTF: 0.25
        ),
        datasetBreakdown: [:],
        samples: [
            .init(
                id: "repair",
                dataset: "repair-intent",
                audioPath: "repair.wav",
                referenceText: "Call Jane",
                hypothesisText: "Call Bob delete that gene",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 720,
                audioDurationMS: 1_000,
                rtf: 0.25,
                metrics: nil
            )
        ]
    )

    let output = await BenchmarkRunner.runPipeline(
        manifest: manifest,
        rawOutput: rawOutput,
        configuration: .init(
            profile: .init(
                name: "benchmark-local",
                tone: .natural,
                structureMode: .natural,
                fillerPolicy: .balanced,
                commandPolicy: .passthrough
            ),
            lexicon: .init(entries: [])
        )
    )

    #expect(output.summary.repairMarkerPreservationRate == 1)
    #expect(output.summary.repairResolutionRate == 1)
    #expect(output.summary.repairExactMatchRate == 0)
}

@Test("Release signoff pipeline measures coordinator stop-to-insert latency")
func releaseSignoffPipelineMeasuresCoordinatorLatency() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("benchmark-latency-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let audioURL = tempDir.appendingPathComponent("sample.wav")
    try Data().write(to: audioURL)

    let scriptURL = tempDir.appendingPathComponent("fake-whisper.sh")
    try """
    #!/bin/sh
    output_base=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-of" ]; then
        output_base="$arg"
      fi
      prev="$arg"
    done
    printf "send it to John scratch that Jane and ping terso\\n" > "${output_base}.txt"
    exit 0
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: scriptURL.path
    )

    let manifest = BenchmarkManifest(
        benchmarkName: "Release Signoff Fixture",
        evidenceTier: .releaseSignoff,
        hardwareProfile: .init(chipClass: .m5Pro, memoryGB: 64, modelID: .largeV3Turbo),
        samples: [
            .init(
                id: "sample-1",
                dataset: "fixture",
                audioPath: "sample.wav",
                referenceText: "send it to Jane and ping TURSO",
                audioDurationMS: 10_000
            )
        ]
    )

    let rawOutput = RawEngineOutput(
        benchmarkName: "Release Signoff Fixture",
        evidenceTier: .releaseSignoff,
        hardwareProfile: .init(chipClass: .m5Pro, memoryGB: 64, modelID: .largeV3Turbo),
        manifestSchemaVersion: manifest.schemaVersion,
        normalizationPolicy: manifest.scoring.normalization,
        whisperConfiguration: .init(
            whisperCLIPath: scriptURL.path,
            modelPath: tempDir.appendingPathComponent("fake-model.bin").path
        ),
        summary: .init(
            totalSamples: 1,
            succeeded: 1,
            failed: 0,
            failureRate: 0,
            wer: 0.5,
            cer: 0.2,
            meanLatencyMS: 720,
            p50LatencyMS: 720,
            p90LatencyMS: 720,
            p99LatencyMS: 720,
            meanRTF: 0.25
        ),
        datasetBreakdown: [:],
        samples: [
            .init(
                id: "sample-1",
                dataset: "fixture",
                audioPath: "sample.wav",
                referenceText: "send it to Jane and ping TURSO",
                hypothesisText: "send it to John scratch that Jane and ping terso",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 720,
                audioDurationMS: 10_000,
                rtf: 0.25,
                metrics: nil
            )
        ]
    )

    let profile = StyleProfile(
        name: "benchmark-local",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )
    let lexicon = PersonalLexicon(entries: [
        .init(term: "TURSO", preferred: "TURSO", scope: .global, phoneticRecovery: .properNounEnglish)
    ])

    let output = await BenchmarkRunner.runPipeline(
        manifest: manifest,
        rawOutput: rawOutput,
        configuration: .init(profile: profile, lexicon: lexicon, manifestPath: tempDir.path)
    )

    #expect(output.summary.p90LatencyMS != nil)
    #expect(output.summary.p99LatencyMS != nil)
    let observation = try #require(output.samples[0].coordinatorObservations.first)
    #expect(observation.timingBreakdownMS?.transcriptionMS != nil)
}

@Test("Release signoff pipeline computes literal command no-speech punctuation and multi-iteration latency metrics")
func releaseSignoffPipelineComputesExtendedMetrics() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("benchmark-extended-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sampleFileNames = [
        "repair.wav",
        "literal.wav",
        "command.wav",
        "artifact.wav",
        "nospeech.wav",
    ]
    for fileName in sampleFileNames {
        try Data().write(to: tempDir.appendingPathComponent(fileName))
    }

    let scriptURL = tempDir.appendingPathComponent("fake-whisper.sh")
    try """
    #!/bin/sh
    input_file=""
    output_base=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-f" ]; then
        input_file="$arg"
      fi
      if [ "$prev" = "-of" ]; then
        output_base="$arg"
      fi
      prev="$arg"
    done
    case "$(basename "$input_file")" in
      repair.wav)
        text="send it to John scratch that Jane"
        ;;
      literal.wav)
        text="type scratch that literally"
        ;;
      command.wav)
        text="/build target"
        ;;
      artifact.wav)
        text="hello ,"
        ;;
      nospeech.wav)
        text="   "
        ;;
      *)
        text="unknown"
        ;;
    esac
    printf "%s\\n" "$text" > "${output_base}.txt"
    exit 0
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: scriptURL.path
    )

    let manifest = BenchmarkManifest(
        benchmarkName: "Extended Release Signoff Fixture",
        evidenceTier: .releaseSignoff,
        hardwareProfile: .init(chipClass: .m5Pro, memoryGB: 64, modelID: .largeV3Turbo),
        samples: [
            .init(
                id: "repair",
                dataset: "targeted",
                audioPath: "repair.wav",
                referenceText: "send it to Jane",
                audioDurationMS: 1_000,
                audioSource: .syntheticSpeech,
                intentLabels: [.repair]
            ),
            .init(
                id: "literal",
                dataset: "targeted",
                audioPath: "literal.wav",
                referenceText: "type scratch that literally",
                audioDurationMS: 1_000,
                audioSource: .syntheticSpeech,
                intentLabels: [.literal],
                preservedPhrases: ["scratch that"]
            ),
            .init(
                id: "command",
                dataset: "targeted",
                audioPath: "command.wav",
                referenceText: "/build target",
                audioDurationMS: 1_000,
                audioSource: .syntheticSpeech,
                intentLabels: [.command],
                appContextPreset: .ide
            ),
            .init(
                id: "artifact",
                dataset: "targeted",
                audioPath: "artifact.wav",
                referenceText: "hello",
                audioDurationMS: 1_000,
                audioSource: .syntheticSpeech
            ),
            .init(
                id: "nospeech",
                dataset: "targeted",
                audioPath: "nospeech.wav",
                referenceText: "",
                audioDurationMS: 1_000,
                audioSource: .syntheticSilence,
                intentLabels: [.noSpeech]
            ),
        ]
    )

    let rawOutput = RawEngineOutput(
        benchmarkName: "Extended Release Signoff Fixture",
        evidenceTier: .releaseSignoff,
        hardwareProfile: .init(chipClass: .m5Pro, memoryGB: 64, modelID: .largeV3Turbo),
        manifestSchemaVersion: manifest.schemaVersion,
        normalizationPolicy: manifest.scoring.normalization,
        whisperConfiguration: .init(
            whisperCLIPath: scriptURL.path,
            modelPath: tempDir.appendingPathComponent("fake-model.bin").path
        ),
        summary: .init(
            totalSamples: 5,
            succeeded: 4,
            failed: 1,
            failureRate: 0.2,
            wer: 0.25,
            cer: 0.1,
            meanLatencyMS: 720,
            p50LatencyMS: 720,
            p90LatencyMS: 720,
            p99LatencyMS: 720,
            meanRTF: 0.25
        ),
        datasetBreakdown: [:],
        samples: [
            .init(
                id: "repair",
                dataset: "targeted",
                audioPath: "repair.wav",
                referenceText: "send it to Jane",
                hypothesisText: "send it to John scratch that Jane",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 720,
                audioDurationMS: 1_000,
                rtf: 0.25,
                metrics: nil
            ),
            .init(
                id: "literal",
                dataset: "targeted",
                audioPath: "literal.wav",
                referenceText: "type scratch that literally",
                hypothesisText: "type scratch that literally",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 720,
                audioDurationMS: 1_000,
                rtf: 0.25,
                metrics: nil
            ),
            .init(
                id: "command",
                dataset: "targeted",
                audioPath: "command.wav",
                referenceText: "/build target",
                hypothesisText: "/build target",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 720,
                audioDurationMS: 1_000,
                rtf: 0.25,
                metrics: nil
            ),
            .init(
                id: "artifact",
                dataset: "targeted",
                audioPath: "artifact.wav",
                referenceText: "hello",
                hypothesisText: "hello ,",
                languageHint: "en",
                status: .success,
                errorMessage: nil,
                elapsedMS: 720,
                audioDurationMS: 1_000,
                rtf: 0.25,
                metrics: nil
            ),
            .init(
                id: "nospeech",
                dataset: "targeted",
                audioPath: "nospeech.wav",
                referenceText: "",
                hypothesisText: nil,
                languageHint: "en",
                status: .failed,
                errorMessage: "Expected no speech from coordinator run.",
                elapsedMS: 720,
                audioDurationMS: 1_000,
                rtf: 0.25,
                metrics: nil
            ),
        ]
    )

    let profile = StyleProfile(
        name: "benchmark-local",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )

    let output = await BenchmarkRunner.runPipeline(
        manifest: manifest,
        rawOutput: rawOutput,
        configuration: .init(
            profile: profile,
            lexicon: .init(entries: []),
            manifestPath: tempDir.path,
            latencyIterations: 3
        )
    )

    #expect(output.summary.repairMarkerPreservationRate == 1)
    #expect(output.summary.repairResolutionRate == 1)
    #expect(output.summary.repairExactMatchRate == 1)
    #expect(output.summary.commandPassthroughCoverageRate == 1)
    #expect(output.summary.literalRepairPhrasePreservationRate == 1)
    #expect(output.summary.commandPassthroughAccuracy == 1)
    #expect(output.summary.noSpeechFalseInsertRate == 0)
    #expect(output.summary.punctuationArtifactRate == 0.25)
    #expect(output.summary.p50LatencyMS != nil)
    #expect(output.summary.p90LatencyMS != nil)
    #expect(output.summary.p99LatencyMS != nil)

    let commandSample = try #require(output.samples.first(where: { $0.id == "command" }))
    #expect(commandSample.coordinatorObservations.count == 3)
    #expect(commandSample.coordinatorObservations.allSatisfy { $0.insertResult?.insertedText == "/build target" })

    let noSpeechSample = try #require(output.samples.first(where: { $0.id == "nospeech" }))
    #expect(noSpeechSample.coordinatorObservations.count == 3)
    #expect(noSpeechSample.coordinatorObservations.allSatisfy { $0.insertResult?.status == .noSpeech })
}
