import CryptoKit
import Foundation
import Testing
@testable import StenoKit

@Test("Whisper model catalog downloads from one fixed upstream revision")
func whisperModelCatalogUsesPinnedDownloadURLs() {
    let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1"
    #expect(WhisperModelCatalog.downloadURL(for: .smallEn).absoluteString == "\(base)/ggml-small.en.bin")
    #expect(WhisperModelCatalog.downloadURL(for: .mediumEn).absoluteString == "\(base)/ggml-medium.en.bin")
    #expect(WhisperModelCatalog.downloadURL(for: .largeV3Turbo).absoluteString == "\(base)/ggml-large-v3-turbo.bin")
}

@Test("Whisper model catalog records the published size and SHA-256 of every model")
func whisperModelCatalogRecordsExpectedFiles() {
    #expect(WhisperModelCatalog.expectedFile(for: .baseEn) == .init(
        byteCount: 147_964_211,
        sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
    ))
    #expect(WhisperModelCatalog.expectedFile(for: .smallEn) == .init(
        byteCount: 487_614_201,
        sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
    ))
    #expect(WhisperModelCatalog.expectedFile(for: .mediumEn) == .init(
        byteCount: 1_533_774_781,
        sha256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356"
    ))
    #expect(WhisperModelCatalog.expectedFile(for: .largeV3Turbo) == .init(
        byteCount: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    ))
}

@Test("Whisper model catalog prefers small as the bundled default")
func whisperModelCatalogPrefersSmallAsBundledDefault() {
    #expect(WhisperModelCatalog.bundledDefaultModel == .smallEn)
    #expect(WhisperModelCatalog.bundledSearchOrder == [.smallEn, .baseEn, .mediumEn, .largeV3Turbo])
}

@Suite("Whisper model file verification")
struct WhisperModelFileVerifierTests {
    private func temporaryFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoModelVerifier-\(UUID().uuidString).bin")
        try contents.write(to: url)
        return url
    }

    private func expectation(for contents: Data) -> WhisperModelFileExpectation {
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        return .init(byteCount: Int64(contents.count), sha256: digest)
    }

    @Test("A file with the expected size and digest passes")
    func matchingFilePasses() throws {
        let contents = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = try temporaryFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }

        try WhisperModelFileVerifier.verify(fileAt: url, expected: expectation(for: contents))
    }

    @Test("A proxy page returned with a success status is rejected by size")
    func blockPageIsRejected() throws {
        let url = try temporaryFile(Data("<html><body>Access blocked by policy</body></html>".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: WhisperModelFileVerificationError.sizeMismatch(expected: 1_533_774_781, actual: 50)) {
            try WhisperModelFileVerifier.verify(fileAt: url, expected: WhisperModelCatalog.expectedFile(for: .mediumEn))
        }
    }

    @Test("A file of the right size with different content is rejected by digest")
    func sameSizeDifferentContentIsRejected() throws {
        let expectedContents = Data(repeating: 7, count: 70_000)
        let url = try temporaryFile(Data(repeating: 8, count: 70_000))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: WhisperModelFileVerificationError.digestMismatch) {
            try WhisperModelFileVerifier.verify(fileAt: url, expected: expectation(for: expectedContents))
        }
    }
}
