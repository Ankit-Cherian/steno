import Foundation

public enum WhisperCompatibilityServiceError: Error, LocalizedError {
    case bundledMatrixMissing
    case bundledMatrixInvalid

    public var errorDescription: String? {
        switch self {
        case .bundledMatrixMissing:
            return "Bundled whisper compatibility matrix is missing."
        case .bundledMatrixInvalid:
            return "Bundled whisper compatibility matrix could not be decoded."
        }
    }
}

public struct WhisperCompatibilityService: Sendable {
    public let rows: [WhisperCompatibilityRow]

    public init(rows: [WhisperCompatibilityRow]) {
        self.rows = rows
    }

    public static func bundled() throws -> WhisperCompatibilityService {
        guard let url = Bundle.module.url(forResource: "whisper-compatibility-matrix", withExtension: "json") else {
            throw WhisperCompatibilityServiceError.bundledMatrixMissing
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        guard let rows = try? decoder.decode([WhisperCompatibilityRow].self, from: data) else {
            throw WhisperCompatibilityServiceError.bundledMatrixInvalid
        }
        return WhisperCompatibilityService(rows: rows)
    }

    public static func hardwareProfile(
        brandString: String,
        physicalMemoryBytes: UInt64
    ) -> WhisperHardwareProfile? {
        guard let chipClass = chipClass(from: brandString) else {
            return nil
        }

        let memoryGB = max(1, Int((Double(physicalMemoryBytes) / 1_073_741_824).rounded()))
        return WhisperHardwareProfile(chipClass: chipClass, memoryGB: memoryGB)
    }

    public static func currentHardwareProfile(
        processInfo: ProcessInfo = .processInfo
    ) -> WhisperHardwareProfile? {
        guard let brandString = currentBrandString() else {
            return nil
        }
        return hardwareProfile(
            brandString: brandString,
            physicalMemoryBytes: processInfo.physicalMemory
        )
    }

    public func assessment(
        forModelPath modelPath: String,
        hardwareProfile: WhisperHardwareProfile?
    ) -> WhisperCompatibilityAssessment {
        let status: WhisperCurrentModelStatus
        if let hardwareProfile {
            status = currentModelStatus(
                forModelPath: modelPath,
                hardwareProfile: hardwareProfile
            )
        } else {
            status = WhisperCurrentModelStatus(
                modelID: Self.canonicalModelID(forModelPath: modelPath),
                level: .custom,
                reason: "Current hardware could not be classified into the Apple silicon compatibility matrix."
            )
        }

        return WhisperCompatibilityAssessment(
            hardwareProfile: hardwareProfile,
            recommendedRow: hardwareProfile.flatMap(recommendation(for:)),
            currentModelStatus: status
        )
    }

    public func recommendation(for hardwareProfile: WhisperHardwareProfile) -> WhisperCompatibilityRow? {
        let matches = matchingRows(for: hardwareProfile)
        let validated = matches.filter { $0.supportLevel == .validated }
        if let bestValidated = bestRow(in: validated) {
            return bestValidated
        }
        return bestRow(in: matches)
    }

    public func matchingRows(for hardwareProfile: WhisperHardwareProfile) -> [WhisperCompatibilityRow] {
        rows.filter {
            $0.chipClass == hardwareProfile.chipClass &&
            $0.memoryRangeGB.contains(hardwareProfile.memoryGB)
        }
    }

    public func row(
        for chipClass: AppleSiliconChipClass,
        memoryGB: Int,
        modelID: WhisperModelID
    ) -> WhisperCompatibilityRow? {
        matchingRows(for: WhisperHardwareProfile(chipClass: chipClass, memoryGB: memoryGB))
            .first(where: { $0.modelID == modelID })
    }

    public func currentModelStatus(
        forModelPath modelPath: String,
        hardwareProfile: WhisperHardwareProfile
    ) -> WhisperCurrentModelStatus {
        guard let modelID = Self.canonicalModelID(forModelPath: modelPath) else {
            return WhisperCurrentModelStatus(
                modelID: nil,
                level: .custom,
                reason: "Current model is custom or quantized, so it is outside the curated compatibility matrix."
            )
        }

        let matchingRow = matchingRows(for: hardwareProfile).first(where: { $0.modelID == modelID })
        if let matchingRow {
            switch matchingRow.supportLevel {
            case .validated:
                return WhisperCurrentModelStatus(
                    modelID: modelID,
                    level: .validated,
                    reason: matchingRow.notes
                )
            case .allowedWarning, .unvalidated:
                return WhisperCurrentModelStatus(
                    modelID: modelID,
                    level: .warning,
                    reason: matchingRow.notes
                )
            }
        }

        return WhisperCurrentModelStatus(
            modelID: modelID,
            level: .warning,
            reason: "This canonical model is not in the curated compatibility matrix for the detected hardware tier."
        )
    }

    public static func canonicalModelID(forModelPath modelPath: String) -> WhisperModelID? {
        let filename = URL(fileURLWithPath: modelPath).lastPathComponent
            .lowercased()
            .replacingOccurrences(of: ".bin", with: "")
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: "model-", with: "")

        let canonicalNames = Set(WhisperModelID.allCases.map(\.rawValue))
        guard canonicalNames.contains(filename) else {
            return nil
        }
        return WhisperModelID(rawValue: filename)
    }

    private static func chipClass(from brandString: String) -> AppleSiliconChipClass? {
        let normalized = brandString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let mappings: [(String, AppleSiliconChipClass)] = [
            ("apple m1 ultra", .m1Ultra),
            ("apple m1 max", .m1Max),
            ("apple m1 pro", .m1Pro),
            ("apple m1", .m1),
            ("apple m2 ultra", .m2Ultra),
            ("apple m2 max", .m2Max),
            ("apple m2 pro", .m2Pro),
            ("apple m2", .m2),
            ("apple m3 max", .m3Max),
            ("apple m3 pro", .m3Pro),
            ("apple m3", .m3),
            ("apple m4 max", .m4Max),
            ("apple m4 pro", .m4Pro),
            ("apple m4", .m4),
            ("apple m5 max", .m5Max),
            ("apple m5 pro", .m5Pro),
            ("apple m5", .m5)
        ]

        for (needle, chipClass) in mappings where normalized.contains(needle) {
            return chipClass
        }

        return nil
    }

    private func bestRow(in rows: [WhisperCompatibilityRow]) -> WhisperCompatibilityRow? {
        rows.sorted { lhs, rhs in
            if supportPriority(lhs.supportLevel) != supportPriority(rhs.supportLevel) {
                return supportPriority(lhs.supportLevel) < supportPriority(rhs.supportLevel)
            }
            if qualityPriority(lhs.qualityTier) != qualityPriority(rhs.qualityTier) {
                return qualityPriority(lhs.qualityTier) < qualityPriority(rhs.qualityTier)
            }
            return lhs.modelID.rawValue < rhs.modelID.rawValue
        }.first
    }

    private func supportPriority(_ level: WhisperCompatibilitySupportLevel) -> Int {
        switch level {
        case .validated:
            return 0
        case .allowedWarning:
            return 1
        case .unvalidated:
            return 2
        }
    }

    private func qualityPriority(_ tier: WhisperCompatibilityQualityTier) -> Int {
        switch tier {
        case .recommended:
            return 0
        case .good:
            return 1
        case .fallback:
            return 2
        }
    }

    private static func currentBrandString() -> String? {
        var size: size_t = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
