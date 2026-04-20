import Foundation
import SwiftUI

enum StenoAppearanceMode: String, Codable, Sendable, CaseIterable {
    case dark
    case light

    var colorScheme: ColorScheme {
        switch self {
        case .dark:
            return .dark
        case .light:
            return .light
        }
    }

    var title: String {
        rawValue.capitalized
    }
}

enum StenoAccentStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case dodger
    case cyan
    case violet
    case emerald
    case rose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dodger:
            return "Dodger"
        case .cyan:
            return "Cyan"
        case .violet:
            return "Violet"
        case .emerald:
            return "Emerald"
        case .rose:
            return "Rose"
        }
    }
}

enum StenoRecordHeroStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case pill
    case ring

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}
