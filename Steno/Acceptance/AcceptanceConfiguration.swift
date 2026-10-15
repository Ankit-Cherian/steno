#if STENO_ACCEPTANCE
import Foundation
import StenoKit

/// The isolated copy of the app used for live acceptance runs. Everything in
/// `Steno/Acceptance` compiles only into the Acceptance build configuration.
/// The released app has no code for it.
enum AcceptanceConfiguration {
    static let bundleIdentifier = "io.stenoapp.steno.acceptance"
    /// The folder inside Application Support that holds this copy's files.
    static let dataFolderName = "Steno Acceptance"
    /// The acceptance copy never registers itself as a login item.
    static let managesLaunchAtLogin = false

    /// The storage root of the acceptance copy. It stops the launch when the
    /// bundle is not the acceptance bundle, so a stray build of this
    /// configuration cannot use another copy's folder.
    static func storageRoot(bundle: Bundle, fileManager: FileManager = .default) -> StenoStorageRoot {
        precondition(
            bundle.bundleIdentifier == bundleIdentifier,
            "The acceptance configuration must run as \(bundleIdentifier)."
        )
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure("The acceptance copy needs Application Support to keep its files.")
        }
        return storageRoot(applicationSupportDirectory: applicationSupport, fileManager: fileManager)
    }

    /// Every location sits inside `<applicationSupportDirectory>/Steno Acceptance`.
    /// Temporary capture and transcript files go to its `Temporary` folder, which
    /// this creates, because recording needs the folder to exist.
    static func storageRoot(applicationSupportDirectory: URL, fileManager: FileManager = .default) -> StenoStorageRoot {
        let data = applicationSupportDirectory.appendingPathComponent(dataFolderName, isDirectory: true)
        let temporary = data.appendingPathComponent("Temporary", isDirectory: true)
        try? fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        return StenoStorageRoot(
            dataDirectory: data,
            temporaryDirectory: temporary,
            legacyDataDirectory: data.appendingPathComponent("NoEarlierHistory", isDirectory: true),
            migratesLegacyDirectory: false,
            modelsDirectory: data.appendingPathComponent("WhisperModels", isDirectory: true)
        )
    }
}
#endif
