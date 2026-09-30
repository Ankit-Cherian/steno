import Foundation
import Testing
@testable import StenoBenchmarkCore
@testable import StenoKit

@Test("Raw benchmark run keeps the decoder's segments and mean token confidence")
func rawRunKeepsDecoderConfidenceAndSegments() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("benchmark-confidence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try Data().write(to: tempDir.appendingPathComponent("sample.wav"))
    let scriptURL = try writeFakeWhisper(
        in: tempDir,
        json: #"{"transcription":[{"offsets":{"from":0,"to":1200},"text":" ping terso","tokens":[{"p":0.9},{"p":0.96}]}]}"#
    )

    let manifest = BenchmarkManifest(
        benchmarkName: "Confidence Fixture",
        samples: [
            .init(id: "sample", dataset: "fixture", audioPath: "sample.wav", referenceText: "ping TURSO")
        ]
    )
    let output = await BenchmarkRunner.runRaw(
        manifest: manifest,
        configuration: .init(
            manifestPath: tempDir.appendingPathComponent("manifest.json").path,
            whisperConfiguration: .init(
                whisperCLIPath: scriptURL.path,
                modelPath: tempDir.appendingPathComponent("fake-model.bin").path
            )
        )
    )

    let sample = try #require(output.samples.first)
    #expect(sample.status == .success)
    #expect(sample.hypothesisText == "ping terso")
    let confidence = try #require(sample.avgConfidence)
    #expect(abs(confidence - 0.93) < 1e-9)
    #expect(sample.segments?.count == 1)
    #expect(sample.segments?.first?.text == "ping terso")
    #expect(sample.segments?.first?.endMS == 1_200)

    let roundTripped = try JSONDecoder().decode(
        RawEngineOutput.self,
        from: JSONEncoder().encode(output)
    )
    #expect(roundTripped.samples.first?.avgConfidence == sample.avgConfidence)
    #expect(roundTripped.samples.first?.segments == sample.segments)
}

@Test("Raw benchmark samples written before confidence was recorded still decode")
func rawSampleWithoutConfidenceDecodes() throws {
    let json = #"""
    {"id":"s","dataset":"d","audioPath":"a.wav","referenceText":"r","hypothesisText":"h",
     "status":"success","elapsedMS":1}
    """#
    let sample = try JSONDecoder().decode(RawEngineSampleResult.self, from: Data(json.utf8))

    #expect(sample.avgConfidence == nil)
    #expect(sample.segments == nil)
}

@Test("Pipeline cleanup receives the recorded confidence")
func pipelineCleanupReceivesRecordedConfidence() async {
    // Phonetic recovery is inferred by Steno and stays confidence-gated, so the cleaned text
    // shows whether the pipeline handed the recorded confidence to cleanup.
    let lexicon = PersonalLexicon(entries: [
        .init(term: "TURSO", preferred: "TURSO", scope: .global, phoneticRecovery: .properNounEnglish)
    ])
    let profile = StyleProfile(
        name: "benchmark-local",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )

    func cleaned(confidence: Double) async -> String? {
        let manifest = BenchmarkManifest(
            benchmarkName: "Confidence Fixture",
            samples: [.init(id: "sample", dataset: "fixture", audioPath: "sample.wav", referenceText: "ping TURSO")]
        )
        let rawOutput = RawEngineOutput(
            benchmarkName: "Confidence Fixture",
            manifestSchemaVersion: manifest.schemaVersion,
            normalizationPolicy: manifest.scoring.normalization,
            whisperConfiguration: .init(whisperCLIPath: "/unused", modelPath: "/unused"),
            summary: .init(
                totalSamples: 1, succeeded: 1, failed: 0, failureRate: 0, wer: 0.5, cer: 0.1,
                meanLatencyMS: nil, p50LatencyMS: nil, p90LatencyMS: nil, p99LatencyMS: nil, meanRTF: nil
            ),
            datasetBreakdown: [:],
            samples: [
                .init(
                    id: "sample",
                    dataset: "fixture",
                    audioPath: "sample.wav",
                    referenceText: "ping TURSO",
                    hypothesisText: "ping terso",
                    languageHint: "en",
                    status: .success,
                    errorMessage: nil,
                    elapsedMS: 100,
                    audioDurationMS: 1_000,
                    rtf: nil,
                    metrics: nil,
                    segments: [.init(startMS: 0, endMS: 1_000, text: "ping terso", confidence: confidence)],
                    avgConfidence: confidence
                )
            ]
        )
        let output = await BenchmarkRunner.runPipeline(
            manifest: manifest,
            rawOutput: rawOutput,
            configuration: .init(profile: profile, lexicon: lexicon)
        )
        return output.samples.first?.cleanedText
    }

    #expect(await cleaned(confidence: 0.55) == "ping TURSO")
    #expect(await cleaned(confidence: 0.96) == "ping terso")
}

private func writeFakeWhisper(in directory: URL, json: String) throws -> URL {
    let scriptURL = directory.appendingPathComponent("fake-whisper.sh")
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
    cat > "${output_base}.json" <<'JSON'
    \(json)
    JSON
    exit 0
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: scriptURL.path
    )
    return scriptURL
}
