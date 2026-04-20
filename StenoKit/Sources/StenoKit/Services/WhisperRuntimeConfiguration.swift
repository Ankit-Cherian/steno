import Foundation

public enum WhisperRuntimeConfiguration {
    public static func defaultVADModelPath(relativeTo modelPath: String) -> String {
        let modelsDir = (modelPath as NSString).deletingLastPathComponent
        return (modelsDir as NSString).appendingPathComponent("ggml-silero-v6.2.0.bin")
    }

    public static func processEnvironment(
        whisperCLIPath: String,
        modelPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: String] {
        var env = environment

        if env["STENO_DISABLE_DYLD_ENV"] == "1" {
            return env
        }

        let libSearchPaths = dynamicLibrarySearchPaths(
            whisperCLIPath: whisperCLIPath,
            modelPath: modelPath,
            fileExists: fileExists
        )
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
        prompt: String? = nil,
        suppressRegex: String? = nil,
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        var args = ["-t", "\(max(1, threadCount))", "--suppress-nst"]

        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--prompt", prompt])
        }

        if let suppressRegex, !suppressRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--suppress-regex", suppressRegex])
        }

        if vadEnabled && pathExists(vadModelPath) {
            args.append(contentsOf: ["--vad", "--vad-model", vadModelPath])
        }

        return args
    }

    public static func buildPrompt(
        for request: TranscriptionRequest,
        maxHotTerms: Int = 8
    ) -> String? {
        let prompt = promptFragments(for: request, maxHotTerms: maxHotTerms).joined(separator: " ")
        return prompt.isEmpty ? nil : prompt
    }

    public static func promptFragments(
        for request: TranscriptionRequest,
        maxHotTerms: Int = 8
    ) -> [String] {
        var parts: [String] = []

        if let firstHint = request.languageHints.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstHint.isEmpty {
            let language = firstHint.lowercased().split(separator: "-").first.map(String.init) ?? firstHint.lowercased()
            parts.append("Language: \(language).")
        }

        if let appName = request.appContext?.appName.trimmingCharacters(in: .whitespacesAndNewlines),
           !appName.isEmpty {
            parts.append("App: \(appName).")
        }

        let hotTerms = Array(request.hotTerms.prefix(maxHotTerms))
        if !hotTerms.isEmpty {
            parts.append("Terms: \(hotTerms.joined(separator: ", ")).")
        }

        return parts
    }

    private static func dynamicLibrarySearchPaths(
        whisperCLIPath: String,
        modelPath: String,
        fileExists: (String) -> Bool
    ) -> [String] {
        let binDir = URL(fileURLWithPath: whisperCLIPath).deletingLastPathComponent()
        let buildDir = binDir.deletingLastPathComponent()

        let candidates = [
            buildDir.appendingPathComponent("src", isDirectory: true).path,
            buildDir.appendingPathComponent("ggml/src", isDirectory: true).path,
            buildDir.appendingPathComponent("ggml/src/ggml-blas", isDirectory: true).path,
            buildDir.appendingPathComponent("ggml/src/ggml-metal", isDirectory: true).path
        ]

        let modelDir = URL(fileURLWithPath: modelPath).deletingLastPathComponent().path
        let combined = candidates + [modelDir]
        return orderedUnique(combined.filter(fileExists))
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
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
