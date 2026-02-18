import Foundation

public struct TranscriptEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var appBundleID: String
    public var rawText: String
    public var cleanText: String
    public var audioURL: URL?
    public var insertionStatus: InsertionStatus

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        appBundleID: String,
        rawText: String,
        cleanText: String,
        audioURL: URL?,
        insertionStatus: InsertionStatus
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appBundleID = appBundleID
        self.rawText = rawText
        self.cleanText = cleanText
        self.audioURL = audioURL
        self.insertionStatus = insertionStatus
    }
}
