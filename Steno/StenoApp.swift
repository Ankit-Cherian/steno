import AppKit
import SwiftUI

@main
struct StenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller: DictationController

    init() {
        AppFontRegistry.registerIfNeeded()
        #if DEBUG
        if IsolatedAppPreview.isTestHost || IsolatedAppPreview.isRequested {
            _controller = StateObject(wrappedValue: IsolatedAppPreview.makeController(
                populated: !ProcessInfo.processInfo.arguments.contains("--preview-empty")
            ))
        } else {
            _controller = StateObject(wrappedValue: DictationController())
        }
        #else
        _controller = StateObject(wrappedValue: DictationController())
        #endif
    }

    private var isHostedTest: Bool {
        #if DEBUG
        IsolatedAppPreview.isTestHost
        #else
        false
        #endif
    }

    var body: some Scene {
        WindowGroup("Steno") {
            Group {
                if isHostedTest {
                    Color.clear.frame(width: 1, height: 1)
                } else {
                    appContent
                }
            }
        }
        .defaultSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private var appContent: some View {
        VStack(spacing: 0) {
            Group {
                if !controller.hasBootstrapped {
                    StenoStageBackground(theme: StenoDesign.theme(for: controller.preferences))
                } else if controller.preferences.general.showOnboarding {
                    OnboardingView()
                        .environmentObject(controller)
                } else {
                    ContentView()
                        .environmentObject(controller)
                }
            }
            .background(WindowConfigurator(savesWindowFrame: !controller.isIsolatedPreview).frame(width: 0, height: 0))
            .preferredColorScheme(controller.preferences.appearance.mode.colorScheme)
            .tint(StenoDesign.theme(for: controller.preferences).accent)
            .task {
                appDelegate.controller = controller
                await controller.bootstrapIfNeeded()
            }
            #if DEBUG
            if controller.isIsolatedPreview {
                Divider()
                IsolatedReviewControls().environmentObject(controller)
            }
            #endif
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: DictationController?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFontRegistry.registerIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else {
            return .terminateNow
        }
        guard !terminationInProgress else {
            return .terminateLater
        }

        terminationInProgress = true
        Task { @MainActor [weak self] in
            await controller.teardownAndWait()
            self?.controller = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let reopenWindow = sender.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
                reopenWindow.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
