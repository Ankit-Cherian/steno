import Foundation
import OSLog

actor AppPreferencesStore {
    private let storageURL: URL
    private static let logger = Logger(subsystem: "io.stenoapp.steno", category: "AppPreferencesStore")

    init(storageURL: URL = AppPreferencesStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    func load() -> AppPreferences {
        Self.migrateIfNeeded()
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return .default
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            var prefs = try decoder.decode(AppPreferences.self, from: data)
            prefs.normalize()
            return prefs
        } catch {
            Self.logger.error(
                "Preferences load failed for path \(self.storageURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .default
        }
    }

    func save(_ preferences: AppPreferences) {
        var normalized = preferences
        normalized.normalize()

        do {
            let dir = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(normalized)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Self.logger.error(
                "Preferences save failed for path \(self.storageURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func defaultStorageURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    private static func migrateIfNeeded() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldDir = appSupport.appendingPathComponent("WhisperClone", isDirectory: true)
        let newDir = appSupport.appendingPathComponent("Steno", isDirectory: true)

        if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
            do {
                try fm.copyItem(at: oldDir, to: newDir)
            } catch {
                logger.error(
                    "Preferences migration copy failed from \(oldDir.path, privacy: .public) to \(newDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
