import AppKit
import SwiftUI

/// Text roles of the Steno 1.1 design. Controls (buttons, menus, pickers) use the system font
/// and are not listed here.
enum QuillTypeStyle: Sendable, CaseIterable {
    /// Onboarding headline only: Archivo 640, 38 pt.
    case display
    /// Page and section titles: Archivo 640, 26 pt.
    case title
    /// Dictation text on the page: Archivo 400, 17 pt on a 30 pt line.
    case dictation
    /// Body text: Archivo 400, 13.5 pt.
    case body
    /// Labels: Archivo 500, 13.5 pt.
    case label
    /// Help text under a label and footnotes: Archivo 400, 12.5 pt.
    case caption
    /// Group headings inside a page, such as "While recording": Archivo 600, 13 pt.
    case heading
    /// Times, counts, keys and the margin: Azeret Mono 500, 11 pt.
    case mono

    var family: QuillType.Family {
        self == .mono ? .azeretMono : .archivo
    }

    var size: CGFloat {
        switch self {
        case .display: 38
        case .title: 26
        case .dictation: 17
        case .body, .label: 13.5
        case .caption: 12.5
        case .heading: 13
        case .mono: QuillType.minimumMonoSize
        }
    }

    /// CSS-style weight (100...900).
    var weight: CGFloat {
        switch self {
        case .display, .title: 640
        case .dictation, .body, .caption: 400
        case .label, .mono: 500
        case .heading: 600
        }
    }
}

/// Resolves the bundled families by name, with weight set through font descriptors. When a
/// family is not registered in the process it falls back to SF Pro or SF Mono at the nearest
/// system weight, so layout keeps working before the fonts are bundled.
enum QuillType {
    enum Family: String, Sendable {
        case archivo = "Archivo"
        case azeretMono = "Azeret Mono"
    }

    /// Times, counts and keys are never smaller than this.
    static let minimumMonoSize: CGFloat = 11

    private static let weightAxis = NSNumber(value: 0x7767_6874) // 'wght'

    /// Whether `family` resolves to itself rather than a substitute.
    static func isAvailable(_ family: Family) -> Bool {
        resolved(family.rawValue, size: 13, weight: 400) != nil
    }

    static func nsFont(_ style: QuillTypeStyle, size: CGFloat? = nil) -> NSFont {
        nsFont(style.family, size: size ?? style.size, weight: style.weight)
    }

    static func nsFont(_ family: Family, size: CGFloat, weight: CGFloat) -> NSFont {
        nsFont(familyName: family.rawValue, monospaced: family == .azeretMono, size: size, weight: weight)
    }

    /// Resolves `familyName`, or SF Pro (SF Mono when `monospaced`) when it is not registered.
    static func nsFont(familyName: String, monospaced: Bool, size: CGFloat, weight: CGFloat) -> NSFont {
        let size = monospaced ? max(size, minimumMonoSize) : size
        if let font = resolved(familyName, size: size, weight: weight) {
            return font
        }
        let systemWeight = systemWeight(forCSSWeight: weight)
        return monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: systemWeight)
            : NSFont.systemFont(ofSize: size, weight: systemWeight)
    }

    private static func resolved(_ familyName: String, size: CGFloat, weight: CGFloat) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [NSFontDescriptor.TraitKey.weight: systemWeight(forCSSWeight: weight).rawValue],
            .variation: [weightAxis: NSNumber(value: Double(weight))]
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == familyName else {
            return nil
        }
        return font
    }

    /// Maps a CSS weight to the AppKit weight scale, interpolating between named weights.
    static func systemWeight(forCSSWeight weight: CGFloat) -> NSFont.Weight {
        let table: [(CGFloat, NSFont.Weight)] = [
            (100, .ultraLight), (200, .thin), (300, .light), (400, .regular), (500, .medium),
            (600, .semibold), (700, .bold), (800, .heavy), (900, .black)
        ]
        let clamped = min(900, max(100, weight))
        for (lower, upper) in zip(table, table.dropFirst()) where clamped <= upper.0 {
            let fraction = (clamped - lower.0) / (upper.0 - lower.0)
            return NSFont.Weight(lower.1.rawValue + (upper.1.rawValue - lower.1.rawValue) * fraction)
        }
        return .black
    }
}

extension QuillType {
    /// Text-size steps relative to the default (`.large`).
    static func scale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.82
        case .small: 0.88
        case .medium: 0.94
        case .large: 1
        case .xLarge: 1.12
        case .xxLarge: 1.24
        case .xxxLarge: 1.35
        case .accessibility1: 1.6
        case .accessibility2: 1.9
        case .accessibility3: 2.2
        case .accessibility4: 2.5
        case .accessibility5: 2.8
        @unknown default: 1
        }
    }
}
