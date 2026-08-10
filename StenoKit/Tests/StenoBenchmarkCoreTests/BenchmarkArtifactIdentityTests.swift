import Foundation
import Testing
@testable import StenoBenchmarkCore
@testable import StenoKit

@Test("Benchmark identity hashes declared inputs without serializing private paths")
func benchmarkIdentityHashesDeclaredInputsWithoutPaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-benchmark-identity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifestURL = root.appendingPathComponent("manifest.json")
    let firstAudioURL = root.appendingPathComponent("first.wav")
    let secondAudioURL = root.appendingPathComponent("second.wav")
    let cliURL = root.appendingPathComponent("whisper-cli")
    let modelURL = root.appendingPathComponent("model.bin")
    let vadURL = root.appendingPathComponent("vad.bin")

    try Data("manifest-v1".utf8).write(to: manifestURL)
    try Data("first-audio".utf8).write(to: firstAudioURL)
    try Data("second-audio".utf8).write(to: secondAudioURL)
    try Data("cli-binary".utf8).write(to: cliURL)
    try Data("model-weights".utf8).write(to: modelURL)
    try Data("vad-weights".utf8).write(to: vadURL)

    let manifest = BenchmarkManifest(
        samples: [
            .init(id: "first", dataset: "fixture", audioPath: "first.wav", referenceText: "first"),
            .init(id: "second", dataset: "fixture", audioPath: "second.wav", referenceText: "second"),
        ]
    )
    let whisperConfiguration = BenchmarkWhisperConfiguration(
        whisperCLIPath: cliURL.path,
        modelPath: modelURL.path,
        additionalArguments: ["--vad", "--vad-model", vadURL.path, "-t", "6"],
        defaultLanguageHint: "en-US"
    )
    let appSource = BenchmarkSourceIdentity(commitSHA: "app-commit", treeIsDirty: false)
    let engineSource = BenchmarkSourceIdentity(commitSHA: "engine-commit", treeIsDirty: false)

    let firstIdentity = BenchmarkArtifactIdentity.capture(
        manifest: manifest,
        manifestPath: manifestURL.path,
        whisperConfiguration: whisperConfiguration,
        appSourceIdentity: appSource,
        engineSourceIdentity: engineSource
    )

    #expect(firstIdentity.appCommitSHA == "app-commit")
    #expect(firstIdentity.appTreeIsDirty == false)
    #expect(firstIdentity.engineCommitSHA == "engine-commit")
    #expect(firstIdentity.manifestSHA256?.count == 64)
    #expect(firstIdentity.audioSetSHA256?.count == 64)
    #expect(firstIdentity.whisperCLISHA256?.count == 64)
    #expect(firstIdentity.modelSHA256?.count == 64)
    #expect(firstIdentity.vadModelSHA256?.count == 64)

    let encoded = try JSONEncoder().encode(firstIdentity)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    #expect(encodedText.contains(root.path) == false)

    try Data("changed-first-audio".utf8).write(to: firstAudioURL)
    let secondIdentity = BenchmarkArtifactIdentity.capture(
        manifest: manifest,
        manifestPath: manifestURL.path,
        whisperConfiguration: whisperConfiguration,
        appSourceIdentity: appSource,
        engineSourceIdentity: engineSource
    )

    #expect(secondIdentity.audioSetSHA256 != firstIdentity.audioSetSHA256)
    #expect(secondIdentity.manifestSHA256 == firstIdentity.manifestSHA256)
    #expect(secondIdentity.modelSHA256 == firstIdentity.modelSHA256)
}

@Test("Pipeline output preserves raw artifact identity and language configuration")
func pipelineOutputPreservesRawIdentityAndLanguageConfiguration() async {
    let identity = BenchmarkArtifactIdentity(
        appCommitSHA: "app-commit",
        appTreeIsDirty: false,
        engineCommitSHA: "engine-commit",
        manifestSHA256: String(repeating: "1", count: 64),
        audioSetSHA256: String(repeating: "2", count: 64),
        whisperCLISHA256: String(repeating: "3", count: 64),
        modelSHA256: String(repeating: "4", count: 64),
        vadModelSHA256: String(repeating: "5", count: 64)
    )
    let whisperConfiguration = BenchmarkWhisperConfiguration(
        whisperCLIPath: "/tmp/whisper-cli",
        modelPath: "/tmp/model.bin",
        additionalArguments: ["-t", "6", "--suppress-nst"],
        defaultLanguageHint: "en-US"
    )
    let manifest = BenchmarkManifest(samples: [])
    let rawOutput = RawEngineOutput(
        benchmarkName: manifest.benchmarkName,
        runtime: BenchmarkRuntimeMetadata(identity: identity),
        manifestSchemaVersion: manifest.schemaVersion,
        normalizationPolicy: manifest.scoring.normalization,
        whisperConfiguration: whisperConfiguration,
        summary: .init(
            totalSamples: 0,
            succeeded: 0,
            failed: 0,
            failureRate: 0,
            wer: nil,
            cer: nil,
            meanLatencyMS: nil,
            p50LatencyMS: nil,
            p90LatencyMS: nil,
            p99LatencyMS: nil,
            meanRTF: nil
        ),
        datasetBreakdown: [:],
        samples: []
    )

    let pipelineOutput = await BenchmarkRunner.runPipeline(
        manifest: manifest,
        rawOutput: rawOutput,
        configuration: .init(
            profile: .init(
                name: "fixture",
                tone: .natural,
                structureMode: .natural,
                fillerPolicy: .balanced,
                commandPolicy: .passthrough
            ),
            lexicon: .init(entries: [])
        )
    )

    #expect(pipelineOutput.runtime.identity == identity)
    #expect(pipelineOutput.whisperConfiguration == whisperConfiguration)
}
