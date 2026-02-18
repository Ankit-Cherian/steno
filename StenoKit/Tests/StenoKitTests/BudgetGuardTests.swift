import Foundation
import Testing
@testable import StenoKit

@Test("BudgetGuard keeps premium mode when far from threshold")
func budgetGuardPremiumMode() async throws {
    let guardrail = BudgetGuard(startingSpendUSD: Decimal(string: "1.00")!)

    let decision = await guardrail.authorize(estimatedTokens: 1_000)

    #expect(decision.mode == .enabled)
    #expect(decision.tier == .premium)
    #expect(decision.estimatedCostUSD > 0)
}

@Test("BudgetGuard degrades near soft threshold")
func budgetGuardDegradedMode() async throws {
    let guardrail = BudgetGuard(startingSpendUSD: Decimal(string: "6.497")!)

    let decision = await guardrail.authorize(estimatedTokens: 1_000)

    #expect(decision.mode == .degraded)
    #expect(decision.tier == .economical)
}

@Test("BudgetGuard disables cleanup at hard cap")
func budgetGuardDisabledMode() async throws {
    let guardrail = BudgetGuard(startingSpendUSD: Decimal(string: "8.00")!)

    let decision = await guardrail.authorize(estimatedTokens: 500)

    #expect(decision.mode == .disabled)
    #expect(decision.tier == .none)
    #expect(decision.estimatedCostUSD == 0)
}
