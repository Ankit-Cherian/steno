import AppKit
import CoreText
import SwiftUI
import StenoKit

private extension Color {
    init(hex: Int, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

struct StenoAccentPalette: Sendable {
    let accent: Color
    let accentGlow: Color
}

/// The saved appearance's accent, which the overlay is still handed and does not draw.
struct StenoTheme: Sendable {
    let appearance: AppPreferences.Appearance
    let accentPalette: StenoAccentPalette

    var accent: Color { accentPalette.accent }
    var accentGlow: Color { accentPalette.accentGlow }
}

/// Registers the bundled fonts with the process: Archivo and Azeret Mono, which the overlay and
/// the shared type roles ask for by name.
@MainActor
enum AppFontRegistry {
    private static var didRegister = false

    static func registerIfNeeded() {
        guard !didRegister, let resourceURL = Bundle.main.resourceURL else {
            return
        }

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "ttf" else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }

        didRegister = true
    }
}

@MainActor
enum StenoDesign {
    static let windowMinWidth: CGFloat = 940
    static let windowIdealWidth: CGFloat = 1120
    static let windowMinHeight: CGFloat = 640
    static let windowIdealHeight: CGFloat = 760

    static func theme(for appearance: AppPreferences.Appearance) -> StenoTheme {
        StenoTheme(
            appearance: appearance,
            accentPalette: accentPalette(for: appearance.accent)
        )
    }

    static func theme(for preferences: AppPreferences) -> StenoTheme {
        theme(for: preferences.appearance)
    }

    static func appDisplayName(for bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "Unknown" }
        if let name = installedAppName(for: bundleID) { return name }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    /// The name of the installed app with this bundle ID, or nil when none is installed.
    static func installedAppName(for bundleID: String) -> String? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    static func whisperModelDisplayName(for modelPath: String) -> String {
        let filename = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        guard !filename.isEmpty else { return "unknown" }

        return filename
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: "model-", with: "")
    }

    private static func dynamicColor(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
    }

    private static func accentPalette(for style: StenoAccentStyle) -> StenoAccentPalette {
        let light: Int
        let dark: Int
        switch style {
        case .citron: (light, dark) = (0x526500, 0xD4EB6D)
        case .terracotta: (light, dark) = (0xB7492C, 0xEEA080)
        case .dodger: (light, dark) = (0x155DA8, 0x86BFFF)
        case .cyan: (light, dark) = (0x00697C, 0x74DAEB)
        case .violet: (light, dark) = (0x6544AB, 0xC4ADFF)
        case .emerald: (light, dark) = (0x176849, 0x87DAB6)
        case .rose: (light, dark) = (0xA33753, 0xFBA2B7)
        }
        let accent = dynamicColor(light: Color(hex: light), dark: Color(hex: dark))
        return StenoAccentPalette(accent: accent, accentGlow: .clear)
    }
}
