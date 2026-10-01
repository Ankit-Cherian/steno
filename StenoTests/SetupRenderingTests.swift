import AppKit
import SwiftUI
import Testing
@testable import Steno
@testable import StenoKit

/// Renders the setup surfaces changed for model, permission and launch-at-login
/// recovery, with fictional data in an isolated preview controller.
@Suite("Setup surfaces render", .serialized)
@MainActor
struct SetupRenderingTests {
    private var root: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering").path)
            .appendingPathComponent("setup", isDirectory: true)
    }

    private func controller(_ appearance: ColorScheme) -> DictationController {
        let controller = IsolatedAppPreview.makeController(populated: false)
        controller.preferences.appearance.mode = appearance == .light ? .light : .dark
        return controller
    }

    @Test("Speech model page: downloaded model, failed download and setup check")
    func speechModelPage() async throws {
        AppFontRegistry.registerIfNeeded()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for appearance in [ColorScheme.light, .dark] {
            let controller = controller(appearance)
            controller.previewWhisperModelOptions = [
                WhisperModelOption(modelID: .smallEn, source: .bundled, path: nil, isInstalled: true, isActive: false, isRecommended: false),
                WhisperModelOption(modelID: .mediumEn, source: .downloaded, path: nil, isInstalled: true, isActive: true, isRecommended: true),
                WhisperModelOption(modelID: .largeV3Turbo, source: nil, path: nil, isInstalled: false, isActive: false, isRecommended: false)
            ]
            controller.modelDownloadMessage = DictationController.modelDownloadFailureMessage(
                for: .largeV3Turbo,
                error: WhisperModelDownloadError.verificationFailed(.largeV3Turbo)
            )
            controller.modelDownloadMessageIsError = true
            let stages: [WhisperSetupCheckStage] = [
                .init(title: "Microphone access", outcome: .passed, detail: "Allowed."),
                .init(title: "Speech model", outcome: .passed, detail: "ggml-medium.en.bin found."),
                .init(title: "Main engine", outcome: .failed, detail: "Couldn't start or transcribe. Dictation would fall back to the tool."),
                .init(title: "Fallback tool", outcome: .passed, detail: "Loaded the model and transcribed a test clip in 2.4 s.")
            ]
            var preferences = controller.preferences
            let binding = Binding(get: { preferences }, set: { preferences = $0 })
            let theme = StenoDesign.theme(for: controller.preferences)
            let view = ScrollView {
                EngineSettingsSection(preferences: binding, controller: controller, previewSetupCheckStages: stages)
                    .padding(24)
            }
            .foregroundStyle(theme.text).background(theme.ink0)
            let data = try await render(view, controller: controller, appearance: appearance, size: CGSize(width: 760, height: 1_000))
            try data.write(to: root.appendingPathComponent("speech-model-\(appearance).png"))
            await controller.teardownAndWait()
        }
    }

    @Test("General page: launch at login waiting for approval and the setup guide control")
    func generalPage() async throws {
        AppFontRegistry.registerIfNeeded()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for appearance in [ColorScheme.light, .dark] {
            let controller = controller(appearance)
            controller.preferences.general.launchAtLoginEnabled = true
            controller.launchAtLoginNeedsApproval = true
            controller.launchAtLoginWarning = DictationController.launchAtLoginApprovalMessage
            let data = try await render(ContentView(initialTab: .settings, initialSettingsSection: .general),
                controller: controller, appearance: appearance,
                size: CGSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight))
            try data.write(to: root.appendingPathComponent("general-approval-\(appearance).png"))
            await controller.teardownAndWait()
        }
    }

    @Test("Settings footer names a model download as the reason Save is locked")
    func modelConflictFooter() async throws {
        AppFontRegistry.registerIfNeeded()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for appearance in [ColorScheme.light, .dark] {
            let controller = controller(appearance)
            let saved = controller.preferences
            var draftState = SettingsDraftState(saved: saved)
            var edited = saved
            edited.hotkeys.optionPressToTalkEnabled.toggle()
            draftState.edit(edited)
            controller.preferences.dictation.updateModelPath("/preview/ggml-medium.en.bin")
            draftState.reconcile(controller.preferences)
            #expect(draftState.conflictCause == .modelChange)
            let theme = StenoDesign.theme(for: controller.preferences)
            let data = try await render(SettingsView(previewDraftState: draftState).foregroundStyle(theme.text).background(theme.ink0),
                controller: controller, appearance: appearance,
                size: CGSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight))
            try data.write(to: root.appendingPathComponent("settings-model-conflict-\(appearance).png"))
            await controller.teardownAndWait()
        }
    }

    @Test("Onboarding speech model step shows a failed download in the error role")
    func onboardingDownloadFailure() async throws {
        AppFontRegistry.registerIfNeeded()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for appearance in [ColorScheme.light, .dark] {
            let controller = controller(appearance)
            controller.previewWhisperModelOptions = [
                WhisperModelOption(modelID: .smallEn, source: .bundled, path: nil, isInstalled: true, isActive: true, isRecommended: false),
                WhisperModelOption(modelID: .mediumEn, source: nil, path: nil, isInstalled: false, isActive: false, isRecommended: true),
                WhisperModelOption(modelID: .largeV3Turbo, source: nil, path: nil, isInstalled: false, isActive: false, isRecommended: false)
            ]
            controller.modelDownloadMessage = DictationController.modelDownloadFailureMessage(
                for: .mediumEn,
                error: URLError(.notConnectedToInternet, userInfo: [
                    NSLocalizedDescriptionKey: "The Internet connection appears to be offline."
                ])
            )
            controller.modelDownloadMessageIsError = true
            let data = try await render(OnboardingView(initialStep: 2), controller: controller, appearance: appearance,
                size: CGSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight))
            try data.write(to: root.appendingPathComponent("onboarding-download-failed-\(appearance).png"))
            await controller.teardownAndWait()
        }
    }

    private func render<V: View>(_ view: V, controller: DictationController, appearance: ColorScheme, size: CGSize) async throws -> Data {
        let content = view.environmentObject(controller)
            .environment(\.colorScheme, appearance)
            .environment(\.controlActiveState, .active)
            .environment(\._accessibilityReduceMotion, true)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 8_000)
        return data
    }
}
