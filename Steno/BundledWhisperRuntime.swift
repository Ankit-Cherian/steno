import Foundation

enum BundledWhisperRuntime {
    struct ResolvedPaths: Sendable, Equatable {
        let whisperCLIPath: String
        let modelPath: String
        let vadModelPath: String?
    }

    private static let bundledHelpersRelativePath = "Helpers/whisper-cli"
    private static let bundledModelsRelativePath = "WhisperModels"
    private static let canonicalModelFilenames = [
        "ggml-small.en.bin",
        "ggml-base.en.bin",
        "ggml-medium.en.bin",
        "ggml-large-v3-turbo.bin"
    ]

    static func resolvedPaths(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> ResolvedPaths? {
        guard let resourceURL = bundle.resourceURL else {
            return nil
        }

        let contentsURL = resourceURL.deletingLastPathComponent()
        let whisperCLI = contentsURL.appendingPathComponent(bundledHelpersRelativePath).path
        guard fileManager.fileExists(atPath: whisperCLI) else {
            return nil
        }

        let modelsDir = resourceURL.appendingPathComponent(bundledModelsRelativePath, isDirectory: true)
        guard let modelPath = canonicalModelFilenames
            .map({ modelsDir.appendingPathComponent($0).path })
            .first(where: fileManager.fileExists(atPath:))
        else {
            return nil
        }

        let vadPath = modelsDir.appendingPathComponent("ggml-silero-v6.2.0.bin").path
        return ResolvedPaths(
            whisperCLIPath: whisperCLI,
            modelPath: modelPath,
            vadModelPath: fileManager.fileExists(atPath: vadPath) ? vadPath : nil
        )
    }
}
