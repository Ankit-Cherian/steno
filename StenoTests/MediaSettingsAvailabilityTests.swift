import AppKit
import SwiftUI
import Testing
@testable import Steno
import StenoKit

@Suite("Media settings availability", .serialized)
@MainActor
struct MediaSettingsAvailabilityTests {
    @Test("Unsupported macOS shows media pausing off and never rewrites the saved choice")
    func unsupportedSystemReadsOffWithoutRewritingPreference() {
        let storage = PreferencesBox(AppPreferences.default)
        #expect(storage.value.media.pauseDuringPressToTalk)
        #expect(storage.value.media.pauseDuringHandsFree)

        let section = MediaSettingsSection(
            preferences: storage.binding,
            isMediaPausingSupported: false
        )

        #expect(!section.pauseDuringPressToTalk.wrappedValue)
        #expect(!section.pauseDuringHandsFree.wrappedValue)
        section.pauseDuringPressToTalk.wrappedValue = false
        section.pauseDuringHandsFree.wrappedValue = false
        #expect(storage.value.media.pauseDuringPressToTalk)
        #expect(storage.value.media.pauseDuringHandsFree)
        #expect(section.captionText.contains("macOS 15"))
    }

    @Test("Supported macOS edits the saved media pausing choice directly")
    func supportedSystemEditsPreference() {
        let storage = PreferencesBox(AppPreferences.default)
        let section = MediaSettingsSection(
            preferences: storage.binding,
            isMediaPausingSupported: true
        )

        #expect(section.pauseDuringPressToTalk.wrappedValue)
        section.pauseDuringPressToTalk.wrappedValue = false
        section.pauseDuringHandsFree.wrappedValue = false
        #expect(!storage.value.media.pauseDuringPressToTalk)
        #expect(!storage.value.media.pauseDuringHandsFree)
        #expect(!section.captionText.contains("macOS 15"))
    }

    @Test("The media caption says that only playing media is paused and resumed")
    func captionMatchesResumeBehavior() {
        let storage = PreferencesBox(AppPreferences.default)
        let section = MediaSettingsSection(
            preferences: storage.binding,
            isMediaPausingSupported: true
        )

        // An app is paused only when it is confirmed playing, so media paused
        // by hand, even moments earlier, is never resumed.
        #expect(section.captionText == "Steno pauses apps that are playing when you start dictating and resumes only those. Media you paused yourself stays paused.")
        #expect(!section.captionText.contains("may resume"))
    }

    @Test("Media settings render in both availability states")
    func mediaSettingsRenderInBothAvailabilityStates() async throws {
        AppFontRegistry.registerIfNeeded()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering").path)
            .appendingPathComponent("media-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousDirection = StenoDesign.reviewDirectionOverride
        defer { StenoDesign.reviewDirectionOverride = previousDirection }
        StenoDesign.reviewDirectionOverride = .manuscript
        let size = CGSize(width: 560, height: 280)

        for supported in [true, false] {
            for appearance in [ColorScheme.light, .dark] {
                let storage = PreferencesBox(AppPreferences.default)
                let theme = StenoDesign.theme(for: storage.value)
                let view = MediaSettingsSection(
                    preferences: storage.binding,
                    isMediaPausingSupported: supported
                )
                .padding(24)
                .foregroundStyle(theme.text)
                .background(theme.ink0)
                .environment(\.colorScheme, appearance)
                .frame(width: size.width, height: size.height)
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua)
                window.contentView = hosting
                hosting.frame = CGRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                window.contentView = nil
                window.close()
                #expect(png.count > 8_000)
                let name = "media-\(supported ? "supported" : "unsupported")-\(appearance).png"
                try png.write(to: root.appendingPathComponent(name))
            }
        }
    }
}

@MainActor
private final class PreferencesBox {
    var value: AppPreferences

    init(_ value: AppPreferences) {
        self.value = value
    }

    var binding: Binding<AppPreferences> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}
