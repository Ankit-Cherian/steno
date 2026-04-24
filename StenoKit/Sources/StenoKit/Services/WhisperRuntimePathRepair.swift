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
    public static func repairedSelection(
        current: WhisperRuntimePathSelection,
        bundled: WhisperRuntimePathCandidates?,
        vendor: WhisperRuntimePathCandidates?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> WhisperRuntimePathSelection {
        guard !fileExists(current.whisperCLIPath) || !fileExists(current.modelPath) else {
            return current
        }

        if let bundled, fileExists(bundled.whisperCLIPath), fileExists(bundled.modelPath) {
            return .init(
                whisperCLIPath: bundled.whisperCLIPath,
                modelPath: bundled.modelPath,
                vadModelPath: repairedVADModelPath(
                    currentVADModelPath: current.vadModelPath,
                    candidateVADModelPath: bundled.vadModelPath,
                    repairedModelPath: bundled.modelPath,
                    fileExists: fileExists
                )
            )
        }

        guard let vendor else {
            return current
        }

        var repaired = current

        if fileExists(vendor.whisperCLIPath) {
            repaired.whisperCLIPath = vendor.whisperCLIPath
        }

        if fileExists(vendor.modelPath) {
            repaired.modelPath = vendor.modelPath
        }

        if !fileExists(repaired.vadModelPath) {
            repaired.vadModelPath = repairedVADModelPath(
                currentVADModelPath: current.vadModelPath,
                candidateVADModelPath: vendor.vadModelPath,
                repairedModelPath: repaired.modelPath,
                fileExists: fileExists
            )
        }

        return repaired
    }

    private static func repairedVADModelPath(
        currentVADModelPath: String,
        candidateVADModelPath: String?,
        repairedModelPath: String,
        fileExists: (String) -> Bool
    ) -> String {
        if fileExists(currentVADModelPath) {
            return currentVADModelPath
        }

        if let candidateVADModelPath, fileExists(candidateVADModelPath) {
            return candidateVADModelPath
        }

        return WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: repairedModelPath)
    }
}
