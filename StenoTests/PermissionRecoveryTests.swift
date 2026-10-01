import AppKit
import Foundation
import Testing
@testable import Steno
import StenoKit

@MainActor
final class CountingHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?
    private(set) var startCount = 0

    func start() { startCount += 1 }
    func stop() {}
}

@MainActor
private final class PermissionFixture {
    let notifications = NotificationCenter()
    let hotkey = CountingHotkeyService()
    var permissions = PermissionStatusSnapshot(microphone: .granted, accessibility: .granted, inputMonitoring: .granted)
    private(set) var controller: DictationController!

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoPermissionTests-\(UUID().uuidString)", isDirectory: true)
        let clipboard = MemoryClipboardService()
        controller = DictationController(
            hotkey: hotkey,
            clipboardService: clipboard,
            overlay: WaveformOverlayPresenter(observeAccessibilityChanges: false),
            mediaInterruption: IsolatedTestMediaService(),
            preferencesStore: AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
            runtimeRebuildOverride: { nil },
            historyStore: HistoryStore(storageURL: directory.appendingPathComponent("history.json"), clipboardService: clipboard),
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            applicationNotificationCenter: notifications,
            permissionStatusReader: { [unowned self] in self.permissions }
        )
    }

    func becomeActive() async {
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        // The observer hops to the main actor in a task.
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
@Suite("Permission refresh")
struct PermissionRefreshTests {
    @Test("Returning to Steno after a change in System Settings shows the new status")
    func activationRefreshesStatus() async {
        let fixture = PermissionFixture()
        defer { fixture.controller.teardown() }
        let controller = fixture.controller!
        controller.refreshPermissionStatuses()
        #expect(controller.accessibilityPermissionStatus == .granted)

        fixture.permissions.accessibility = .denied
        await fixture.becomeActive()
        #expect(controller.accessibilityPermissionStatus == .denied)

        fixture.permissions = .init(microphone: .denied, accessibility: .granted, inputMonitoring: .granted)
        await fixture.becomeActive()
        #expect(controller.microphonePermissionStatus == .denied)
        #expect(controller.accessibilityPermissionStatus == .granted)
    }

    @Test("Activation reinstalls the hotkey monitor only when shortcut access changed")
    func activationReinstallsHotkeysOnlyOnChange() async {
        let fixture = PermissionFixture()
        defer { fixture.controller.teardown() }
        fixture.controller.refreshPermissionStatuses()
        let starts = fixture.hotkey.startCount

        await fixture.becomeActive()
        #expect(fixture.hotkey.startCount == starts, "nothing changed")

        fixture.permissions.inputMonitoring = .denied
        await fixture.becomeActive()
        #expect(fixture.hotkey.startCount == starts + 1)
    }

    @Test("Activation retries a hotkey registration that failed")
    func activationRetriesFailedRegistration() async {
        let fixture = PermissionFixture()
        defer { fixture.controller.teardown() }
        fixture.controller.refreshPermissionStatuses()
        fixture.hotkey.onRegistrationStatusChanged?(.unavailable(reason: "Accessibility permission required for global hotkey."))
        let starts = fixture.hotkey.startCount

        await fixture.becomeActive()
        #expect(fixture.hotkey.startCount == starts + 1)
    }

    @Test("Each Open Settings link names its own Privacy & Security list")
    func privacyPaneLinks() {
        #expect(PermissionDiagnostics.PrivacyPane.microphone.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(PermissionDiagnostics.PrivacyPane.accessibility.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(PermissionDiagnostics.PrivacyPane.inputMonitoring.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }
}

@Suite("Review settings routing")
struct SettingsRecoveryRoutingTests {
    private func context(
        microphone: PermissionDiagnostics.AccessStatus = .granted,
        accessibility: PermissionDiagnostics.AccessStatus = .granted,
        inputMonitoring: PermissionDiagnostics.AccessStatus = .granted,
        lastError: String = "",
        target: ErrorRecoveryTarget? = nil,
        hotkeyMessage: String = ""
    ) -> SettingsRecovery.Context {
        .init(
            microphone: microphone,
            accessibility: accessibility,
            inputMonitoring: inputMonitoring,
            lastError: lastError,
            lastErrorTarget: target,
            hotkeyMessage: hotkeyMessage
        )
    }

    @Test("A missing microphone permission opens Permissions")
    func microphoneOpensPermissions() {
        #expect(SettingsRecovery.section(for: context(microphone: .denied, lastError: "x")) == .permissions)
    }

    @Test("A hotkey that needs Accessibility or Input Monitoring opens Permissions")
    func hotkeyPermissionOpensPermissions() {
        let message = "Accessibility permission required for global hotkey."
        #expect(SettingsRecovery.section(for: context(accessibility: .denied, hotkeyMessage: message)) == .permissions)
        #expect(SettingsRecovery.section(for: context(inputMonitoring: .denied, hotkeyMessage: message)) == .permissions)
    }

    @Test("A hotkey problem with permissions granted opens Recording, where the key is chosen")
    func hotkeyProblemOpensRecording() {
        #expect(SettingsRecovery.section(for: context(hotkeyMessage: "The key is in use.")) == .recording)
    }

    @Test("A model failure opens Speech model")
    func modelErrorOpensSpeechModel() {
        let message = "Couldn't download Medium."
        let target = ErrorRecoveryTarget(message: message, section: .engine)
        #expect(SettingsRecovery.section(for: context(lastError: message, target: target)) == .engine)
    }

    @Test("An insertion problem opens Text output, or Permissions while Accessibility is missing")
    func insertionErrorOpensTextOutput() {
        let message = "The editor closed before insertion."
        let target = ErrorRecoveryTarget(message: message, section: .output)
        #expect(SettingsRecovery.section(for: context(lastError: message, target: target)) == .output)
        #expect(SettingsRecovery.section(for: context(accessibility: .denied, lastError: message, target: target)) == .permissions)
    }

    @Test("A target recorded for an earlier error isn't used for a newer one")
    func staleTargetIsIgnored() {
        let target = ErrorRecoveryTarget(message: "Couldn't download Medium.", section: .engine)
        #expect(SettingsRecovery.section(for: context(lastError: "Insertion failed", target: target)) == .recording)
        #expect(SettingsRecovery.section(for: context(accessibility: .denied, lastError: "Insertion failed", target: target)) == .permissions)
    }
}

@MainActor
@Test("A failed model download sends Review settings to Speech model")
func modelDownloadFailureRoutesToSpeechModel() async throws {
    let fixture = try ModelSetupFixture(failure: URLError(.timedOut))
    defer { fixture.tearDown() }
    let controller = fixture.controller!
    controller.microphonePermissionStatus = .granted
    controller.accessibilityPermissionStatus = .granted
    controller.inputMonitoringPermissionStatus = .granted

    controller.downloadWhisperModel(.mediumEn)
    #expect(await fixture.waitForDownloadToFinish())

    #expect(controller.lastError == controller.modelDownloadMessage)
    #expect(controller.recoverySection == .engine)
}
