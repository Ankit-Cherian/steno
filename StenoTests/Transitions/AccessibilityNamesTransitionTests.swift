import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Every control on every screen has a name VoiceOver can say: a person moving through a
/// screen with VoiceOver hears what each one is, not "button" or "text field".
@Suite("VoiceOver names on every screen", .serialized)
@MainActor
struct AccessibilityNamesTransitionTests {
    typealias F = TransitionFixtures

    static let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXRadioButton",
                                            "AXTextField", "AXTextArea", "AXSlider", "AXIncrementor", "AXLink",
                                            "AXDisclosureTriangle", "AXComboBox", "AXSearchField"]

    /// The controls on screen with no name, by role, with what is around them.
    static func unnamed(_ host: TransitionHost) -> [String] {
        let nodes = host.nodes()
        return nodes.enumerated().compactMap { index, node in
            guard controlRoles.contains(node.role), node.name.isEmpty, node.help.isEmpty else { return nil }
            // A stepper's arrows are named by their kind ("increment arrow") and by the stepper.
            if ["AXIncrementArrow", "AXDecrementArrow"].contains(node.subrole) { return nil }
            let before = nodes[max(0, index - 2)..<index].map { $0.name.isEmpty ? $0.text : $0.name }.joined(separator: " / ")
            return "\(node.role) after “\(before.prefix(60))”"
        }
    }

    enum Screen: String, CaseIterable, CustomTestStringConvertible {
        case todayReady, todayListening, todayEmpty, history, historyEmpty, insights, insightsEmpty
        var testDescription: String { rawValue }
    }

    @Test("Every control on the window's screens has a name", arguments: Screen.allCases)
    func windowScreens(screen: Screen) async throws {
        let controller = F.sampleController(screen == .todayEmpty || screen == .historyEmpty ? [] : WindowSampleData.entries())
        if screen == .insightsEmpty { controller.usageAnalyticsSnapshot = .empty }
        let host = TransitionHost(controller: controller) {
            switch screen {
            case .todayReady, .todayListening, .todayEmpty:
                GroveRenderHarness.window(.today, controller: controller) { GroveTodayView() }
            case .history, .historyEmpty:
                GroveRenderHarness.window(.history, controller: controller) { GroveHistoryView(initialSelectedEntryID: WindowSampleData.latestID) }
            case .insights, .insightsEmpty:
                GroveRenderHarness.window(.insights, controller: controller) { GroveInsightsView() }
            }
        }
        defer { host.close() }
        if screen == .todayListening {
            controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
            controller.recordingStartedAt = Date()
            await host.settle { host.node(named: "Stop and insert") != nil }
        }
        await host.settle()
        await host.pump(.milliseconds(60))
        if screen != .insightsEmpty {
            #expect(host.nodes().contains { Self.controlRoles.contains($0.role) }, "\(screen) drew no controls")
        }
        #expect(Self.unnamed(host).isEmpty, "\(screen): \(Self.unnamed(host))")
        if screen == .todayListening { controller.stageIsolatedPreviewLifecycle(.idle) }
    }

    @Test("Every control on every Settings page has a name", arguments: SettingsSection.allCases)
    func settingsPages(section: SettingsSection) async throws {
        let controller = F.sampleController()
        let session = SettingsSession(previewDraft: SettingsDraftState(saved: controller.preferences), section: section)
        let host = TransitionHost(size: CGSize(width: 860, height: 1_000), controller: controller) { SettingsView(session: session) }
        defer { host.close() }
        await host.settle { host.node(identifier: "settings.section.\(section.rawValue)")?.isSelected == true }
        if section == .engine, let advanced = host.node(named: "Advanced") {
            advanced.press()
            await host.settle { host.node(named: "Model path") != nil }
        }
        #expect(Self.unnamed(host).isEmpty, "\(section): \(Self.unnamed(host))")
    }

    @Test("Fix a Word's form says the name of its word list once and names its Correct spelling field")
    func fixAWordFormNames() async throws {
        let controller = F.sampleController()
        let host = TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller) { GroveTodayView() }
        }
        defer { host.close() }
        let fixable: (TransitionHost.Node) -> Bool = { $0.customActionNames.contains { $0.hasPrefix("Fix a Word") } }
        await host.settle { host.node(where: fixable) != nil }
        #expect(try #require(host.node(where: fixable)).perform(action: "Fix a Word…"))
        let form = { host.popoverWindows.first?.contentView.map { host.nodes(under: TransitionHost.Node(object: $0)) } ?? [] }
        #expect(await host.settle { form().contains { $0.role == "AXTextField" } }, "the form did not open")
        // VoiceOver says a control's label, then its title when it has one.
        let spoken = { (node: TransitionHost.Node) in [node.label, node.title].filter { !$0.isEmpty }.joined(separator: ", ") }
        let list = try #require(form().first { $0.role == "AXPopUpButton" }, "no word list")
        #expect(spoken(list) == "Word", "the word list reads “\(spoken(list))”")
        let field = try #require(form().first { $0.role == "AXTextField" })
        #expect(field.label == "Correct spelling", "the field's name is “\(field.label)”")
    }

    @Test("Every control on every step of the setup guide has a name", arguments: [0, 1, 2])
    func onboardingSteps(step: Int) async throws {
        let controller = F.sampleController()
        controller.accessibilityPermissionStatus = .denied
        let host = TransitionHost(controller: controller) { OnboardingView(initialStep: step) }
        defer { host.close() }
        await host.settle()
        #expect(Self.unnamed(host).isEmpty, "step \(step): \(Self.unnamed(host))")
    }
}
