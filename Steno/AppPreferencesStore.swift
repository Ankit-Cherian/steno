import Foundation
import OSLog
import StenoKit

enum AppPreferencesStoreError: Error, LocalizedError, Equatable {
    case writeFailed
    case originalNotPreserved

    var errorDescription: String? {
        switch self {
        case .writeFailed:
            return "Steno couldn't write the settings file. Your changes weren't saved."
        case .originalNotPreserved:
            return "Steno couldn't keep a copy of the existing settings file, so it left the file unchanged. Your changes weren't saved."
        }
    }
}

/// Stores preferences in one JSON file. Only a missing file counts as empty.
/// A file that can't be read is moved aside before it is replaced, and a file
/// that is only partly readable is kept as a copy.
actor AppPreferencesStore {
    private let storageURL: URL
    private let migratesLegacyStorage: Bool
    private var hasPreparedStorageDirectory = false
    /// The file present at load couldn't be read; it must not be overwritten in place.
    private var loadFailed = false
    /// Original bytes of a partly readable file that still need a kept copy.
    private var unpreservedOriginal: (data: Data, issues: DecodingIssueLog)?
    private var pendingNotices: [StorageRecoveryNotice] = []
    private var noticeHandler: (@Sendable (StorageRecoveryNotice) -> Void)?
    private static let logger = Logger(subsystem: "io.stenoapp.steno", category: "AppPreferencesStore")

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.migratesLegacyStorage = storageURL == nil
    }

    func load() -> AppPreferences {
        if migratesLegacyStorage { Self.migrateIfNeeded() }
        loadFailed = false
        unpreservedOriginal = nil
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return .default
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let issues = DecodingIssueLog()
            let decoder = JSONDecoder.recordingIssues(to: issues)
            var prefs = try decoder.decode(AppPreferences.self, from: data)
            prefs.normalize()
            if !issues.isEmpty {
                unpreservedOriginal = (data, issues)
                // A failure here is retried before the next save.
                try? preserveOriginal()
            }
            return prefs
        } catch {
            Self.logger.error(
                "Preferences load failed for path \(self.storageURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            loadFailed = true
            report(StorageRecoveryNotice(
                message: "Steno couldn't read your settings file, so it's using default settings. The file hasn't been changed.",
                fileURL: storageURL
            ))
            return .default
        }
    }

    /// Writes `preferences`, keeping the previous file as a single backup copy.
    /// Fails without touching the file when an unreadable original can't be kept.
    @discardableResult
    func save(_ preferences: AppPreferences) -> Result<Void, AppPreferencesStoreError> {
        var normalized = preferences
        normalized.normalize()

        do {
            if loadFailed, FileManager.default.fileExists(atPath: storageURL.path) {
                let movedURL = try StorageFilePreservation.moveAside(storageURL, label: "unreadable")
                report(StorageRecoveryNotice(
                    message: "Steno couldn't read your earlier settings file, so it kept it as “\(movedURL.lastPathComponent)” and saved your new settings.",
                    fileURL: movedURL
                ))
            }
            loadFailed = false
            try preserveOriginal()
        } catch {
            Self.logger.error(
                "Preferences original could not be preserved for path \(self.storageURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return .failure(.originalNotPreserved)
        }

        do {
            try ensureStorageDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(normalized)
            if FileManager.default.fileExists(atPath: storageURL.path) {
                do {
                    try StorageFilePreservation.keepPreviousCopy(of: storageURL)
                } catch {
                    Self.logger.error("Preferences previous-copy update failed.")
                }
            }
            try data.write(to: storageURL, options: .atomic)
            return .success(())
        } catch {
            Self.logger.error(
                "Preferences save failed for path \(self.storageURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return .failure(.writeFailed)
        }
    }

    /// Returns recovery notices not yet delivered to a handler, once each.
    func takeRecoveryNotices() -> [StorageRecoveryNotice] {
        defer { pendingNotices = [] }
        return pendingNotices
    }

    /// Delivers pending and future recovery notices to `handler`.
    func setRecoveryNoticeHandler(_ handler: @escaping @Sendable (StorageRecoveryNotice) -> Void) {
        noticeHandler = handler
        for notice in takeRecoveryNotices() {
            handler(notice)
        }
    }

    private func preserveOriginal() throws {
        guard let original = unpreservedOriginal else { return }
        let copyURL = try StorageFilePreservation.preserveCopy(
            of: storageURL,
            data: original.data,
            label: "original"
        )
        unpreservedOriginal = nil
        let skipped = original.issues.skippedCount
        let message = skipped > 0
            ? "\(skipped) saved \(skipped == 1 ? "item" : "items") in your settings, such as a word correction or text shortcut, couldn't be read and \(skipped == 1 ? "was" : "were") left out. Steno kept a copy of the original settings file."
            : "Some settings couldn't be read, so Steno used defaults for them. Steno kept a copy of the original settings file."
        report(StorageRecoveryNotice(message: message, fileURL: copyURL))
    }

    private func report(_ notice: StorageRecoveryNotice) {
        if let noticeHandler {
            noticeHandler(notice)
        } else {
            pendingNotices.append(notice)
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
                    "Preferences migration copy failed from \(oldDir.path, privacy: .private) to \(newDir.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }
}
