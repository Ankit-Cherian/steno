import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Every Settings pane opened from the sidebar and every control on it driven: switches, menus,
/// segmented choices, the word and phrase lists, the insertion order, the speech model's
/// advanced fields, the permissions as they change, the sidebar search and the microphone test.
@Suite("Settings coverage transitions", .serialized)
@MainActor
struct SettingsCoverageTransitionTests {
    typealias F = TransitionFixtures

    private func host(_ controller: DictationController, section: SettingsSection = .recording,
                      session: SettingsSession? = nil) -> (TransitionHost, SettingsSession) {
        let session = session ?? SettingsSession(previewDraft: SettingsDraftState(saved: controller.preferences), section: section)
        let host = TransitionHost(size: CGSize(width: 860, height: 1_000), controller: controller) {
            SettingsView(session: session)
        }
        return (host, session)
    }

    private func isClean(_ host: TransitionHost) -> Bool {
        host.nodes(under: host.node(named: "Unsaved changes")).contains { $0.text == "No unsaved changes" }
    }

    private func open(_ section: SettingsSection, in host: TransitionHost) async throws {
        let item = try #require(host.node(identifier: "settings.section.\(section.rawValue)"), "no sidebar item for \(section)")
        #expect(item.press())
        await host.settle()
    }

    /// The page's heading: the one heading that is not a sidebar group.
    private func heading(_ host: TransitionHost) -> [String] {
        let groups = Set(SettingsGroup.allCases.map(\.title))
        return host.nodes().filter { $0.role == "AXHeading" && !groups.contains($0.name) }.map(\.name)
    }

    static let pageTitles: [SettingsSection: String] = [
        .recording: "Recording", .microphone: "Microphone", .engine: "Speech Model", .media: "Media",
        .cleanup: "Cleanup", .corrections: "Word Corrections", .shortcuts: "Text Shortcuts", .output: "Inserting Text",
        .permissions: "Permissions", .appearance: "Appearance", .general: "General",
    ]

    @Test("Each sidebar item opens its own page and marks itself as the one shown")
    func everyPaneFromTheSidebar() async throws {
        let controller = F.sampleController()
        let (host, session) = host(controller)
        defer { host.close() }
        await host.settle { isClean(host) }
        for section in SettingsSection.allCases.reversed() {
            try await open(section, in: host)
            let title = try #require(Self.pageTitles[section])
            #expect(await host.settle { heading(host).first == title }, "\(section) shows \(heading(host))")
            #expect(session.selectedSection == section)
            #expect(host.node(identifier: "settings.section.\(section.rawValue)")?.isSelected == true,
                    "the sidebar does not mark \(section)")
        }
    }

    /// The switches a page draws, by name, with their value.
    private func switches(_ host: TransitionHost) -> [(name: String, value: Int)] {
        host.nodes().filter { $0.role == "AXCheckBox" && $0.isEnabled }.compactMap { node in node.number.map { (node.name, $0) } }
    }

    @Test("Every switch on every page makes a draft the bar counts, and Discard puts each one back",
          arguments: [SettingsSection.recording, .microphone, .engine, .media, .output, .general])
    func everySwitchDraftsAndDiscards(section: SettingsSection) async throws {
        let controller = F.sampleController()
        let (host, _) = host(controller, section: section)
        defer { host.close() }
        await host.settle { isClean(host) && !switches(host).isEmpty }
        let before = switches(host)
        #expect(!before.isEmpty, "no switches on \(section)")
        for (name, value) in before {
            try await host.press(name)
            #expect(await host.settle { switches(host).first { $0.name == name }?.value == 1 - value },
                    "\(section) › \(name) did not change")
            #expect(await host.settle { !isClean(host) }, "\(section) › \(name) made no draft")
            try await host.press("Discard")
            #expect(await host.settle { isClean(host) })
            #expect(switches(host).first { $0.name == name }?.value == value, "\(section) › \(name) did not come back")
        }
    }

    @Test("Each segmented choice makes a draft and Discard brings back the saved one",
          arguments: [("After inserting", "Always say where"), ("Layout", "Bullets"), ("Filler words", "Thorough"),
                      ("Slash commands", "Keep as spoken")])
    func segmentedChoices(group: String, choice: String) async throws {
        let controller = F.sampleController()
        let section: SettingsSection = group == "After inserting" ? .recording : .cleanup
        let (host, _) = host(controller, section: section)
        defer { host.close() }
        await host.settle { host.node(named: group) != nil }
        let radios = { host.nodes(under: host.node { $0.role == "AXRadioGroup" && $0.name == group }).filter { $0.role == "AXRadioButton" } }
        let saved = try #require(radios().first { $0.number == 1 }?.name, "no choice is marked in \(group)")
        #expect(saved != choice, "\(choice) is already the saved \(group)")

        try await host.selectSegment(choice)
        #expect(await host.settle { radios().first { $0.number == 1 }?.name == choice }, "\(group) did not take \(choice)")
        #expect(!isClean(host))
        try await host.press("Discard")
        #expect(await host.settle { radios().first { $0.number == 1 }?.name == saved })
    }

    @Test("The hands-free key and Paste Last Dictation menus each make a draft, and Discard brings the saved key back")
    func shortcutMenus() async throws {
        let controller = F.sampleController()
        let (host, session) = host(controller)
        defer { host.close() }
        await host.settle { host.node(named: "Hands-free key") != nil }
        try await host.choose(menuItem: "F13") { $0.accessibilityLabel() == "Hands-free key" }
        #expect(await host.settle { host.node(named: "Hands-free key")?.value == "F13" })
        #expect(!isClean(host))
        #expect(session.draft.preferences.hotkeys.handsFreeGlobalKeyCode != controller.preferences.hotkeys.handsFreeGlobalKeyCode)
        try await host.press("Discard")
        #expect(await host.settle { host.node(named: "Hands-free key")?.value == "F18" })

        let paste = try #require(host.views(NSPopUpButton.self).first { $0.accessibilityLabel() == "Paste last dictation" })
        let choice = try #require(paste.itemTitles.first { $0 != "None" && !$0.isEmpty }, "no shortcut offered: \(paste.itemTitles)")
        try await host.choose(menuItem: choice) { $0.accessibilityLabel() == "Paste last dictation" }
        #expect(await host.settle { host.node(named: "Paste last dictation")?.value == choice })
        #expect(!isClean(host))
    }

    @Test("A shortcut problem names the registered key's real reason, and choosing another key in the draft does not change it")
    func hotkeyProblemDescribesTheRegisteredKey() async throws {
        let controller = F.sampleController()
        controller.hotkeyRegistrationMessage = "Accessibility permission required for global hotkey."
        let (host, session) = host(controller)
        defer { host.close() }
        let reason = { host.node(where: { $0.text.contains("Accessibility permission required") }) }
        await host.settle { reason() != nil }
        #expect(reason() != nil, "the registration problem is not shown: \(host.names().suffix(14))")
        #expect(host.node(where: { $0.text.contains("isn\u{2019}t working as the hands-free key") }) == nil)

        try await host.choose(menuItem: "F19") { $0.accessibilityLabel() == "Hands-free key" }
        #expect(await host.settle { session.draft.preferences.hotkeys.handsFreeGlobalKeyCode != controller.preferences.hotkeys.handsFreeGlobalKeyCode })
        await host.settle()
        #expect(reason() != nil, "the reason went away after an unsaved choice")
        #expect(host.node(where: { $0.text.contains("F19 isn") }) == nil, "an unsaved key was blamed")
        #expect(host.node(where: { $0.text.contains("Choose another key") }) == nil)
    }

    private static let listedApp = "com.example.steno-test-app"

    @Test("Choosing an app with no identifier, or one that is already listed, says why instead of doing nothing")
    func appChooserOnCleanupSaysWhyItAddedNothing() async throws {
        let original = AppIdentity.chooser
        defer { AppIdentity.chooser = original }
        let controller = F.sampleController()
        var profile = controller.preferences.globalStyleProfile
        profile.name = "App Override"
        controller.preferences.appStyleProfiles[Self.listedApp] = profile
        let (host, session) = host(controller, section: .cleanup)
        defer { host.close() }
        await host.settle { host.node(named: "Add an App…") != nil }
        let message = { host.nodes().first { $0.text.contains("no identifier") || $0.text.contains("already has an override") }?.text }
        #expect(message() == nil)

        AppIdentity.chooser = { .noIdentifier }
        try await host.press("Add an App…")
        #expect(await host.settle { message() == "That app has no identifier Steno can use." }, "\(String(describing: message()))")
        #expect(session.preferences.appStyleProfiles.keys.sorted() == [Self.listedApp])

        AppIdentity.chooser = { .app(Self.listedApp) }
        try await host.press("Add an App…")
        #expect(await host.settle { message() == "\(Self.listedApp) already has an override." }, "\(String(describing: message()))")
        #expect(session.preferences.appStyleProfiles.keys.sorted() == [Self.listedApp])

        // A cancelled panel is not a problem and clears the last message.
        AppIdentity.chooser = { .cancelled }
        try await host.press("Add an App…")
        #expect(await host.settle { message() == nil })

        // A new app adds its row.
        AppIdentity.chooser = { .app("com.example.steno-test-other") }
        try await host.press("Add an App…")
        #expect(await host.settle { host.node(named: "Remove com.example.steno-test-other") != nil })
        #expect(message() == nil)
        #expect(session.preferences.appStyleProfiles.keys.sorted() == [Self.listedApp, "com.example.steno-test-other"])
    }

    @Test("Choosing an app with no identifier for a correction or a text shortcut says why instead of doing nothing",
          arguments: [SettingsSection.corrections, .shortcuts])
    func appChooserOnScopeMenuSaysWhyItChoseNothing(section: SettingsSection) async throws {
        let original = AppIdentity.chooser
        defer { AppIdentity.chooser = original }
        let controller = F.sampleController()
        let (host, _) = host(controller, section: section)
        defer { host.close() }
        await host.settle { host.node(named: "Apps") != nil }
        let message = { host.nodes().first { $0.text.contains("no identifier") }?.text }
        #expect(message() == nil)

        AppIdentity.chooser = { .noIdentifier }
        try await host.choose(menuItem: "Choose an App…") { $0.accessibilityLabel() == "Apps" }
        #expect(await host.settle { message() == "That app has no identifier Steno can use." }, "\(String(describing: message()))")
        #expect(host.node(named: "Apps")?.value == "All Apps")

        AppIdentity.chooser = { .app(Self.listedApp) }
        try await host.choose(menuItem: "Choose an App…") { $0.accessibilityLabel() == "Apps" }
        #expect(await host.settle { host.node(named: "Apps")?.value == Self.listedApp })
        #expect(message() == nil)
    }

    @Test("A word correction typed and added appears in the list as a draft, and Remove takes it out")
    func wordCorrections() async throws {
        let controller = F.sampleController()
        let (host, _) = host(controller, section: .corrections)
        defer { host.close() }
        await host.settle { host.node(named: "Add") != nil }
        #expect(host.node(named: "Add")?.isEnabled == false, "Add is on with both fields empty")
        try await host.type("kwill", into: "Misheard word")
        try await host.type("quill", into: "Correct word")
        #expect(await host.settle { host.node(named: "Add")?.isEnabled == true })
        try await host.press("Add")
        #expect(await host.settle { host.node(named: "Remove kwill") != nil }, "\(host.names().suffix(14))")
        #expect(!isClean(host))
        try await host.press("Remove kwill")
        #expect(await host.settle { host.node(named: "Remove kwill") == nil })
    }

    @Test("A text shortcut typed and added appears in the list as a draft, and Remove takes it out")
    func textShortcuts() async throws {
        let controller = F.sampleController()
        let (host, _) = host(controller, section: .shortcuts)
        defer { host.close() }
        await host.settle { host.node(named: "Phrase to say") != nil }
        try await host.type("my address", into: "Phrase to say")
        try await host.type("1 Infinite Loop", into: "Text Steno types")
        try await host.press("Add")
        #expect(await host.settle { host.node(named: "Remove “my address”") != nil }, "\(host.names().suffix(10))")
        #expect(!isClean(host))
        try await host.press("Remove “my address”")
        #expect(await host.settle { host.node(named: "Remove “my address”") == nil })
    }

    @Test("Moving a way of inserting down reorders the list and numbers it again; Discard puts it back")
    func insertionOrder() async throws {
        let controller = F.sampleController()
        let (host, _) = host(controller, section: .output)
        defer { host.close() }
        let order = { host.nodes().filter { $0.role == "AXGroup" && $0.name.first?.isNumber == true }.map(\.name) }
        await host.settle { order().count == 3 }
        #expect(order() == ["1. Type the text", "2. Insert with Accessibility", "3. Paste from the clipboard"])
        try await host.press("Move Type the text down")
        #expect(await host.settle { order() == ["1. Insert with Accessibility", "2. Type the text", "3. Paste from the clipboard"] },
                "order: \(order())")
        #expect(host.node(named: "Move Insert with Accessibility up")?.isEnabled == false, "the first can still move up")
        #expect(!isClean(host))
        try await host.press("Discard")
        #expect(await host.settle { order() == ["1. Type the text", "2. Insert with Accessibility", "3. Paste from the clipboard"] })
    }

    @Test("Advanced opens the speech model's paths and thread count, and the count steps as a draft")
    func speechModelAdvanced() async throws {
        let controller = F.sampleController()
        let (host, _) = host(controller, section: .engine)
        defer { host.close() }
        await host.settle { host.node(named: "Advanced") != nil }
        #expect(host.node(named: "Model path") == nil)
        try await host.press("Advanced")
        #expect(await host.settle { host.node(named: "Advanced")?.value == "Expanded" && host.node(named: "Model path") != nil },
                "\(host.names().suffix(12))")
        #expect(host.node(named: "whisper-cli path") != nil)
        let count = { host.node { $0.text.hasPrefix("Thread count: ") }?.text }
        let before = try #require(count(), "no thread count")
        let stepper = try #require(host.node { $0.role == "AXIncrementor" }, "no stepper: \(host.nodes().map(\.role))")
        #expect(stepper.name == "Thread count", "VoiceOver reads the stepper as “\(stepper.name)”")
        let control = try #require(host.views(NSStepper.self).first)
        control.integerValue += 1
        if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
        #expect(await host.settle { count() != before }, "the count stayed \(before)")
        #expect(!isClean(host))
        try await host.press("Advanced")
        #expect(await host.settle { host.node(named: "Model path") == nil })
    }

    @Test("Permissions follow each permission as it changes: allowed, not allowed with a way to fix it, not asked yet")
    func permissionsFollowChanges() async throws {
        let controller = F.sampleController()
        let (host, _) = host(controller, section: .permissions)
        defer { host.close() }
        await host.settle { host.node(named: "Microphone, allowed") != nil }
        #expect(host.node(named: "Check Again") != nil)

        controller.microphonePermissionStatus = .denied
        #expect(await host.settle { host.node(named: "Microphone, not allowed") != nil }, "\(host.names())")
        #expect(host.node(named: "Open System Settings") != nil)
        controller.microphonePermissionStatus = .unknown
        #expect(await host.settle { host.node(named: "Microphone, not asked yet") != nil }, "\(host.names())")
        #expect(host.node { $0.name.hasPrefix("Allow") } != nil)
        controller.accessibilityPermissionStatus = .denied
        #expect(await host.settle { host.node(named: "Accessibility, not allowed") != nil })
        controller.microphonePermissionStatus = .granted
        controller.accessibilityPermissionStatus = .granted
        #expect(await host.settle { host.node(named: "Microphone, allowed") != nil && host.node(named: "Accessibility, allowed") != nil })
        #expect(host.node(named: "Open System Settings") == nil)
    }

    @Test("Appearance applies at once, with no draft")
    func appearanceAppliesAtOnce() async throws {
        let controller = F.sampleController()
        let (host, _) = host(controller, section: .appearance)
        defer { host.close() }
        await host.settle { host.node(named: "Dark") != nil }
        let saved = controller.preferences.appearance
        let savedChoice = try #require(host.nodes(under: host.node { $0.role == "AXRadioGroup" && $0.name == "Appearance" })
            .first { $0.role == "AXRadioButton" && $0.number == 1 }?.name)
        #expect(savedChoice != "Dark")
        try await host.selectSegment("Dark")
        #expect(await host.settle { controller.preferences.appearance != saved }, "Dark was not applied")
        #expect(isClean(host), "Appearance made a draft")
        try await host.selectSegment(savedChoice)
        #expect(await host.settle { controller.preferences.appearance == saved })
    }

    @Test("Searching the sidebar keeps the pages that match, and says when none does")
    func sidebarSearch() async throws {
        let controller = F.sampleController()
        let (host, _) = host(controller)
        defer { host.close() }
        await host.settle { host.node(named: "Search settings") != nil }
        let items = { SettingsSection.allCases.filter { host.node(identifier: "settings.section.\($0.rawValue)") != nil } }
        #expect(items().count == SettingsSection.allCases.count)
        try await host.type("transcript", into: "Search settings")
        #expect(await host.settle { items() == [.recording] }, "matches: \(items())")
        try await host.clearField()
        try await host.type("zzqx", into: "Search settings")
        #expect(await host.settle { items().isEmpty && host.node { $0.text.hasPrefix("No settings match") } != nil },
                "\(host.names().prefix(12))")
        try await host.press("Clear search")
        #expect(await host.settle { items().count == SettingsSection.allCases.count })
    }

    // MARK: Microphone test

    private final class Tester: MicrophoneTesting {
        var onLevel: ((Float) -> Void)?
        var onStop: (() -> Void)?
        private(set) var isRunning = false
        var refusal: MicrophoneTestError?

        func start(deviceID: String?) throws {
            if let refusal { throw refusal }
            isRunning = true
        }

        func stop() {
            guard isRunning else { return }
            isRunning = false
            onLevel?(0)
            onStop?()
        }
    }

    private static let devices = [AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", isDefault: true),
                                  AudioInputDevice(id: "usb", name: "USB Desk Mic", isDefault: false)]

    private func microphoneHost(_ tester: Tester) -> (TransitionHost, DictationController) {
        let controller = makeTestDictationController(hotkey: TransitionHotkey(), makeMicrophoneTester: { _ in tester },
                                                     audioInputDevices: { Self.devices })
        let session = SettingsSession(previewDraft: SettingsDraftState(saved: controller.preferences), section: .microphone)
        let (host, _) = host(controller, section: .microphone, session: session)
        return (host, controller)
    }

    @Test("Test Microphone runs a test: the level shows, Good level appears in the band, and Stop Test ends it")
    func microphoneTestRuns() async throws {
        MicrophoneTestModel.duration = .seconds(600)
        defer { MicrophoneTestModel.duration = .seconds(5) }
        let tester = Tester()
        let (host, controller) = microphoneHost(tester)
        defer { host.close(); controller.teardown() }
        await host.settle { host.node(named: "Test Microphone")?.isEnabled == true }
        try await host.press("Test Microphone")
        #expect(await host.settle { host.node(named: "Stop Test") != nil }, "\(host.names().suffix(8))")
        tester.onLevel?(0.55)
        #expect(await host.settle { host.node { $0.text == "Good level" } != nil }, "no Good level")
        #expect(await host.settle { host.node(named: "Input level")?.valueDescription == "55 percent" },
                "the bar reads \(host.node(named: "Input level")?.valueDescription ?? "nothing")")
        try await host.press("Stop Test")
        #expect(await host.settle { host.node(named: "Test Microphone") != nil && !tester.isRunning })
    }

    @Test("VoiceOver reads the input level once, as a level with its percentage")
    func inputLevelReachesVoiceOver() async throws {
        MicrophoneTestModel.duration = .seconds(600)
        defer { MicrophoneTestModel.duration = .seconds(5) }
        let tester = Tester()
        let (host, controller) = microphoneHost(tester)
        defer { host.close(); controller.teardown() }
        await host.settle { host.node(named: "Test Microphone")?.isEnabled == true }
        try await host.press("Test Microphone")
        tester.onLevel?(0.55)
        #expect(await host.settle { host.node(named: "Input level")?.valueDescription == "55 percent" })

        let meters = host.nodes(named: "Input level")
        #expect(meters.count == 1, "VoiceOver finds \(meters.count) input levels")
        let meter = try #require(meters.first)
        #expect(meter.role == "AXProgressIndicator", "the input level is a \(meter.role)")
        let value = meter.object.perform(#selector(NSAccessibilityProtocol.accessibilityValue))?.takeUnretainedValue() as? NSNumber
        #expect(value.map { abs($0.doubleValue - 0.55) < 0.001 } == true, "the input level's value is \(value.map { "\($0)" } ?? "missing")")

        // In a narrow window the meter moves under the button, and is still read once.
        await host.resize(to: CGSize(width: 600, height: 1_000))
        func meterIsUnderTheButton() -> Bool {
            guard let button = host.node(named: "Stop Test"), let meter = host.node(named: "Input level") else { return false }
            return meter.screenFrame.maxY <= button.screenFrame.minY
        }
        #expect(await host.settle(timeout: .seconds(5)) { meterIsUnderTheButton() }, "the meter stayed beside the button")
        #expect(host.nodes(named: "Input level").count == 1, "VoiceOver finds \(host.nodes(named: "Input level").count) input levels")
        try await host.press("Stop Test")
    }

    @Test("A test that cannot start says why, and the next one that runs clears it")
    func microphoneTestRefused() async throws {
        let tester = Tester()
        tester.refusal = .microphoneUnavailable
        let (host, controller) = microphoneHost(tester)
        defer { host.close(); controller.teardown() }
        await host.settle { host.node(named: "Test Microphone")?.isEnabled == true }
        let reason = try #require(MicrophoneTestError.microphoneUnavailable.errorDescription)
        try await host.press("Test Microphone")
        #expect(await host.settle { host.node { $0.text == reason } != nil }, "a refused test said nothing: \(host.names().suffix(8))")
        #expect(host.node(named: "Test Microphone") != nil)

        tester.refusal = nil
        try await host.press("Test Microphone")
        #expect(await host.settle { host.node(named: "Stop Test") != nil })
        #expect(host.node { $0.text == reason } == nil, "the old reason stayed while a test runs")
        try await host.press("Stop Test")
    }
}
