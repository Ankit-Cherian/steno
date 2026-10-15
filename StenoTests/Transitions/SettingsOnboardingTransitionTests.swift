import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Settings driven through its controls: an edit makes a draft, the draft survives moving
/// between pages, Save and Discard settle it, and a change made elsewhere is caught.
@Suite("Settings transitions", .serialized)
@MainActor
struct SettingsTransitionTests {
    typealias F = TransitionFixtures

    private func host(_ controller: DictationController) -> (TransitionHost, SettingsSession) {
        let session = SettingsSession(previewDraft: SettingsDraftState(saved: controller.preferences))
        let host = TransitionHost(size: CGSize(width: 860, height: 680), controller: controller) {
            SettingsView(session: session)
        }
        return (host, session)
    }

    private let liveTranscript = "Show live transcript"

    private func barSays(_ host: TransitionHost, _ text: String) -> Bool {
        host.nodes(under: host.node(named: "Unsaved changes")).contains { $0.text == text }
    }

    @Test("An edit makes a draft that survives moving to another page and back, and Discard drops it")
    func draftSurvivesNavigationAndDiscard() async throws {
        let controller = F.sampleController()
        let (host, session) = host(controller)
        defer { host.close() }
        await host.settle { host.node(named: liveTranscript) != nil }
        let before = try #require(host.node { $0.role == "AXCheckBox" && $0.name == liveTranscript }?.number)
        #expect(barSays(host, "No unsaved changes"))
        #expect(host.node(identifier: "settings.save")?.isEnabled == false)

        try await host.press(liveTranscript)
        #expect(await host.settle { !barSays(host, "No unsaved changes") }, "the bar did not notice the edit")
        #expect(host.node(identifier: "settings.save")?.isEnabled == true)
        #expect(host.node { $0.role == "AXCheckBox" && $0.name == liveTranscript }?.number == 1 - before)

        try await host.press("Microphone")
        #expect(await host.settle { session.selectedSection == .microphone && host.node(named: liveTranscript) == nil })
        #expect(!barSays(host, "No unsaved changes"), "the draft was lost on another page")
        try await host.press("Recording")
        #expect(await host.settle { host.node(named: liveTranscript) != nil })
        #expect(host.node { $0.role == "AXCheckBox" && $0.name == liveTranscript }?.number == 1 - before,
                "the switch came back showing the saved value, not the draft")

        try await host.press("Discard")
        #expect(await host.settle { barSays(host, "No unsaved changes") })
        #expect(host.node { $0.role == "AXCheckBox" && $0.name == liveTranscript }?.number == before)
        #expect(controller.preferences == session.draft.preferences)
    }

    @Test("Save Changes applies the draft and the bar says Saved")
    func saveApplies() async throws {
        let controller = F.sampleController()
        let (host, session) = host(controller)
        defer { host.close() }
        await host.settle { host.node(named: liveTranscript) != nil }
        let saved = controller.preferences

        try await host.press(liveTranscript)
        #expect(await host.settle { host.node(identifier: "settings.save")?.isEnabled == true })
        try await host.press("Save Changes")
        #expect(await host.settle { controller.preferences != saved }, "Save did not reach the controller")
        #expect(await host.settle { barSays(host, "Saved") }, "the bar does not say Saved")
        #expect(session.draft.preferences == controller.preferences)
        #expect(host.node(identifier: "settings.save")?.isEnabled == false)
    }

    @Test("A change made outside the window while a draft is open is caught, and Discard loads it")
    func externalChangeConflicts() async throws {
        let controller = F.sampleController()
        let (host, _) = host(controller)
        defer { host.close() }
        await host.settle { host.node(named: liveTranscript) != nil }
        let conflict = SettingsDraftBarState.externalConflict.message

        try await host.press(liveTranscript)
        #expect(await host.settle { host.node(identifier: "settings.save")?.isEnabled == true })
        controller.preferences.hotkeys.optionPressToTalkEnabled.toggle()
        let external = controller.preferences.hotkeys.optionPressToTalkEnabled
        #expect(await host.settle { barSays(host, conflict) }, "the conflict is not shown")
        #expect(host.node(identifier: "settings.save")?.isEnabled == false, "a stale draft can still be saved")

        try await host.press("Discard")
        #expect(await host.settle { barSays(host, "No unsaved changes") })
        #expect(host.node { $0.role == "AXCheckBox" && $0.name == "Hold Option to dictate" }?.number == (external ? 1 : 0),
                "the switch does not show the change made elsewhere")
    }

    @Test("Settings › Microphone names a chosen microphone that is unplugged and says what Steno uses instead")
    func unpluggedMicrophone() async throws {
        let base = SettingsWindowRenderingTests()
        let controller = base.makeController(.light)
        controller.preferences.inputDeviceID = "unplugged-usb-microphone"
        let session = base.session(for: controller, section: .microphone)
        let host = TransitionHost(size: CGSize(width: 860, height: 700), controller: controller) { SettingsView(session: session) }
        defer { host.close() }
        let input = { host.views(NSPopUpButton.self).first { $0.itemTitles.contains("MacBook Pro Microphone") } }
        #expect(await host.settle { input() != nil }, "no Input menu")
        let menu = try #require(input())
        // It showed nothing at all: the choice matched none of the listed inputs.
        #expect(menu.titleOfSelectedItem == "Chosen microphone", "the Input menu shows “\(menu.titleOfSelectedItem ?? "")”")
        #expect(host.node { $0.text.hasPrefix("Not connected. Steno uses MacBook Pro Microphone") } != nil, "no note: \(host.names())")
        try await host.press("Follow the system input")
        #expect(await host.settle { host.node { $0.text.hasPrefix("Not connected.") } == nil }, "the note stayed after following the system")
        await controller.teardownAndWait()
    }
}

/// The first-run guide stepped forward and back with its own buttons.
@Suite("Onboarding transitions", .serialized)
@MainActor
struct OnboardingTransitionTests {
    @Test("Continue and Back move between Welcome, Permissions and the first dictation, each showing only its own step")
    func stepsForwardAndBack() async throws {
        // No History: the sample's are dated at set times of today, which are later than now
        // before mid-morning and would read as a first dictation made on the last step.
        let controller = TransitionFixtures.sampleController([])
        let host = TransitionHost(controller: controller) { OnboardingView() }
        defer { host.close() }
        let welcome = { host.node(named: "Steno") != nil && host.node(named: "Back") == nil }
        let permissions = { host.node(named: "Three permissions") != nil }
        let firstDictation = { host.node(named: "Skip the first dictation and finish setup") != nil }
        await host.settle { welcome() }
        #expect(welcome())

        try await host.press("Get Started")
        #expect(await host.settle { permissions() }, "Permissions did not show: \(host.names())")
        #expect(!welcome(), "Welcome stayed")

        try await host.press("Back")
        #expect(await host.settle { welcome() }, "Back did not return to Welcome")
        #expect(!permissions())

        try await host.press("Get Started")
        #expect(await host.settle { permissions() })
        try await host.press(prefix: "Continue to ")
        #expect(await host.settle { firstDictation() }, "the first dictation did not show: \(host.names())")
        #expect(!permissions(), "Permissions stayed on the first dictation")

        try await host.press("Back")
        #expect(await host.settle { permissions() })
        #expect(!firstDictation())
    }

    @Test("Onboarding's first dictation starts Arabic and Hebrew at the right of its box, and English at the left")
    func onboardingFirstDictationDirection() async throws {
        let base = SettingsWindowRenderingTests()
        for (text, rightToLeft) in [("سأتصل بك بعد الاجتماع", true), ("אני אתקשר אליך", true), ("Call me back when you land.", false)] {
            var entry = GroveOnboardingRenderingTests.firstDictation
            entry.cleanText = text
            entry.rawText = text
            let controller = base.makeController(.light, populated: false)
            let host = TransitionHost(size: GroveOnboardingRenderingTests.size, controller: controller) {
                OnboardingView(initialStep: 2, previewFirstDictation: entry)
            }
            defer { host.close() }
            #expect(await host.settle { host.node { $0.text == text } != nil }, "no first dictation: \(host.names())")
            let words = try #require(host.node { $0.text == text }).screenFrame
            let heading = try #require(host.node { $0.text == "That’s your first dictation" }).screenFrame
            if rightToLeft {
                #expect(words.minX > heading.minX + 150, "“\(text)” starts at the left of the box")
            } else {
                #expect(words.minX < heading.minX + 40, "“\(text)” does not start at the left")
            }
            await controller.teardownAndWait()
        }
    }
}
