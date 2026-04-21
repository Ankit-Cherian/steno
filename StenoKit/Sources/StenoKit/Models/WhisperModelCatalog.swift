import Foundation

public enum WhisperModelCatalog {
    private static let baseDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main")!

    public static let bundledDefaultModel: WhisperModelID = .smallEn
    public static let bundledSearchOrder: [WhisperModelID] = [.smallEn, .baseEn, .mediumEn, .largeV3Turbo]
    public static let downloadableUpgradeOrder: [WhisperModelID] = [.mediumEn, .largeV3Turbo]

    public static func fileName(for modelID: WhisperModelID) -> String {
        "ggml-\(modelID.rawValue).bin"
    }

    public static func downloadURL(for modelID: WhisperModelID) -> URL {
        baseDownloadURL.appendingPathComponent(fileName(for: modelID))
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
