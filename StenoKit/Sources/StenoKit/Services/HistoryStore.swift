import Foundation

public enum HistoryStoreError: Error, LocalizedError {
    case missingEntry
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .missingEntry:
            return "Transcript entry not found"
        case .persistenceFailed:
            return "Unable to persist transcript history"
        }
    }
}

public actor HistoryStore: HistoryStoreProtocol {
    private var entries: [TranscriptEntry] = []
    private var hasLoaded = false
    private let storageURL: URL
    private let clipboardService: ClipboardService
    private let maxEntries: Int

    public init(
        storageURL: URL? = nil,
        clipboardService: ClipboardService,
        maxEntries: Int = 500
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.clipboardService = clipboardService
        self.maxEntries = maxEntries
    }

    private func ensureLoaded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            entries = try Self.loadEntries(from: storageURL)
        } catch {
            entries = []
        }
    }

    public func append(entry: TranscriptEntry) async throws {
        ensureLoaded()
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        try persist()
    }

    public func delete(entryID: UUID) async throws {
        ensureLoaded()
        entries.removeAll { $0.id == entryID }
        try persist()
    }

    public func recent(limit: Int) async -> [TranscriptEntry] {
        ensureLoaded()
        guard limit > 0 else { return [] }
        return Array(entries.prefix(limit))
    }

    public func search(query: String) async -> [TranscriptEntry] {
        ensureLoaded()
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
        lexicon: PersonalLexicon,
        tier: CloudModelTier
    ) async throws -> CleanTranscript {
        ensureLoaded()
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw HistoryStoreError.missingEntry
        }

        let raw = RawTranscript(text: entry.rawText, durationMS: 0)
        let retried = try await cleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon, tier: tier)

        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            var updated = entries[index]
            updated.cleanText = retried.text
            entries[index] = updated
            try persist()
        }

        return retried
    }

    @discardableResult
    public func pasteLast() async throws -> TranscriptEntry? {
        ensureLoaded()
        guard let latest = entries.first else {
            return nil
        }

        let text = latest.cleanText.isEmpty ? latest.rawText : latest.cleanText
        try await clipboardService.setString(text)
        return latest
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(entries)
            let dir = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            throw HistoryStoreError.persistenceFailed
        }
    }

    private static func loadEntries(from url: URL) throws -> [TranscriptEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TranscriptEntry].self, from: data)
    }

    private static func defaultStorageURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return appSupport
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("transcript-history.json")
    }
}
