import Foundation

public actor BudgetGuard {
    public struct Pricing: Sendable, Codable, Equatable {
        public var premiumPer1KTokensUSD: Decimal
        public var economicalPer1KTokensUSD: Decimal

        public init(
            premiumPer1KTokensUSD: Decimal = Decimal(string: "0.005") ?? Decimal(0.005),
            economicalPer1KTokensUSD: Decimal = Decimal(string: "0.0012") ?? Decimal(0.0012)
        ) {
            self.premiumPer1KTokensUSD = premiumPer1KTokensUSD
            self.economicalPer1KTokensUSD = economicalPer1KTokensUSD
        }
    }

    private struct PersistedBudget: Codable {
        var monthlySpendUSD: Decimal
        var lastResetDate: Date
    }

    private let pricing: Pricing
    private let softDegradeThresholdUSD: Decimal
    private let hardStopThresholdUSD: Decimal
    private let storageURL: URL?

    private var runningMonthlySpendUSD: Decimal

    public init(
        pricing: Pricing = .init(),
        softDegradeThresholdUSD: Decimal = Decimal(string: "6.5") ?? Decimal(6.5),
        hardStopThresholdUSD: Decimal = Decimal(string: "8.0") ?? Decimal(8.0),
        startingSpendUSD: Decimal = 0,
        storageURL: URL? = nil
    ) {
        self.pricing = pricing
        self.softDegradeThresholdUSD = softDegradeThresholdUSD
        self.hardStopThresholdUSD = hardStopThresholdUSD
        self.storageURL = storageURL

        if let url = storageURL, let loaded = Self.loadBudget(from: url) {
            if Self.isCurrentMonth(loaded.lastResetDate) {
                self.runningMonthlySpendUSD = loaded.monthlySpendUSD
            } else {
                self.runningMonthlySpendUSD = 0
            }
        } else {
            self.runningMonthlySpendUSD = startingSpendUSD
        }
    }

    public func authorize(estimatedTokens: Int) -> CloudDecision {
        guard runningMonthlySpendUSD < hardStopThresholdUSD else {
            return CloudDecision(
                mode: .disabled,
                tier: .none,
                estimatedCostUSD: 0,
                reason: "Monthly cloud budget cap reached"
            )
        }

        let premiumCost = estimateCost(tokens: estimatedTokens, per1K: pricing.premiumPer1KTokensUSD)
        let economicalCost = estimateCost(tokens: estimatedTokens, per1K: pricing.economicalPer1KTokensUSD)
        let projectedPremium = runningMonthlySpendUSD + premiumCost
        let projectedEconomical = runningMonthlySpendUSD + economicalCost

        if projectedEconomical >= hardStopThresholdUSD {
            return CloudDecision(
                mode: .disabled,
                tier: .none,
                estimatedCostUSD: 0,
                reason: "Skipping cloud cleanup to avoid exceeding hard cap"
            )
        }

        if runningMonthlySpendUSD >= softDegradeThresholdUSD || projectedPremium >= softDegradeThresholdUSD {
            return CloudDecision(mode: .degraded, tier: .economical, estimatedCostUSD: economicalCost)
        }

        return CloudDecision(mode: .enabled, tier: .premium, estimatedCostUSD: premiumCost)
    }

    public func record(costUSD: Decimal) {
        guard costUSD > 0 else { return }
        runningMonthlySpendUSD += costUSD
        persist()
    }

    public func monthlySpend() -> Decimal {
        runningMonthlySpendUSD
    }

    public func effectiveMode() -> CloudMode {
        if runningMonthlySpendUSD >= hardStopThresholdUSD {
            return .disabled
        }
        if runningMonthlySpendUSD >= softDegradeThresholdUSD {
            return .degraded
        }
        return .enabled
    }

    public func resetMonth() {
        runningMonthlySpendUSD = 0
        persist()
    }

    private func estimateCost(tokens: Int, per1K: Decimal) -> Decimal {
        let tokenCount = Decimal(tokens)
        return (tokenCount / 1000) * per1K
    }

    // MARK: - Persistence

    private func persist() {
        guard let url = storageURL else { return }
        let budget = PersistedBudget(monthlySpendUSD: runningMonthlySpendUSD, lastResetDate: Date())
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(budget)
            try data.write(to: url, options: .atomic)
        } catch {
            StenoKitDiagnostics.logger.error(
                "Budget persistence failed for path \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func loadBudget(from url: URL) -> PersistedBudget? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PersistedBudget.self, from: data)
        } catch {
            StenoKitDiagnostics.logger.error(
                "Budget load failed for path \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func isCurrentMonth(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        return calendar.component(.year, from: date) == calendar.component(.year, from: now)
            && calendar.component(.month, from: date) == calendar.component(.month, from: now)
    }

    public static func defaultStorageURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("budget.json")
    }
}
