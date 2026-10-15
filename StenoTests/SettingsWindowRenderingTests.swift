import AppKit
import SwiftUI
import Testing
@testable import Steno
@testable import StenoKit

/// Renders the Settings window, onboarding and the status icons to PNG with sample data.
/// Output goes to `STENO_UI_RENDER_OUTPUT/settings-window` (and `onboarding`, `menu-bar`).
@Suite("Settings, onboarding and menu bar renders", .serialized)
@MainActor
struct SettingsWindowRenderingTests {
    enum Variant: String, CaseIterable, Sendable {
        case light, dark, accessible

        var scheme: ColorScheme { self == .dark ? .dark : .light }
    }

    static let windowSize = CGSize(width: 860, height: 760)

    private func directory(_ name: String) throws -> URL {
        let root = ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering", isDirectory: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func makeController(_ variant: Variant, populated: Bool = true) -> DictationController {
        let controller = IsolatedAppPreview.makeController(populated: populated)
        controller.preferences.appearance.mode = variant.scheme == .light ? .light : .dark
        controller.previewWhisperModelOptions = [
            WhisperModelOption(modelID: .smallEn, source: .bundled, path: nil, isInstalled: true, isActive: true, isRecommended: false),
            WhisperModelOption(modelID: .mediumEn, source: nil, path: nil, isInstalled: false, isActive: false, isRecommended: true),
            WhisperModelOption(modelID: .largeV3Turbo, source: nil, path: nil, isInstalled: false, isActive: false, isRecommended: false)
        ]
        controller.preferences.lexiconEntries = [
            LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global, aliases: ["steno", "stenno"]),
            LexiconEntry(term: "Dana", preferred: "Danna", scope: .global),
            LexiconEntry(term: "sequel", preferred: "SQL", scope: .app(bundleID: "com.apple.Terminal")),
        ]
        controller.preferences.snippets = [
            Snippet(trigger: "brb", expansion: "I’ll be right back.", scope: .global),
            Snippet(trigger: "my address", expansion: "41 Harbour Street, Apt 3\nPortland, ME 04101", scope: .global),
            Snippet(trigger: "sign off", expansion: "Kind regards,\nSam", scope: .app(bundleID: "com.apple.mail")),
        ]
        var mail = controller.preferences.globalStyleProfile
        mail.structureMode = .paragraph
        var notes = controller.preferences.globalStyleProfile
        notes.structureMode = .bullets
        notes.fillerPolicy = .minimal
        controller.preferences.appStyleProfiles = ["com.apple.mail": mail, "com.apple.Notes": notes]
        return controller
    }

    func session(
        for controller: DictationController,
        section: SettingsSection,
        edit: ((inout AppPreferences) -> Void)? = nil,
        microphone: MicrophoneTestModel = .preview(devices: SettingsPreviewData.devices, testingAt: nil)
    ) -> SettingsSession {
        var draft = SettingsDraftState(saved: controller.preferences)
        if let edit {
            var edited = controller.preferences
            edit(&edited)
            draft.edit(edited)
        }
        return SettingsSession(previewDraft: draft, section: section, microphone: microphone)
    }

    private func render<V: View>(
        _ view: V, controller: DictationController?, variant: Variant, size: CGSize
    ) async throws -> Data {
        let themed = view
            .environment(\.colorScheme, variant.scheme)
            .environment(\._colorSchemeContrast, variant == .accessible ? .increased : .standard)
            .environment(\.dynamicTypeSize, variant == .accessible ? .xxxLarge : .large)
            .environment(\.systemTextSize, SystemTextSize(read: { SystemTextSize.baselineBodyPointSize }))
            .environment(\._accessibilityReduceMotion, true)
            .environment(\.controlActiveState, .active)
            .frame(width: size.width, height: size.height)
        let content: AnyView = controller.map { AnyView(themed.environmentObject($0)) } ?? AnyView(themed)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: variant.scheme == .light ? .aqua : .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 8_000)
        return data
    }

    // MARK: Settings

    @Test("Every Settings section renders in light and dark", arguments: SettingsSection.allCases)
    func everySection(section: SettingsSection) async throws {
        AppFontRegistry.registerIfNeeded()
        for variant in [Variant.light, .dark] {
            let controller = makeController(variant)
            let size = CGSize(width: Self.windowSize.width, height: section == .engine ? 900 : Self.windowSize.height)
            let data = try await render(
                SettingsView(session: session(for: controller, section: section)),
                controller: controller, variant: variant, size: size
            )
            try data.write(to: directory("settings-window").appendingPathComponent("\(section.rawValue)-\(variant.rawValue).png"))
            await controller.teardownAndWait()
        }
    }

    @Test("Recording, Permissions and Appearance render with Increase Contrast and larger text",
          arguments: [SettingsSection.recording, .permissions, .appearance])
    func accessibleSections(section: SettingsSection) async throws {
        AppFontRegistry.registerIfNeeded()
        let controller = makeController(.accessible)
        let data = try await render(
            SettingsView(session: session(for: controller, section: section)),
            controller: controller, variant: .accessible, size: CGSize(width: 860, height: 1_000)
        )
        try data.write(to: directory("settings-window").appendingPathComponent("\(section.rawValue)-accessible.png"))
        await controller.teardownAndWait()
    }

    @Test("Draft bar states: pending, saved, failed, external conflict and model conflict")
    func draftBarStates() async throws {
        AppFontRegistry.registerIfNeeded()
        for variant in [Variant.light, .dark] {
            for state in ["pending", "pending-three", "saved", "failed", "conflict", "model-conflict"] {
                let controller = makeController(variant)
                let session = session(for: controller, section: .recording) { preferences in
                    preferences.hotkeys.handsFreeGlobalKeyCode = 64
                    if state == "pending-three" {
                        preferences.dictation.showLiveTranscriptWhileRecording = true
                        preferences.media.pauseDuringHandsFree = false
                    }
                }
                switch state {
                case "saved":
                    session.discard(controller: controller)
                    session.showPreviewSaveNotice(.saved)
                case "failed":
                    controller.settingsSaveError = "The settings file couldn’t be written."
                case "conflict":
                    var external = controller.preferences
                    external.dictation.threadCount += 1
                    controller.preferences = external
                    session.reconcile(external)
                case "model-conflict":
                    var external = controller.preferences
                    external.dictation.updateModelPath("/preview/ggml-medium.en.bin")
                    controller.preferences = external
                    session.reconcile(external)
                default: break
                }
                let data = try await render(SettingsView(session: session), controller: controller, variant: variant, size: Self.windowSize)
                try data.write(to: directory("settings-window").appendingPathComponent("draft-\(state)-\(variant.rawValue).png"))
                await controller.teardownAndWait()
            }
        }
    }

    @Test("Sidebar search lists matching rows, and says when nothing matches")
    func search() async throws {
        AppFontRegistry.registerIfNeeded()
        for (query, name) in [("pause", "results"), ("microphone", "results-microphone"), ("zebra", "no-results")] {
            let controller = makeController(.light)
            let session = session(for: controller, section: .media)
            session.searchText = query
            let data = try await render(SettingsView(session: session), controller: controller, variant: .light, size: Self.windowSize)
            try data.write(to: directory("settings-window").appendingPathComponent("search-\(name)-light.png"))
            await controller.teardownAndWait()
        }
    }

    @Test("Microphone test, model download states, media on old macOS and accents")
    func pageStates() async throws {
        AppFontRegistry.registerIfNeeded()
        for variant in [Variant.light, .dark] {
            let controller = makeController(variant)
            let testing = MicrophoneTestModel.preview(devices: SettingsPreviewData.devices, testingAt: 0.58)
            var data = try await render(
                SettingsView(session: session(for: controller, section: .microphone, edit: { $0.inputDeviceID = "builtin" }, microphone: testing)),
                controller: controller, variant: variant, size: Self.windowSize
            )
            try data.write(to: directory("settings-window").appendingPathComponent("microphone-testing-\(variant.rawValue).png"))

            data = try await render(
                SettingsView(session: session(for: controller, section: .cleanup, edit: { $0.globalStyleProfile.commandPolicy = .passthrough })),
                controller: controller, variant: variant, size: Self.windowSize
            )
            try data.write(to: directory("settings-window").appendingPathComponent("cleanup-commands-changed-\(variant.rawValue).png"))

            controller.activeModelDownloadID = .mediumEn
            data = try await render(SettingsView(session: session(for: controller, section: .engine)), controller: controller, variant: variant, size: CGSize(width: 860, height: 900))
            try data.write(to: directory("settings-window").appendingPathComponent("engine-downloading-\(variant.rawValue).png"))

            controller.activeModelDownloadID = nil
            controller.modelDownloadMessage = DictationController.modelDownloadFailureMessage(
                for: .mediumEn, error: URLError(.notConnectedToInternet)
            )
            controller.modelDownloadMessageIsError = true
            data = try await render(SettingsView(session: session(for: controller, section: .engine)), controller: controller, variant: variant, size: CGSize(width: 860, height: 900))
            try data.write(to: directory("settings-window").appendingPathComponent("engine-failed-\(variant.rawValue).png"))

            data = try await render(
                ScrollView { MediaSettingsSection(preferences: .constant(controller.preferences), isMediaPausingSupported: false).padding(34) }
                    .background(QuillTheme.resolve(accent: .dodger, scheme: variant.scheme, increaseContrast: false).ground),
                controller: controller, variant: variant, size: CGSize(width: 646, height: 420)
            )
            try data.write(to: directory("settings-window").appendingPathComponent("media-unsupported-\(variant.rawValue).png"))

            controller.permissionPreview(microphone: .granted, accessibility: .denied, inputMonitoring: .unknown)
            data = try await render(SettingsView(session: session(for: controller, section: .permissions)), controller: controller, variant: variant, size: Self.windowSize)
            try data.write(to: directory("settings-window").appendingPathComponent("permissions-mixed-\(variant.rawValue).png"))

            controller.launchAtLoginNeedsApproval = true
            controller.launchAtLoginWarning = "macOS needs your approval. Turn on Steno in Login Items."
            data = try await render(SettingsView(session: session(for: controller, section: .general)), controller: controller, variant: variant, size: Self.windowSize)
            try data.write(to: directory("settings-window").appendingPathComponent("general-approval-\(variant.rawValue).png"))
            await controller.teardownAndWait()
        }
        for accent in [StenoAccentStyle.citron, .rose] {
            for variant in [Variant.light, .dark] {
                let controller = makeController(variant)
                controller.preferences.appearance.accent = accent
                let data = try await render(
                    SettingsView(session: session(for: controller, section: .appearance)),
                    controller: controller, variant: variant, size: Self.windowSize
                )
                try data.write(to: directory("settings-window").appendingPathComponent("appearance-\(accent.rawValue)-\(variant.rawValue).png"))
                await controller.teardownAndWait()
            }
        }
    }

    // MARK: Onboarding

    @Test("Onboarding steps, first-dictation states and done")
    func onboarding() async throws {
        AppFontRegistry.registerIfNeeded()
        let size = CGSize(width: 940, height: 640)
        let cases: [(String, Int, (DictationController) -> Void, TranscriptEntry?)] = [
            ("1-welcome", 0, { _ in }, nil),
            ("2-permissions", 1, { $0.permissionPreview(microphone: .granted, accessibility: .denied, inputMonitoring: .denied) }, nil),
            ("3-first-dictation", 2, { _ in }, nil),
            ("3-listening", 2, { $0.stageIsolatedPreviewLifecycle(.recordingPressToTalk) }, nil),
            ("3-no-speech", 2, { $0.status = "No speech detected." }, nil),
            ("3-microphone-off", 2, { $0.microphonePermissionStatus = .denied }, nil),
            ("4-done", 2, { _ in }, SettingsPreviewData.firstDictation),
        ]
        for variant in Variant.allCases {
            for (name, step, stage, entry) in cases {
                if variant == .accessible, !["2-permissions", "4-done"].contains(name) { continue }
                let controller = makeController(variant, populated: false)
                stage(controller)
                let data = try await render(
                    OnboardingView(initialStep: step, previewFirstDictation: entry, previewTriedDictation: name == "3-no-speech"),
                    controller: controller, variant: variant, size: size
                )
                try data.write(to: directory("onboarding").appendingPathComponent("\(name)-\(variant.rawValue).png"))
                await controller.teardownAndWait()
            }
        }
    }

    // MARK: Menu bar

    @Test("The status icon frames")
    func menuBar() async throws {
        let images = [MenuBarIcon.idle, MenuBarIcon.attention] + MenuBarIcon.recordingFrames + [MenuBarIcon.transcribing]
        let scale: CGFloat = 4
        let cell = CGSize(width: 40, height: 26)
        for dark in [false, true] {
            let width = Int(cell.width * CGFloat(images.count) * scale)
            let height = Int(cell.height * scale)
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            rep.size = CGSize(width: cell.width * CGFloat(images.count), height: cell.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            CGRect(origin: .zero, size: rep.size).fill()
            for (index, image) in images.enumerated() {
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    (dark ? NSColor.white : NSColor.black).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let origin = CGPoint(x: CGFloat(index) * cell.width + (cell.width - image.size.width) / 2, y: (cell.height - image.size.height) / 2)
                tinted.draw(in: CGRect(origin: origin, size: image.size))
            }
            NSGraphicsContext.restoreGraphicsState()
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: directory("menu-bar").appendingPathComponent("icons-\(dark ? "dark" : "light").png"))
            #expect(data.count > 2_000)
        }
    }
}

/// Sample content for the Settings and onboarding renders.
@MainActor
enum SettingsPreviewData {
    static let devices = [
        InputDeviceOption(id: "builtin", name: "MacBook Pro Microphone", isDefault: true),
        InputDeviceOption(id: "usb", name: "USB Audio Interface", isDefault: false),
    ]

    static var firstDictation: TranscriptEntry {
        TranscriptEntry(
            createdAt: Date(timeIntervalSince1970: 1_791_196_260),
            appBundleID: "io.stenoapp.steno", rawText: "Testing one two three. This is my first dictation.",
            cleanText: "Testing one two three. This is my first dictation.",
            durationMS: 3_200, audioURL: nil, insertionStatus: .copiedOnly
        )
    }
}

extension DictationController {
    func permissionPreview(
        microphone: PermissionDiagnostics.AccessStatus,
        accessibility: PermissionDiagnostics.AccessStatus,
        inputMonitoring: PermissionDiagnostics.AccessStatus
    ) {
        microphonePermissionStatus = microphone
        accessibilityPermissionStatus = accessibility
        inputMonitoringPermissionStatus = inputMonitoring
    }
}
