import Foundation
import Testing
@testable import StenoKit

@Test("Hardware profile normalizes Apple silicon chip classes")
func hardwareProfileNormalizesChipClasses() throws {
    let m1 = try #require(
        WhisperCompatibilityService.hardwareProfile(
            brandString: "Apple M1",
            physicalMemoryBytes: 8 * 1_073_741_824
        )
    )
    let m1Max = try #require(
        WhisperCompatibilityService.hardwareProfile(
            brandString: "Apple M1 Max",
            physicalMemoryBytes: 32 * 1_073_741_824
        )
    )
    let m5Pro = try #require(
        WhisperCompatibilityService.hardwareProfile(
            brandString: "Apple M5 Pro",
            physicalMemoryBytes: 64 * 1_073_741_824
        )
    )

    #expect(m1.chipClass == .m1)
    #expect(m1.memoryGB == 8)
    #expect(m1Max.chipClass == .m1Max)
    #expect(m1Max.memoryGB == 32)
    #expect(m5Pro.chipClass == .m5Pro)
    #expect(m5Pro.memoryGB == 64)
}

@Test("Compatibility service recommends best validated row for hardware tier")
func compatibilityServiceRecommendsBestValidatedRow() throws {
    let service = WhisperCompatibilityService(
        rows: [
            .init(
                chipClass: .m2,
                memoryRangeGB: .init(minGB: 8, maxGB: 16),
                modelID: .smallEn,
                supportLevel: .validated,
                qualityTier: .recommended,
                p90BudgetMS: 900,
                p99BudgetMS: 1_300,
                notes: "Validated baseline"
            ),
            .init(
                chipClass: .m2,
                memoryRangeGB: .init(minGB: 8, maxGB: 16),
                modelID: .baseEn,
                supportLevel: .validated,
                qualityTier: .fallback,
                p90BudgetMS: 700,
                p99BudgetMS: 1_000,
                notes: "Fallback"
            )
        ]
    )

    let recommendation = try #require(
        service.recommendation(
            for: .init(chipClass: .m2, memoryGB: 8)
        )
    )

    #expect(recommendation.modelID == .smallEn)
    #expect(recommendation.supportLevel == .validated)
    #expect(recommendation.qualityTier == .recommended)
}

@Test("Compatibility service warns for canonical models outside the matrix and marks quantized models custom")
func compatibilityServiceClassifiesCurrentModelStatus() {
    let service = WhisperCompatibilityService(
        rows: [
            .init(
                chipClass: .m5Pro,
                memoryRangeGB: .init(minGB: 32, maxGB: 128),
                modelID: .largeV3Turbo,
                supportLevel: .validated,
                qualityTier: .recommended,
                p90BudgetMS: 800,
                p99BudgetMS: 1_200,
                notes: "Validated on high-end Pro hardware"
            )
        ]
    )

    let profile = WhisperHardwareProfile(chipClass: .m1, memoryGB: 8)
    let canonical = service.currentModelStatus(
        forModelPath: "/tmp/ggml-large-v3-turbo.bin",
        hardwareProfile: profile
    )
    let quantized = service.currentModelStatus(
        forModelPath: "/tmp/ggml-small.en-q5_0.bin",
        hardwareProfile: profile
    )

    #expect(canonical.level == .warning)
    #expect(canonical.modelID == .largeV3Turbo)
    #expect(quantized.level == .custom)
    #expect(quantized.modelID == nil)
}
