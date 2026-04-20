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
                referenceText: "send it to Jane and ping TURSO"
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
    #expect(output.summary.repairResolutionRate == 1)
    #expect(output.summary.unintendedRewriteRate == 0)
    #expect(output.summary.p90LatencyMS == nil)
    #expect(output.summary.p99LatencyMS == nil)
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
}
