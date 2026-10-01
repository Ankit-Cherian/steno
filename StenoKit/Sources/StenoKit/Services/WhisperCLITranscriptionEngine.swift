import Foundation

public enum WhisperCLITranscriptionError: Error, LocalizedError, Equatable {
    case cliNotFound(path: String)
    case failedToRun(status: Int32, stderr: String)
    case outputMissing
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .cliNotFound(let path):
            return "whisper-cli not found at: \(path)"
        case .failedToRun(let status, let stderr):
            return "whisper-cli failed with status \(status): \(stderr)"
        case .outputMissing:
            return "whisper-cli completed but transcript output was missing"
        case .timedOut:
            return "Transcription took too long and was stopped."
        }
    }
}

public struct WhisperCLITranscriptionEngine: TranscriptionEngine, Sendable {
    public struct Configuration: Sendable {
        public var whisperCLIPath: URL
        public var modelPath: URL
        public var additionalArguments: [String]
        /// The shortest time a run may take before it is stopped. Each run
        /// loads the model from scratch, so this covers the retained helper's
        /// model-load allowance as well as its minimum inference allowance.
        public var minimumTimeout: Duration

        public init(
            whisperCLIPath: URL,
            modelPath: URL,
            additionalArguments: [String] = [],
            minimumTimeout: Duration = .seconds(300)
        ) {
            self.whisperCLIPath = whisperCLIPath
            self.modelPath = modelPath
            self.additionalArguments = additionalArguments
            self.minimumTimeout = minimumTimeout
        }

        /// Longer recordings get the retained helper's allowance of twice
        /// their length plus a minute.
        func timeout(for audioURL: URL) -> Duration {
            WhisperRuntimeWatchdog.inferenceTimeout(minimum: minimumTimeout, audioURL: audioURL)
        }
    }

    private let config: Configuration
    /// Cached at init to avoid copying ProcessInfo.environment + stat() calls per transcription.
    private let cachedEnvironment: [String: String]

    public init(config: Configuration) {
        self.config = config
        self.cachedEnvironment = Self.buildProcessEnvironment(config: config)
    }

    public func transcribe(audioURL: URL, languageHints: [String]) async throws -> RawTranscript {
        try await transcribe(
            audioURL: audioURL,
            request: TranscriptionRequest(languageHints: languageHints)
        )
    }

    public func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        guard FileManager.default.fileExists(atPath: config.whisperCLIPath.path) else {
            throw WhisperCLITranscriptionError.cliNotFound(path: config.whisperCLIPath.path)
        }

        let outputBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-out-\(UUID().uuidString)")

        let txtURL = outputBase.appendingPathExtension("txt")
        let jsonURL = outputBase.appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: txtURL)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        var args: [String] = [
            "-m", config.modelPath.path,
            "-f", audioURL.path,
            "-of", outputBase.path,
            "-otxt",
            "-ojf",
            "-nt"
        ]

        if let firstHint = request.languageHints.first,
           let languageCode = normalizeLanguage(from: firstHint) {
            args.append(contentsOf: ["-l", languageCode])
        }

        args.append(contentsOf: config.additionalArguments)

        if config.additionalArguments.contains("--prompt") == false,
           let prompt = WhisperRuntimeConfiguration.buildPrompt(for: request) {
            args.append(contentsOf: ["--prompt", prompt])
        }

        let result: ProcessExecutionResult
        do {
            result = try await ProcessRunner.run(
                executableURL: config.whisperCLIPath,
                arguments: args,
                environment: cachedEnvironment,
                standardOutput: FileHandle.nullDevice,
                timeout: config.timeout(for: audioURL)
            )
        } catch ProcessRunnerError.timedOut {
            StenoKitDiagnostics.logger.error("whisper-cli ran past its deadline and was stopped.")
            throw WhisperCLITranscriptionError.timedOut
        }

        let stderrText = String(data: result.standardError, encoding: .utf8) ?? ""

        guard result.terminationStatus == 0 else {
            throw WhisperCLITranscriptionError.failedToRun(status: result.terminationStatus, stderr: stderrText)
        }

        if FileManager.default.fileExists(atPath: jsonURL.path),
           let richTranscript = WhisperTranscriptDecoder.decodeRichJSON(
               try Data(contentsOf: jsonURL)
           ) {
            return richTranscript
        }

        guard FileManager.default.fileExists(atPath: txtURL.path) else {
            throw WhisperCLITranscriptionError.outputMissing
        }

        return try parsePlainTranscript(at: txtURL)
    }

    private func normalizeLanguage(from hint: String) -> String? {
        let lower = hint.lowercased()
        if lower == "en-us" || lower == "en" {
            return "en"
        }

        if lower.contains("-") {
            return String(lower.split(separator: "-").first ?? "")
        }

        return lower.isEmpty ? nil : lower
    }

    private static func buildProcessEnvironment(config: Configuration) -> [String: String] {
        WhisperRuntimeConfiguration.processEnvironment(
            whisperCLIPath: config.whisperCLIPath.path,
            modelPath: config.modelPath.path
        )
    }

    private func parsePlainTranscript(at txtURL: URL) throws -> RawTranscript {
        let rawText = try String(contentsOf: txtURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let text = Self.stripArtifacts(rawText)

        return RawTranscript(text: text)
    }

    // MARK: - Artifact Stripping

    private static let artifactSet: Set<String> = [
        "music", "applause", "laughter", "noise", "silence", "inaudible",
        "background noise", "blank_audio", "blank audio", "audio is blank",
        "buzzing", "crowd", "cheering", "clapping", "sound effects"
    ]

    private static let bracketPattern = try! NSRegularExpression(pattern: #"\[([^\]]{1,40})\]"#)
    private static let parenPattern = try! NSRegularExpression(pattern: #"\(([^)]{1,40})\)"#)
    private static let multiSpacePattern = try! NSRegularExpression(pattern: #" {2,}"#)

    static func stripArtifacts(_ text: String) -> String {
        var result = text
        let fullRange = NSRange(result.startIndex..., in: result)

        // Remove bracketed artifacts like [Music], [BLANK_AUDIO]
        for match in bracketPattern.matches(in: result, range: fullRange).reversed() {
            guard let innerRange = Range(match.range(at: 1), in: result) else { continue }
            let inner = result[innerRange].trimmingCharacters(in: .whitespaces).lowercased()
            if artifactSet.contains(inner) {
                let outerRange = Range(match.range, in: result)!
                result.removeSubrange(outerRange)
            }
        }

        // Remove parenthetical artifacts like (buzzing), (Music)
        let updatedRange = NSRange(result.startIndex..., in: result)
        for match in parenPattern.matches(in: result, range: updatedRange).reversed() {
            guard let innerRange = Range(match.range(at: 1), in: result) else { continue }
            let inner = result[innerRange].trimmingCharacters(in: .whitespaces).lowercased()
            if artifactSet.contains(inner) {
                let outerRange = Range(match.range, in: result)!
                result.removeSubrange(outerRange)
            }
        }

        // Collapse multiple spaces and trim
        let collapsedRange = NSRange(result.startIndex..., in: result)
        result = multiSpacePattern.stringByReplacingMatches(in: result, range: collapsedRange, withTemplate: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
