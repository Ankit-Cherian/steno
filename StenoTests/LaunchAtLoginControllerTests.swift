import Foundation
import Testing
@testable import Steno
import StenoKit

@MainActor
final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginSystemStatus = .notRegistered
    /// The status macOS reports after a successful register().
    var statusAfterRegister: LaunchAtLoginSystemStatus = .enabled
    var registerError: Error?
    private(set) var calls: [Bool] = []
    private(set) var openedLoginItems = 0

    func setEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if enabled, let registerError { throw registerError }
        status = enabled ? statusAfterRegister : .notRegistered
    }

    func openLoginItemsSettings() { openedLoginItems += 1 }
}

private struct RegistrationRefused: LocalizedError {
    var errorDescription: String? { "Operation not permitted." }
}

@MainActor
private final class LaunchAtLoginFixture {
    let service = FakeLaunchAtLoginService()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoLaunchAtLoginTests-\(UUID().uuidString)", isDirectory: true)
    var preferencesURL: URL { directory.appendingPathComponent("preferences.json") }
    private(set) var controller: DictationController!

    init(saved: AppPreferences? = nil) async {
        if let saved {
            await AppPreferencesStore(storageURL: preferencesURL).save(saved)
        }
        let clipboard = MemoryClipboardService()
        controller = DictationController(
            hotkey: CountingHotkeyService(),
            clipboardService: clipboard,
            overlay: WaveformOverlayPresenter(observeAccessibilityChanges: false),
            mediaInterruption: IsolatedTestMediaService(),
            preferencesStore: AppPreferencesStore(storageURL: preferencesURL),
            launchAtLoginService: service,
            runtimeRebuildOverride: { nil },
            historyStore: HistoryStore(storageURL: directory.appendingPathComponent("history.json"), clipboardService: clipboard),
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            permissionStatusReader: {
                PermissionStatusSnapshot(microphone: .granted, accessibility: .granted, inputMonitoring: .granted)
            }
        )
    }

    func save(launchAtLogin: Bool) async -> Bool {
        var draft = controller.preferences
        draft.general.launchAtLoginEnabled = launchAtLogin
        return await controller.applySettingsDraft(preferences: draft).value
    }

    func savedValue() async -> Bool {
        await AppPreferencesStore(storageURL: preferencesURL).load().general.launchAtLoginEnabled
    }

    func tearDown() {
        controller.teardown()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite("Launch at login")
struct LaunchAtLoginControllerTests {
    @Test("Turning on registers with macOS and saves On")
    func enableRegisters() async {
        let fixture = await LaunchAtLoginFixture()
        defer { fixture.tearDown() }

        #expect(await fixture.save(launchAtLogin: true))
        #expect(fixture.service.calls == [true])
        #expect(fixture.controller.preferences.general.launchAtLoginEnabled)
        #expect(await fixture.savedValue())
        #expect(fixture.controller.launchAtLoginWarning.isEmpty)
    }

    @Test("A registration that fails saves Off and says why")
    func failedRegistrationSavesOff() async {
        let fixture = await LaunchAtLoginFixture()
        defer { fixture.tearDown() }
        fixture.service.registerError = RegistrationRefused()

        #expect(await fixture.save(launchAtLogin: true))
        #expect(fixture.controller.preferences.general.launchAtLoginEnabled == false)
        #expect(await fixture.savedValue() == false)
        #expect(fixture.controller.launchAtLoginWarning.contains("couldn't turn on launch at login"))
        #expect(fixture.controller.launchAtLoginWarning.contains("Operation not permitted."))

        fixture.service.registerError = nil
        #expect(await fixture.save(launchAtLogin: true))
        #expect(fixture.service.calls == [true, true], "turning it on again retries")
        #expect(await fixture.savedValue())
        #expect(fixture.controller.launchAtLoginWarning.isEmpty)
    }

    @Test("Approval required keeps On, says so, and offers Login Items")
    func approvalRequiredIsExplained() async {
        let fixture = await LaunchAtLoginFixture()
        defer { fixture.tearDown() }
        fixture.service.statusAfterRegister = .requiresApproval

        #expect(await fixture.save(launchAtLogin: true))
        #expect(await fixture.savedValue())
        #expect(fixture.controller.launchAtLoginNeedsApproval)
        #expect(fixture.controller.launchAtLoginWarning == DictationController.launchAtLoginApprovalMessage)

        fixture.controller.openLoginItemsSettings()
        #expect(fixture.service.openedLoginItems == 1)

        fixture.service.status = .enabled
        await fixture.controller.refreshLaunchAtLoginStatus()
        #expect(!fixture.controller.launchAtLoginNeedsApproval)
        #expect(fixture.controller.launchAtLoginWarning.isEmpty)
    }

    @Test("Launch reads the login item, so one turned off in System Settings shows Off")
    func bootstrapReadsSystemStatus() async {
        var saved = AppPreferences.default
        saved.general.launchAtLoginEnabled = true
        saved.general.showOnboarding = false
        let fixture = await LaunchAtLoginFixture(saved: saved)
        defer { fixture.tearDown() }
        fixture.service.status = .notRegistered

        await fixture.controller.bootstrap()

        #expect(fixture.controller.preferences.general.launchAtLoginEnabled == false)
        #expect(await fixture.savedValue() == false)
        #expect(fixture.service.calls.isEmpty, "reading the status never registers")

        #expect(await fixture.save(launchAtLogin: true))
        #expect(fixture.service.calls == [true], "turning it back on registers again")
    }

    @Test("Saving other settings never registers or unregisters")
    func unrelatedSaveLeavesLoginItemAlone() async {
        let fixture = await LaunchAtLoginFixture()
        defer { fixture.tearDown() }
        var draft = fixture.controller.preferences
        draft.media.pauseDuringHandsFree.toggle()

        #expect(await fixture.controller.applySettingsDraft(preferences: draft).value)
        #expect(fixture.service.calls.isEmpty)
    }
}
