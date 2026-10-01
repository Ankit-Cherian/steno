import CryptoKit
import Foundation
import Testing
@testable import Steno
import StenoKit

/// Test-owned model folders and a scripted download server. Nothing here touches
/// the network or the user's Application Support folder.
@MainActor
final class ModelSetupFixture {
    let directory: URL
    let modelsDirectory: URL
    let bundledDirectory: URL
    let preferencesDirectory: URL
    let downloadsDirectory: URL
    let preferencesURL: URL
    let modelBytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
    private(set) var controller: DictationController!

    init(body: Data? = nil, statusCode: Int = 200, failure: Error? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoModelSetupTests-\(UUID().uuidString)", isDirectory: true)
        modelsDirectory = directory.appendingPathComponent("WhisperModels", isDirectory: true)
        bundledDirectory = directory.appendingPathComponent("Bundle/WhisperModels", isDirectory: true)
        preferencesDirectory = directory.appendingPathComponent("Preferences", isDirectory: true)
        downloadsDirectory = directory.appendingPathComponent("Downloads", isDirectory: true)
        preferencesURL = preferencesDirectory.appendingPathComponent("preferences.json")
        for folder in [bundledDirectory, modelsDirectory, preferencesDirectory, downloadsDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("bundled small".utf8).write(to: bundledDirectory.appendingPathComponent("ggml-small.en.bin"))
        try Data("bundled vad".utf8).write(to: bundledDirectory.appendingPathComponent("ggml-silero-v6.2.0.bin"))

        let served = body ?? modelBytes
        let expectedDigest = SHA256.hash(data: modelBytes).map { String(format: "%02x", $0) }.joined()
        let expected = WhisperModelFileExpectation(byteCount: Int64(modelBytes.count), sha256: expectedDigest)
        let modelsDirectory = modelsDirectory
        let bundledDirectory = bundledDirectory
        let scratch = downloadsDirectory
        let service = WhisperModelDownloadService(
            locations: WhisperModelLocations(
                modelsDirectory: { modelsDirectory },
                bundledModelPath: { modelID in
                    let path = bundledDirectory.appendingPathComponent(WhisperModelCatalog.fileName(for: modelID)).path
                    return FileManager.default.fileExists(atPath: path) ? path : nil
                }
            ),
            fetch: { url in
                if let failure { throw failure }
                let temporary = scratch.appendingPathComponent("download-\(UUID().uuidString).tmp")
                try served.write(to: temporary)
                let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (temporary, response)
            },
            expectedFile: { _ in expected }
        )

        let clipboard = MemoryClipboardService()
        controller = DictationController(
            hotkey: StorageRecoveryTestHotkeyService(),
            clipboardService: clipboard,
            overlay: WaveformOverlayPresenter(observeAccessibilityChanges: false),
            mediaInterruption: IsolatedTestMediaService(),
            preferencesStore: AppPreferencesStore(storageURL: preferencesURL),
            modelDownloadService: service,
            runtimeRebuildOverride: { nil },
            historyStore: HistoryStore(storageURL: directory.appendingPathComponent("history.json"), clipboardService: clipboard),
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false
        )
        var preferences = controller.preferences
        preferences.dictation.modelPath = bundledPath(.smallEn)
        preferences.dictation.vadModelPath = bundledDirectory.appendingPathComponent("ggml-silero-v6.2.0.bin").path
        controller.preferences = preferences
    }

    func bundledPath(_ modelID: WhisperModelID) -> String {
        bundledDirectory.appendingPathComponent(WhisperModelCatalog.fileName(for: modelID)).path
    }

    func downloadedPath(_ modelID: WhisperModelID) -> String {
        modelsDirectory.appendingPathComponent(WhisperModelCatalog.fileName(for: modelID)).path
    }

    func leftoverDownloads() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: downloadsDirectory.path)) ?? []
    }

    /// Makes the settings file unwritable while model folders stay writable.
    func setPreferencesWritable(_ writable: Bool) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555],
            ofItemAtPath: preferencesDirectory.path
        )
    }

    func placeDownloadedModel(_ modelID: WhisperModelID) throws {
        try modelBytes.write(to: URL(fileURLWithPath: downloadedPath(modelID)))
    }

    func tearDown() {
        controller.teardown()
        setPreferencesWritable(true)
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForDownloadToFinish() async -> Bool {
        await waitForModelSetupCondition { self.controller.activeModelDownloadID == nil }
    }
}

@MainActor
func waitForModelSetupCondition(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@MainActor
@Suite("Model download and activation")
struct ModelSetupControllerTests {
    @Test("A download whose content doesn't match is rejected, and the current model stays active")
    func mismatchedDownloadIsRejected() async throws {
        let fixture = try ModelSetupFixture(body: Data("<html><body>Access blocked by policy</body></html>".utf8))
        defer { fixture.tearDown() }
        let controller = fixture.controller!
        let before = controller.preferences

        controller.downloadWhisperModel(.mediumEn)
        #expect(await fixture.waitForDownloadToFinish())

        #expect(controller.preferences.dictation == before.dictation)
        #expect(!FileManager.default.fileExists(atPath: fixture.downloadedPath(.mediumEn)))
        #expect(fixture.leftoverDownloads().isEmpty, "the rejected download is deleted")
        #expect(controller.modelDownloadMessageIsError)
        #expect(controller.modelDownloadMessage.contains("didn't match the published file"))
        #expect(controller.modelDownloadMessage.contains("Your current model is still in use"))
        #expect(controller.whisperModelOptions.first { $0.modelID == .mediumEn }?.isInstalled == false)
    }

    @Test("A failed download says why next to the Download control")
    func failedDownloadExplainsWhy() async throws {
        let fixture = try ModelSetupFixture(failure: URLError(.notConnectedToInternet))
        defer { fixture.tearDown() }
        let controller = fixture.controller!

        controller.downloadWhisperModel(.largeV3Turbo)
        #expect(controller.modelDownloadMessageIsError == false)
        #expect(await fixture.waitForDownloadToFinish())

        #expect(controller.modelDownloadMessageIsError)
        #expect(controller.modelDownloadMessage.hasPrefix("Couldn't download Large V3 Turbo."))
        #expect(controller.modelDownloadMessage.contains(URLError(.notConnectedToInternet).localizedDescription))
    }

    @Test("An error status from the server is reported and leaves nothing behind")
    func httpErrorIsReported() async throws {
        let fixture = try ModelSetupFixture(statusCode: 429)
        defer { fixture.tearDown() }
        let controller = fixture.controller!

        controller.downloadWhisperModel(.mediumEn)
        #expect(await fixture.waitForDownloadToFinish())

        #expect(controller.modelDownloadMessageIsError)
        #expect(controller.modelDownloadMessage.contains("HTTP status 429"))
        #expect(fixture.leftoverDownloads().isEmpty)
    }

    @Test("A verified download is installed and becomes the active model")
    func verifiedDownloadIsInstalled() async throws {
        let fixture = try ModelSetupFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller!

        controller.downloadWhisperModel(.mediumEn)
        #expect(await fixture.waitForDownloadToFinish())

        #expect(!controller.modelDownloadMessageIsError)
        #expect(controller.preferences.dictation.modelPath == fixture.downloadedPath(.mediumEn))
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.downloadedPath(.mediumEn))) == fixture.modelBytes)
        #expect(controller.whisperModelOptions.first { $0.modelID == .mediumEn }?.isActive == true)
    }

    @Test("A download keeps a custom voice-detection model")
    func downloadKeepsCustomVAD() async throws {
        let fixture = try ModelSetupFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller!
        let customVAD = fixture.directory.appendingPathComponent("my-silero.bin").path
        try Data("custom vad".utf8).write(to: URL(fileURLWithPath: customVAD))
        controller.preferences.dictation.vadModelPath = customVAD

        controller.downloadWhisperModel(.mediumEn)
        #expect(await fixture.waitForDownloadToFinish())

        #expect(controller.preferences.dictation.modelPath == fixture.downloadedPath(.mediumEn))
        #expect(controller.preferences.dictation.vadModelPath == customVAD)
        #expect(await AppPreferencesStore(storageURL: fixture.preferencesURL).load().dictation.vadModelPath == customVAD)
    }

    @Test("A download moves a derived voice-detection path next to the new model")
    func downloadFollowsDerivedVAD() async throws {
        let fixture = try ModelSetupFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller!

        controller.downloadWhisperModel(.mediumEn)
        #expect(await fixture.waitForDownloadToFinish())

        let expectedVAD = fixture.modelsDirectory.appendingPathComponent("ggml-silero-v6.2.0.bin").path
        #expect(controller.preferences.dictation.vadModelPath == expectedVAD)
        #expect(FileManager.default.fileExists(atPath: expectedVAD))
    }

    @Test("A downloaded model whose switch can't be saved isn't announced as active")
    func downloadWithUnwritableSettings() async throws {
        let fixture = try ModelSetupFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller!
        let before = controller.preferences

        fixture.setPreferencesWritable(false)
        controller.downloadWhisperModel(.mediumEn)
        #expect(await fixture.waitForDownloadToFinish())
        #expect(await waitForModelSetupCondition { controller.modelDownloadMessageIsError })

        #expect(controller.preferences == before)
        #expect(controller.modelDownloadMessage.hasPrefix("Downloaded Medium, but couldn't switch to it."))
        #expect(controller.modelDownloadMessage.contains(AppPreferencesStoreError.writeFailed.localizedDescription))
        #expect(controller.status == "Settings couldn't be saved.")
        #expect(!controller.status.contains("switched to it"))
        #expect(FileManager.default.fileExists(atPath: fixture.downloadedPath(.mediumEn)), "the verified file stays for a later Use")
    }

    @Test("Choosing a model whose switch can't be saved keeps the current model and says so")
    func activationWithUnwritableSettings() async throws {
        let fixture = try ModelSetupFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller!
        try fixture.placeDownloadedModel(.mediumEn)
        let before = controller.preferences

        fixture.setPreferencesWritable(false)
        controller.activateWhisperModel(.mediumEn)
        #expect(await waitForModelSetupCondition { controller.modelDownloadMessageIsError })

        #expect(controller.preferences == before)
        #expect(controller.modelDownloadMessage.hasPrefix("Couldn't switch to Medium."))
        #expect(controller.status == "Settings couldn't be saved.")

        fixture.setPreferencesWritable(true)
        controller.activateWhisperModel(.mediumEn)
        #expect(await waitForModelSetupCondition { !controller.modelDownloadMessageIsError })
        #expect(controller.modelDownloadMessage == "Using Medium.")
        #expect(controller.preferences.dictation.modelPath == fixture.downloadedPath(.mediumEn))
        #expect(controller.lastError.isEmpty, "the earlier model error is cleared")
    }

    @Test("An appearance change that can't be saved is reported, never shown as saved")
    func appearanceWithUnwritableSettings() async throws {
        let fixture = try ModelSetupFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller!
        var appearance = controller.preferences.appearance
        appearance.accent = appearance.accent == .rose ? .citron : .rose

        fixture.setPreferencesWritable(false)
        controller.saveAppearance(appearance)
        #expect(await waitForModelSetupCondition { !controller.settingsSaveError.isEmpty })
        #expect(controller.status == "Appearance couldn't be saved.")
        #expect(controller.settingsSaveError == AppPreferencesStoreError.writeFailed.localizedDescription)

        fixture.setPreferencesWritable(true)
        controller.saveAppearance(appearance)
        #expect(await waitForModelSetupCondition { controller.settingsSaveError.isEmpty })
        #expect(controller.lastError.isEmpty)
        #expect(await AppPreferencesStore(storageURL: fixture.preferencesURL).load().appearance.accent == appearance.accent)
    }
}

@Suite("Settings draft after a model download")
struct SettingsDraftModelConflictTests {
    @Test("A download finishing during unsaved edits keeps Save locked and names the cause")
    func modelDownloadConflictIsNamed() {
        let saved = AppPreferences.default
        var draft = saved
        draft.snippets = [Snippet(trigger: "sig", expansion: "Best regards")]
        var state = SettingsDraftState(saved: saved)
        state.edit(draft)

        var downloaded = saved
        downloaded.dictation.updateModelPath("/Models/ggml-medium.en.bin")
        state.reconcile(downloaded)

        #expect(state.hasConflictingUpdate)
        #expect(state.conflictCause == .modelChange)
        #expect(state.preferences == draft)
    }

    @Test("Any other external change is reported as a general conflict")
    func otherConflictStaysGeneral() {
        let saved = AppPreferences.default
        var draft = saved
        draft.snippets = [Snippet(trigger: "sig", expansion: "Best regards")]
        var state = SettingsDraftState(saved: saved)
        state.edit(draft)

        var external = saved
        external.dictation.updateModelPath("/Models/ggml-medium.en.bin")
        external.media.pauseDuringHandsFree.toggle()
        state.reconcile(external)

        #expect(state.conflictCause == .externalChange)
    }
}

@MainActor
@Suite("Removing and downloading a model again")
struct ModelRemovalControllerTests {
    @Test("Removing the model in use switches to the included model first")
    func removingActiveModelSwitchesToBundled() async throws {
        let fixture = try ModelSetupFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller!
        controller.downloadWhisperModel(.mediumEn)
        #expect(await fixture.waitForDownloadToFinish())
        #expect(controller.preferences.dictation.modelPath == fixture.downloadedPath(.mediumEn))

        controller.removeDownloadedModel(.mediumEn)
        #expect(await waitForModelSetupCondition { controller.modelDownloadMessage.hasPrefix("Removed") })

        #expect(controller.modelDownloadMessage == "Removed Medium and switched to Small.")
        #expect(!FileManager.default.fileExists(atPath: fixture.downloadedPath(.mediumEn)))
        #expect(controller.preferences.dictation.modelPath == fixture.bundledPath(.smallEn))
        #expect(await AppPreferencesStore(storageURL: fixture.preferencesURL).load().dictation.modelPath == fixture.bundledPath(.smallEn))
        #expect(controller.whisperModelOptions.first { $0.modelID == .mediumEn }?.isInstalled == false)
    }

    @Test("Removing a model that isn't in use leaves the current model alone")
    func removingInactiveModel() async throws {
        let fixture = try ModelSetupFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller!
        try fixture.placeDownloadedModel(.largeV3Turbo)
        let before = controller.preferences

        controller.removeDownloadedModel(.largeV3Turbo)
        #expect(await waitForModelSetupCondition { controller.modelDownloadMessage == "Removed Large V3 Turbo." })

        #expect(controller.preferences == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.downloadedPath(.largeV3Turbo)))
    }

    @Test("Downloading again replaces a damaged downloaded file with a verified one")
    func downloadAgainReplacesDamagedFile() async throws {
        let fixture = try ModelSetupFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller!
        try Data("damaged".utf8).write(to: URL(fileURLWithPath: fixture.downloadedPath(.mediumEn)))

        controller.downloadWhisperModel(.mediumEn)
        #expect(await fixture.waitForDownloadToFinish())

        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.downloadedPath(.mediumEn))) == fixture.modelBytes)
        #expect(controller.preferences.dictation.modelPath == fixture.downloadedPath(.mediumEn))
    }

    @Test("A failed download again keeps the existing file in place")
    func failedDownloadAgainKeepsExistingFile() async throws {
        let fixture = try ModelSetupFixture(body: Data("<html>blocked</html>".utf8))
        defer { fixture.tearDown() }
        let controller = fixture.controller!
        try fixture.placeDownloadedModel(.mediumEn)

        controller.downloadWhisperModel(.mediumEn)
        #expect(await fixture.waitForDownloadToFinish())

        #expect(controller.modelDownloadMessageIsError)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.downloadedPath(.mediumEn))) == fixture.modelBytes)
    }
}
