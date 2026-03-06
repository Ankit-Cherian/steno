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
