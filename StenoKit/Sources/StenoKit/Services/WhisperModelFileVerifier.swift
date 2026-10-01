import CryptoKit
import Foundation

public enum WhisperModelFileVerificationError: Error, Equatable, Sendable {
    case sizeMismatch(expected: Int64, actual: Int64)
    case digestMismatch
    case unreadable
}

/// Checks a downloaded model file against its published size and digest
/// before it is moved into place.
public enum WhisperModelFileVerifier {
    public static func verify(fileAt url: URL, expected: WhisperModelFileExpectation) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value
        else {
            throw WhisperModelFileVerificationError.unreadable
        }
        guard size == expected.byteCount else {
            throw WhisperModelFileVerificationError.sizeMismatch(expected: expected.byteCount, actual: size)
        }
        guard try sha256Hex(ofFileAt: url) == expected.sha256.lowercased() else {
            throw WhisperModelFileVerificationError.digestMismatch
        }
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw WhisperModelFileVerificationError.unreadable
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 * 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
