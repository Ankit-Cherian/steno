import Testing
@testable import StenoKit

@Suite("Whisper runtime path repair")
struct WhisperRuntimePathRepairTests {
    private let bundled = WhisperRuntimePathCandidates(
        whisperCLIPath: "/Applications/Steno.app/Contents/Helpers/whisper-cli",
        modelPath: "/Applications/Steno.app/Contents/Resources/WhisperModels/ggml-small.en.bin",
        vadModelPath: "/Applications/Steno.app/Contents/Resources/WhisperModels/ggml-silero-v6.2.0.bin"
    )
    private let downloadedMedium = "/Users/u/Library/Application Support/Steno/WhisperModels/ggml-medium.en.bin"
    private let downloadedVAD = "/Users/u/Library/Application Support/Steno/WhisperModels/ggml-silero-v6.2.0.bin"
    private let translocatedBundle = "/private/var/folders/xx/AppTranslocation/ABC/d/Steno.app"

    private var bundledPaths: Set<String> {
        [bundled.whisperCLIPath, bundled.modelPath, bundled.vadModelPath!]
    }

    @Test("A stale tool path from a moved app keeps a downloaded model and its voice-detection model")
    func staleCLIKeepsDownloadedModel() {
        let current = WhisperRuntimePathSelection(
            whisperCLIPath: "\(translocatedBundle)/Contents/Helpers/whisper-cli",
            modelPath: downloadedMedium,
            vadModelPath: downloadedVAD
        )
        let existing = bundledPaths.union([downloadedMedium, downloadedVAD])

        let repaired = WhisperRuntimePathRepair.repairedSelection(
            current: current,
            bundled: bundled,
            vendor: nil,
            fileExists: existing.contains
        )

        #expect(repaired.whisperCLIPath == bundled.whisperCLIPath)
        #expect(repaired.modelPath == downloadedMedium)
        #expect(repaired.vadModelPath == downloadedVAD)
    }

    @Test("A voice-detection path left inside the old app location is repaired with the tool path")
    func staleBundledVADIsRepairedAlongsideCLI() {
        let current = WhisperRuntimePathSelection(
            whisperCLIPath: "\(translocatedBundle)/Contents/Helpers/whisper-cli",
            modelPath: downloadedMedium,
            vadModelPath: "\(translocatedBundle)/Contents/Resources/WhisperModels/ggml-silero-v6.2.0.bin"
        )
        let existing = bundledPaths.union([downloadedMedium])

        let repaired = WhisperRuntimePathRepair.repairedSelection(
            current: current,
            bundled: bundled,
            vendor: nil,
            fileExists: existing.contains
        )

        #expect(repaired.whisperCLIPath == bundled.whisperCLIPath)
        #expect(repaired.modelPath == downloadedMedium)
        #expect(repaired.vadModelPath == bundled.vadModelPath)
    }

    @Test("A missing model is replaced without touching a working tool path")
    func missingModelKeepsWorkingCLI() {
        let customCLI = "/opt/whisper/bin/whisper-cli"
        let current = WhisperRuntimePathSelection(
            whisperCLIPath: customCLI,
            modelPath: downloadedMedium,
            vadModelPath: downloadedVAD
        )
        let existing = bundledPaths.union([customCLI])

        let repaired = WhisperRuntimePathRepair.repairedSelection(
            current: current,
            bundled: bundled,
            vendor: nil,
            fileExists: existing.contains
        )

        #expect(repaired.whisperCLIPath == customCLI)
        #expect(repaired.modelPath == bundled.modelPath)
        #expect(repaired.vadModelPath == bundled.vadModelPath, "a derived path follows the replacement model")
    }

    @Test("A custom voice-detection path is never replaced by repair")
    func customVADSurvivesRepair() {
        let customVAD = "/Volumes/Models/silero-custom.bin"
        let current = WhisperRuntimePathSelection(
            whisperCLIPath: "\(translocatedBundle)/Contents/Helpers/whisper-cli",
            modelPath: "\(translocatedBundle)/Contents/Resources/WhisperModels/ggml-small.en.bin",
            vadModelPath: customVAD
        )

        let repaired = WhisperRuntimePathRepair.repairedSelection(
            current: current,
            bundled: bundled,
            vendor: nil,
            fileExists: bundledPaths.contains
        )

        #expect(repaired.whisperCLIPath == bundled.whisperCLIPath)
        #expect(repaired.modelPath == bundled.modelPath)
        #expect(repaired.vadModelPath == customVAD)
    }

    @Test("A development runtime repairs only the missing tool path")
    func vendorRepairKeepsExistingModel() {
        let vendor = WhisperRuntimePathCandidates(
            whisperCLIPath: "/src/vendor/whisper.cpp/build/bin/whisper-cli",
            modelPath: "/src/vendor/whisper.cpp/models/ggml-small.en.bin",
            vadModelPath: "/src/vendor/whisper.cpp/models/ggml-silero-v6.2.0.bin"
        )
        let current = WhisperRuntimePathSelection(
            whisperCLIPath: "/old/build/bin/whisper-cli",
            modelPath: downloadedMedium,
            vadModelPath: downloadedVAD
        )
        let existing: Set<String> = [
            vendor.whisperCLIPath, vendor.modelPath, vendor.vadModelPath!, downloadedMedium, downloadedVAD
        ]

        let repaired = WhisperRuntimePathRepair.repairedSelection(
            current: current,
            bundled: nil,
            vendor: vendor,
            fileExists: existing.contains
        )

        #expect(repaired.whisperCLIPath == vendor.whisperCLIPath)
        #expect(repaired.modelPath == downloadedMedium)
        #expect(repaired.vadModelPath == downloadedVAD)
    }
}
