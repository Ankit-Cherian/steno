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
        controller.pasteLastTranscript()
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
        AppFontRegistry.registerIfNeeded()
        let root = ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var receipt: [String] = ["surface,appearance,width,height,populated,accessibility,png_bytes"]
        let sizes: [(String, CGSize)] = [
            ("minimum", CGSize(width: StenoDesign.windowMinWidth, height: StenoDesign.windowMinHeight)),
            ("default", CGSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight)),
            ("large", CGSize(width: 1440, height: 1000))
        ]
        let previousDirection = StenoDesign.reviewDirectionOverride
        defer { StenoDesign.reviewDirectionOverride = previousDirection }
        for direction in StenoDesignDirection.allCases {
            StenoDesign.reviewDirectionOverride = direction
            let root = root.appendingPathComponent(direction.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for appearance in [ColorScheme.light, .dark] {
            for populated in [false, true] {
                let controller = IsolatedAppPreview.makeController(populated: populated)
                controller.preferences.appearance.mode = appearance == .light ? .light : .dark
                for (sizeName, size) in sizes {
                    for tab in StenoTab.allCases {
                        let name = "\(tab.rawValue.lowercased())-\(appearance)-\(populated ? "populated" : "empty")-\(sizeName)"
                        let data = try await render(ContentView(initialTab: tab), controller: controller,
                            appearance: appearance, size: size, accessibility: false)
                        try data.write(to: root.appendingPathComponent(name + ".png"))
                        receipt.append("\(direction.rawValue)/\(name),\(appearance),\(size.width),\(size.height),\(populated),false,\(data.count)")
                    }
                }
                for section in SettingsSection.allCases {
                    let name = "settings-\(section.rawValue)-\(appearance)-\(populated ? "populated" : "empty")-accessible"
                    let size = sizes[0].1
                    let data = try await render(ContentView(initialTab: .settings, initialSettingsSection: section),
                        controller: controller, appearance: appearance, size: size, accessibility: true)
                    try data.write(to: root.appendingPathComponent(name + ".png"))
                    receipt.append("\(direction.rawValue)/\(name),\(appearance),\(size.width),\(size.height),\(populated),true,\(data.count)")
                }
                await controller.teardownAndWait()
            }
        }
        for step in 0...3 {
            let controller = IsolatedAppPreview.makeController(populated: false)
            controller.microphonePermissionStatus = step == 1 ? .denied : .unknown
            for appearance in [ColorScheme.light, .dark] {
                controller.preferences.appearance.mode = appearance == .light ? .light : .dark
                let name = "onboarding-\(step)-\(appearance)"
                let data = try await render(OnboardingView(initialStep: step), controller: controller,
                    appearance: appearance, size: sizes[0].1, accessibility: true)
                try data.write(to: root.appendingPathComponent(name + ".png"))
                receipt.append("\(direction.rawValue)/\(name),\(appearance),\(sizes[0].1.width),\(sizes[0].1.height),false,true,\(data.count)")
            }
            await controller.teardownAndWait()
        }
        for state in ["recording", "finishing", "permission", "copied", "recovery"] {
            let controller = IsolatedAppPreview.makeController()
            switch state {
            case "recording": controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
            case "finishing": controller.stageIsolatedPreviewLifecycle(.transcribing)
            case "permission": controller.microphonePermissionStatus = .denied
            case "copied": controller.recentEntries = [IsolatedAppPreview.entries[1]]
            default:
                controller.lastError = "The editor closed before insertion. Your words are safe in History."
                controller.hotkeyRegistrationMessage = "The recording shortcut is unavailable. Review Recording settings."
                controller.recentEntries = [IsolatedAppPreview.entries[3]]
            }
            for appearance in [ColorScheme.light, .dark] {
                controller.preferences.appearance.mode = appearance == .light ? .light : .dark
                let name = "record-\(state)-\(appearance)"
                let data = try await render(ContentView(), controller: controller,
                    appearance: appearance, size: sizes[0].1, accessibility: true)
                try data.write(to: root.appendingPathComponent(name + ".png"))
                receipt.append("\(direction.rawValue)/\(name),\(appearance),\(sizes[0].1.width),\(sizes[0].1.height),true,true,\(data.count)")
            }
            await controller.teardownAndWait()
        }
        for appearance in [ColorScheme.light, .dark] {
            for state in ["insights-loading", "insights-error", "history-long", "permissions-denied", "inactive-window"] {
                let controller = IsolatedAppPreview.makeController(populated: state == "history-long" || state == "inactive-window")
                controller.preferences.appearance.mode = appearance == .light ? .light : .dark
                let content: AnyView
                switch state {
                case "insights-loading":
                    controller.isLoadingUsageAnalytics = true
                    content = AnyView(ContentView(initialTab: .insights))
                case "insights-error":
                    controller.usageAnalyticsError = "The local activity file could not be read. Try again."
                    content = AnyView(ContentView(initialTab: .insights))
                case "history-long":
                    content = AnyView(HistoryTab(initialSelectedEntryID: controller.recentEntries[2].id)
                        .foregroundStyle(StenoDesign.theme(for: controller.preferences).text)
                        .background(StenoDesign.theme(for: controller.preferences).ink0))
                case "permissions-denied":
                    controller.microphonePermissionStatus = .denied
                    controller.accessibilityPermissionStatus = .denied
                    controller.inputMonitoringPermissionStatus = .denied
                    content = AnyView(ContentView(initialTab: .settings, initialSettingsSection: .permissions))
                default: content = AnyView(ContentView())
                }
                let name = "\(state)-\(appearance)"
                let data = try await render(content, controller: controller, appearance: appearance,
                    size: sizes[0].1, accessibility: true, active: state != "inactive-window")
                try data.write(to: root.appendingPathComponent(name + ".png"))
                receipt.append("\(direction.rawValue)/\(name),\(appearance),\(sizes[0].1.width),\(sizes[0].1.height),true,true,\(data.count)")
                await controller.teardownAndWait()
            }
        }
        }
        try receipt.joined(separator: "\n").write(to: root.appendingPathComponent("render-matrix.csv"), atomically: true, encoding: .utf8)
        #expect(receipt.count == 349)
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
            ("failure", .failure(message: "The document closed. Your words are ready to copy."))
        ]
        for (name, state) in states {
            let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
            let data = try #require(presenter.hostedEvidenceRenderPNG(state: state))
            try data.write(to: root.appendingPathComponent("overlay-\(name).png"))
            #expect(data.count > 500)
        }
        for pointSize in [13.0, 22.0] {
            let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
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
