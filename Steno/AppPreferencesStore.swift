import Foundation
import OSLog

actor AppPreferencesStore {
    private let storageURL: URL
    private let migratesLegacyStorage: Bool
    private var hasPreparedStorageDirectory = false
    private static let logger = Logger(subsystem: "io.stenoapp.steno", category: "AppPreferencesStore")

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.migratesLegacyStorage = storageURL == nil
    }

    func load() -> AppPreferences {
        if migratesLegacyStorage { Self.migrateIfNeeded() }
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
                "Preferences load failed for path \(self.storageURL.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return .default
        }
    }

    func save(_ preferences: AppPreferences) {
        var normalized = preferences
        normalized.normalize()

        do {
            try ensureStorageDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(normalized)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Self.logger.error(
                "Preferences save failed for path \(self.storageURL.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func ensureStorageDirectoryExists() throws {
        guard !hasPreparedStorageDirectory else { return }
        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hasPreparedStorageDirectory = true
    }

    private static func defaultStorageURL() -> URL {
        let appSupport: URL
        if let resolved = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupport = resolved
        } else {
            appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            logger.fault(
                "Application Support directory lookup failed. Falling back to \(appSupport.path, privacy: .private)."
            )
        }
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
                    "Preferences migration copy failed from \(oldDir.path, privacy: .private) to \(newDir.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
