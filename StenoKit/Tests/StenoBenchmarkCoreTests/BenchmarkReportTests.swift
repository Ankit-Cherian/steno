import Foundation
import Testing
@testable import StenoBenchmarkCore
@testable import StenoKit

@Test("Report renderer includes required scorecard labels")
func reportRendererIncludesRequiredLabels() throws {
    let manifest = BenchmarkManifest(
        benchmarkName: "Report Fixture",
        samples: [
            .init(
                id: "sample-1",
                dataset: "fixture",
                audioPath: "audio.wav",
                referenceText: "hello world"
            )
        ]
    )
    let raw = RawEngineOutput(
        benchmarkName: "Report Fixture",
        manifestSchemaVersion: manifest.schemaVersion,
        normalizationPolicy: manifest.scoring.normalization,
        whisperConfiguration: .init(whisperCLIPath: "/tmp/whisper-cli", modelPath: "/tmp/model.bin"),
        summary: .init(
            totalSamples: 1,
            succeeded: 1,
            failed: 0,
            failureRate: 0,
            wer: 0,
            cer: 0,
            meanLatencyMS: 100,
            p50LatencyMS: 100,
            p90LatencyMS: 100,
            p99LatencyMS: 100,
            meanRTF: 0.5
        ),
        datasetBreakdown: [:],
        samples: []
    )
    let pipeline = PipelineOutput(
        benchmarkName: "Report Fixture",
        profile: .init(
            name: "benchmark-local",
            tone: .natural,
            structureMode: .natural,
            fillerPolicy: .balanced,
            commandPolicy: .passthrough
        ),
        lexiconEntryCount: 0,
        normalizationPolicy: manifest.scoring.normalization,
        summary: .init(
            totalSamples: 1,
            scoredSamples: 1,
            rawWER: 0,
            rawCER: 0,
            cleanedWER: 0,
            cleanedCER: 0,
            werDelta: 0,
            cerDelta: 0,
            improved: 0,
            unchanged: 1,
            regressed: 0,
            unscored: 0,
            lexicon: .init(
                totalAppliedEdits: 0,
                editsMatchingReference: 0,
                editsNotMatchingReference: 0,
                referenceMatchAccuracy: nil
            ),
            fillerImpact: .init(
                samplesWithFillerRemovals: 0,
                totalRemovedFillers: 0,
                rawWEROnFillerSamples: nil,
                cleanedWEROnFillerSamples: nil,
                deltaWEROnFillerSamples: nil,
                improved: 0,
                unchanged: 0,
                regressed: 0
            )
        ),
        samples: []
    )
    let mac = MacSanityChecklist(
        items: [
            .init(id: "hotkey", title: "Hotkey works", status: "pass")
        ]
    )

    let report = BenchmarkReportRenderer.render(
        manifest: manifest,
        raw: raw,
        pipeline: pipeline,
        macSanity: mac
    )
    try BenchmarkReportRenderer.validateRequiredLabels(in: report)

    #expect(report.contains(BenchmarkReportRenderer.rawLabel))
    #expect(report.contains(BenchmarkReportRenderer.pipelineLabel))
}

@Test("Report validation fails if required labels are missing")
func reportValidationFailsWithoutRequiredLabels() {
    let report = "This report is missing labels."
    do {
        try BenchmarkReportRenderer.validateRequiredLabels(in: report)
        Issue.record("Expected validation to throw when labels are missing.")
    } catch BenchmarkReportError.missingRequiredLabel(let label) {
        #expect(!label.isEmpty)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

