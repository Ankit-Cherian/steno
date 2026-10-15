import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Shared by the Grove window render tests: sample controllers and offscreen rendering.
@MainActor
enum GroveRenderHarness {
    enum Variant: String, CaseIterable {
        case light, dark
        /// Increase Contrast, light.
        case contrast
        /// Increase Contrast, dark.
        case contrastDark = "contrast-dark"

        var scheme: ColorScheme { self == .dark || self == .contrastDark ? .dark : .light }
        var increasedContrast: Bool { self == .contrast || self == .contrastDark }
    }

    static let windowSize = CGSize(width: MainWindowMetrics.idealWidth, height: MainWindowMetrics.idealHeight)
    static let minimumSize = CGSize(width: MainWindowMetrics.minWidth, height: MainWindowMetrics.minHeight)

    static var outputDirectory: URL {
        get throws {
            let root = ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering", isDirectory: true)
            let directory = root.appendingPathComponent("grove", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    /// An isolated controller with the sample dictations, records and usage.
    static func sampleController(_ variant: Variant, populated: Bool = true) -> DictationController {
        let controller = IsolatedAppPreview.makeController(populated: false)
        controller.preferences.appearance.mode = variant.scheme == .light ? .light : .dark
        controller.preferences.hotkeys.optionPressToTalkEnabled = true
        controller.preferences.hotkeys.handsFreeGlobalKeyCode = 79
        controller.status = "Ready"
        if populated {
            WindowSampleData.install(on: controller)
        } else {
            controller.recentEntries = []
            controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot(weeks: [])
        }
        return controller
    }

    /// The window facts the navigation footer reads, from a controller.
    static func status(of controller: DictationController) -> WindowStatusInputs {
        WindowStatusInputs(
            lifecycle: controller.recordingLifecycleState, recordingStartedAt: controller.recordingStartedAt,
            microphone: controller.microphonePermissionStatus, accessibility: controller.accessibilityPermissionStatus,
            inputMonitoring: controller.inputMonitoringPermissionStatus, speechModelMissing: false, downloadPercent: nil,
            optionHold: controller.preferences.hotkeys.optionPressToTalkEnabled,
            handsFreeKeyName: controller.preferences.hotkeys.handsFreeGlobalKeyCode.flatMap(HandsFreeKey.displayName(for:)))
    }

    /// A page under the window's toolbar row, as ContentView draws it, for states ContentView
    /// cannot be told about.
    static func window<Page: View>(_ tab: StenoTab, controller: DictationController, feedback: GroveFeedback = GroveFeedback(),
                                   @ViewBuilder page: () -> Page) -> some View {
        GroveWindowContent(accent: controller.preferences.appearance.accent, feedback: feedback) {
            VStack(spacing: 0) {
                InlineWindowChrome(tab: .constant(tab), inputs: status(of: controller))
                page()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Renders `view` as the Grove window would draw it and writes `name`.png.
    static func write<V: View>(_ view: V, controller: DictationController, variant: Variant,
                               size: CGSize = windowSize, reduceTransparency: Bool = false,
                               textSize: DynamicTypeSize = .large,
                               name: String, prepare: (@MainActor () -> Void)? = nil) async throws {
        let data = try await render(view, controller: controller, variant: variant, size: size,
                                    reduceTransparency: reduceTransparency, textSize: textSize, prepare: prepare)
        try data.write(to: outputDirectory.appendingPathComponent(name + ".png"))
        #expect(data.count > 8_000, "\(name)")
    }

    static func render<V: View>(_ view: V, controller: DictationController?, variant: Variant, size: CGSize,
                                reduceTransparency: Bool = false, textSize: DynamicTypeSize = .large,
                                settle: Duration = .milliseconds(120),
                                prepare: (@MainActor () -> Void)? = nil) async throws -> Data {
        AppFontRegistry.registerIfNeeded()
        var content = AnyView(view
            .environment(\.colorScheme, variant.scheme)
            .environment(\.drawsWindowChromeInline, true)
            .environment(\.rendersPopoversInline, true)
            .environment(\._accessibilityReduceMotion, true)
            .environment(\._colorSchemeContrast, variant.increasedContrast ? .increased : .standard)
            .environment(\._accessibilityReduceTransparency, reduceTransparency)
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.systemTextSize, SystemTextSize(read: { SystemTextSize.baselineBodyPointSize }))
            .frame(width: size.width, height: size.height))
        if let controller { content = AnyView(content.environmentObject(controller)) }
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: variant.scheme == .light ? .aqua : .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settle)
        // Runs once the view is on screen, for what it only takes then (an input level).
        prepare?()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

/// The three window lights, drawn into offscreen renders of windows that have no real title bar.
struct GroveInlineTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                Circle().fill($0).frame(width: 12, height: 12)
            }
        }
        .accessibilityHidden(true)
    }
}
