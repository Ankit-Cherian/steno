import Foundation

public typealias SessionID = UUID

public struct TranscriptSegment: Sendable, Codable, Equatable {
    public var startMS: Int
    public var endMS: Int
    public var text: String
    public var confidence: Double?

    public init(startMS: Int, endMS: Int, text: String, confidence: Double? = nil) {
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
        self.confidence = confidence
    }
}

public struct RawTranscript: Sendable, Codable, Equatable {
    public var text: String
    public var segments: [TranscriptSegment]
    public var avgConfidence: Double?
    public var durationMS: Int

    public init(
        text: String,
        segments: [TranscriptSegment] = [],
        avgConfidence: Double? = nil,
        durationMS: Int = 0
    ) {
        self.text = text
        self.segments = segments
        self.avgConfidence = avgConfidence
        self.durationMS = durationMS
    }
}

public struct TranscriptEdit: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case fillerRemoval
        case lexiconCorrection
        case structureRewrite
        case punctuation
        case commandTransform
    }

    public var kind: Kind
    public var from: String
    public var to: String

    public init(kind: Kind, from: String, to: String) {
        self.kind = kind
        self.from = from
        self.to = to
    }
}

public struct CleanTranscript: Sendable, Codable, Equatable {
    public var text: String
    public var edits: [TranscriptEdit]
    public var removedFillers: [String]
    public var uncertaintyFlags: [String]
    public var modelTier: CloudModelTier

    public init(
        text: String,
        edits: [TranscriptEdit] = [],
        removedFillers: [String] = [],
        uncertaintyFlags: [String] = [],
        modelTier: CloudModelTier = .none
    ) {
        self.text = text
        self.edits = edits
        self.removedFillers = removedFillers
        self.uncertaintyFlags = uncertaintyFlags
        self.modelTier = modelTier
    }
}

public enum InsertionMethod: String, Sendable, Codable, Equatable {
    case direct
    case accessibility
    case clipboardPaste
    case none
}

public enum InsertionStatus: String, Sendable, Codable, Equatable {
    case inserted
    case copiedOnly
    case failed
}

public struct InsertResult: Sendable, Codable, Equatable {
    public var status: InsertionStatus
    public var method: InsertionMethod
    public var insertedText: String
    public var errorMessage: String?

    public init(
        status: InsertionStatus,
        method: InsertionMethod,
        insertedText: String,
        errorMessage: String? = nil
    ) {
        self.status = status
        self.method = method
        self.insertedText = insertedText
        self.errorMessage = errorMessage
    }
}

public struct CaptureChunk: Sendable, Codable, Equatable {
    public var sessionID: SessionID
    public var startedAt: Date
    public var durationMS: Int

    public init(sessionID: SessionID, startedAt: Date, durationMS: Int) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.durationMS = durationMS
    }
}
