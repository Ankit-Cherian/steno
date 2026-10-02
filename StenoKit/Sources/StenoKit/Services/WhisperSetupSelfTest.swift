import Foundation

/// One step of the Speech model setup check, reported in order.
public struct WhisperSetupCheckStage: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case passed
        case failed
        case skipped
    }

    public let title: String
    public let outcome: Outcome
    public let detail: String

    public init(title: String, outcome: Outcome, detail: String) {
        self.title = title
        self.outcome = outcome
        self.detail = detail
    }
}

/// A short, real transcription through separately created engines. It never
/// uses the warm runtime, a dictation session, History, or Insights.
public enum WhisperSetupSelfTest {
    public struct Inputs: Sendable {
        public var microphoneAllowed: Bool
        public var modelPath: String
        public var vadEnabled: Bool
        public var vadModelPath: String
        /// The retained helper with its fallback disabled, or nil when the tool path has no helper.
        public var mainEngine: (any TranscriptionEngine)?
        public var toolEngine: any TranscriptionEngine
        public var stageTimeout: Duration

        public init(
            microphoneAllowed: Bool,
            modelPath: String,
            vadEnabled: Bool,
            vadModelPath: String,
            mainEngine: (any TranscriptionEngine)?,
            toolEngine: any TranscriptionEngine,
            stageTimeout: Duration = .seconds(150)
        ) {
            self.microphoneAllowed = microphoneAllowed
            self.modelPath = modelPath
            self.vadEnabled = vadEnabled
            self.vadModelPath = vadModelPath
            self.mainEngine = mainEngine
            self.toolEngine = toolEngine
            self.stageTimeout = stageTimeout
        }
    }

    /// Thrown by the main engine's stand-in fallback, so a helper failure is
    /// reported instead of being hidden by the tool.
    public struct FallbackDisabled: Error, Sendable {}

    /// Stands in for the main engine's fallback during the check.
    public struct RefusingFallbackEngine: TranscriptionEngine {
        public init() {}
        public func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
            throw FallbackDisabled()
        }
    }

    public static func run(
        _ inputs: Inputs,
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) async -> [WhisperSetupCheckStage] {
        var stages: [WhisperSetupCheckStage] = []
        stages.append(.init(
            title: "Microphone access",
            outcome: inputs.microphoneAllowed ? .passed : .failed,
            detail: inputs.microphoneAllowed ? "Allowed." : "Not allowed. Turn it on in Settings > Permissions."
        ))

        guard fileExists(inputs.modelPath) else {
            stages.append(.init(title: "Speech model", outcome: .failed, detail: "The model file wasn't found."))
            stages.append(.init(title: "Main engine", outcome: .skipped, detail: "Needs the model file."))
            stages.append(.init(title: "Fallback tool", outcome: .skipped, detail: "Needs the model file."))
            return stages
        }
        let modelName = (inputs.modelPath as NSString).lastPathComponent
        if inputs.vadEnabled, !fileExists(inputs.vadModelPath) {
            stages.append(.init(
                title: "Speech model",
                outcome: .passed,
                detail: "\(modelName) found. The voice-detection model wasn't found, so the check runs without it."
            ))
        } else {
            stages.append(.init(title: "Speech model", outcome: .passed, detail: "\(modelName) found."))
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoSetupCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipURL = directory.appendingPathComponent("setup-check.wav")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeTestClip(to: clipURL)
        } catch {
            stages.append(.init(title: "Main engine", outcome: .skipped, detail: "Couldn't create the test clip."))
            stages.append(.init(title: "Fallback tool", outcome: .skipped, detail: "Couldn't create the test clip."))
            return stages
        }

        if let mainEngine = inputs.mainEngine {
            stages.append(await transcribeStage(
                title: "Main engine",
                engine: mainEngine,
                clipURL: clipURL,
                timeout: inputs.stageTimeout
            ))
            await mainEngine.shutdown()
        } else {
            stages.append(.init(
                title: "Main engine",
                outcome: .skipped,
                detail: "This tool path has no retained engine, so dictation uses the tool directly."
            ))
        }

        stages.append(await transcribeStage(
            title: "Fallback tool",
            engine: inputs.toolEngine,
            clipURL: clipURL,
            timeout: inputs.stageTimeout
        ))
        await inputs.toolEngine.shutdown()
        return stages
    }

    private static func transcribeStage(
        title: String,
        engine: any TranscriptionEngine,
        clipURL: URL,
        timeout: Duration
    ) async -> WhisperSetupCheckStage {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await withStageTimeout(timeout) {
                try await engine.transcribe(audioURL: clipURL, request: TranscriptionRequest(languageHints: ["en"]))
            }
            let elapsed = started.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return .init(
                title: title,
                outcome: .passed,
                detail: String(format: "Loaded the model and transcribed a test clip in %.1f s.", seconds)
            )
        } catch is StageTimedOut {
            return .init(title: title, outcome: .failed, detail: "Didn't finish the test clip in time.")
        } catch is FallbackDisabled {
            return .init(title: title, outcome: .failed, detail: "Couldn't start or transcribe. Dictation would fall back to the tool.")
        } catch {
            return .init(title: title, outcome: .failed, detail: error.localizedDescription)
        }
    }

    private struct StageTimedOut: Error {}

    private static func withStageTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw StageTimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw StageTimedOut() }
            return first
        }
    }

    /// Writes one second of quiet 16 kHz mono 16-bit audio. It contains no
    /// speech, so the check proves the engine runs without needing a voice.
    public static func writeTestClip(to url: URL, durationSeconds: Double = 1.0) throws {
        let sampleRate = 16_000
        let sampleCount = Int(Double(sampleRate) * durationSeconds)
        var samples = Data(capacity: sampleCount * 2)
        var seed: UInt32 = 0x5EED
        for _ in 0..<sampleCount {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let value = Int16(truncatingIfNeeded: Int32(seed >> 16) % 33 - 16)
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }

        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count))
        try (header + samples).write(to: url, options: .atomic)
    }
}
