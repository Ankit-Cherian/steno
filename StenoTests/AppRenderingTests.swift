import AppKit
import SwiftUI
import Testing
@testable import Steno
@testable import StenoKit

@Suite("Isolated app interface", .serialized)
@MainActor
struct AppRenderingTests {
    @Test("Preview actions preserve synthetic state and never create persistent storage")
    func previewActionsAreIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StenoIsolation-\(UUID().uuidString)")
        let controller = IsolatedAppPreview.makeController(storageDirectory: directory)
        let entries = controller.recentEntries
        await controller.bootstrap()
        controller.pressToTalkStart()
        controller.toggleHandsFree()
        controller.requestMicrophonePermission()
        controller.requestAccessibilityPermission()
        controller.requestInputMonitoringPermission()
        controller.downloadWhisperModel(.smallEn)
        controller.copyEntry(entries[0])
        controller.pasteEntry(entries[0])
        controller.deleteEntry(entries[0])
        controller.retryCleanup(for: entries[0])
        var preferences = controller.preferences
        preferences.general.launchAtLoginEnabled = true
        controller.applySettingsDraft(preferences: preferences)
        controller.saveAppearance(preferences.appearance)
        await controller.refreshHistory()
        await controller.refreshUsageAnalytics()
        #expect(controller.isIsolatedPreview)
        #expect(!controller.isRecording)
        #expect(controller.activeModelDownloadID == nil)
        #expect(controller.recentEntries == entries)
        #expect(controller.microphonePermissionStatus == .granted)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await controller.teardownAndWait()
    }

    @Test("Production views render with synthetic content across window and accessibility states")
    func renderMatrix() async throws {
        typealias Harness = GroveRenderHarness
        let root = ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering", isDirectory: true)
        let pngs = root.appendingPathComponent("render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: pngs, withIntermediateDirectories: true)
        var receipt = ["surface,appearance,width,height,populated,accessibility,png_bytes"]
        func write(_ data: Data, _ name: String, _ variant: Harness.Variant, _ size: CGSize, populated: Bool, accessible: Bool) throws {
            #expect(data.count > 8_000, "\(name)")
            try data.write(to: pngs.appendingPathComponent(name + ".png"))
            receipt.append("\(name),\(variant.scheme),\(size.width),\(size.height),\(populated),\(accessible),\(data.count)")
        }
        let sizes: [(String, CGSize)] = [
            ("minimum", CGSize(width: MainWindowMetrics.minWidth, height: MainWindowMetrics.minHeight)),
            ("default", CGSize(width: MainWindowMetrics.idealWidth, height: MainWindowMetrics.idealHeight)),
            ("large", CGSize(width: 1440, height: 1000)),
        ]
        let minimum = sizes[0].1
        let settingsSize = GroveSettingsRenderingTests.windowSize
        let settingsBase = SettingsWindowRenderingTests()

        for variant in [Harness.Variant.light, .dark] {
            for populated in [false, true] {
                let controller = Harness.sampleController(variant, populated: populated)
                for (sizeName, size) in sizes {
                    for tab in StenoTab.allCases {
                        let name = "\(tab.rawValue.lowercased())-\(variant.scheme)-\(populated ? "populated" : "empty")-\(sizeName)"
                        let data = try await Harness.render(ContentView(initialTab: tab), controller: controller, variant: variant, size: size)
                        try write(data, name, variant, size, populated: populated, accessible: false)
                    }
                }
                await controller.teardownAndWait()
            }

            // Settings at the largest window text and Increase Contrast.
            let accessible: Harness.Variant = variant == .light ? .contrast : .contrastDark
            for section in SettingsSection.allCases {
                let controller = settingsBase.makeController(variant == .light ? .light : .dark)
                let view = SettingsView(session: settingsBase.session(for: controller, section: section))
                    .environment(\.controlActiveState, .active)
                let data = try await Harness.render(view, controller: controller, variant: accessible, size: settingsSize, textSize: .xxxLarge)
                try write(data, "settings-\(section.rawValue)-\(variant.scheme)-accessible", variant, settingsSize, populated: true, accessible: true)
                await controller.teardownAndWait()
            }

            for (name, step, entry) in [("welcome", 0, nil), ("permissions", 1, nil), ("first-dictation", 2, nil),
                                         ("done", 2, SettingsPreviewData.firstDictation)] as [(String, Int, TranscriptEntry?)] {
                let controller = settingsBase.makeController(variant == .light ? .light : .dark, populated: false)
                if step == 1 { controller.permissionPreview(microphone: .granted, accessibility: .denied, inputMonitoring: .denied) }
                let view = OnboardingView(initialStep: step, previewFirstDictation: entry)
                let data = try await Harness.render(view, controller: controller, variant: variant, size: minimum)
                try write(data, "setup-\(name)-\(variant.scheme)", variant, minimum, populated: false, accessible: false)
                await controller.teardownAndWait()
            }

            for state in ["insights-loading", "insights-error", "history-long", "permissions-denied", "inactive-window"] {
                let controller = Harness.sampleController(variant, populated: state == "history-long" || state == "inactive-window")
                let view: AnyView
                var size = minimum
                switch state {
                case "insights-loading":
                    controller.isLoadingUsageAnalytics = true
                    view = AnyView(ContentView(initialTab: .insights))
                case "insights-error":
                    controller.usageAnalyticsError = "The local activity file could not be read. Try again."
                    view = AnyView(ContentView(initialTab: .insights))
                case "history-long":
                    view = AnyView(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.latestID)))
                case "permissions-denied":
                    controller.permissionPreview(microphone: .denied, accessibility: .denied, inputMonitoring: .denied)
                    size = settingsSize
                    view = AnyView(SettingsView(session: settingsBase.session(for: controller, section: .permissions))
                        .environment(\.controlActiveState, .active))
                default:
                    view = AnyView(ContentView().environment(\.controlActiveState, .inactive))
                }
                let data = try await Harness.render(view, controller: controller, variant: variant, size: size)
                try write(data, "\(state)-\(variant.scheme)", variant, size, populated: true, accessible: false)
                await controller.teardownAndWait()
            }
        }
        try receipt.joined(separator: "\n").write(to: root.appendingPathComponent("render-matrix.csv"), atomically: true, encoding: .utf8)
        // 1 header + 2 appearances × (2 fills × 3 sizes × 3 tabs + 11 Settings sections + 4 setup steps + 5 states).
        #expect(receipt.count == 77)
    }

    @Test("Recording overlay renders every outcome and bounded long previews offscreen")
    func overlayRenderMatrix() throws {
        let root = ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let states: [(String, OverlayState)] = [
            ("listening", .listening(handsFree: false, elapsedSeconds: 12)),
            ("hands-free", .listening(handsFree: true, elapsedSeconds: 130)),
            ("finishing", .transcribing), ("inserted", .inserted),
            ("copied", .copiedOnly), ("silence", .noSpeechDetected),
            ("failure", .failure(message: "The document closed. Your words are ready to copy.")),
            ("vad-failure", .failure(message: RetainedWhisperRuntimeError.vadIntegrityFailure.localizedDescription))
        ]
        for (name, state) in states {
            let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
            presenter.appearance = .grove
            let data = try #require(presenter.hostedEvidenceRenderPNG(state: state))
            try data.write(to: root.appendingPathComponent("overlay-\(name).png"))
            #expect(data.count > 500)
        }
        for pointSize in [13.0, 22.0] {
            let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
            presenter.appearance = .grove
            presenter.setHostedAccessibilityPreferences(OverlayAccessibilityPreferences(
                reduceMotion: true, reduceTransparency: true, increaseContrast: true,
                preferredBodyPointSize: pointSize))
            presenter.setLiveTranscriptEnabled(true)
            var renderedTranscript = ""
            presenter.setHostedEvidenceHandler { [weak presenter] event in
                if case .previewRendered = event {
                    renderedTranscript = presenter?.hostedEvidenceVisibleTranscript() ?? ""
                }
            }
            let snapshot = LiveTranscriptionSnapshot(session: LiveTranscriptionSession(
                sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1,
                runtimeIdentity: .pending),
                stablePrefix: "Keep the exact date and do not change the meaning. ",
                revisableTail: String(repeating: "A longer thought flows across the available width with room for natural pauses. ", count: 12),
                lastAcceptedRevision: 1, decodedAudioWatermark: 16_000)
            let data = try #require(presenter.hostedEvidenceRenderPNG(
                state: .listening(handsFree: true, elapsedSeconds: 90), snapshot: snapshot))
            try data.write(to: root.appendingPathComponent("overlay-long-accessible-\(Int(pointSize)).png"))
            #expect(renderedTranscript.contains("natural pauses."))
            #expect(data.count > 500)
            presenter.setHostedEvidenceHandler(nil)
        }
    }

    @Test("Focused text, settings, and permission states render at minimum accessible size")
    func renderFocusedPolishStates() async throws {
        AppFontRegistry.registerIfNeeded()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering").path)
            .appendingPathComponent("focused-polish", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let size = CGSize(width: MainWindowMetrics.minWidth, height: MainWindowMetrics.minHeight)
        var receipt = ["surface,appearance,width,height,accessibility,png_bytes"]
        let transcripts = [
            ("short", "Keep this sentence."),
            ("medium", "Please send the revised agenda on Thursday. Keep the launch date at September 18, and leave enough time for the accessibility review before the team meets."),
            ("long", String(repeating: "Take the path along the river, turn left at the bridge, and meet outside the cafe after the walk. ", count: 18))
        ]

        for appearance in [ColorScheme.light, .dark] {
            for (length, text) in transcripts {
                let controller = IsolatedAppPreview.makeController(populated: false)
                controller.preferences.appearance.mode = appearance == .light ? .light : .dark
                controller.recentEntries = [TranscriptEntry(createdAt: Date(timeIntervalSince1970: 1_783_000_000),
                    appBundleID: "com.example.preview", rawText: text, cleanText: text,
                    durationMS: 12_000, audioURL: nil, insertionStatus: .inserted)]
                let name = "record-\(length)-\(appearance)-minimum-accessible"
                let data = try await render(ContentView(), controller: controller,
                    appearance: appearance, size: size, accessibility: true)
                try data.write(to: root.appendingPathComponent(name + ".png"))
                receipt.append("\(name),\(appearance),\(size.width),\(size.height),true,\(data.count)")
                #expect(controller.recentEntries.first?.cleanText == text)
                await controller.teardownAndWait()
            }

            for state in ["clean", "dirty", "conflict"] {
                let controller = IsolatedAppPreview.makeController(populated: false)
                controller.preferences.appearance.mode = appearance == .light ? .light : .dark
                let savedPreferences = controller.preferences
                var draftState = SettingsDraftState(saved: savedPreferences)
                if state != "clean" {
                    var editedPreferences = savedPreferences
                    editedPreferences.hotkeys.optionPressToTalkEnabled.toggle()
                    draftState.edit(editedPreferences)
                    #expect(controller.preferences == savedPreferences)
                }
                if state == "conflict" {
                    controller.preferences.dictation.threadCount = savedPreferences.dictation.threadCount + 1
                    draftState.reconcile(controller.preferences)
                }
                #expect(draftState.hasConflictingUpdate == (state == "conflict"))
                #expect((draftState.preferences != controller.preferences) == (state != "clean"))
                #expect((!draftState.hasConflictingUpdate && draftState.preferences != controller.preferences) == (state == "dirty"))
                let name = "settings-\(state)-\(appearance)-minimum-accessible"
                let data = try await render(SettingsView(previewDraftState: draftState),
                    controller: controller, appearance: appearance, size: size, accessibility: true)
                try data.write(to: root.appendingPathComponent(name + ".png"))
                receipt.append("\(name),\(appearance),\(size.width),\(size.height),true,\(data.count)")
                await controller.teardownAndWait()
            }

            let controller = IsolatedAppPreview.makeController(populated: false)
            controller.preferences.appearance.mode = appearance == .light ? .light : .dark
            controller.microphonePermissionStatus = .unknown
            controller.accessibilityPermissionStatus = .unknown
            controller.inputMonitoringPermissionStatus = .unknown
            let name = "permissions-unknown-\(appearance)-minimum-accessible"
            let data = try await render(settingsPage(.permissions, controller: controller),
                controller: controller, appearance: appearance, size: size, accessibility: true)
            try data.write(to: root.appendingPathComponent(name + ".png"))
            receipt.append("\(name),\(appearance),\(size.width),\(size.height),true,\(data.count)")
            #expect(controller.microphonePermissionStatus == .unknown)
            #expect(controller.accessibilityPermissionStatus == .unknown)
            #expect(controller.inputMonitoringPermissionStatus == .unknown)
            await controller.teardownAndWait()
        }
        #expect(receipt.count == 15)
        try receipt.joined(separator: "\n").write(to: root.appendingPathComponent("focused-polish.csv"), atomically: true, encoding: .utf8)
    }

    /// Settings left the main window; its pages render on their own.
    private func settingsPage(_ section: SettingsSection, controller: DictationController) -> some View {
        let session = SettingsSession(
            previewDraft: SettingsDraftState(saved: controller.preferences),
            section: section,
            microphone: .preview(devices: SettingsPreviewData.devices, testingAt: nil)
        )
        return SettingsView(session: session)
    }

    func render<V: View>(
        _ view: V, controller: DictationController, appearance: ColorScheme,
        size: CGSize, accessibility: Bool, active: Bool = true
    ) async throws -> Data {
        // These SDK-declared test setters override the otherwise read-only accessibility
        // environment without changing the user's system preferences.
        let content = view.environmentObject(controller)
            .environment(\.colorScheme, appearance)
            .environment(\.controlActiveState, active ? .active : .inactive)
            .environment(\._accessibilityReduceMotion, true)
            .environment(\._accessibilityReduceTransparency, accessibility)
            .environment(\._colorSchemeContrast, accessibility ? .increased : .standard)
            .environment(\.sizeCategory, accessibility ? .accessibilityExtraExtraExtraLarge : .large)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Allow production onAppear/task state to settle without ordering a window onscreen.
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        #expect(!window.isKeyWindow)
        #expect(!window.isVisible)
        #expect(hosting.bounds.width == size.width)
        #expect(hosting.bounds.height == size.height)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(size.height))
        // Empty or failed view trees compress to a tiny solid rectangle.
        #expect(data.count > 8_000)
        return data
    }
}
