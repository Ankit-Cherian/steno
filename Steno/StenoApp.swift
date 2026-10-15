import AppKit
import StenoKit
import SwiftUI

@main
struct StenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// Holds the controller without observing it: a change of app state redraws the windows'
    /// content, which observes the controller itself, and never re-evaluates the scenes.
    @StateObject private var holder: ControllerHolder

    private var controller: DictationController { holder.controller }

    init() {
        AppFontRegistry.registerIfNeeded()
        #if DEBUG
        if !IsolatedAppPreview.isTestHost && PipelineBenchmark.isRequested {
            _holder = StateObject(wrappedValue: ControllerHolder(PipelineBenchmark.makeController()))
        } else if IsolatedAppPreview.isTestHost || IsolatedAppPreview.isRequested {
            _holder = StateObject(wrappedValue: ControllerHolder(IsolatedAppPreview.makeController(
                populated: !ProcessInfo.processInfo.arguments.contains("--preview-empty")
            )))
        } else {
            _holder = StateObject(wrappedValue: ControllerHolder(DictationController()))
        }
        #else
        _holder = StateObject(wrappedValue: ControllerHolder(DictationController()))
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
        WindowGroup("Steno", id: SettingsRouter.mainWindowID) {
            Group {
                if isHostedTest {
                    HostedTestWindowHider()
                } else {
                    AppWindowContent(controller: controller, appDelegate: appDelegate)
                }
            }
            .background(SettingsOpenerInstaller())
        }
        .defaultSize(width: MainWindowMetrics.idealWidth, height: MainWindowMetrics.idealHeight)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsRouter.shared.open() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            StenoWindowCommands()
            DictationMenuCommands()
            AboutCommands()
        }

        Window("Settings", id: SettingsRouter.windowID) {
            SettingsWindowRoot()
                .environmentObject(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 680)
        .windowResizability(.contentMinSize)
    }
}

/// The main window's content. It observes the controller, so a change of app state redraws
/// what the window shows; the scenes above it do not observe it.
struct AppWindowContent: View {
    @ObservedObject var controller: DictationController
    let appDelegate: AppDelegate

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if !controller.hasBootstrapped {
                    GroveLaunchGround()
                } else if controller.preferences.general.showOnboarding {
                    OnboardingView()
                        .environmentObject(controller)
                        .followsSystemTextSize()
                } else {
                    ContentView()
                        .environmentObject(controller)
                }
            }
            .preferredColorScheme(controller.preferences.appearance.mode.colorScheme)
            .task {
                appDelegate.controller = controller
                DictationLatency.watchMainThread()
                await controller.bootstrapIfNeeded()
                #if DEBUG
                PerfTour.runIfRequested(controller: controller)
                #endif
            }
            #if DEBUG
            if controller.isIsolatedPreview {
                Divider()
                IsolatedReviewControls().environmentObject(controller)
            }
            #endif
        }
        // Outside the Group, so it is made once per window, not again for each page it shows.
        .background(WindowConfigurator(savesWindowFrame: !controller.isIsolatedPreview).frame(width: 0, height: 0))
    }
}

/// Owns the app's controller for the scenes. It publishes nothing.
@MainActor
final class ControllerHolder: ObservableObject {
    let controller: DictationController

    init(_ controller: DictationController) {
        self.controller = controller
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: DictationController?
    private var terminationInProgress = false
    private let brandApplier = GroveBrandApplier()
    #if STENO_ACCEPTANCE
    private var acceptanceSleepTrigger: AcceptanceSleepTrigger?
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if IsolatedAppPreview.isTestHost {
            // Hosted tests render views offscreen; the test host needs no Dock icon, window or focus.
            NSApp.setActivationPolicy(.prohibited)
        } else if IsolatedAppPreview.isRequested {
            // A preview runs beside the real Steno: no Dock icon of its own to mistake for it.
            NSApp.setActivationPolicy(.accessory)
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFontRegistry.registerIfNeeded()
        PopoverAnimation.turnOffForEveryPopover()
        // Hosted tests pin the design per view and per overlay; the host keeps the defaults.
        #if DEBUG
        if !IsolatedAppPreview.isTestHost { brandApplier.start() }
        #else
        brandApplier.start()
        #endif
        #if DEBUG
        OverlayBenchmark.runIfRequested()
        #endif
        #if STENO_ACCEPTANCE
        acceptanceSleepTrigger = AcceptanceSleepTrigger()
        #endif
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

/// Orders out the window the `WindowGroup` creates when the app runs as the hosted test host.
private struct HostedTestWindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HiderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HiderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderOut(nil)
        }
    }
}
