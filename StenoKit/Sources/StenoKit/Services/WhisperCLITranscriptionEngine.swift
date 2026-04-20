import Foundation

public enum WhisperCLITranscriptionError: Error, LocalizedError {
    case cliNotFound(path: String)
    case failedToRun(status: Int32, stderr: String)
    case outputMissing

    public var errorDescription: String? {
        switch self {
        case .cliNotFound(let path):
            return "whisper-cli not found at: \(path)"
        case .failedToRun(let status, let stderr):
            return "whisper-cli failed with status \(status): \(stderr)"
        case .outputMissing:
            return "whisper-cli completed but transcript output was missing"
        }
    }
}

public struct WhisperCLITranscriptionEngine: TranscriptionEngine, Sendable {
    private struct WhisperJSONOutput: Decodable {
        struct TranscriptionSegment: Decodable {
            struct Offsets: Decodable {
                var from: Int
                var to: Int
            }

            struct Token: Decodable {
                struct Offsets: Decodable {
                    var from: Int
                    var to: Int
                }

                var text: String
                var p: Double?
                var offsets: Offsets?
            }

            var offsets: Offsets?
            var text: String
            var tokens: [Token]?
        }

        var transcription: [TranscriptionSegment]
    }

    public struct Configuration: Sendable {
        public var whisperCLIPath: URL
        public var modelPath: URL
        public var additionalArguments: [String]

        public init(
            whisperCLIPath: URL,
            modelPath: URL,
            additionalArguments: [String] = []
        ) {
            self.whisperCLIPath = whisperCLIPath
            self.modelPath = modelPath
            self.additionalArguments = additionalArguments
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

        let result = try await ProcessRunner.run(
            executableURL: config.whisperCLIPath,
            arguments: args,
            environment: cachedEnvironment,
            standardOutput: FileHandle.nullDevice
        )

        let stderrText = String(data: result.standardError, encoding: .utf8) ?? ""

        guard result.terminationStatus == 0 else {
            throw WhisperCLITranscriptionError.failedToRun(status: result.terminationStatus, stderr: stderrText)
        }

        if FileManager.default.fileExists(atPath: jsonURL.path),
           let richTranscript = try parseRichTranscript(at: jsonURL) {
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

    private func parseRichTranscript(at jsonURL: URL) throws -> RawTranscript? {
        let decoder = JSONDecoder()
        guard let output = try? decoder.decode(WhisperJSONOutput.self, from: Data(contentsOf: jsonURL)) else {
            return nil
        }

        var segments: [TranscriptSegment] = []
        var transcriptParts: [String] = []
        var tokenConfidences: [Double] = []

        for item in output.transcription {
            let segmentText = Self.stripArtifacts(item.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let segmentConfidence = averageConfidence(for: item.tokens)
            tokenConfidences.append(contentsOf: item.tokens?.compactMap(\.p) ?? [])

            let startMS = item.offsets?.from ?? 0
            let endMS = item.offsets?.to ?? startMS

            if !segmentText.isEmpty {
                transcriptParts.append(segmentText)
                segments.append(
                    TranscriptSegment(
                        startMS: startMS,
                        endMS: endMS,
                        text: segmentText,
                        confidence: segmentConfidence
                    )
                )
            }
        }

        let text = transcriptParts.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMS = segments.map(\.endMS).max() ?? 0
        let avgConfidence = tokenConfidences.isEmpty
            ? nil
            : tokenConfidences.reduce(0, +) / Double(tokenConfidences.count)

        return RawTranscript(
            text: text,
            segments: segments,
            avgConfidence: avgConfidence,
            durationMS: durationMS
        )
    }

    private func averageConfidence(for tokens: [WhisperJSONOutput.TranscriptionSegment.Token]?) -> Double? {
        guard let tokens else { return nil }
        let confidences = tokens.compactMap(\.p)
        guard confidences.isEmpty == false else { return nil }
        return confidences.reduce(0, +) / Double(confidences.count)
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
