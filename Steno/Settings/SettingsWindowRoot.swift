import AppKit
import SwiftUI

/// Root of the Settings window scene: theme, size, and the section another part of the app asked for.
struct SettingsWindowRoot: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var router = SettingsRouter.shared
    @ObservedObject private var session = SettingsSession.shared

    static let minimumSize = CGSize(width: 760, height: 520)

    var body: some View {
        SettingsView(session: session)
            .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
            .preferredColorScheme(controller.preferences.appearance.mode.colorScheme)
            .background(SettingsWindowConfigurator(title: session.selectedSection.groveTitle))
            .onAppear { session.showRequestedSection(from: router) }
            .onChange(of: router.requestedSection) { _ in session.showRequestedSection(from: router) }
            .followsSystemTextSize()
    }
}

/// Captures the scene's `openWindow` for `SettingsRouter`. Place it once in a view that exists at launch.
struct SettingsOpenerInstaller: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { SettingsRouter.shared.install(openWindow) }
            .accessibilityHidden(true)
    }
}

/// Keeps the Settings window out of state restoration, so it doesn't reopen at the next launch,
/// and names the window after the pane on show, as macOS Settings windows do. The title bar
/// stays hidden; the name is what VoiceOver, the Window menu and Mission Control read.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        WindowSettingsView { window in
            window.setIfChanged(\.isRestorable, false)
            window.setIfChanged(\.titlebarAppearsTransparent, true)
            window.setIfChanged(\.titleVisibility, .hidden)
            window.setIfChanged(\.tabbingMode, .disallowed)
            if window.title != title { window.title = title }
        }
    }

    // Only the title follows the pane, and only when it differs: rewriting window settings on
    // every update notifies every hosting view, which crashed SwiftUI during a page swap.
    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window, window.title != title { window.title = title }
    }
}
