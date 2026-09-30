import Foundation

public enum HistoryStoreError: Error, LocalizedError {
    case missingEntry
    case persistenceFailed
    case originalNotPreserved

    public var errorDescription: String? {
        switch self {
        case .missingEntry:
            return "Transcript entry not found"
        case .persistenceFailed:
            return "Unable to persist transcript history"
        case .originalNotPreserved:
            return "History couldn't be saved because the existing History file couldn't be read or kept aside. The file was left unchanged."
        }
    }
}

/// Stores transcript history in one JSON file shared by every running copy of
/// Steno. Only a missing file counts as empty. A file that can't be read is
/// never overwritten in place: it is moved aside first, and entries that can't
/// be decoded are kept in a copy of the original file.
public actor HistoryStore: HistoryStoreProtocol {
    private var entries: [TranscriptEntry] = []
    /// `entries` mirror the file version with this signature (nil: no file).
    private var loadedSignature: StorageFilePreservation.Signature?
    private var hasLoaded = false
    private var loadFailed = false
    /// A partly readable file whose original content still needs a kept copy.
    private var unpreservedOriginal: PartlyReadFile?
    private var reportedSignature: StorageFilePreservation.Signature?
    private var pendingNotices: [StorageRecoveryNotice] = []
    private var noticeHandler: (@Sendable (StorageRecoveryNotice) -> Void)?
    private var hasPreparedStorageDirectory = false
    private let storageURL: URL
    private let clipboardService: ClipboardService
    private let maxEntries: Int

    public init(
        storageURL: URL? = nil,
        clipboardService: ClipboardService,
        maxEntries: Int = 1_000
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.clipboardService = clipboardService
        self.maxEntries = maxEntries
    }

    public func append(entry: TranscriptEntry) async throws {
        try commit { working in
            working.insert(entry, at: 0)
            if working.count > maxEntries {
                working = Array(working.prefix(maxEntries))
            }
            return true
        }
    }

    public func delete(entryID: UUID) async throws {
        try commit { working in
            let countBefore = working.count
            working.removeAll { $0.id == entryID }
            return working.count != countBefore
        }
    }

    /// Removes every transcript. The previous-generation copy kept beside the
    /// file is removed too, so the deleted text doesn't stay on disk.
    public func deleteAll() async throws {
        try commit { working in
            working.removeAll()
            return true
        }
        let previousURL = StorageFilePreservation.previousCopyURL(for: storageURL)
        guard FileManager.default.fileExists(atPath: previousURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: previousURL)
        } catch {
            throw HistoryStoreError.persistenceFailed
        }
    }

    /// Returns recovery notices not yet delivered to a handler, once each.
    public func takeRecoveryNotices() -> [StorageRecoveryNotice] {
        defer { pendingNotices = [] }
        return pendingNotices
    }

    /// Delivers pending and future recovery notices to `handler`.
    public func setRecoveryNoticeHandler(
        _ handler: @escaping @Sendable (StorageRecoveryNotice) -> Void
    ) {
        noticeHandler = handler
        for notice in takeRecoveryNotices() {
            handler(notice)
        }
    }

    public func recent(limit: Int) async -> [TranscriptEntry] {
        refreshFromDisk()
        guard limit > 0 else { return [] }
        return Array(entries.prefix(limit))
    }

    public func search(query: String) async -> [TranscriptEntry] {
        refreshFromDisk()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }

        return entries.filter {
            $0.rawText.localizedCaseInsensitiveContains(trimmed)
            || $0.cleanText.localizedCaseInsensitiveContains(trimmed)
            || $0.appBundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    public func retry(
        entryID: UUID,
        using cleanupEngine: CleanupEngine,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        refreshFromDisk()
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw HistoryStoreError.missingEntry
        }

        let raw = RawTranscript(text: entry.rawText, durationMS: entry.durationMS)
        let retried = try await cleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)

        try commit { working in
            guard let index = working.firstIndex(where: { $0.id == entryID }) else { return false }
            working[index].cleanText = retried.text
            return true
        }

        return retried
    }

    @discardableResult
    public func pasteLast() async throws -> TranscriptEntry? {
        refreshFromDisk()
        guard let latest = entries.first else {
            return nil
        }

        let text = latest.cleanText.isEmpty ? latest.rawText : latest.cleanText
        try await clipboardService.setString(text)
        return latest
    }

    /// Applies `change` to the entries currently on disk and writes the result.
    /// Re-reading under a file lock keeps entries another running copy of Steno
    /// added or removed. Memory changes only after the write succeeds.
    private func commit(_ change: (inout [TranscriptEntry]) throws -> Bool) throws {
        try StorageFileLock.withLock(for: storageURL) {
            refreshFromDisk()
            if loadFailed {
                try moveUnreadableFileAside()
            }
            if let original = unpreservedOriginal {
                try preserve(original)
            }

            var working = entries
            guard try change(&working) else { return }
            try write(working)
            entries = working
        }
    }

    private func write(_ newEntries: [TranscriptEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        encoder.dateEncodingStrategy = .iso8601

        do {
            try ensureStorageDirectoryExists()
            let data = try encoder.encode(newEntries)
            if FileManager.default.fileExists(atPath: storageURL.path) {
                do {
                    try StorageFilePreservation.keepPreviousCopy(of: storageURL)
                } catch {
                    StenoKitDiagnostics.logger.error("History previous-copy update failed.")
                }
            }
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            throw HistoryStoreError.persistenceFailed
        }
        loadedSignature = StorageFilePreservation.signature(of: storageURL)
        hasLoaded = true
    }

    /// Reloads when the file changed since this store last read or wrote it.
    private func refreshFromDisk() {
        let signature = StorageFilePreservation.signature(of: storageURL)
        if hasLoaded, !loadFailed, signature == loadedSignature { return }

        switch Self.readEntries(from: storageURL) {
        case .missing:
            entries = []
            loadedSignature = nil
            hasLoaded = true
            loadFailed = false
            unpreservedOriginal = nil
        case .loaded(let decoded, let original, let issues):
            entries = decoded
            loadedSignature = signature
            hasLoaded = true
            loadFailed = false
            unpreservedOriginal = nil
            if !issues.isEmpty {
                let partlyRead = PartlyReadFile(data: original, issues: issues, signature: signature)
                unpreservedOriginal = partlyRead
                // A failure here is retried, and reported, before the next write.
                try? preserve(partlyRead)
            }
        case .failed:
            // Keep the last good entries in memory and leave the file alone.
            loadFailed = true
            if signature != reportedSignature {
                reportedSignature = signature
                report(StorageRecoveryNotice(
                    message: "Steno couldn't read your History file, so older transcripts aren't shown. The file hasn't been changed.",
                    fileURL: storageURL
                ))
            }
        }
    }

    private struct PartlyReadFile {
        var data: Data
        var issues: DecodingIssueLog
        var signature: StorageFilePreservation.Signature?
    }

    private func preserve(_ file: PartlyReadFile) throws {
        let copyURL: URL
        do {
            copyURL = try StorageFilePreservation.preserveCopy(
                of: storageURL,
                data: file.data,
                label: "original"
            )
        } catch {
            throw HistoryStoreError.originalNotPreserved
        }
        unpreservedOriginal = nil
        guard file.signature != reportedSignature else { return }
        reportedSignature = file.signature
        let skipped = file.issues.skippedCount
        let message = skipped > 0
            ? "\(skipped) History \(skipped == 1 ? "entry" : "entries") couldn't be read and \(skipped == 1 ? "is" : "are") hidden. Steno kept a copy of the original file."
            : "Some History entries were saved by a newer version of Steno and show a default status. Steno kept a copy of the original file."
        report(StorageRecoveryNotice(message: message, fileURL: copyURL))
    }

    private func moveUnreadableFileAside() throws {
        let movedURL: URL
        do {
            movedURL = try StorageFilePreservation.moveAside(storageURL, label: "unreadable")
        } catch {
            throw HistoryStoreError.originalNotPreserved
        }
        loadFailed = false
        loadedSignature = nil
        report(StorageRecoveryNotice(
            message: "Steno couldn't read your History file, so it kept it as “\(movedURL.lastPathComponent)” and started a new one.",
            fileURL: movedURL
        ))
    }

    private func report(_ notice: StorageRecoveryNotice) {
        if let noticeHandler {
            noticeHandler(notice)
        } else {
            pendingNotices.append(notice)
        }
    }

    private func ensureStorageDirectoryExists() throws {
        guard !hasPreparedStorageDirectory else { return }
        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hasPreparedStorageDirectory = true
    }

    private enum ReadResult {
        case missing
        case loaded([TranscriptEntry], original: Data, issues: DecodingIssueLog)
        case failed
    }

    /// Decodes entry by entry: an entry that can't be read is skipped and the
    /// rest load. Only a missing, empty or whitespace-only file counts as empty.
    private static func readEntries(from url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        let issues = DecodingIssueLog()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failed
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return .loaded([], original: data, issues: issues)
        }

        let decoder = JSONDecoder.recordingIssues(to: issues)
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode(LossyArray<TranscriptEntry>.self, from: data)
            return .loaded(decoded.elements, original: data, issues: issues)
        } catch {
            return .failed
        }
    }

    private static func defaultStorageURL() -> URL {
        let appSupport: URL
        if let resolved = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupport = resolved
        } else {
            appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            StenoKitDiagnostics.logger.fault(
                "Application Support directory lookup failed; using the conventional fallback directory."
            )
        }

        return appSupport
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("transcript-history.json")
    }
}
