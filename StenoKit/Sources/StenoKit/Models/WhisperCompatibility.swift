import Foundation

public enum AppleSiliconChipClass: String, Codable, CaseIterable, Sendable, Equatable {
    case m1 = "m1"
    case m1Pro = "m1-pro"
    case m1Max = "m1-max"
    case m1Ultra = "m1-ultra"
    case m2 = "m2"
    case m2Pro = "m2-pro"
    case m2Max = "m2-max"
    case m2Ultra = "m2-ultra"
    case m3 = "m3"
    case m3Pro = "m3-pro"
    case m3Max = "m3-max"
    case m4 = "m4"
    case m4Pro = "m4-pro"
    case m4Max = "m4-max"
    case m5 = "m5"
    case m5Pro = "m5-pro"
    case m5Max = "m5-max"

    public var displayName: String {
        rawValue.uppercased().replacingOccurrences(of: "-", with: " ")
    }
}

public enum WhisperModelID: String, Codable, CaseIterable, Sendable, Equatable {
    case baseEn = "base.en"
    case smallEn = "small.en"
    case mediumEn = "medium.en"
    case largeV3Turbo = "large-v3-turbo"

    public var displayName: String {
        rawValue
    }
}

public enum WhisperCompatibilitySupportLevel: String, Codable, Sendable, Equatable {
    case validated
    case allowedWarning = "allowed-warning"
    case unvalidated
}

public enum WhisperCompatibilityQualityTier: String, Codable, Sendable, Equatable {
    case recommended
    case good
    case fallback
}

public struct WhisperCompatibilityMemoryRange: Sendable, Codable, Equatable {
    public var minGB: Int
    public var maxGB: Int?

    public init(minGB: Int, maxGB: Int? = nil) {
        self.minGB = max(0, minGB)
        self.maxGB = maxGB
    }

    public func contains(_ memoryGB: Int) -> Bool {
        guard memoryGB >= minGB else { return false }
        if let maxGB {
            return memoryGB <= maxGB
        }
        return true
    }
}

public struct WhisperHardwareProfile: Sendable, Codable, Equatable {
    public var chipClass: AppleSiliconChipClass
    public var memoryGB: Int

    public init(chipClass: AppleSiliconChipClass, memoryGB: Int) {
        self.chipClass = chipClass
        self.memoryGB = memoryGB
    }
}

public struct WhisperCompatibilityRow: Sendable, Codable, Equatable {
    public var chipClass: AppleSiliconChipClass
    public var memoryRangeGB: WhisperCompatibilityMemoryRange
    public var modelID: WhisperModelID
    public var supportLevel: WhisperCompatibilitySupportLevel
    public var qualityTier: WhisperCompatibilityQualityTier
    public var p90BudgetMS: Int?
    public var p99BudgetMS: Int?
    public var notes: String

    public init(
        chipClass: AppleSiliconChipClass,
        memoryRangeGB: WhisperCompatibilityMemoryRange,
        modelID: WhisperModelID,
        supportLevel: WhisperCompatibilitySupportLevel,
        qualityTier: WhisperCompatibilityQualityTier,
        p90BudgetMS: Int? = nil,
        p99BudgetMS: Int? = nil,
        notes: String
    ) {
        self.chipClass = chipClass
        self.memoryRangeGB = memoryRangeGB
        self.modelID = modelID
        self.supportLevel = supportLevel
        self.qualityTier = qualityTier
        self.p90BudgetMS = p90BudgetMS
        self.p99BudgetMS = p99BudgetMS
        self.notes = notes
    }
}

public enum WhisperCurrentModelStatusLevel: Sendable, Equatable {
    case validated
    case warning
    case custom
}

public struct WhisperCurrentModelStatus: Sendable, Equatable {
    public var modelID: WhisperModelID?
    public var level: WhisperCurrentModelStatusLevel
    public var reason: String

    public init(modelID: WhisperModelID?, level: WhisperCurrentModelStatusLevel, reason: String) {
        self.modelID = modelID
        self.level = level
        self.reason = reason
    }
}

public struct WhisperCompatibilityAssessment: Sendable, Equatable {
    public var hardwareProfile: WhisperHardwareProfile?
    public var recommendedRow: WhisperCompatibilityRow?
    public var currentModelStatus: WhisperCurrentModelStatus

    public init(
        hardwareProfile: WhisperHardwareProfile?,
        recommendedRow: WhisperCompatibilityRow?,
        currentModelStatus: WhisperCurrentModelStatus
    ) {
        self.hardwareProfile = hardwareProfile
        self.recommendedRow = recommendedRow
        self.currentModelStatus = currentModelStatus
    }
}
