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

@Test("path repair preserves custom CLI and model when only VAD is missing")
func pathRepairPreservesValidCustomRuntimeWithoutVAD() {
    let original = WhisperRuntimePathSelection(
        whisperCLIPath: "/custom/bin/whisper-cli",
        modelPath: "/custom/models/ggml-large-v3-turbo.bin",
        vadModelPath: "/custom/models/missing-vad.bin"
    )
    let bundled = WhisperRuntimePathCandidates(
        whisperCLIPath: "/bundle/Helpers/whisper-cli",
        modelPath: "/bundle/Models/ggml-small.en.bin",
        vadModelPath: "/bundle/Models/ggml-silero-v6.2.0.bin"
    )
    let existingPaths: Set<String> = [
        original.whisperCLIPath,
        original.modelPath,
        bundled.whisperCLIPath,
        bundled.modelPath,
        bundled.vadModelPath!
    ]

    let repaired = WhisperRuntimePathRepair.repairedSelection(
        current: original,
        bundled: bundled,
        vendor: nil,
        fileExists: existingPaths.contains
    )

    #expect(repaired.whisperCLIPath == original.whisperCLIPath)
    #expect(repaired.modelPath == original.modelPath)
    #expect(repaired.vadModelPath == original.vadModelPath)
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

@Test("additionalArguments include prompt and suppress regex when configured")
func additionalArgumentsIncludePromptAndSuppressRegex() {
    let args = WhisperRuntimeConfiguration.additionalArguments(
        threadCount: 6,
        vadEnabled: false,
        vadModelPath: "/tmp/missing-vad.bin",
        prompt: "Language: en. App: Cursor. Terms: TURSO, StenoKit.",
        suppressRegex: #"\[(?:MUSIC|NOISE)\]"#,
        pathExists: { _ in false }
    )

    #expect(
        args == [
            "-t", "6",
            "--suppress-nst",
            "--prompt", "Language: en. App: Cursor. Terms: TURSO, StenoKit.",
            "--suppress-regex", #"\[(?:MUSIC|NOISE)\]"#
        ]
    )
}

@Test("promptFragments omit app metadata when hot terms are present")
func promptFragmentsOmitAppMetadataWhenHotTermsPresent() {
    let fragments = WhisperRuntimeConfiguration.promptFragments(
        for: TranscriptionRequest(
            languageHints: ["en-US"],
            appContext: AppContext(
                bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                appName: "Cursor",
                isIDE: true
            ),
            hotTerms: ["TURSO", "StenoKit"]
        )
    )

    #expect(
        fragments == [
            "Language: en.",
            "Terms: TURSO, StenoKit."
        ]
    )
}

@Test("promptFragments keep app metadata when no hot terms are present")
func promptFragmentsKeepAppMetadataWithoutHotTerms() {
    let fragments = WhisperRuntimeConfiguration.promptFragments(
        for: TranscriptionRequest(
            languageHints: ["en-US"],
            appContext: AppContext(
                bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                appName: "Cursor",
                isIDE: true
            )
        )
    )

    #expect(
        fragments == [
            "Language: en.",
            "App: Cursor."
        ]
    )
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
