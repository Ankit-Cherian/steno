import Foundation
import Testing
@testable import StenoKit

private actor RecordingEngine: TranscriptionEngine {
    enum Behavior { case succeed, fail, hang }
    let behavior: Behavior
    private(set) var transcribedClips: [URL] = []
    private(set) var clipSizes: [Int] = []
    private(set) var shutdownCount = 0

    init(_ behavior: Behavior) { self.behavior = behavior }

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        transcribedClips.append(audioURL)
        clipSizes.append((try? Data(contentsOf: audioURL).count) ?? 0)
        switch behavior {
        case .succeed: return RawTranscript(text: "")
        case .fail: throw WhisperSetupSelfTest.FallbackDisabled()
        case .hang:
            try await Task.sleep(for: .seconds(60))
            return RawTranscript(text: "")
        }
    }

    func shutdown() async { shutdownCount += 1 }
}

@Suite("Speech model setup check")
struct WhisperSetupSelfTestTests {
    private func inputs(
        microphoneAllowed: Bool = true,
        main: (any TranscriptionEngine)?,
        tool: any TranscriptionEngine,
        timeout: Duration = .seconds(5)
    ) -> WhisperSetupSelfTest.Inputs {
        .init(
            microphoneAllowed: microphoneAllowed,
            modelPath: "/Models/ggml-small.en.bin",
            vadEnabled: true,
            vadModelPath: "/Models/ggml-silero-v6.2.0.bin",
            mainEngine: main,
            toolEngine: tool,
            stageTimeout: timeout
        )
    }

    @Test("Both engines transcribe a real clip and each stage is reported")
    func bothEnginesPass() async {
        let main = RecordingEngine(.succeed)
        let tool = RecordingEngine(.succeed)

        let stages = await WhisperSetupSelfTest.run(inputs(main: main, tool: tool), fileExists: { _ in true })

        #expect(stages.map(\.title) == ["Microphone access", "Speech model", "Main engine", "Fallback tool"])
        #expect(stages.allSatisfy { $0.outcome == .passed })
        #expect(await main.transcribedClips.count == 1)
        #expect(await main.clipSizes == [44 + 32_000], "one second of 16 kHz 16-bit mono audio")
        #expect(await tool.transcribedClips.count == 1)
        #expect(await main.shutdownCount == 1)
        #expect(await tool.shutdownCount == 1)
        let clip = await main.transcribedClips[0]
        #expect(!FileManager.default.fileExists(atPath: clip.path), "the clip is removed afterwards")
    }

    @Test("A main engine that fails is reported even though the tool works")
    func mainEngineFailureIsNotHidden() async {
        let stages = await WhisperSetupSelfTest.run(
            inputs(main: RecordingEngine(.fail), tool: RecordingEngine(.succeed)),
            fileExists: { _ in true }
        )
        #expect(stages[2].outcome == .failed)
        #expect(stages[2].detail.contains("fall back"))
        #expect(stages[3].outcome == .passed)
    }

    @Test("A missing model stops before any engine runs")
    func missingModelSkipsEngines() async {
        let main = RecordingEngine(.succeed)
        let stages = await WhisperSetupSelfTest.run(
            inputs(microphoneAllowed: false, main: main, tool: RecordingEngine(.succeed)),
            fileExists: { _ in false }
        )
        #expect(stages.map(\.outcome) == [.failed, .failed, .skipped, .skipped])
        #expect(await main.transcribedClips.isEmpty)
    }

    @Test("A stage that doesn't finish in time fails instead of waiting forever")
    func stageTimesOut() async {
        let stages = await WhisperSetupSelfTest.run(
            inputs(main: nil, tool: RecordingEngine(.hang), timeout: .milliseconds(200)),
            fileExists: { _ in true }
        )
        #expect(stages[2].outcome == .skipped)
        #expect(stages[3].outcome == .failed)
        #expect(stages[3].detail == "Didn't finish the test clip in time.")
    }

    @Test("The shipped engines load the model and transcribe the test clip",
          .enabled(if: VendorRuntime.available))
    func realEnginesTranscribeClip() async {
        let model = URL(fileURLWithPath: VendorRuntime.modelPath)
        let main = RetainedWhisperTranscriptionEngine(
            configuration: RetainedWhisperTranscriptionConfiguration(
                helperExecutableURL: URL(fileURLWithPath: VendorRuntime.helperPath),
                modelPath: model,
                threadCount: 4,
                vadModelPath: URL(fileURLWithPath: VendorRuntime.vadPath),
                suppressNonSpeechTokens: true,
                suppressRegex: nil,
                beamSize: 5,
                bestOf: 5
            ),
            fallback: WhisperSetupSelfTest.RefusingFallbackEngine()
        )
        let tool = WhisperCLITranscriptionEngine(config: .init(
            whisperCLIPath: URL(fileURLWithPath: VendorRuntime.cliPath),
            modelPath: model,
            additionalArguments: WhisperRuntimeConfiguration.additionalArguments(
                threadCount: 4,
                vadEnabled: true,
                vadModelPath: VendorRuntime.vadPath
            )
        ))

        let stages = await WhisperSetupSelfTest.run(.init(
            microphoneAllowed: true,
            modelPath: VendorRuntime.modelPath,
            vadEnabled: true,
            vadModelPath: VendorRuntime.vadPath,
            mainEngine: main,
            toolEngine: tool
        ))

        #expect(stages.map(\.outcome) == [.passed, .passed, .passed, .passed], "\(stages)")
    }
}

private enum VendorRuntime {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("vendor/whisper.cpp").path
    static let helperPath = "\(root)/build-steno/bin/steno-whisper-runtime"
    static let cliPath = "\(root)/build-steno/bin/whisper-cli"
    static let modelPath = "\(root)/models/ggml-small.en.bin"
    static let vadPath = "\(root)/models/ggml-silero-v6.2.0.bin"
    static var available: Bool {
        [helperPath, cliPath, modelPath, vadPath].allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }
}
