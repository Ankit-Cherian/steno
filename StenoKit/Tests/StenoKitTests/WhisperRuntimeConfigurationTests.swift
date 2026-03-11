import Testing
@testable import StenoKit

@Test("defaultVADModelPath uses the Whisper model directory")
func defaultVADModelPathUsesModelDirectory() {
    let modelPath = "/tmp/custom-models/ggml-small.en.bin"
    #expect(
        WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: modelPath)
            == "/tmp/custom-models/ggml-silero-v6.2.0.bin"
    )
}

@Test("syncedVADModelPath follows model path when current VAD path is the derived default")
func syncedVADModelPathUpdatesDerivedDefault() {
    let previousModelPath = "/tmp/old-models/ggml-small.en.bin"
    let newModelPath = "/tmp/new-models/ggml-small.en.bin"
    let currentVADModelPath = WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: previousModelPath)

    #expect(
        WhisperRuntimeConfiguration.syncedVADModelPath(
            currentVADModelPath: currentVADModelPath,
            previousModelPath: previousModelPath,
            newModelPath: newModelPath
        ) == "/tmp/new-models/ggml-silero-v6.2.0.bin"
    )
}

@Test("syncedVADModelPath follows model path when current VAD path is empty")
func syncedVADModelPathUpdatesEmptyPath() {
    #expect(
        WhisperRuntimeConfiguration.syncedVADModelPath(
            currentVADModelPath: "",
            previousModelPath: "/tmp/old-models/ggml-small.en.bin",
            newModelPath: "/tmp/new-models/ggml-small.en.bin"
        ) == "/tmp/new-models/ggml-silero-v6.2.0.bin"
    )
}

@Test("syncedVADModelPath preserves custom VAD paths")
func syncedVADModelPathPreservesCustomPath() {
    #expect(
        WhisperRuntimeConfiguration.syncedVADModelPath(
            currentVADModelPath: "/opt/vad/custom-vad.bin",
            previousModelPath: "/tmp/old-models/ggml-small.en.bin",
            newModelPath: "/tmp/new-models/ggml-small.en.bin"
        ) == "/opt/vad/custom-vad.bin"
    )
}

@Test("additionalArguments always include thread count and suppress-nst")
func additionalArgumentsAlwaysIncludeSuppressNST() {
    let args = WhisperRuntimeConfiguration.additionalArguments(
        threadCount: 4,
        vadEnabled: false,
        vadModelPath: "/tmp/missing-vad.bin",
        pathExists: { _ in false }
    )

    #expect(args == ["-t", "4", "--suppress-nst"])
}

@Test("additionalArguments include VAD flags when enabled and model exists")
func additionalArgumentsIncludeVADFlags() {
    let args = WhisperRuntimeConfiguration.additionalArguments(
        threadCount: 6,
        vadEnabled: true,
        vadModelPath: "/tmp/vad.bin",
        pathExists: { path in path == "/tmp/vad.bin" }
    )

    #expect(args == ["-t", "6", "--suppress-nst", "--vad", "--vad-model", "/tmp/vad.bin"])
}

@Test("additionalArguments omit VAD flags when model is missing")
func additionalArgumentsOmitMissingVADFlags() {
    let args = WhisperRuntimeConfiguration.additionalArguments(
        threadCount: 6,
        vadEnabled: true,
        vadModelPath: "/tmp/missing-vad.bin",
        pathExists: { _ in false }
    )

    #expect(args == ["-t", "6", "--suppress-nst"])
}

@Test("processEnvironment adds local whisper library search paths")
func processEnvironmentAddsLocalWhisperLibraryPaths() {
    let cliPath = "/tmp/whisper.cpp/build/bin/whisper-cli"
    let modelPath = "/tmp/whisper.cpp/models/ggml-small.en.bin"
    let existing = [
        "DYLD_LIBRARY_PATH": "/already/present",
        "DYLD_FALLBACK_LIBRARY_PATH": "/fallback/present"
    ]
    let existingPaths: Set<String> = [
        "/tmp/whisper.cpp/build/src",
        "/tmp/whisper.cpp/build/ggml/src",
        "/tmp/whisper.cpp/build/ggml/src/ggml-blas",
        "/tmp/whisper.cpp/build/ggml/src/ggml-metal",
        "/tmp/whisper.cpp/models"
    ]

    let env = WhisperRuntimeConfiguration.processEnvironment(
        whisperCLIPath: cliPath,
        modelPath: modelPath,
        environment: existing,
        fileExists: { existingPaths.contains($0) }
    )

    #expect(env["DYLD_LIBRARY_PATH"]?.contains("/tmp/whisper.cpp/build/src") == true)
    #expect(env["DYLD_LIBRARY_PATH"]?.contains("/already/present") == true)
    #expect(env["DYLD_FALLBACK_LIBRARY_PATH"]?.contains("/tmp/whisper.cpp/models") == true)
    #expect(env["DYLD_FALLBACK_LIBRARY_PATH"]?.contains("/fallback/present") == true)
}
