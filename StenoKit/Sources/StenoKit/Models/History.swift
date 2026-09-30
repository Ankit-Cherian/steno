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

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        appBundleID: String,
        rawText: String,
        cleanText: String,
        durationMS: Int = 0,
        audioURL: URL?,
        insertionStatus: InsertionStatus,
        pasteAttempted: Bool? = nil
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
    }

    /// A clipboard insertion whose paste keystroke was sent.
    public var wasPasted: Bool {
        insertionStatus == .copiedOnly && pasteAttempted == true
    }
}
