import Foundation

public enum WhisperRuntimeConfiguration {
    public static func defaultVADModelPath(relativeTo modelPath: String) -> String {
        let modelsDir = (modelPath as NSString).deletingLastPathComponent
        return (modelsDir as NSString).appendingPathComponent("ggml-silero-v6.2.0.bin")
    }

    public static func syncedVADModelPath(
        currentVADModelPath: String,
        previousModelPath: String,
        newModelPath: String
    ) -> String {
        let previousDefault = defaultVADModelPath(relativeTo: previousModelPath)
        guard currentVADModelPath.isEmpty || currentVADModelPath == previousDefault else {
            return currentVADModelPath
        }
        return defaultVADModelPath(relativeTo: newModelPath)
    }

    public static func additionalArguments(
        threadCount: Int,
        vadEnabled: Bool,
        vadModelPath: String,
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        var args = ["-t", "\(max(1, threadCount))", "--suppress-nst"]

        if vadEnabled && pathExists(vadModelPath) {
            args.append(contentsOf: ["--vad", "--vad-model", vadModelPath])
        }

        return args
    }
}
