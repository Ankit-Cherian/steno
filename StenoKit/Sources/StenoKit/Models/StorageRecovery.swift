import Foundation

/// Tells the user that a data file couldn't be read in full and where the
/// original content was kept.
public struct StorageRecoveryNotice: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var message: String
    public var fileURL: URL?
    /// Text the user may want to copy because it couldn't be saved.
    public var recoverableText: String?

    public init(
        id: UUID = UUID(),
        message: String,
        fileURL: URL?,
        recoverableText: String? = nil
    ) {
        self.id = id
        self.message = message
        self.fileURL = fileURL
        self.recoverableText = recoverableText
    }
}

// MARK: - Lenient decoding

/// Records values that decoding skipped or replaced with a fallback, so a store
/// can keep the original file before it rewrites it without them.
public final class DecodingIssueLog: @unchecked Sendable {
    public static let userInfoKey = CodingUserInfoKey(rawValue: "io.stenoapp.decodingIssueLog")!

    private let lock = NSLock()
    private var skipped = 0
    private var replaced = 0

    public init() {}

    /// Elements left out because they couldn't be decoded.
    public var skippedCount: Int { lock.withLock { skipped } }
    /// Values replaced with a fallback, such as an unknown enum value.
    public var replacedCount: Int { lock.withLock { replaced } }
    public var isEmpty: Bool { lock.withLock { skipped == 0 && replaced == 0 } }

    func recordSkipped() { lock.withLock { skipped += 1 } }
    func recordReplaced() { lock.withLock { replaced += 1 } }
}

extension Decoder {
    var decodingIssueLog: DecodingIssueLog? {
        userInfo[DecodingIssueLog.userInfoKey] as? DecodingIssueLog
    }

    /// Notes that a value was missing or unrecognized and a fallback was used.
    public func recordReplacedValue() {
        decodingIssueLog?.recordReplaced()
    }
}

extension JSONDecoder {
    /// A decoder that reports skipped and replaced values to `log`.
    public static func recordingIssues(to log: DecodingIssueLog) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[DecodingIssueLog.userInfoKey] = log
        return decoder
    }
}

extension RawRepresentable where RawValue == String {
    /// Decodes a string raw value, using `fallback` for a value this build
    /// doesn't know (for example one written by a newer version).
    public static func decodeLeniently(from decoder: Decoder, fallback: Self) throws -> Self {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = Self(rawValue: raw) {
            return value
        }
        decoder.recordReplacedValue()
        return fallback
    }
}

/// An array that skips elements it can't decode instead of failing as a whole.
public struct LossyArray<Element: Decodable>: Decodable {
    public var elements: [Element]

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        if let count = container.count {
            elements.reserveCapacity(count)
        }
        while !container.isAtEnd {
            let index = container.currentIndex
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                decoder.decodingIssueLog?.recordSkipped()
                if try !container.decodeNil() {
                    _ = try container.decode(SkippedValue.self)
                }
                guard container.currentIndex > index else { throw error }
            }
        }
        self.elements = elements
    }
}

/// A string-keyed dictionary that skips values it can't decode.
public struct LossyDictionary<Value: Decodable>: Decodable {
    public var values: [String: Value]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: Value] = [:]
        for key in container.allKeys {
            do {
                values[key.stringValue] = try container.decode(Value.self, forKey: key)
            } catch {
                decoder.decodingIssueLog?.recordSkipped()
            }
        }
        self.values = values
    }
}

private struct SkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - File preservation

/// File operations that keep a user's data file whenever it can't be read in full.
public enum StorageFilePreservation {
    /// Identifies one version of a file so a store can tell whether another
    /// process replaced it.
    public struct Signature: Hashable, Sendable {
        var fileNumber: Int
        var size: Int
        var modified: Date?
    }

    public static func signature(of url: URL) -> Signature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return Signature(
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0,
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modified: attributes[.modificationDate] as? Date
        )
    }

    /// The single previous-generation copy kept beside `url`.
    public static func previousCopyURL(for url: URL) -> URL {
        sibling(of: url, suffix: "previous")
    }

    /// Moves a file that couldn't be read to a timestamped name in the same
    /// folder. The file is never deleted.
    public static func moveAside(_ url: URL, label: String, now: Date = Date()) throws -> URL {
        let destination = uniqueTimestampedURL(for: url, label: label, now: now)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Keeps a copy of `data`, the original content of `url`, unless an
    /// identical copy with the same label already exists.
    public static func preserveCopy(
        of url: URL,
        data: Data,
        label: String,
        now: Date = Date()
    ) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let prefix = "\(url.deletingPathExtension().lastPathComponent).\(label)-"
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        for candidate in existing where candidate.lastPathComponent.hasPrefix(prefix) {
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if size == data.count, (try? Data(contentsOf: candidate)) == data {
                return candidate
            }
        }
        let destination = uniqueTimestampedURL(for: url, label: label, now: now)
        try data.write(to: destination, options: .withoutOverwriting)
        return destination
    }

    /// Replaces the previous-generation copy with the file currently at `url`.
    public static func keepPreviousCopy(of url: URL) throws {
        let previous = previousCopyURL(for: url)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: previous.path) {
            try fileManager.removeItem(at: previous)
        }
        try fileManager.copyItem(at: url, to: previous)
    }

    private static func uniqueTimestampedURL(for url: URL, label: String, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now)
        var candidate = sibling(of: url, suffix: "\(label)-\(stamp)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = sibling(of: url, suffix: "\(label)-\(stamp)-\(attempt)")
            attempt += 1
        }
        return candidate
    }

    private static func sibling(of url: URL, suffix: String) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(base).\(suffix).\(ext)")
    }
}

/// Serializes read-modify-write cycles on one data file across processes with
/// an advisory lock beside it. Locking is best effort: if the lock file can't
/// be opened, the work still runs.
enum StorageFileLock {
    static func withLock<T>(for url: URL, _ body: () throws -> T) rethrows -> T {
        let lockURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 && errno == EINTR {}
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
