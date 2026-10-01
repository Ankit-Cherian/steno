import Foundation

public enum HistoryStoreError: Error, LocalizedError {
    case missingEntry
    case persistenceFailed
    case originalNotPreserved
    case directiveCannotBeReplayed
    case rerunLeftNoText

    public var errorDescription: String? {
        switch self {
        case .missingEntry:
            return "Transcript entry not found"
        case .persistenceFailed:
            return "Unable to persist transcript history"
        case .originalNotPreserved:
            return "History couldn't be saved because the existing History file couldn't be read or kept aside. The file was left unchanged."
        case .directiveCannotBeReplayed:
            return "This transcript starts with a spoken \u{201C}lowercase\u{201D} command that History can't replay, so its text was left unchanged."
        case .rerunLeftNoText:
            return "Cleanup with the current settings would leave no text, so this transcript was left unchanged."
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

    /// Removes one transcript. The previous-generation copy kept beside the
    /// file is rewritten to match, so the deleted text doesn't stay on disk.
    /// Copies kept when the file couldn't be read in full lose the entry too;
    /// one that can't be parsed is left as it is, and a notice says so.
    public func delete(entryID: UUID) async throws {
        try commit(previousCopy: .matchNewFile) { working in
            let countBefore = working.count
            working.removeAll { $0.id == entryID }
            return working.count != countBefore
        }
        StorageFileLock.withLock(for: storageURL) {
            removeFromKeptCopies(entryID: entryID)
        }
    }

    /// Removes every transcript. The previous-generation copy kept beside the
    /// file is removed too, and so are copies kept when the file couldn't be
    /// read in full, so the deleted text doesn't stay on disk.
    public func deleteAll() async throws {
        try commit { working in
            working.removeAll()
            return true
        }
        let copies = [StorageFilePreservation.previousCopyURL(for: storageURL)]
            + StorageFilePreservation.keptCopies(of: storageURL, labels: ["original", "unreadable"])
        for copy in copies where FileManager.default.fileExists(atPath: copy.path) {
            do {
                try FileManager.default.removeItem(at: copy)
            } catch {
                throw HistoryStoreError.persistenceFailed
            }
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
        return try await retry(
            entryID: entryID,
            using: cleanupEngine,
            profile: profile,
            lexicon: lexicon,
            appContext: AppContext.classified(bundleIdentifier: entry.appBundleID, appName: entry.appBundleID),
            snippets: nil
        )
    }

    /// Re-runs live dictation's cleanup stages on an entry's recognized text and saves the result
    /// as its clean text. The clean text live dictation produced is kept in `originalCleanText`
    /// until it is restored, however many times cleanup is re-run. An entry whose spoken directive
    /// can't be replayed, or whose re-run would leave no text, is left unchanged and the error says
    /// why.
    public func retry(
        entryID: UUID,
        using cleanupEngine: CleanupEngine,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        appContext: AppContext,
        snippets: SnippetService?
    ) async throws -> CleanTranscript {
        refreshFromDisk()
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw HistoryStoreError.missingEntry
        }

        let retried = try await HistoryCleanupRerun.clean(
            entry,
            using: cleanupEngine,
            profile: profile,
            lexicon: lexicon,
            appContext: appContext,
            snippets: snippets
        )

        try commit { working in
            guard let index = working.firstIndex(where: { $0.id == entryID }) else { return false }
            let original = working[index].originalCleanText ?? working[index].cleanText
            working[index].cleanText = retried.text
            working[index].originalCleanText = retried.text == original ? nil : original
            return true
        }

        return retried
    }

    /// Puts back the clean text live dictation produced before cleanup was re-run. Returns the
    /// restored entry, or nil when there was nothing to restore.
    @discardableResult
    public func restoreOriginalCleanText(entryID: UUID) async throws -> TranscriptEntry? {
        var restored: TranscriptEntry?
        try commit { working in
            guard let index = working.firstIndex(where: { $0.id == entryID }),
                  let original = working[index].originalCleanText
            else {
                return false
            }
            working[index].cleanText = original
            working[index].originalCleanText = nil
            restored = working[index]
            return true
        }
        return restored
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
    private func commit(
        previousCopy: PreviousCopy = .keepReplacedFile,
        _ change: (inout [TranscriptEntry]) throws -> Bool
    ) throws {
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
            try write(working, previousCopy: previousCopy)
            entries = working
        }
    }

    /// What a write does with the previous-generation copy kept beside the file.
    private enum PreviousCopy {
        /// The copy becomes the file being replaced.
        case keepReplacedFile
        /// The copy is rewritten with the new content, so text removed by
        /// this write is not kept.
        case matchNewFile
    }

    private func write(_ newEntries: [TranscriptEntry], previousCopy: PreviousCopy) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        encoder.dateEncodingStrategy = .iso8601

        do {
            try ensureStorageDirectoryExists()
            let data = try encoder.encode(newEntries)
            if previousCopy == .keepReplacedFile,
               FileManager.default.fileExists(atPath: storageURL.path) {
                do {
                    try StorageFilePreservation.keepPreviousCopy(of: storageURL)
                } catch {
                    StenoKitDiagnostics.logger.error("History previous-copy update failed.")
                }
            }
            try data.write(to: storageURL, options: [.atomic])
            if previousCopy == .matchNewFile {
                try replacePreviousCopy(with: data)
            }
        } catch {
            throw HistoryStoreError.persistenceFailed
        }
        loadedSignature = StorageFilePreservation.signature(of: storageURL)
        hasLoaded = true
    }

    /// Rewrites an existing previous-generation copy with `data`, or removes it
    /// when it can't be rewritten.
    private func replacePreviousCopy(with data: Data) throws {
        let previousURL = StorageFilePreservation.previousCopyURL(for: storageURL)
        guard FileManager.default.fileExists(atPath: previousURL.path) else { return }
        do {
            try data.write(to: previousURL, options: [.atomic])
        } catch {
            try FileManager.default.removeItem(at: previousURL)
        }
    }

    /// Removes `entryID` from each copy kept when the file couldn't be read in
    /// full. A copy that can't be parsed or rewritten is left untouched, and
    /// the user is told that it still holds older text.
    private func removeFromKeptCopies(entryID: UUID) {
        var untouched: [URL] = []
        for copy in StorageFilePreservation.keptCopies(of: storageURL, labels: ["original", "unreadable"]) {
            guard let data = try? Data(contentsOf: copy) else {
                untouched.append(copy)
                continue
            }
            let edited: Data
            switch Self.removingEntry(entryID, fromKeptCopy: data) {
            case .unparseable:
                untouched.append(copy)
                continue
            case .noMatch:
                continue
            case .edited(let data):
                edited = data
            }
            do {
                try edited.write(to: copy, options: [.atomic])
            } catch {
                untouched.append(copy)
            }
        }
        guard let first = untouched.first else { return }
        let subject = untouched.count == 1
            ? "a damaged copy of the History file that Steno kept earlier still holds"
            : "\(untouched.count) damaged copies of the History file that Steno kept earlier still hold"
        report(StorageRecoveryNotice(
            message: "The transcript was deleted, but \(subject) older text. “Delete all history” removes \(untouched.count == 1 ? "it" : "them").",
            fileURL: first
        ))
    }

    enum KeptCopyEdit: Equatable {
        case unparseable
        case noMatch
        case edited(Data)
    }

    /// Removes the entries whose `id` is `entryID` from `data`, a kept copy's
    /// JSON array. Every other entry keeps its exact bytes.
    static func removingEntry(_ entryID: UUID, fromKeptCopy data: Data) -> KeptCopyEdit {
        guard (try? JSONSerialization.jsonObject(with: data)) is [Any] else { return .unparseable }
        let bytes = [UInt8](data)
        let whitespace: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
        guard let open = bytes.firstIndex(where: { !whitespace.contains($0) }), bytes[open] == UInt8(ascii: "[") else {
            return .unparseable
        }

        // The array is valid JSON, so tracking strings and nesting is enough
        // to find where each top-level element starts and ends.
        var elements: [Range<Int>] = []
        var elementStart = open + 1
        var close: Int?
        var depth = 0
        var inString = false
        var escaped = false
        for index in (open + 1)..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == 0 {
                    elements.append(elementStart..<index)
                    close = index
                } else {
                    depth -= 1
                }
            case UInt8(ascii: ",") where depth == 0:
                elements.append(elementStart..<index)
                elementStart = index + 1
            default:
                break
            }
            if close != nil { break }
        }
        guard let close else { return .unparseable }

        var kept: [ArraySlice<UInt8>] = []
        var removed = false
        for range in elements {
            guard let first = range.first(where: { !whitespace.contains(bytes[$0]) }),
                  let last = range.last(where: { !whitespace.contains(bytes[$0]) })
            else { continue }
            let element = bytes[first...last]
            if let object = try? JSONSerialization.jsonObject(with: Data(element)) as? [String: Any],
               let id = object["id"] as? String,
               UUID(uuidString: id) == entryID {
                removed = true
            } else {
                kept.append(element)
            }
        }
        guard removed else { return .noMatch }

        var result = Array(bytes[...open])
        for (index, element) in kept.enumerated() {
            if index > 0 { result.append(UInt8(ascii: ",")) }
            result.append(contentsOf: element)
        }
        result.append(contentsOf: bytes[close...])
        return .edited(Data(result))
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
