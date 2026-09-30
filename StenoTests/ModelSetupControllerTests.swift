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
    let preferencesURL: URL
    let modelBytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
    private(set) var controller: DictationController!

    init(body: Data? = nil, statusCode: Int = 200, failure: Error? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoModelSetupTests-\(UUID().uuidString)", isDirectory: true)
        modelsDirectory = directory.appendingPathComponent("WhisperModels", isDirectory: true)
        bundledDirectory = directory.appendingPathComponent("Bundle/WhisperModels", isDirectory: true)
        preferencesURL = directory.appendingPathComponent("preferences.json")
        try FileManager.default.createDirectory(at: bundledDirectory, withIntermediateDirectories: true)
        try Data("bundled small".utf8).write(to: bundledDirectory.appendingPathComponent("ggml-small.en.bin"))
        try Data("bundled vad".utf8).write(to: bundledDirectory.appendingPathComponent("ggml-silero-v6.2.0.bin"))

        let served = body ?? modelBytes
        let expectedDigest = SHA256.hash(data: modelBytes).map { String(format: "%02x", $0) }.joined()
        let expected = WhisperModelFileExpectation(byteCount: Int64(modelBytes.count), sha256: expectedDigest)
        let modelsDirectory = modelsDirectory
        let bundledDirectory = bundledDirectory
        let scratch = directory
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
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".tmp") }
    }

    func setDirectoryWritable(_ writable: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: directory.path)
    }

    func tearDown() {
        controller.teardown()
        setDirectoryWritable(true)
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
}
