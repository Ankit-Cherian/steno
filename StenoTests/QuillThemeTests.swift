import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

@Suite("Quill design tokens")
struct QuillThemeTests {
    @Test("Each saved accent resolves to its re-tuned value and readable text on it", arguments: [
        (StenoAccentStyle.citron, ColorScheme.light, "#4a6b10", "#ffffff"),
        (.citron, .dark, "#c9e27a", "#0d1330"),
        (.terracotta, .light, "#b0482e", "#ffffff"),
        (.terracotta, .dark, "#efa686", "#0d1330"),
        (.dodger, .light, "#2a4fd0", "#ffffff"),
        (.dodger, .dark, "#8ec0f5", "#0d1330"),
        (.cyan, .light, "#0b6a84", "#ffffff"),
        (.cyan, .dark, "#7fd3e8", "#0d1330"),
        (.violet, .light, "#5a46c4", "#ffffff"),
        (.violet, .dark, "#b9aaff", "#0d1330"),
        (.emerald, .light, "#1d6b55", "#ffffff"),
        (.emerald, .dark, "#8fd1ad", "#0d1330"),
        (.rose, .light, "#a3365a", "#ffffff"),
        (.rose, .dark, "#f5a3bc", "#0d1330"),
    ])
    func accentTokens(accent: StenoAccentStyle, scheme: ColorScheme, expectedAccent: String, expectedOnAccent: String) {
        let palette = QuillTheme.resolve(accent: accent, scheme: scheme, increaseContrast: false).palette
        #expect(palette.accent.description == expectedAccent)
        #expect(palette.onAccent.description == expectedOnAccent)
        #expect(palette.accentWash.alpha == (scheme == .dark ? 0.12 : 0.08))
    }

    @Test("Shared roles match the design for each scheme", arguments: [
        (ColorScheme.light, ["#f4f6fb", "#ffffff", "#eaf0f8", "#0e1433", "#3d4560", "#535c79", "#646d8a", "#142c8c", "#2d6a4f", "#94450f", "#2a4fd0"]),
        (.dark, ["#070a14", "#0e1220", "#0b0f1c", "#edf2ff", "#b8c2dc", "#97a2c1", "#7d89ad", "#1b2a7a", "#8fd1ad", "#f0b37a", "#8ec0f5"]),
    ])
    func sharedRoles(scheme: ColorScheme, expected: [String]) {
        for accent in [StenoAccentStyle.citron, .dodger, .rose] {
            let p = QuillTheme.resolve(accent: accent, scheme: scheme, increaseContrast: false).palette
            let actual = [p.ground, p.paper, p.well, p.ink, p.ink2, p.ink3, p.numbers, p.working, p.ok, p.caution, p.chart]
            #expect(actual.map(\.description) == expected)
        }
    }

    @Test("Rules and control borders are translucent ink", arguments: [
        (ColorScheme.light, "#0e1433@0.11", "#0e1433@0.48", "#0e1433@0.24", "#0e1433@0.72"),
        (.dark, "#cddaff@0.12", "#cddaff@0.42", "#cddaff@0.28", "#cddaff@0.66"),
    ])
    func rulesAndBorders(scheme: ColorScheme, rule: String, border: String, strongRule: String, strongBorder: String) {
        let standard = QuillTheme.resolve(accent: .dodger, scheme: scheme, increaseContrast: false).palette
        let increased = QuillTheme.resolve(accent: .dodger, scheme: scheme, increaseContrast: true).palette
        #expect(standard.rule.description == rule)
        #expect(standard.controlBorder.description == border)
        #expect(increased.rule.description == strongRule)
        #expect(increased.controlBorder.description == strongBorder)
        #expect(increased.ink3 == standard.ink2)
        #expect(increased.numbers == standard.ink2)
        #expect(increased.margin.alpha > standard.margin.alpha)
    }

    static let accentsBySchemeAndContrast: [(StenoAccentStyle, ColorScheme, Bool)] =
        StenoAccentStyle.allCases.flatMap { accent in
            [(accent, ColorScheme.light, false), (accent, .dark, false), (accent, .light, true), (accent, .dark, true)]
        }

    @Test("Text tokens reach 4.5:1 where they are used: paper, ground and well", arguments: accentsBySchemeAndContrast)
    func textContrast(accent: StenoAccentStyle, scheme: ColorScheme, increaseContrast: Bool) {
        let p = QuillTheme.resolve(accent: accent, scheme: scheme, increaseContrast: increaseContrast).palette
        let text: [(String, QuillColor)] = [
            ("ink", p.ink), ("ink2", p.ink2), ("ink3", p.ink3), ("numbers", p.numbers),
            ("accent", p.accent), ("ok", p.ok), ("caution", p.caution),
        ]
        for (backgroundName, background) in [("paper", p.paper), ("ground", p.ground), ("well", p.well)] {
            // Line numbers sit only on the page and the window ground, never in a field.
            for (name, color) in text where !(name == "numbers" && backgroundName == "well") {
                let ratio = color.contrastRatio(on: background)
                #expect(ratio >= 4.5, "\(name) on \(backgroundName): \(ratio)")
            }
        }
        let onAccent = p.onAccent.contrastRatio(on: p.accent)
        #expect(onAccent >= 4.5, "on-accent text: \(onAccent)")
    }

    @Test("Chart, selection and control borders reach 3:1 against the page", arguments: accentsBySchemeAndContrast)
    func graphicContrast(accent: StenoAccentStyle, scheme: ColorScheme, increaseContrast: Bool) {
        let p = QuillTheme.resolve(accent: accent, scheme: scheme, increaseContrast: increaseContrast).palette
        for (name, color) in [("chart", p.chart), ("selection", p.accent), ("control border", p.controlBorder)] {
            let ratio = color.contrastRatio(on: p.paper)
            #expect(ratio >= 3, "\(name) on paper: \(ratio)")
        }
    }

    @Test("The environment default is the cobalt light theme")
    func environmentDefault() {
        #expect(EnvironmentValues().quillTheme == QuillTheme.standard)
        #expect(QuillTheme.standard.accentStyle == .dodger)
        #expect(QuillTheme.standard.scheme == .light)
    }
}

@Suite("Quill typography")
struct QuillTypeTests {
    @Test("Roles keep their sizes and weights", arguments: [
        (QuillTypeStyle.display, CGFloat(38), CGFloat(640)), (.title, 26, 640), (.dictation, 17, 400),
        (.body, 13.5, 400), (.label, 13.5, 500), (.mono, 11, 500),
    ])
    func roleMetrics(style: QuillTypeStyle, size: CGFloat, weight: CGFloat) {
        #expect(style.size == size)
        #expect(style.weight == weight)
        #expect(QuillType.nsFont(style).pointSize == size)
    }

    @Test("Mono text is never smaller than 11 pt")
    func monoMinimum() {
        #expect(QuillType.nsFont(.azeretMono, size: 9, weight: 500).pointSize == 11)
        #expect(QuillType.nsFont(.mono, size: 14).pointSize == 14)
    }

    @Test("Missing families fall back to the system fonts at the nearest weight")
    func fallback() {
        let title = QuillType.nsFont(.title)
        let mono = QuillType.nsFont(.mono)
        if QuillType.isAvailable(.archivo) {
            #expect(title.familyName == "Archivo")
        } else {
            #expect(title.familyName == NSFont.systemFont(ofSize: 26).familyName)
        }
        if QuillType.isAvailable(.azeretMono) {
            #expect(mono.familyName == "Azeret Mono")
        } else {
            #expect(mono.familyName == NSFont.monospacedSystemFont(ofSize: 11, weight: .medium).familyName)
            #expect(mono.isFixedPitch)
        }
    }

    @Test("Text size steps scale a 17 pt role", arguments: [
        (DynamicTypeSize.large, CGFloat(17)), (.xLarge, 19), (.xxxLarge, 23), (.accessibility1, 27),
    ])
    func textSizeSteps(size: DynamicTypeSize, dictation: CGFloat) {
        #expect((17 * QuillType.scale(for: size) * 2).rounded() / 2 == dictation)
    }

    @Test("CSS weights map onto the AppKit weight scale")
    func weightMapping() {
        #expect(QuillType.systemWeight(forCSSWeight: 400) == .regular)
        #expect(QuillType.systemWeight(forCSSWeight: 600) == .semibold)
        let display = QuillType.systemWeight(forCSSWeight: 640)
        #expect(display.rawValue > NSFont.Weight.semibold.rawValue)
        #expect(display.rawValue < NSFont.Weight.bold.rawValue)
    }
}

@Suite("Quill components")
struct QuillComponentTests {
    @Test("Status pill words, with problems in caution", arguments: [
        (QuillStatusPillState.ready, "Ready", false), (.listening(elapsedSeconds: 102), "Listening 1:42", false),
        (.transcribing, "Transcribing", false), (.microphoneOff, "Microphone off", true),
        (.copyOnly, "Copy only", true), (.shortcutKeyOff("Option"), "Option key off", true),
        (.shortcutKeyOff("F18"), "F18 key off", true), (.shortcutKeyOff(nil), "Shortcuts off", true),
        (.noSpeechModel, "No speech model", true), (.downloading(percent: 62), "Downloading 62%", false),
    ])
    func pillWords(state: QuillStatusPillState, title: String, isProblem: Bool) {
        #expect(state.title == title)
        #expect(state.isProblem == isProblem)
    }

    @Test("Keycaps read their modifiers aloud", arguments: [("⌘V", "Command V"), ("F18", "F18"), ("⌃⌥V", "Control Option V")])
    func keycapNames(key: String, spoken: String) {
        #expect(Keycap.spokenName(for: key) == spoken)
    }
}
