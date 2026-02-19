import Foundation

public struct CleanupCandidate: Sendable, Codable, Equatable {
    public var text: String
    public var appliedEdits: [TranscriptEdit]
    public var removedFillers: [String]
    public var rulePathID: String

    public init(
        text: String,
        appliedEdits: [TranscriptEdit],
        removedFillers: [String],
        rulePathID: String
    ) {
        self.text = text
        self.appliedEdits = appliedEdits
        self.removedFillers = removedFillers
        self.rulePathID = rulePathID
    }
}

public struct CleanupRankingScore: Sendable, Codable, Equatable {
    public var semanticPreservationScore: Double
    public var fluencyScore: Double
    public var editDistancePenalty: Double
    public var commandSafetyPenalty: Double
    public var totalScore: Double

    public init(
        semanticPreservationScore: Double,
        fluencyScore: Double,
        editDistancePenalty: Double,
        commandSafetyPenalty: Double,
        totalScore: Double
    ) {
        self.semanticPreservationScore = semanticPreservationScore
        self.fluencyScore = fluencyScore
        self.editDistancePenalty = editDistancePenalty
        self.commandSafetyPenalty = commandSafetyPenalty
        self.totalScore = totalScore
    }
}
