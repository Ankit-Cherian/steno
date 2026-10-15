import AppKit
import Combine
import StenoKit
import SwiftUI

/// The status item: a quill icon that shows recording and transcribing, and the glass panel it
/// opens. Left and right click both open it.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private weak var controller: DictationController?
    private var observers: Set<AnyCancellable> = []
    private var panelPresenter: GroveMenuPresenter?
    private let makePanelPresenter: () -> GroveMenuPresenter
    var iconState: MenuBarIconState = .idle
    private(set) var levelGate = MenuBarLevelGate()
    private var levelToken: UUID?
    /// Replaceable in tests.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var refreshScheduled = false

    /// `makePanelPresenter` is replaceable so tests can drive the panel without showing a window.
    init(makePanelPresenter: @escaping () -> GroveMenuPresenter = { GroveMenuPresenter() }) {
        self.makePanelPresenter = makePanelPresenter
        super.init()
    }

    /// The icon for a state.
    func iconImage(for state: MenuBarIconState, frame: Int) -> NSImage {
        MenuBarIcon.image(for: state, frame: frame)
    }

    func setup(controller: DictationController) {
        self.controller = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = iconImage(for: .idle, frame: MenuBarIcon.staticRecordingFrame)
        item.button?.setAccessibilityLabel(MenuBarIconState.idle.accessibilityDescription)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem = item

        // Recording state isn't published on its own; these change with it, so re-read on each.
        controller.$isRecording.sink { [weak self] _ in self?.scheduleIconRefresh() }.store(in: &observers)
        controller.$status.sink { [weak self] _ in self?.scheduleIconRefresh() }.store(in: &observers)
        controller.$microphonePermissionStatus.sink { [weak self] _ in self?.scheduleIconRefresh() }.store(in: &observers)
        controller.$recentEntries.sink { [weak self] _ in self?.scheduleIconRefresh() }.store(in: &observers)
        observeInputLevel(of: controller)
        refreshIcon()
    }

    /// Draws the recording's level on the icon: the same stream the overlay and Today get.
    func observeInputLevel(of controller: DictationController) {
        if let levelToken { self.controller?.inputLevels.remove(levelToken) }
        self.controller = controller
        levelToken = controller.inputLevels.add { [weak self] level in
            self?.updateInputLevel(level)
        }
    }

    /// Called by the controller when recording starts or stops.
    func updateIcon(isRecording: Bool, handsFreeOn: Bool) {
        scheduleIconRefresh()
    }

    /// The smoothed input level while recording, 0...1, drawn in quantised frames at most ten
    /// times a second and not at all under Reduce Motion.
    func updateInputLevel(_ level: Float) {
        // The open panel's header bars follow the same stream, at the meter's own rate.
        if panelPresenter?.isShown == true { panelPresenter?.state.haloSource.send(level) }
        guard iconState == .recording,
              let frame = levelGate.update(
                  level: level,
                  now: ProcessInfo.processInfo.systemUptime,
                  reduceMotion: reducesMotion()
              )
        else { return }
        statusItem?.button?.image = iconImage(for: .recording, frame: frame)
    }

    private func scheduleIconRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Publishers fire before the new value is stored; read the state on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refreshIcon()
        }
    }

    private func refreshIcon() {
        refreshPanel()
        guard let controller, let button = statusItem?.button else { return }
        let state = snapshot(of: controller).iconState
        guard state != iconState || button.image == nil else { return }
        iconState = state
        levelGate.reset()
        button.image = iconImage(for: state, frame: MenuBarIcon.staticRecordingFrame)
        button.setAccessibilityLabel(state.accessibilityDescription)
    }

    // MARK: Panel

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let type = NSApp.currentEvent?.type
        toggleGrovePanel(keyboardInitiated: type == nil || type == .keyDown || type == .keyUp)
    }

    /// Opens the panel under the status item, or closes it when it is already open.
    func toggleGrovePanel(keyboardInitiated: Bool) {
        let presenter = panelPresenter ?? makePanelPresenter()
        if panelPresenter == nil {
            panelPresenter = presenter
            presenter.state.perform = { [weak self] action in self?.run(action) }
            presenter.onVisibilityChange = { [weak self] isOpen in
                self?.statusItem?.button?.highlight(isOpen)
            }
        }
        if presenter.isShown {
            presenter.close()
            return
        }
        guard let controller else { return }
        let button = statusItem?.button
        let anchor = button?.window?.frame ?? Self.fallbackAnchor()
        let screens = NSScreen.screens.map(\.frame)
        guard let screenFrame = GroveMenuPlacement.screenFrame(for: anchor, among: screens) else { return }
        presenter.show(
            snapshot: snapshot(of: controller),
            targetAppName: Self.frontmostAppName(),
            accent: controller.preferences.appearance.accent,
            appearance: Self.panelAppearance(for: controller.preferences.appearance.mode),
            statusItemFrame: anchor,
            screenFrame: screenFrame,
            anchorWindow: button?.window,
            keyboardInitiated: keyboardInitiated
        )
    }

    /// The panel's appearance follows the saved appearance; with System it follows the Mac.
    static func panelAppearance(for mode: StenoAppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The app a dictation would go into: the frontmost one, unless that is Steno.
    private static func frontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app.localizedName
    }

    private static func fallbackAnchor() -> CGRect {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        return CGRect(x: frame.maxX - 120, y: frame.maxY - 24, width: 24, height: 24)
    }

    /// Keeps an open panel current as recording, transcribing and History change.
    private func refreshPanel() {
        guard let controller, panelPresenter?.isShown == true else { return }
        panelPresenter?.refresh(snapshot: snapshot(of: controller), targetAppName: Self.frontmostAppName())
    }

    private func run(_ action: MenuBarAction) {
        guard let controller else { return }
        MenuBarCommandRunner(
            target: controller,
            pasteLast: { controller.pasteLastDictation() },
            selectMicrophone: { controller.selectMicrophone($0) },
            openSteno: { SettingsRouter.shared.openMainWindow() },
            openSettings: { SettingsRouter.shared.open() },
            quit: { NSApp.terminate(nil) }
        ).run(action)
    }

    private func snapshot(of controller: DictationController) -> MenuBarSnapshot {
        MenuBarSnapshot(
            lifecycle: controller.recordingLifecycleState,
            isRecording: controller.isRecording,
            recordingStartedAt: controller.recordingStartedAt,
            entries: Array(controller.recentEntries.prefix(4)),
            microphoneDenied: controller.microphonePermissionStatus == .denied,
            pasteShortcut: controller.preferences.recording.pasteLastGlobalShortcut,
            // Refused while a dictation is in progress, as the shortcut is.
            canPasteLast: controller.recordingLifecycleState == .idle,
            hasUnsavedLast: controller.hasUnsavedLastDictation,
            canUndoDiscard: controller.canUndoDiscard,
            devices: controller.microphone.devices.map(InputDeviceOption.init),
            selectedDeviceID: controller.preferences.inputDeviceID,
            shortcuts: TodayShortcuts(controller.preferences.hotkeys, inputMonitoring: controller.inputMonitoringPermissionStatus)
        )
    }
}
