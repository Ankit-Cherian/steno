import Foundation

public enum CloudModelTier: String, Sendable, Codable, Equatable {
    case premium
    case economical
    case none
}

public enum CloudMode: String, Sendable, Codable, Equatable {
    case enabled
    case degraded
    case disabled
}

public struct CloudDecision: Sendable, Codable, Equatable {
    public var mode: CloudMode
    public var tier: CloudModelTier
    public var estimatedCostUSD: Decimal
    public var reason: String?

    public init(
        mode: CloudMode,
        tier: CloudModelTier,
        estimatedCostUSD: Decimal,
        reason: String? = nil
    ) {
        self.mode = mode
        self.tier = tier
        self.estimatedCostUSD = estimatedCostUSD
        self.reason = reason
    }
}
