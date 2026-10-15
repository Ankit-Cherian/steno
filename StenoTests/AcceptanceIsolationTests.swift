import Foundation
import Testing
@testable import Steno
import StenoKit

/// The acceptance configuration keeps every file Steno writes inside one folder
/// of its own. `AcceptanceConfiguration` compiles into this test bundle with its
/// flag, so these tests need no acceptance app to run.
@Suite("Acceptance isolation")
struct AcceptanceIsolationTests {
    @Test("A build without the acceptance flag resolves the released app's folders and may register at login")
    func releaseLaunchConfigurationIsUnchanged() throws {
        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let configuration = LaunchConfiguration.resolve(bundle: .main)

        #expect(configuration.managesLaunchAtLogin)
        #expect(configuration.storage == StenoStorageRoot.release())
        #expect(configuration.storage.preferencesURL.path == appSupport.path + "/Steno/preferences.json")
        #expect(configuration.storage.historyURL.path == appSupport.path + "/Steno/transcript-history.json")
        #expect(configuration.storage.usageAnalyticsURL.path == appSupport.path + "/Steno/usage-analytics.json")
        #expect(configuration.storage.modelsDirectory?.path == appSupport.path + "/Steno/WhisperModels")
        #expect(configuration.storage.legacyHistoryURL.path == appSupport.path + "/WhisperClone/transcript-history.json")
        #expect(configuration.storage.temporaryDirectory == FileManager.default.temporaryDirectory)
        #expect(configuration.storage.legacyMigration != nil)
        #expect(AppPreferencesStore(storageURL: nil).storageURL == configuration.storage.preferencesURL)
        #expect(AppPreferencesStore(root: configuration.storage).storageURL == configuration.storage.preferencesURL)
    }

    @Test("The acceptance root sits in its own folder and shares nothing with the released app")
    func acceptanceRootIsSeparate() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let applicationSupport = sandbox.appendingPathComponent("Application Support", isDirectory: true)
        let root = AcceptanceConfiguration.storageRoot(applicationSupportDirectory: applicationSupport)
        let folder = applicationSupport.appendingPathComponent("Steno Acceptance", isDirectory: true).path

        #expect(AcceptanceConfiguration.bundleIdentifier == "io.stenoapp.steno.acceptance")
        #expect(!AcceptanceConfiguration.managesLaunchAtLogin)
        let urls = [
            root.dataDirectory, root.temporaryDirectory, root.legacyDataDirectory, root.legacyHistoryURL,
            root.preferencesURL, root.historyURL, root.usageAnalyticsURL, try #require(root.modelsDirectory),
        ]
        for url in urls {
            #expect(url.path == folder || url.path.hasPrefix(folder + "/"), "\(url.path)")
        }
        #expect(root.legacyMigration == nil)
        #expect(FileManager.default.fileExists(atPath: root.temporaryDirectory.path))
        let release = StenoStorageRoot.release()
        #expect(root.preferencesURL != release.preferencesURL)
        #expect(root.dataDirectory != release.dataDirectory)
    }

    @MainActor
    @Test("A controller built on the acceptance root keeps every store and temporary folder inside it")
    func controllerStaysInsideTheAcceptanceRoot() async throws {
        let realBefore = RealStorageSnapshot.take()
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let applicationSupport = sandbox.appendingPathComponent("Application Support", isDirectory: true)
        let root = AcceptanceConfiguration.storageRoot(applicationSupportDirectory: applicationSupport)
        let folder = root.dataDirectory.path

        let controller = DictationController(
            hotkey: TranscriptionCancelHotkey(),
            clipboardService: MemoryClipboardService(),
            overlay: WaveformOverlayPresenter(observeAccessibilityChanges: false),
            mediaInterruption: IsolatedTestMediaService(),
            runtimeRebuildOverride: { nil },
            systemIntegrationsEnabled: false,
            appContextProvider: { AppContext(bundleIdentifier: "com.example.steno-test-editor", appName: "Test Editor") },
            targetDisplayPointProvider: { CGPoint(x: 400, y: 300) },
            launchConfiguration: LaunchConfiguration(storage: root, managesLaunchAtLogin: AcceptanceConfiguration.managesLaunchAtLogin)
        )

        let locations = await controller.storageLocationsForTesting()
        #expect(locations.preferences == root.preferencesURL)
        #expect(locations.history == root.historyURL)
        #expect(locations.usageAnalytics == root.usageAnalyticsURL)
        #expect(locations.legacyHistory == root.legacyHistoryURL)
        #expect(locations.recordings == root.temporaryDirectory)
        #expect(locations.transcriptOutput == root.temporaryDirectory)
        #expect(locations.models == root.modelsDirectory)

        // Settings and Insights write through the stores the controller built.
        controller.preferences.general.showDockIcon = false
        controller.savePreferences()
        await controller.refreshUsageAnalytics()
        let saved = await eventually { FileManager.default.fileExists(atPath: root.preferencesURL.path) }
        #expect(saved)

        // A model found in the root's folder is the one the controller offers.
        let modelsDirectory = try #require(root.modelsDirectory)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let modelFile = modelsDirectory.appendingPathComponent(WhisperModelCatalog.fileName(for: .mediumEn))
        try Data("model".utf8).write(to: modelFile)
        let medium = try #require(controller.whisperModelOptions.first { $0.modelID == .mediumEn })
        #expect(medium.source == .downloaded)
        #expect(medium.path == modelFile.path)

        await controller.teardownAndWait()

        // Nothing exists in the sandbox outside the acceptance folder.
        let relativeFolder = "Application Support/Steno Acceptance"
        let outside = try FileManager.default.subpathsOfDirectory(atPath: sandbox.path).filter {
            !relativeFolder.hasPrefix($0) && !$0.hasPrefix(relativeFolder)
        }
        #expect(outside.isEmpty, "\(outside)")
        #expect(folder.hasPrefix(sandbox.path) || folder.hasPrefix("/private" + sandbox.path))

        // And this Mac's real Steno folders, listed by name and date only, did not change.
        let realAfter = RealStorageSnapshot.take()
        #expect(realBefore == realAfter, "\(realBefore.difference(from: realAfter))")
    }

    // MARK: - Support

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoAcceptanceIsolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        await eventuallyOnMain { condition() }
    }
}

/// Names and modification dates of the released app's Application Support
/// folders. Contents are never read. This differs only if something else, such
/// as a Steno running on this Mac, changes those folders during the test.
private struct RealStorageSnapshot: Equatable {
    var lines: [String]

    static func take() -> RealStorageSnapshot {
        let fileManager = FileManager.default
        var lines: [String] = []
        func list(_ root: URL) {
            guard let names = try? fileManager.subpathsOfDirectory(atPath: root.path) else { return }
            for name in names.sorted() {
                let attributes = try? fileManager.attributesOfItem(atPath: root.appendingPathComponent(name).path)
                let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                lines.append("\(root.lastPathComponent)/\(name) \(modified)")
            }
        }
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            for folder in ["Steno", "WhisperClone", "Steno Acceptance"] {
                list(appSupport.appendingPathComponent(folder, isDirectory: true))
            }
        }
        return RealStorageSnapshot(lines: lines)
    }

    func difference(from other: RealStorageSnapshot) -> [String] {
        Array(Set(lines).symmetricDifference(other.lines)).sorted()
    }
}
