import Foundation
import Testing
@testable import StenoKit

@Test("Whisper model catalog uses the expected canonical download URLs")
func whisperModelCatalogUsesExpectedCanonicalDownloadURLs() {
    #expect(
        WhisperModelCatalog.downloadURL(for: .smallEn).absoluteString
            == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
    )
    #expect(
        WhisperModelCatalog.downloadURL(for: .mediumEn).absoluteString
            == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin"
    )
    #expect(
        WhisperModelCatalog.downloadURL(for: .largeV3Turbo).absoluteString
            == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    )
}

@Test("Whisper model catalog prefers small as the bundled default")
func whisperModelCatalogPrefersSmallAsBundledDefault() {
    #expect(WhisperModelCatalog.bundledDefaultModel == .smallEn)
    #expect(WhisperModelCatalog.bundledSearchOrder == [.smallEn, .baseEn, .mediumEn, .largeV3Turbo])
}
