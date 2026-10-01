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

enum WhisperModelDownloadError: LocalizedError, Equatable {
    case invalidResponse
    case unexpectedStatusCode(Int)
    case missingDownloadedFile
    case applicationSupportUnavailable
    case verificationFailed(WhisperModelID)

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
        case .verificationFailed:
            return "The download didn't match the published file, so it wasn't installed. A network filter or proxy may have changed it."
        }
    }
}

/// Where downloaded and bundled models live. Tests supply their own folders.
struct WhisperModelLocations: Sendable {
    var modelsDirectory: @Sendable () throws -> URL
    var bundledModelPath: @Sendable (WhisperModelID) -> String?

    static let system = WhisperModelLocations(
        modelsDirectory: { try WhisperModelLibrary.modelsDirectory() },
        bundledModelPath: { BundledWhisperRuntime.modelPath(for: $0) }
    )
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
        locations: WhisperModelLocations = .system,
        fileManager: FileManager = .default
    ) -> [WhisperModelOption] {
        let activeModelID = WhisperCompatibilityService.canonicalModelID(forModelPath: preferences.dictation.modelPath)
        let hardwareProfile = WhisperCompatibilityService.currentHardwareProfile()
        let recommendedModelID = hardwareProfile.flatMap { compatibilityService?.recommendation(for: $0)?.modelID }

        return managedModelIDs.map { modelID in
            let installed = installedModelLocation(
                for: modelID,
                preferences: preferences,
                locations: locations,
                fileManager: fileManager
            )
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
        locations: WhisperModelLocations = .system,
        fileManager: FileManager = .default
    ) -> (source: WhisperModelOption.Source, path: String)? {
        if let downloadedPath = downloadedModelPath(for: modelID, locations: locations),
           fileManager.fileExists(atPath: downloadedPath) {
            return (.downloaded, downloadedPath)
        }

        if let bundledPath = locations.bundledModelPath(modelID),
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
        locations: WhisperModelLocations = .system
    ) -> String? {
        guard let modelsDirectory = try? locations.modelsDirectory() else {
            return nil
        }
        return modelsDirectory.appendingPathComponent(WhisperModelCatalog.fileName(for: modelID)).path
    }
}

actor WhisperModelDownloadService {
    typealias Fetch = @Sendable (URL) async throws -> (URL, URLResponse)

    nonisolated let locations: WhisperModelLocations
    private let fetch: Fetch
    private let expectedFile: @Sendable (WhisperModelID) -> WhisperModelFileExpectation

    init(
        locations: WhisperModelLocations = .system,
        fetch: @escaping Fetch = { try await URLSession.shared.download(from: $0) },
        expectedFile: @escaping @Sendable (WhisperModelID) -> WhisperModelFileExpectation = {
            WhisperModelCatalog.expectedFile(for: $0)
        }
    ) {
        self.locations = locations
        self.fetch = fetch
        self.expectedFile = expectedFile
    }

    /// Downloads, verifies, then moves the model into place. A download that
    /// fails verification is deleted and never replaces an existing file.
    func install(
        modelID: WhisperModelID,
        vadSourcePath: String?
    ) async throws -> WhisperModelInstallResult {
        let fileManager = FileManager.default
        let modelsDirectory = try locations.modelsDirectory()
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let destinationURL = modelsDirectory.appendingPathComponent(WhisperModelCatalog.fileName(for: modelID))
        let (temporaryURL, response) = try await fetch(WhisperModelCatalog.downloadURL(for: modelID))
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperModelDownloadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WhisperModelDownloadError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let expected = expectedFile(modelID)
        do {
            try await Self.verifyOffExecutor(fileAt: temporaryURL, expected: expected)
        } catch {
            throw WhisperModelDownloadError.verificationFailed(modelID)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }

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

    /// Deletes a downloaded model. Bundled models are never touched.
    func removeDownloadedModel(_ modelID: WhisperModelID) throws {
        guard let path = WhisperModelLibrary.downloadedModelPath(for: modelID, locations: locations),
              FileManager.default.fileExists(atPath: path)
        else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    /// Hashing a multi-gigabyte file takes seconds; keep it off the shared executor.
    private static func verifyOffExecutor(fileAt url: URL, expected: WhisperModelFileExpectation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try WhisperModelFileVerifier.verify(fileAt: url, expected: expected)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
