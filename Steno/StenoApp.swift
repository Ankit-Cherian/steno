import AppKit
import SwiftUI

@main
struct StenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = DictationController()

    var body: some Scene {
        WindowGroup("Steno") {
            Group {
                if !controller.hasBootstrapped {
                    StenoDesign.background
                } else if controller.preferences.general.showOnboarding {
                    OnboardingView()
                        .environmentObject(controller)
                } else {
                    ContentView()
                        .environmentObject(controller)
                }
            }
            .task {
                await controller.bootstrapIfNeeded()
            }
        }
        .defaultSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
