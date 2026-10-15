import Foundation
import Testing
@testable import Steno

/// New installs start on System appearance and the cobalt accent; every saved, missing or
/// unknown value keeps decoding exactly as in 1.0, and 1.0.x can still read what 1.1 writes.
@Suite("Appearance defaults and saved accents")
struct QuillAppearanceDefaultsTests {
    @Test("Accent and appearance IDs are the 1.0 IDs")
    func identifiersUnchanged() {
        #expect(StenoAccentStyle.allCases.map(\.rawValue) == ["citron", "terracotta", "dodger", "cyan", "violet", "emerald", "rose"])
        #expect(StenoAppearanceMode.allCases.map(\.rawValue) == ["system", "dark", "light"])
    }

    @Test("New preferences follow the system and use the cobalt accent")
    func newPreferenceDefaults() {
        let appearance = AppPreferences.default.appearance
        #expect(appearance.mode == .system)
        #expect(appearance.accent == .dodger)
        #expect(StenoAccentStyle.dodger.title == "Cobalt")
        #expect(StenoAccentStyle.dodger.rawValue == "dodger")
    }

    @Test("A saved accent decodes to itself in the current and the 1.0.0 decoders", arguments: [
        ("citron", StenoAccentStyle.citron), ("terracotta", .terracotta), ("dodger", .dodger),
        ("cyan", .cyan), ("violet", .violet), ("emerald", .emerald), ("rose", .rose),
    ])
    func savedAccentDecodes(raw: String, expected: StenoAccentStyle) throws {
        let data = Data(#"{"accent":"\#(raw)","mode":"light"}"#.utf8)
        let current = try JSONDecoder().decode(AppPreferences.Appearance.self, from: data)
        let released = try JSONDecoder().decode(Released100Preferences.Preferences.Appearance.self, from: data)
        #expect(current.accent == expected)
        #expect(current.mode == .light)
        #expect(released.accent.rawValue == raw)
    }

    @Test("A saved appearance mode decodes to itself", arguments: [
        ("system", StenoAppearanceMode.system), ("dark", .dark), ("light", .light),
    ])
    func savedModeDecodes(raw: String, expected: StenoAppearanceMode) throws {
        let data = Data(#"{"mode":"\#(raw)"}"#.utf8)
        #expect(try JSONDecoder().decode(AppPreferences.Appearance.self, from: data).mode == expected)
        #expect(try JSONDecoder().decode(Released100Preferences.Preferences.Appearance.self, from: data).mode.rawValue == raw)
    }

    @Test("Missing keys keep the 1.0 fallbacks: dark and the original blue accent")
    func missingKeys() throws {
        let empty = Data("{}".utf8)
        let current = try JSONDecoder().decode(AppPreferences.Appearance.self, from: empty)
        let released = try JSONDecoder().decode(Released100Preferences.Preferences.Appearance.self, from: empty)
        #expect(current.mode == .dark)
        #expect(current.accent == .dodger)
        #expect(released.mode == .dark)
        #expect(released.accent == .dodger)

        let withoutAppearance = try JSONDecoder().decode(AppPreferences.self, from: empty)
        #expect(withoutAppearance.appearance == .legacy)
        #expect(withoutAppearance.appearance.mode == .dark)
        #expect(withoutAppearance.appearance.accent == .dodger)
    }

    @Test("Unknown values fall back to dark and citron as in 1.0")
    func unknownValues() throws {
        let data = Data(#"{"accent":"aurora","mode":"dim","atmosphereIntensity":40}"#.utf8)
        let current = try JSONDecoder().decode(AppPreferences.Appearance.self, from: data)
        #expect(current.accent == .citron)
        #expect(current.mode == .dark)
        #expect(current.atmosphereIntensity == 40)
    }

    @Test("Explicit choices round-trip unchanged", arguments: StenoAppearanceMode.allCases, StenoAccentStyle.allCases)
    func explicitChoicesRoundTrip(mode: StenoAppearanceMode, accent: StenoAccentStyle) throws {
        let saved = AppPreferences.Appearance(mode: mode, accent: accent)
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(AppPreferences.Appearance.self, from: data) == saved)
        let released = try JSONDecoder().decode(Released100Preferences.Preferences.Appearance.self, from: data)
        #expect(released.mode.rawValue == mode.rawValue)
        #expect(released.accent.rawValue == accent.rawValue)
    }

    @Test("Release 1.0.0 reads new default preferences written by this version")
    func releasedDecoderReadsNewDefaults() throws {
        let data = try JSONEncoder().encode(AppPreferences.default)
        let released = try JSONDecoder().decode(Released100Preferences.Preferences.self, from: data)
        #expect(released.appearance.mode == .system)
        #expect(released.appearance.accent == .dodger)
        let reloaded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(reloaded.appearance == AppPreferences.default.appearance)
    }
}
