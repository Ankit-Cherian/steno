import Foundation

/// Every location Steno keeps its own files in, resolved once at launch and
/// handed to each store, so a copy of the app can be pointed at a different
/// folder as a whole.
///
/// `release()` resolves the folders the released app has always used, with the
/// same fallbacks. Nothing else in this type decides where files go.
public struct StenoStorageRoot: Sendable, Equatable {
    /// Holds preferences, History, the Insights ledger and recovery copies.
    public let dataDirectory: URL
    /// Holds temporary capture recordings and transcript output files.
    public let temporaryDirectory: URL
    /// The folder an earlier app name used. Read for old History, and copied
    /// to `dataDirectory` once when `migratesLegacyDirectory` is true.
    public let legacyDataDirectory: URL
    public let migratesLegacyDirectory: Bool
    /// Where downloaded speech models live, or nil when the system could not
    /// say where Application Support is.
    public let modelsDirectory: URL?

    public init(
        dataDirectory: URL,
        temporaryDirectory: URL,
        legacyDataDirectory: URL,
        migratesLegacyDirectory: Bool,
        modelsDirectory: URL?
    ) {
        self.dataDirectory = dataDirectory
        self.temporaryDirectory = temporaryDirectory
        self.legacyDataDirectory = legacyDataDirectory
        self.migratesLegacyDirectory = migratesLegacyDirectory
        self.modelsDirectory = modelsDirectory
    }

    public var preferencesURL: URL {
        dataDirectory.appendingPathComponent("preferences.json")
    }

    public var historyURL: URL {
        dataDirectory.appendingPathComponent("transcript-history.json")
    }

    public var usageAnalyticsURL: URL {
        dataDirectory.appendingPathComponent("usage-analytics.json")
    }

    public var legacyHistoryURL: URL {
        legacyDataDirectory.appendingPathComponent("transcript-history.json")
    }

    /// The one-time copy of the earlier app folder, or nil when none applies.
    public var legacyMigration: (source: URL, destination: URL)? {
        migratesLegacyDirectory ? (legacyDataDirectory, dataDirectory) : nil
    }

    /// The folders the released app uses.
    public static func release(fileManager: FileManager = .default) -> StenoStorageRoot {
        let resolved = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let appSupport: URL
        if let resolved {
            appSupport = resolved
        } else {
            appSupport = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            StenoKitDiagnostics.logger.fault(
                "Application Support directory lookup failed; using the conventional fallback directory."
            )
        }
        let dataDirectory = appSupport.appendingPathComponent("Steno", isDirectory: true)
        return StenoStorageRoot(
            dataDirectory: dataDirectory,
            temporaryDirectory: fileManager.temporaryDirectory,
            legacyDataDirectory: appSupport.appendingPathComponent("WhisperClone", isDirectory: true),
            migratesLegacyDirectory: resolved != nil,
            modelsDirectory: resolved == nil
                ? nil
                : dataDirectory.appendingPathComponent("WhisperModels", isDirectory: true)
        )
    }
}
