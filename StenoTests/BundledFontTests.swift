import AppKit
import CoreText
import Testing
@testable import Steno

/// Archivo and Azeret Mono ship inside the app and register at launch, for the overlay and the
/// shared text roles; when a family is missing the text roles fall back to the system fonts.
@Suite("Bundled fonts")
@MainActor
struct BundledFontTests {
    @Test("Archivo and Azeret Mono register from the app bundle", arguments: [
        ("ArchivoRoman-Regular", "Archivo", false),
        ("AzeretMonoRoman-Regular", "Azeret Mono", false),
    ])
    func facesRegisterFromBundle(postScriptName: String, family: String, italic: Bool) throws {
        AppFontRegistry.registerIfNeeded()
        let font = try #require(NSFont(name: postScriptName, size: 13))
        #expect(font.fontName == postScriptName)
        #expect(font.familyName == family)
        #expect(font.fontDescriptor.symbolicTraits.contains(.italic) == italic)
        let url = try #require(CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL)
        #expect(url.standardizedFileURL.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path))
    }

    @Test("Only Archivo and Azeret Mono are bundled")
    func onlyTwoFamiliesShip() throws {
        let resources = try #require(Bundle.main.resourceURL)
        let fonts = try FileManager.default.contentsOfDirectory(atPath: resources.path).filter { $0.hasSuffix(".ttf") }.sorted()
        #expect(fonts == ["Archivo.ttf", "AzeretMono.ttf"])
    }

    @Test("Each bundled family ships its licence", arguments: ["Archivo-OFL", "AzeretMono-OFL"])
    func licencesShip(name: String) throws {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("SIL Open Font License, Version 1.1"))
    }

    @Test("Text roles resolve the bundled families at their design weight", arguments: [
        (QuillTypeStyle.title, "Archivo", 640.0),
        (.dictation, "Archivo", 400.0),
        (.mono, "Azeret Mono", 500.0),
    ])
    func rolesResolveBundledFamilies(style: QuillTypeStyle, family: String, weight: Double) {
        AppFontRegistry.registerIfNeeded()
        let font = QuillType.nsFont(style)
        #expect(font.familyName == family)
        let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber] ?? [:]
        #expect(variation[NSNumber(value: 0x7767_6874)]?.doubleValue == weight, "wght axis")
        #expect((variation[NSNumber(value: 0x7764_7468)]?.doubleValue ?? 100) == 100, "normal width")
        #expect(!font.fontDescriptor.symbolicTraits.contains(.italic))
    }

    @Test("A family that is not registered falls back to SF Pro or SF Mono at the nearest weight")
    func unregisteredFamilyFallsBack() {
        let text = QuillType.nsFont(familyName: "Steno Missing Family", monospaced: false, size: 17, weight: 640)
        #expect(text.familyName == NSFont.systemFont(ofSize: 17).familyName)
        #expect(text.pointSize == 17)
        let textWeight = (text.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        #expect(textWeight.map { $0 > NSFont.Weight.semibold.rawValue } == true)

        let mono = QuillType.nsFont(familyName: "Steno Missing Mono", monospaced: true, size: 9, weight: 500)
        #expect(mono.isFixedPitch)
        #expect(mono.familyName == NSFont.monospacedSystemFont(ofSize: 11, weight: .medium).familyName)
        #expect(mono.pointSize == QuillType.minimumMonoSize)
    }
}
