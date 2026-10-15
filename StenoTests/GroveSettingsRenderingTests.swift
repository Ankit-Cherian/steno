import AppKit
import SwiftUI
import Testing
@testable import Steno
@testable import StenoKit

/// Renders the quiet Settings window: every pane in light and dark, Increase Contrast for a few,
/// the drafts bar in each state and the states a pane can be in. Output goes to
/// `STENO_UI_RENDER_OUTPUT/grove/settings`.
@Suite("Grove Settings renders", .serialized)
@MainActor
struct GroveSettingsRenderingTests {
    typealias Variant = GroveRenderHarness.Variant

    static let windowSize = CGSize(width: 860, height: 680)
    /// The size of the window in the lab's renders, for side-by-side comparison.
    static let labSize = CGSize(width: 804, height: 584)

    private let base = SettingsWindowRenderingTests()

    private func directory() throws -> URL {
        let directory = try GroveRenderHarness.outputDirectory.appendingPathComponent("settings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func controller(_ variant: Variant) -> DictationController {
        base.makeController(variant.scheme == .dark ? .dark : .light)
    }

    private func write<V: View>(
        _ view: V, controller: DictationController, variant: Variant, size: CGSize = windowSize, name: String
    ) async throws {
        // The traffic lights sit over the sidebar panel, as the window draws them.
        let framed = view
            .overlay(alignment: .topLeading) {
                GroveInlineTrafficLights().padding(.leading, 20).padding(.top, 20)
            }
            .environment(\.controlActiveState, .active)
        let data = try await GroveRenderHarness.render(framed, controller: controller, variant: variant, size: size)
        #expect(data.count > 8_000, "\(name)")
        try data.write(to: directory().appendingPathComponent("\(name)-\(variant.rawValue).png"))
    }

    private func settings(
        _ controller: DictationController, _ section: SettingsSection,
        edit: ((inout AppPreferences) -> Void)? = nil,
        microphone: MicrophoneTestModel = .preview(devices: SettingsPreviewData.devices, testingAt: nil)
    ) -> SettingsView {
        SettingsView(session: base.session(for: controller, section: section, edit: edit, microphone: microphone))
    }

    @Test("Every pane renders in light and dark", arguments: SettingsSection.allCases)
    func everyPane(section: SettingsSection) async throws {
        for variant in [Variant.light, .dark] {
            let controller = controller(variant)
            let size = CGSize(width: Self.windowSize.width, height: section == .engine ? 900 : Self.windowSize.height)
            try await write(settings(controller, section), controller: controller, variant: variant, size: size, name: section.rawValue)
            await controller.teardownAndWait()
        }
    }

    @Test("Recording matches the lab's window size, with the Hands-free key changed")
    func recordingAtLabSize() async throws {
        for variant in [Variant.light, .dark] {
            let controller = controller(variant)
            let view = settings(controller, .recording) { $0.hotkeys.handsFreeGlobalKeyCode = 64 }
            try await write(view, controller: controller, variant: variant, size: Self.labSize, name: "recording-lab")
            await controller.teardownAndWait()
        }
    }

    @Test("Increase Contrast", arguments: [SettingsSection.recording, .engine, .permissions, .appearance])
    func increaseContrast(section: SettingsSection) async throws {
        for variant in [Variant.contrast, .contrastDark] {
            let controller = controller(variant)
            let view = settings(controller, section) { $0.hotkeys.handsFreeGlobalKeyCode = 64 }
            try await write(view, controller: controller, variant: variant, size: CGSize(width: 860, height: 860), name: section.rawValue)
            await controller.teardownAndWait()
        }
    }

    @Test("Drafts bar: clean, pending, saved, failed and both conflicts")
    func draftsBar() async throws {
        for variant in [Variant.light, .dark] {
            for state in ["clean", "pending-three", "saved", "failed", "conflict", "model-conflict"] {
                let controller = controller(variant)
                let session = base.session(for: controller, section: .recording) { preferences in
                    guard state != "clean" else { return }
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
                try await write(SettingsView(session: session), controller: controller, variant: variant, name: "draft-\(state)")
                await controller.teardownAndWait()
            }
        }
    }

    @Test("Sidebar search lists matching rows, and says when nothing matches")
    func search() async throws {
        for (query, name) in [("pause", "results"), ("zebra", "no-results")] {
            let controller = controller(.light)
            let session = base.session(for: controller, section: .media)
            session.searchText = query
            try await write(SettingsView(session: session), controller: controller, variant: .light, name: "search-\(name)")
            await controller.teardownAndWait()
        }
    }

    @Test("Page states: microphone test, downloads, old macOS, permissions, login approval")
    func pageStates() async throws {
        for variant in [Variant.light, .dark] {
            let controller = controller(variant)
            let testing = MicrophoneTestModel.preview(devices: SettingsPreviewData.devices, testingAt: 0.58)
            try await write(
                settings(controller, .microphone, edit: { $0.inputDeviceID = "builtin" }, microphone: testing),
                controller: controller, variant: variant, name: "microphone-testing")

            try await write(
                settings(controller, .cleanup, edit: { $0.globalStyleProfile.commandPolicy = .passthrough }),
                controller: controller, variant: variant, size: CGSize(width: 860, height: 900), name: "cleanup-changed")

            controller.activeModelDownloadID = .mediumEn
            try await write(settings(controller, .engine), controller: controller, variant: variant,
                            size: CGSize(width: 860, height: 900), name: "engine-downloading")

            controller.activeModelDownloadID = nil
            controller.modelDownloadMessage = DictationController.modelDownloadFailureMessage(
                for: .mediumEn, error: URLError(.notConnectedToInternet))
            controller.modelDownloadMessageIsError = true
            try await write(settings(controller, .engine), controller: controller, variant: variant,
                            size: CGSize(width: 860, height: 900), name: "engine-failed")

            controller.permissionPreview(microphone: .granted, accessibility: .denied, inputMonitoring: .unknown)
            try await write(settings(controller, .permissions), controller: controller, variant: variant, name: "permissions-mixed")

            controller.launchAtLoginNeedsApproval = true
            controller.launchAtLoginWarning = "macOS needs your approval. Turn on Steno in Login Items."
            try await write(settings(controller, .general), controller: controller, variant: variant, name: "general-approval")
            await controller.teardownAndWait()
        }
    }

    @Test("Media on a Mac that can't pause media")
    func mediaUnsupported() async throws {
        for variant in [Variant.light, .dark] {
            let controller = controller(variant)
            let page = ScrollView {
                MediaSettingsSection(preferences: .constant(controller.preferences), isMediaPausingSupported: false)
                    .padding(.horizontal, 36).padding(.top, 52)
            }
            .groveSettingsPage()
            try await write(page, controller: controller, variant: variant, size: CGSize(width: 640, height: 420), name: "media-unsupported")
            await controller.teardownAndWait()
        }
    }

    @Test("The smallest window")
    func smallestWindow() async throws {
        for variant in [Variant.light, .dark] {
            let controller = controller(variant)
            try await write(settings(controller, .recording), controller: controller, variant: variant,
                            size: SettingsWindowRoot.minimumSize, name: "recording-minimum")
            await controller.teardownAndWait()
        }
    }

    @Test("Larger text")
    func largerText() async throws {
        let controller = controller(.light)
        let view = settings(controller, .recording) { $0.hotkeys.handsFreeGlobalKeyCode = 64 }
        let data = try await GroveRenderHarness.render(view, controller: controller, variant: .light,
                                                       size: CGSize(width: 960, height: 900), textSize: .xxxLarge)
        try data.write(to: directory().appendingPathComponent("recording-larger-text-light.png"))
        await controller.teardownAndWait()
    }
}

// MARK: - Onboarding

/// Renders the setup guide in the Quiet design: every step and first-dictation state. Output goes
/// to `STENO_UI_RENDER_OUTPUT/grove/onboarding`.
@Suite("Grove onboarding renders", .serialized)
@MainActor
struct GroveOnboardingRenderingTests {
    typealias Variant = GroveRenderHarness.Variant

    static let size = CGSize(width: 940, height: 640)

    private let base = SettingsWindowRenderingTests()

    private func directory() throws -> URL {
        let directory = try GroveRenderHarness.outputDirectory.appendingPathComponent("onboarding", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The sample first dictation, with the time its record kept.
    static var firstDictation: TranscriptEntry {
        var entry = SettingsPreviewData.firstDictation
        entry.cleanText = "Remind me to call the venue about the deposit before Friday."
        entry.rawText = entry.cleanText
        entry.record = DictationRecord(endToEndMS: 1_100)
        return entry
    }

    private func cases() -> [(String, Int, (DictationController) -> Void, TranscriptEntry?)] {
        [
            ("1-welcome", 0, { _ in }, nil),
            ("2-permissions", 1, { $0.permissionPreview(microphone: .granted, accessibility: .denied, inputMonitoring: .denied) }, nil),
            ("2-permissions-first", 1, { $0.permissionPreview(microphone: .unknown, accessibility: .denied, inputMonitoring: .denied) }, nil),
            ("2-permissions-microphone-denied", 1, { $0.permissionPreview(microphone: .denied, accessibility: .denied, inputMonitoring: .denied) }, nil),
            ("2-permissions-granted", 1, { $0.permissionPreview(microphone: .granted, accessibility: .granted, inputMonitoring: .granted) }, nil),
            ("3-first-dictation", 2, { _ in }, nil),
            ("3-listening", 2, { $0.stageIsolatedPreviewLifecycle(.recordingPressToTalk) }, nil),
            ("3-listening-hands-free", 2, { $0.stageIsolatedPreviewLifecycle(.recordingHandsFree) }, nil),
            ("3-transcribing", 2, { $0.stageIsolatedPreviewLifecycle(.transcribing) }, nil),
            ("3-no-speech", 2, { $0.status = "No speech detected." }, nil),
            ("3-microphone-off", 2, { $0.microphonePermissionStatus = .denied }, nil),
            ("4-done", 2, { _ in }, Self.firstDictation),
            ("4-done-no-time", 2, { _ in }, SettingsPreviewData.firstDictation),
        ]
    }

    @Test("Every step and state, light and dark")
    func everyStep() async throws {
        for variant in [Variant.light, .dark] {
            for (name, step, stage, entry) in cases() {
                let controller = base.makeController(variant.scheme == .dark ? .dark : .light, populated: false)
                stage(controller)
                let view = OnboardingView(initialStep: step, previewFirstDictation: entry, previewTriedDictation: name == "3-no-speech")
                    .overlay(alignment: .topLeading) { GroveInlineTrafficLights().padding(.leading, 20).padding(.top, 20) }
                    .environment(\.controlActiveState, .active)
                let data = try await GroveRenderHarness.render(view, controller: controller, variant: variant, size: Self.size)
                #expect(data.count > 5_000, "\(name)")
                try data.write(to: directory().appendingPathComponent("\(name)-\(variant.rawValue).png"))
                await controller.teardownAndWait()
            }
        }
    }

    @Test("Increase Contrast", arguments: ["2-permissions", "3-first-dictation", "4-done"])
    func increaseContrast(name: String) async throws {
        for variant in [Variant.contrast, .contrastDark] {
            let (_, step, stage, entry) = try #require(cases().first { $0.0 == name })
            let controller = base.makeController(variant.scheme == .dark ? .dark : .light, populated: false)
            stage(controller)
            let data = try await GroveRenderHarness.render(
                OnboardingView(initialStep: step, previewFirstDictation: entry).environment(\.controlActiveState, .active),
                controller: controller, variant: variant, size: Self.size)
            try data.write(to: directory().appendingPathComponent("\(name)-\(variant.rawValue).png"))
            await controller.teardownAndWait()
        }
    }

    @Test("The first dictation names the measured time, and leaves the number out when there is none")
    func measuredTime() {
        #expect(GroveOnboardingFirstDictation.secondsText(for: Self.firstDictation) == "1.1 seconds")
        #expect(GroveOnboardingFirstDictation.secondsText(for: SettingsPreviewData.firstDictation) == nil)
        var slow = Self.firstDictation
        slow.record = DictationRecord(endToEndMS: 12_400)
        #expect(GroveOnboardingFirstDictation.secondsText(for: slow) == "12 seconds")
    }
}

extension View {
    /// A bare page in the quiet design, for a pane drawn without the window around it.
    func groveSettingsPage() -> some View {
        GroveSettingsContent(accent: .dodger) { self }
    }
}

// MARK: - Logic

@Suite("Grove Settings logic")
struct GroveSettingsLogicTests {
    private func field(_ title: String) -> SettingsField {
        SettingsField("x-\(title)", title, in: .recording) { _ in 0 }
    }

    @Test("The drafts bar counts changes and names a few of them")
    func draftsBarWords() {
        #expect(GroveDraftBarStatus.headline(count: 1, fallback: "") == "1 unsaved change")
        #expect(GroveDraftBarStatus.headline(count: 3, fallback: "") == "3 unsaved changes")
        #expect(GroveDraftBarStatus.headline(count: 0, fallback: "Unsaved") == "Unsaved")
        #expect(GroveDraftBarStatus.names([field("Hands-free key")]) == "Hands-free key")
        #expect(GroveDraftBarStatus.names([field("A"), field("B"), field("C")]) == "A, B, C")
        #expect(GroveDraftBarStatus.names([field("A"), field("B"), field("C"), field("D")]) == nil)
        #expect(GroveDraftBarStatus.names([]) == nil)
    }

    @Test("Every pane has a quiet name and symbol, and Recording and Microphone are not swapped")
    func namesAndSymbols() {
        #expect(SettingsSection.recording.groveSymbolName == "waveform")
        #expect(SettingsSection.microphone.groveSymbolName == "mic")
        #expect(SettingsSection.engine.groveTitle == "Speech Model")
        #expect(SettingsSection.corrections.groveTitle == "Word Corrections")
        #expect(Set(SettingsSection.allCases.map(\.groveSymbolName)).count == SettingsSection.allCases.count)
    }
}
