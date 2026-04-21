import Foundation
import StenoKit

struct WhisperModelOption: Identifiable, Equatable {
    enum Source: String, Equatable {
        case bundled
        case downloaded
        case customPath
    }

    let modelID: WhisperModelID
    let source: Source?
    let path: String?
    let isInstalled: Bool
    let isActive: Bool
    let isRecommended: Bool

    var id: WhisperModelID { modelID }
    var title: String { WhisperModelCatalog.title(for: modelID) }
    var summary: String { WhisperModelCatalog.summary(for: modelID) }
}

enum WhisperModelDownloadError: LocalizedError {
    case invalidResponse
    case unexpectedStatusCode(Int)
    case missingDownloadedFile
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The model server returned an invalid response."
        case .unexpectedStatusCode(let code):
            return "The model download failed with HTTP status \(code)."
        case .missingDownloadedFile:
            return "The downloaded model file could not be saved."
        case .applicationSupportUnavailable:
            return "Application Support is unavailable on this Mac."
        }
    }
}

struct WhisperModelInstallResult: Sendable, Equatable {
    let modelPath: String
    let vadModelPath: String?
}

enum WhisperModelLibrary {
    static let managedModelIDs: [WhisperModelID] = [.smallEn, .mediumEn, .largeV3Turbo]

    static func modelsDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw WhisperModelDownloadError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("WhisperModels", isDirectory: true)
    }

    static func installedOptions(
        preferences: AppPreferences,
        compatibilityService: WhisperCompatibilityService? = try? WhisperCompatibilityService.bundled(),
        fileManager: FileManager = .default
    ) -> [WhisperModelOption] {
        let activeModelID = WhisperCompatibilityService.canonicalModelID(forModelPath: preferences.dictation.modelPath)
        let hardwareProfile = WhisperCompatibilityService.currentHardwareProfile()
        let recommendedModelID = hardwareProfile.flatMap { compatibilityService?.recommendation(for: $0)?.modelID }

        return managedModelIDs.map { modelID in
            let installed = installedModelLocation(for: modelID, preferences: preferences, fileManager: fileManager)
            return WhisperModelOption(
                modelID: modelID,
                source: installed?.source,
                path: installed?.path,
                isInstalled: installed != nil,
                isActive: activeModelID == modelID,
                isRecommended: recommendedModelID == modelID
            )
        }
    }

    static func installedModelLocation(
        for modelID: WhisperModelID,
        preferences: AppPreferences,
        fileManager: FileManager = .default
    ) -> (source: WhisperModelOption.Source, path: String)? {
        if let downloadedPath = downloadedModelPath(for: modelID, fileManager: fileManager),
           fileManager.fileExists(atPath: downloadedPath) {
            return (.downloaded, downloadedPath)
        }

        if let bundledPath = bundledModelPath(for: modelID, fileManager: fileManager),
           fileManager.fileExists(atPath: bundledPath) {
            return (.bundled, bundledPath)
        }

        if WhisperCompatibilityService.canonicalModelID(forModelPath: preferences.dictation.modelPath) == modelID,
           fileManager.fileExists(atPath: preferences.dictation.modelPath) {
            return (.customPath, preferences.dictation.modelPath)
        }

        return nil
    }

    static func downloadedModelPath(
        for modelID: WhisperModelID,
        fileManager: FileManager = .default
    ) -> String? {
        guard let modelsDirectory = try? modelsDirectory(fileManager: fileManager) else {
            return nil
        }
        return modelsDirectory.appendingPathComponent(WhisperModelCatalog.fileName(for: modelID)).path
    }

    static func bundledModelPath(
        for modelID: WhisperModelID,
        fileManager: FileManager = .default
    ) -> String? {
        BundledWhisperRuntime.modelPath(for: modelID, fileManager: fileManager)
    }
}

actor WhisperModelDownloadService {
    func install(
        modelID: WhisperModelID,
        vadSourcePath: String?,
        fileManager: FileManager = .default
    ) async throws -> WhisperModelInstallResult {
        let modelsDirectory = try WhisperModelLibrary.modelsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let destinationURL = modelsDirectory.appendingPathComponent(WhisperModelCatalog.fileName(for: modelID))
        let (temporaryURL, response) = try await URLSession.shared.download(from: WhisperModelCatalog.downloadURL(for: modelID))

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperModelDownloadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WhisperModelDownloadError.unexpectedStatusCode(httpResponse.statusCode)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)

        guard fileManager.fileExists(atPath: destinationURL.path) else {
            throw WhisperModelDownloadError.missingDownloadedFile
        }

        let vadDestinationURL = modelsDirectory.appendingPathComponent("ggml-silero-v6.2.0.bin")
        if let vadSourcePath, fileManager.fileExists(atPath: vadSourcePath), !fileManager.fileExists(atPath: vadDestinationURL.path) {
            try fileManager.copyItem(atPath: vadSourcePath, toPath: vadDestinationURL.path)
        }

        let savedVADPath = fileManager.fileExists(atPath: vadDestinationURL.path) ? vadDestinationURL.path : nil
        return WhisperModelInstallResult(modelPath: destinationURL.path, vadModelPath: savedVADPath)
    }
}
