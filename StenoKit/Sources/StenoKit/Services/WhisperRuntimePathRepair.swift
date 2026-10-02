import Foundation

public struct WhisperRuntimePathSelection: Equatable, Sendable {
    public var whisperCLIPath: String
    public var modelPath: String
    public var vadModelPath: String

    public init(
        whisperCLIPath: String,
        modelPath: String,
        vadModelPath: String
    ) {
        self.whisperCLIPath = whisperCLIPath
        self.modelPath = modelPath
        self.vadModelPath = vadModelPath
    }
}

public struct WhisperRuntimePathCandidates: Equatable, Sendable {
    public var whisperCLIPath: String
    public var modelPath: String
    public var vadModelPath: String?

    public init(
        whisperCLIPath: String,
        modelPath: String,
        vadModelPath: String?
    ) {
        self.whisperCLIPath = whisperCLIPath
        self.modelPath = modelPath
        self.vadModelPath = vadModelPath
    }
}

public enum WhisperRuntimePathRepair {
    /// Repairs the tool path and the model path independently, so a stale tool
    /// path never discards a model that still exists. A derived or stale bundled
    /// voice-detection path is recomputed when needed; a custom one is kept.
    public static func repairedSelection(
        current: WhisperRuntimePathSelection,
        bundled: WhisperRuntimePathCandidates?,
        vendor: WhisperRuntimePathCandidates?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> WhisperRuntimePathSelection {
        let cliExists = fileExists(current.whisperCLIPath)
        let modelExists = fileExists(current.modelPath)
        guard !cliExists || !modelExists else {
            return current
        }

        let sources = [bundled, vendor].compactMap { $0 }
        var repaired = current

        if !cliExists,
           let source = sources.first(where: { fileExists($0.whisperCLIPath) }) {
            repaired.whisperCLIPath = source.whisperCLIPath
        }

        var modelSource: WhisperRuntimePathCandidates?
        if !modelExists,
           let source = sources.first(where: { fileExists($0.modelPath) }) {
            repaired.modelPath = source.modelPath
            modelSource = source
        }

        if vadModelPathNeedsRepair(current: current, repairedModelPath: repaired.modelPath, fileExists: fileExists) {
            let candidates = [
                WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: repaired.modelPath),
                modelSource?.vadModelPath
            ] + sources.map(\.vadModelPath)
            repaired.vadModelPath = candidates.compactMap { $0 }.first(where: fileExists)
                ?? WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: repaired.modelPath)
        }

        return repaired
    }

    private static func vadModelPathNeedsRepair(
        current: WhisperRuntimePathSelection,
        repairedModelPath: String,
        fileExists: (String) -> Bool
    ) -> Bool {
        let vadPath = current.vadModelPath
        let isDerived = vadPath.isEmpty
            || vadPath == WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: current.modelPath)
        if isDerived {
            return repairedModelPath != current.modelPath || !fileExists(vadPath)
        }
        // A path inside the app bundle the stale tool path pointed into is the
        // app's own file, left behind when the app moved, not a user's choice.
        guard !fileExists(vadPath),
              !fileExists(current.whisperCLIPath),
              let staleBundle = appBundlePath(containing: current.whisperCLIPath)
        else {
            return false
        }
        return vadPath.hasPrefix(staleBundle + "/")
    }

    private static func appBundlePath(containing path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
