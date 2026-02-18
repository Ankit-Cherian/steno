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

    public init(config: Configuration) {
        self.config = config
    }

    public func transcribe(audioURL: URL, languageHints: [String]) async throws -> RawTranscript {
        guard FileManager.default.fileExists(atPath: config.whisperCLIPath.path) else {
            throw WhisperCLITranscriptionError.cliNotFound(path: config.whisperCLIPath.path)
        }

        let outputBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-out-\(UUID().uuidString)")

        let txtURL = URL(fileURLWithPath: outputBase.path + ".txt")
        defer { try? FileManager.default.removeItem(at: txtURL) }

        var args: [String] = [
            "-m", config.modelPath.path,
            "-f", audioURL.path,
            "-of", outputBase.path,
            "-otxt",
            "-nt"
        ]

        if let firstHint = languageHints.first,
           let languageCode = normalizeLanguage(from: firstHint) {
            args.append(contentsOf: ["-l", languageCode])
        }

        args.append(contentsOf: config.additionalArguments)

        let result = try await ProcessRunner.run(
            executableURL: config.whisperCLIPath,
            arguments: args,
            environment: processEnvironment(),
            standardOutput: FileHandle.nullDevice
        )

        let stderrText = String(data: result.standardError, encoding: .utf8) ?? ""

        guard result.terminationStatus == 0 else {
            throw WhisperCLITranscriptionError.failedToRun(status: result.terminationStatus, stderr: stderrText)
        }

        guard FileManager.default.fileExists(atPath: txtURL.path) else {
            throw WhisperCLITranscriptionError.outputMissing
        }

        let text = try String(contentsOf: txtURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return RawTranscript(text: text)
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

    private func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        let libSearchPaths = dynamicLibrarySearchPaths()
        guard !libSearchPaths.isEmpty else {
            return env
        }

        let existingDYLD = env["DYLD_LIBRARY_PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let mergedDYLD = orderedUnique(libSearchPaths + existingDYLD)
        env["DYLD_LIBRARY_PATH"] = mergedDYLD.joined(separator: ":")

        let existingFallback = env["DYLD_FALLBACK_LIBRARY_PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let mergedFallback = orderedUnique(libSearchPaths + existingFallback)
        env["DYLD_FALLBACK_LIBRARY_PATH"] = mergedFallback.joined(separator: ":")

        return env
    }

    private func dynamicLibrarySearchPaths() -> [String] {
        let fileManager = FileManager.default
        let binDir = config.whisperCLIPath.deletingLastPathComponent()
        let buildDir = binDir.deletingLastPathComponent()

        let candidates = [
            buildDir.appendingPathComponent("src", isDirectory: true).path,
            buildDir.appendingPathComponent("ggml/src", isDirectory: true).path,
            buildDir.appendingPathComponent("ggml/src/ggml-blas", isDirectory: true).path,
            buildDir.appendingPathComponent("ggml/src/ggml-metal", isDirectory: true).path
        ]

        return orderedUnique(candidates.filter { fileManager.fileExists(atPath: $0) })
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        output.reserveCapacity(values.count)

        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            output.append(value)
        }
        return output
    }
}
