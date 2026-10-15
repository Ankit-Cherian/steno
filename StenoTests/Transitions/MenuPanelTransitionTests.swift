import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The menu bar panel following the controller while it is open.
@Suite("Menu panel transitions", .serialized)
@MainActor
struct MenuPanelTransitionTests {
    private static let devices = [InputDeviceOption(id: "built-in", name: "MacBook Pro Microphone", isDefault: true),
                                  InputDeviceOption(id: "usb", name: "USB Microphone", isDefault: false)]

    private func makePresenter() -> GroveMenuPresenter {
        GroveMenuPresenter(installsMonitors: false, reducesTransparency: { false },
                           present: { panel in
                               panel.alphaValue = 0
                               panel.ignoresMouseEvents = true
                               panel.orderFrontRegardless()
                           },
                           dismiss: { $0.orderOut(nil) })
    }

    private func snapshot(_ lifecycle: RecordingLifecycleState = .idle, entries: [TranscriptEntry] = [],
                          denied: Bool = false, device: String? = nil) -> MenuBarSnapshot {
        let recording = lifecycle == .recordingHandsFree || lifecycle == .recordingPressToTalk
        return MenuBarSnapshot(lifecycle: lifecycle, isRecording: recording,
                               recordingStartedAt: recording ? Date() : nil, entries: entries, microphoneDenied: denied,
                               canPasteLast: !entries.isEmpty, devices: Self.devices, selectedDeviceID: device)
    }

    private func show(_ presenter: GroveMenuPresenter, _ snapshot: MenuBarSnapshot) {
        presenter.show(snapshot: snapshot, targetAppName: "Mail", accent: .dodger, appearance: NSAppearance(named: .darkAqua),
                       statusItemFrame: CGRect(x: -19_000, y: -19_100, width: 28, height: 24),
                       screenFrame: CGRect(x: -20_000, y: -20_000, width: 1440, height: 900),
                       anchorWindow: nil, keyboardInitiated: false)
    }

    /// What VoiceOver reads in the panel: the status line, then each item.
    private func read(_ presenter: GroveMenuPresenter) -> (status: String, items: [NSAccessibilityElement]) {
        let children = presenter.panel.contentView?.accessibilityChildren() ?? []
        let status = (children.first as? NSAccessibilityElement)?.accessibilityLabel() ?? ""
        return (status, children.dropFirst().compactMap { $0 as? NSAccessibilityElement })
    }

    private func item(_ presenter: GroveMenuPresenter, _ label: String) -> NSAccessibilityElement? {
        read(presenter).items.first { $0.accessibilityLabel() == label }
    }

    /// Waits for the panel to show `condition`, so a slow main thread cannot make a check run early.
    private func settle(until condition: @MainActor () -> Bool) async {
        _ = await eventuallyOnMain { condition() }
    }

    private func barsShown(_ presenter: GroveMenuPresenter) -> Bool {
        func walk(_ view: NSView) -> Bool { view is GroveBarsView || view.subviews.contains(where: walk) }
        return presenter.panel.contentView.map(walk) ?? false
    }

    @Test("The status VoiceOver reads first names the state the panel's header shows", arguments: [
        (RecordingLifecycleState.idle, "Ready"), (.recordingHandsFree, "Listening"),
        (.recordingPressToTalk, "Listening"), (.transcribing, "Transcribing"),
    ])
    func spokenStatusMatchesTheHeader(lifecycle: RecordingLifecycleState, title: String) async throws {
        let presenter = makePresenter()
        defer { presenter.close() }
        show(presenter, snapshot(lifecycle))
        let container = try #require(presenter.panel.contentView as? GroveMenuContainerView)
        await settle { !read(presenter).status.isEmpty }
        // The header is hidden from VoiceOver, which reads the status line instead, so what it
        // draws is read from the title it draws.
        #expect(container.state.title == title, "the header shows \(container.state.title)")
        #expect(read(presenter).status.components(separatedBy: ", ").first == title,
                "VoiceOver reads “\(read(presenter).status)” for a header that shows \(container.state.title)")
    }

    @Test("Idle, listening, transcribing and the result each replace what the panel said before")
    func lifecycle() async throws {
        let presenter = makePresenter()
        defer { presenter.close() }
        show(presenter, snapshot())
        await settle { item(presenter, "Dictate") != nil }
        #expect(item(presenter, "Dictate") != nil)
        #expect(!barsShown(presenter))
        let idleHeight = presenter.panel.frame.height

        presenter.refresh(snapshot: snapshot(.recordingHandsFree), targetAppName: "Mail")
        // The voice bars are an AppKit view inside SwiftUI, which can be added on a later layout
        // pass than the status change.
        await settle {
            presenter.panel.contentView?.layoutSubtreeIfNeeded()
            return read(presenter).status.hasPrefix("Listening, ") && barsShown(presenter)
        }
        #expect(read(presenter).status.hasPrefix("Listening, "),
                "status: \(read(presenter).status)")
        #expect(item(presenter, "Stop and insert") != nil)
        #expect(item(presenter, "Dictate") == nil, "Dictate stayed while listening")
        #expect(barsShown(presenter), "no voice bars while listening")

        presenter.refresh(snapshot: snapshot(.transcribing), targetAppName: "Mail")
        await settle {
            presenter.panel.contentView?.layoutSubtreeIfNeeded()
            return read(presenter).status == "Transcribing, on this Mac" && !barsShown(presenter)
        }
        #expect(read(presenter).status == "Transcribing, on this Mac")
        #expect(item(presenter, "Stop and insert") == nil, "Stop stayed while transcribing")
        #expect(!barsShown(presenter), "the voice bars stayed after listening")

        let result = TranscriptEntry(appBundleID: "com.apple.mail", rawText: "Lunch at noon", cleanText: "Lunch at noon",
                                     audioURL: nil, insertionStatus: .inserted)
        presenter.refresh(snapshot: snapshot(entries: [result]), targetAppName: "Mail")
        await settle { item(presenter, "Dictate") != nil && read(presenter).items.contains { $0.accessibilityLabel()?.contains("Paste") == true || $0.accessibilityLabel()?.contains("Copy") == true } }
        #expect(item(presenter, "Dictate") != nil)
        #expect(read(presenter).items.contains { $0.accessibilityLabel()?.contains("Paste") == true || $0.accessibilityLabel()?.contains("Copy") == true },
                "the result cannot be reached from the panel")
        #expect(presenter.panel.frame.height >= idleHeight)
        #expect(presenter.panel.frame.maxY <= -19_100, "the panel left its place under the item")
    }

    @Test("Microphone access turned off disables Dictate and offers Turn On; turned back on, both clear")
    func microphoneDeniedAppearsAndClears() async throws {
        let presenter = makePresenter()
        defer { presenter.close() }
        show(presenter, snapshot())
        await settle { item(presenter, "Dictate")?.isAccessibilityEnabled() == true && item(presenter, "Turn on microphone access") == nil }
        #expect(item(presenter, "Dictate")?.isAccessibilityEnabled() == true)
        #expect(item(presenter, "Turn on microphone access") == nil)

        presenter.refresh(snapshot: snapshot(denied: true), targetAppName: "Mail")
        await settle { item(presenter, "Dictate")?.isAccessibilityEnabled() == false && item(presenter, "Turn on microphone access") != nil }
        #expect(item(presenter, "Dictate")?.isAccessibilityEnabled() == false)
        #expect(item(presenter, "Turn on microphone access") != nil)

        presenter.refresh(snapshot: snapshot(), targetAppName: "Mail")
        await settle { item(presenter, "Dictate")?.isAccessibilityEnabled() == true && item(presenter, "Turn on microphone access") == nil }
        #expect(item(presenter, "Dictate")?.isAccessibilityEnabled() == true, "Dictate stayed disabled")
        #expect(item(presenter, "Turn on microphone access") == nil, "Turn On stayed after access came back")
    }

    @Test("Choosing another microphone moves the selection: the old one no longer reads as selected")
    func microphoneSelectionDoesNotStick() async throws {
        let presenter = makePresenter()
        defer { presenter.close() }
        show(presenter, snapshot(device: "built-in"))
        presenter.state.setExpanded(.microphone, true)
        await settle { item(presenter, "MacBook Pro Microphone")?.isAccessibilitySelected() == true }
        let builtIn = try #require(item(presenter, "MacBook Pro Microphone"))
        #expect(builtIn.isAccessibilitySelected())
        #expect(item(presenter, "USB Microphone")?.isAccessibilitySelected() == false)

        presenter.refresh(snapshot: snapshot(device: "usb"), targetAppName: "Mail")
        await settle { item(presenter, "USB Microphone")?.isAccessibilitySelected() == true }
        #expect(item(presenter, "USB Microphone")?.isAccessibilitySelected() == true)
        #expect(item(presenter, "MacBook Pro Microphone")?.isAccessibilitySelected() == false,
                "the microphone that was chosen before still reads as selected")
        #expect(item(presenter, "Microphone")?.isAccessibilitySelected() == false)
    }
}
