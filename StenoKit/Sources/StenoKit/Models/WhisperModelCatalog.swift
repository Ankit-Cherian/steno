import Foundation

/// The published size and SHA-256 of a model file at the pinned revision.
public struct WhisperModelFileExpectation: Equatable, Sendable {
    public let byteCount: Int64
    /// Lowercase hexadecimal SHA-256 digest.
    public let sha256: String

    public init(byteCount: Int64, sha256: String) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum WhisperModelCatalog {
    /// Upstream files are immutable per revision, so a pinned revision keeps
    /// every download identical to the recorded size and digest.
    public static let downloadRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    private static let baseDownloadURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(downloadRevision)"
    )!

    public static let bundledDefaultModel: WhisperModelID = .smallEn
    public static let bundledSearchOrder: [WhisperModelID] = [.smallEn, .baseEn, .mediumEn, .largeV3Turbo]
    public static let downloadableUpgradeOrder: [WhisperModelID] = [.mediumEn, .largeV3Turbo]

    public static func fileName(for modelID: WhisperModelID) -> String {
        "ggml-\(modelID.rawValue).bin"
    }

    public static func downloadURL(for modelID: WhisperModelID) -> URL {
        baseDownloadURL.appendingPathComponent(fileName(for: modelID))
    }

    public static func expectedFile(for modelID: WhisperModelID) -> WhisperModelFileExpectation {
        switch modelID {
        case .baseEn:
            return .init(
                byteCount: 147_964_211,
                sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
            )
        case .smallEn:
            return .init(
                byteCount: 487_614_201,
                sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
            )
        case .mediumEn:
            return .init(
                byteCount: 1_533_774_781,
                sha256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356"
            )
        case .largeV3Turbo:
            return .init(
                byteCount: 1_624_555_275,
                sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
            )
        }
    }

    public static func title(for modelID: WhisperModelID) -> String {
        switch modelID {
        case .baseEn:
            return "Base"
        case .smallEn:
            return "Small"
        case .mediumEn:
            return "Medium"
        case .largeV3Turbo:
            return "Large V3 Turbo"
        }
    }

    public static func summary(for modelID: WhisperModelID) -> String {
        switch modelID {
        case .baseEn:
            return "Lightest download, lowest quality."
        case .smallEn:
            return "Included by default. Fastest setup for most users."
        case .mediumEn:
            return "Better accuracy with a larger download."
        case .largeV3Turbo:
            return "Best quality, but the biggest download."
        }
    }
}
