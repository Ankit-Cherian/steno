import Foundation

public struct TranscriptEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var appBundleID: String
    public var rawText: String
    public var cleanText: String
    public var durationMS: Int
    public var audioURL: URL?
    public var insertionStatus: InsertionStatus
    /// Optional so History files stay readable by Steno 1.0.0, which ignores
    /// unknown keys but rejects unknown `insertionStatus` values. Set only
    /// when a `.copiedOnly` insertion also sent the paste keystroke.
    public var pasteAttempted: Bool?
    /// The clean text live dictation produced, kept when "Run cleanup again" replaces `cleanText`
    /// so it can be restored. Nil when the entry was never re-run or was restored. Optional for the
    /// same reason as `pasteAttempted`.
    public var originalCleanText: String?
    /// True when the dictation was copied concealed because it was meant for
    /// a secure field, so later copies of it are concealed too. Optional for
    /// the same reason as `pasteAttempted`.
    public var concealedCopy: Bool?
    /// What happened at each step of the dictation. Nil for entries saved before records were kept.
    public var record: DictationRecord?
    /// Words corrected with Fix a word, oldest first. Nil when there are none.
    public var fixes: [WordFix]?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        appBundleID: String,
        rawText: String,
        cleanText: String,
        durationMS: Int = 0,
        audioURL: URL?,
        insertionStatus: InsertionStatus,
        pasteAttempted: Bool? = nil,
        originalCleanText: String? = nil,
        concealedCopy: Bool? = nil,
        record: DictationRecord? = nil,
        fixes: [WordFix]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appBundleID = appBundleID
        self.rawText = rawText
        self.cleanText = cleanText
        self.durationMS = durationMS
        self.audioURL = audioURL
        self.insertionStatus = insertionStatus
        self.pasteAttempted = pasteAttempted
        self.originalCleanText = originalCleanText
        self.concealedCopy = concealedCopy
        self.record = record
        self.fixes = fixes
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, appBundleID, rawText, cleanText, durationMS, audioURL
        case insertionStatus, pasteAttempted, originalCleanText, concealedCopy, record, fixes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        appBundleID = try container.decode(String.self, forKey: .appBundleID)
        rawText = try container.decode(String.self, forKey: .rawText)
        cleanText = try container.decode(String.self, forKey: .cleanText)
        durationMS = try container.decode(Int.self, forKey: .durationMS)
        audioURL = try container.decodeIfPresent(URL.self, forKey: .audioURL)
        insertionStatus = try container.decode(InsertionStatus.self, forKey: .insertionStatus)
        pasteAttempted = try container.decodeIfPresent(Bool.self, forKey: .pasteAttempted)
        originalCleanText = try container.decodeIfPresent(String.self, forKey: .originalCleanText)
        concealedCopy = try container.decodeIfPresent(Bool.self, forKey: .concealedCopy)
        // The record and fixes are details: one that can't be read is left out, and the copy of
        // the original file History keeps for replaced values preserves it, instead of the whole
        // entry being skipped.
        do {
            record = try container.decodeIfPresent(DictationRecord.self, forKey: .record)
        } catch {
            record = nil
            try container.superDecoder(forKey: .record).recordReplacedValue()
        }
        do {
            fixes = try container.decodeLossyDetailsIfPresent(of: WordFix.self, forKey: .fixes)
            if let decoded = fixes, decoded.count > WordFix.maximumFixesPerEntry {
                // Undo works from the newest fix, so the newest are kept.
                fixes = Array(decoded.suffix(WordFix.maximumFixesPerEntry))
                try container.superDecoder(forKey: .fixes).recordReplacedValue()
            }
        } catch {
            fixes = nil
            try container.superDecoder(forKey: .fixes).recordReplacedValue()
        }
    }

    /// A clipboard insertion whose paste keystroke was sent.
    public var wasPasted: Bool {
        insertionStatus == .copiedOnly && pasteAttempted == true
    }

    /// A clipboard insertion whose paste was skipped because another app wrote to the clipboard
    /// first. The words are saved in History but were never put where the person was typing,
    /// so it reads as not inserted, not as a copy. An entry with no record is never one.
    public var wasNotPasted: Bool {
        insertionStatus == .copiedOnly && record?.outcome == DictationRecord.notPastedOutcome
    }
}
