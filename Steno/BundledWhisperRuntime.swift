import Foundation
import StenoKit

enum BundledWhisperRuntime {
    struct ResolvedPaths: Sendable, Equatable {
        let whisperCLIPath: String
        let modelPath: String
        let vadModelPath: String?
    }

    private static let bundledHelpersRelativePath = "Helpers/whisper-cli"
    private static let bundledModelsRelativePath = "WhisperModels"

    static func resolvedPaths(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> ResolvedPaths? {
        guard let whisperCLI = helperPath(bundle: bundle, fileManager: fileManager),
              let modelPath = WhisperModelCatalog.bundledSearchOrder
                .compactMap({ modelPath(for: $0, bundle: bundle, fileManager: fileManager) })
                .first,
              let resourceURL = bundle.resourceURL else {
            return nil
        }

        let modelsDir = resourceURL.appendingPathComponent(bundledModelsRelativePath, isDirectory: true)
        let vadPath = modelsDir.appendingPathComponent("ggml-silero-v6.2.0.bin").path
        return ResolvedPaths(
            whisperCLIPath: whisperCLI,
            modelPath: modelPath,
            vadModelPath: fileManager.fileExists(atPath: vadPath) ? vadPath : nil
        )
    }

    static func helperPath(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> String? {
        guard let resourceURL = bundle.resourceURL else {
            return nil
        }
        let contentsURL = resourceURL.deletingLastPathComponent()
        let whisperCLI = contentsURL.appendingPathComponent(bundledHelpersRelativePath).path
        return fileManager.fileExists(atPath: whisperCLI) ? whisperCLI : nil
    }

    static func modelPath(
        for modelID: WhisperModelID,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> String? {
        guard let resourceURL = bundle.resourceURL else {
            return nil
        }
        let modelsDir = resourceURL.appendingPathComponent(bundledModelsRelativePath, isDirectory: true)
        let path = modelsDir.appendingPathComponent(WhisperModelCatalog.fileName(for: modelID)).path
        return fileManager.fileExists(atPath: path) ? path : nil
    }
}
