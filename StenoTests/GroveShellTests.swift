import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

@Suite("Grove shell logic")
@MainActor
struct GroveShellLogicTests {
    @Test("The three sections keep their order and their shortcuts")
    func sections() {
        #expect(StenoTab.allCases.map(\.title) == ["Today", "History", "Insights"])
        #expect(StenoTab.allCases.map { $0.shortcut.character } == ["1", "2", "3"])
    }

    @Test("History's list column keeps its width")
    func widths() {
        #expect(GroveMetrics.historyListWidth == 320)
    }
}

@Suite("Grove confirmations")
@MainActor
struct GroveFeedbackTests {
    @Test("A note is shown, announced to VoiceOver, and replaced by the next one")
    func noteIsAnnounced() {
        let feedback = GroveFeedback()
        var announced: [String] = []
        feedback.announce = { announced.append($0) }
        feedback.post("Copied to the clipboard")
        #expect(feedback.notice?.text == "Copied to the clipboard")
        feedback.post("Dictation deleted", systemImage: "trash")
        #expect(feedback.notice?.text == "Dictation deleted")
        #expect(announced == ["Copied to the clipboard", "Dictation deleted"])
        feedback.dismissNotice()
        #expect(feedback.notice == nil)
    }

    @Test("A note goes away on its own")
    func noteExpires() async {
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        let posted = ContinuousClock.now
        feedback.post("Copied", action: nil)
        #expect(feedback.notice != nil)
        #expect(await eventuallyOnMain { feedback.notice == nil })
        // It stayed at least its full time; a busy machine can only make that longer.
        #expect(ContinuousClock.now - posted >= GroveFeedback.plainDuration)
    }

    @Test("A dialog runs its action only when confirmed")
    func dialog() {
        let feedback = GroveFeedback()
        var deleted = 0
        feedback.confirm(title: "Delete this dictation?", message: "m", confirmTitle: "Delete") { deleted += 1 }
        #expect(feedback.dialog?.title == "Delete this dictation?")
        feedback.resolveDialog(confirmed: false)
        #expect(feedback.dialog == nil)
        #expect(deleted == 0)
        feedback.confirm(title: "t", message: "m", confirmTitle: "Delete") { deleted += 1 }
        feedback.resolveDialog(confirmed: true)
        #expect(deleted == 1)
        #expect(feedback.dialog == nil)
    }
}

@Suite("Grove window chrome")
@MainActor
struct GroveWindowChromeTests {
    @Test("Arrow keys, Return and Delete reach the list handler; modified keys do not")
    func keyHandling() throws {
        let view = GroveKeyView()
        var moves: [GroveMove] = []
        var returned = 0
        var deleted = 0
        view.onMove = { moves.append($0) }
        view.onReturn = { returned += 1 }
        view.onDelete = { deleted += 1 }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                          context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        view.keyDown(with: try key(126))
        view.keyDown(with: try key(125))
        view.keyDown(with: try key(36))
        view.keyDown(with: try key(51))
        view.keyDown(with: try key(125, .command))
        #expect(moves == [.up, .down])
        #expect(returned == 1)
        #expect(deleted == 1)
        #expect(!view.isAccessibilityElement())
        #expect(view.focusRingType == .none)
    }
}

@Suite("Grove shell renders", .serialized)
@MainActor
struct GroveShellRenderingTests {
    typealias Variant = GroveRenderHarness.Variant

    @Test("The shell around each section", arguments: StenoTab.allCases, [Variant.light, .dark])
    func shell(tab: StenoTab, variant: Variant) async throws {
        let controller = GroveRenderHarness.sampleController(variant)
        try await GroveRenderHarness.write(ContentView(initialTab: tab), controller: controller, variant: variant,
                                           name: "shell-\(tab.rawValue.lowercased())-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("A problem shows in the toolbar's status pill")
    func problem() async throws {
        let controller = GroveRenderHarness.sampleController(.light)
        controller.microphonePermissionStatus = .denied
        try await GroveRenderHarness.write(ContentView(initialTab: .history), controller: controller, variant: .light,
                                           name: "shell-problem-light")
        await controller.teardownAndWait()
    }

    @Test("Every pill button kind, on the window ground and on forest glass", arguments: [Variant.light, .dark])
    func buttons(variant: Variant) async throws {
        let view = GroveWindowContent(accent: .citron, feedback: GroveFeedback()) {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Button("Primary") {}.buttonStyle(.grove(.primary, .large))
                    Button("Outline") {}.buttonStyle(.grove(.outline))
                    Button("Ghost") {}.buttonStyle(.grove(.ghost))
                    Button("Small") {}.buttonStyle(.grove(.outline, .small))
                    Button("Delete") {}.buttonStyle(.grove(.danger))
                }
                HStack(spacing: 10) {
                    Button("Stop") {}.buttonStyle(.grove(.cream))
                    Button("Discard") {}.buttonStyle(.grove(.soft))
                }
                .padding(18)
                .forestGlass(cornerRadius: 18)
            }
            .padding(30)
        }
        let data = try await GroveRenderHarness.render(view, controller: nil, variant: variant, size: CGSize(width: 560, height: 220))
        try data.write(to: GroveRenderHarness.outputDirectory.appendingPathComponent("buttons-\(variant.rawValue).png"))
        #expect(data.count > 4_000)
    }

    @Test("A note and a dialog draw over the window", arguments: [Variant.light, .dark])
    func feedback(variant: Variant) async throws {
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        feedback.post("Copied to the clipboard")
        feedback.confirm(title: HistoryRules.deleteOneTitle, message: HistoryRules.deleteOneMessage, confirmTitle: "Delete") {}
        let view = GroveWindowContent(accent: .citron, feedback: feedback) {
            Color.clear
        }
        let data = try await GroveRenderHarness.render(view, controller: nil, variant: variant,
                                                       size: CGSize(width: 760, height: 420))
        try data.write(to: GroveRenderHarness.outputDirectory.appendingPathComponent("feedback-dialog-\(variant.rawValue).png"))
        #expect(data.count > 4_000)
    }
}
