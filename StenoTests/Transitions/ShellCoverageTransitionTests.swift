import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The whole window: Today's ways into History, a recording that outlives a section switch,
/// ⌘1 to ⌘3, the recovery strips, and the window resized from its minimum to large.
@Suite("Window coverage transitions", .serialized)
@MainActor
struct ShellCoverageTransitionTests {
    typealias F = TransitionFixtures

    private func host(_ controller: DictationController, size: CGSize = GroveRenderHarness.windowSize) -> TransitionHost {
        TransitionHost(size: size, controller: controller) { ContentView() }
    }

    private func isOnToday(_ host: TransitionHost) -> Bool { host.node(identifier: "today.start") != nil }
    private func isOnHistory(_ host: TransitionHost) -> Bool { host.node(identifier: "history.more") != nil }
    private func isOnInsights(_ host: TransitionHost) -> Bool { host.node(named: "The last six months") != nil }

    private func readerText(_ host: TransitionHost) -> String? {
        host.transcriptViews().first?.textStorage?.string
    }

    private func says(_ host: TransitionHost, _ prefix: String) -> Bool {
        host.node { $0.text.hasPrefix(prefix) } != nil
    }

    // MARK: Today into History

    @Test("How It Was Written on Today opens History on that dictation with its steps in view")
    func howItWasWrittenFromToday() async throws {
        let text = F.longText + " " + F.longText
        let latest = TranscriptEntry(appBundleID: "com.apple.mail", rawText: text, cleanText: text, audioURL: nil,
                                     insertionStatus: .inserted, record: WindowSampleData.latestRecord)
        let controller = F.sampleController([latest, F.entry(WindowSampleData.groceries, minutesAgo: 5)])
        let host = host(controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }

        try await host.press("How It Was Written")
        #expect(await host.settle { isOnHistory(host) }, "History did not open: \(host.names().prefix(10))")
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(text) }, "History opened on another dictation")
        let window = host.window.frame
        #expect(await host.settle { host.node(named: "How it was written").map { window.contains($0.screenFrame.insetBy(dx: 2, dy: 2)) } ?? false },
                "How it was written is at \(host.node(named: "How it was written")?.screenFrame ?? .zero), outside \(window)")
    }

    @Test("A row under Earlier today opens History on that dictation, and Show in History opens History")
    func earlierRowAndShowInHistory() async throws {
        let entries = [F.entry(WindowSampleData.latestText), F.entry(WindowSampleData.groceries, minutesAgo: 4),
                       F.entry(WindowSampleData.booking, minutesAgo: 8)]
        let controller = F.sampleController(entries)
        let host = host(controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }

        let row = try #require(host.node { $0.role == "AXButton" && $0.name.hasPrefix("Book a table") })
        #expect(row.help == "Opens it in History")
        #expect(row.press())
        #expect(await host.settle { isOnHistory(host) && readerText(host) == GroveFlowText.displayText(entries[2].cleanText) },
                "the row opened \(readerText(host)?.prefix(30) ?? "nothing")")

        try await host.selectSegment("Today")
        #expect(await host.settle { isOnToday(host) })
        try await host.press("Show in History")
        #expect(await host.settle { isOnHistory(host) })
    }

    @Test("Earlier today's last row opens History on the first dictation it left out, in view")
    func earlierTodayMoreOpensHistory() async throws {
        let entries = (0..<20).map { F.entry("Note number \($0) for the morning review.", minutesAgo: Double($0) / 60) }
        let controller = F.sampleController(entries)
        // Tall enough that Today's lazy list builds its last row.
        let host = host(controller, size: CGSize(width: 1120, height: 1_600))
        defer { host.close() }
        await host.settle { isOnToday(host) }

        try await host.press("7 more in History")
        let firstLeftOut = entries[13]
        #expect(await host.settle { isOnHistory(host) && readerText(host) == GroveFlowText.displayText(firstLeftOut.cleanText) },
                "History opened on \(readerText(host)?.prefix(30) ?? "nothing")")
        let row = try #require(host.node(identifier: "history.row.\(firstLeftOut.id.uuidString)"), "the row is not in the list")
        #expect(host.window.frame.contains(row.screenFrame.insetBy(dx: 2, dy: 2)), "the row is at \(row.screenFrame), outside \(host.window.frame)")
    }

    @Test("A dictation keeps going while the window switches sections, and Today shows it on return")
    func recordingSurvivesSectionSwitches() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }
        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date()
        controller.stageIsolatedPreviewRecording(targetApp: "Mail", words: .init(stable: "Draft the reply", tail: " to Dana"))
        #expect(await host.settle { host.node(named: "Stop and insert") != nil })

        for (segment, check) in [("History", isOnHistory), ("Insights", isOnInsights)] {
            try await host.selectSegment(segment)
            #expect(await host.settle { check(host) }, "\(segment) did not show while recording")
        }
        try await host.selectSegment("Today")
        #expect(await host.settle { host.node(named: "Stop and insert") != nil }, "Today lost the recording: \(host.names().prefix(10))")
        #expect(says(host, "Listening"))
        #expect(host.node { $0.text.contains("Draft the reply to Dana") } != nil)
        controller.stageIsolatedPreviewLifecycle(.idle)
    }

    @Test("⌘1, ⌘2 and ⌘3 switch sections from the keyboard in a window without the View menu's commands")
    func commandNumberSwitches() async throws {
        // The app's View menu holds these keys for its own scene's window. A window outside that
        // scene, like this one, carries the same keys itself.
        let installed = StenoWindowCommandsInstallation.isInstalled
        StenoWindowCommandsInstallation.isInstalled = false
        defer { StenoWindowCommandsInstallation.isInstalled = installed }
        let host = host(F.sampleController())
        defer { host.close() }
        host.window.makeKey()
        await host.settle { isOnToday(host) }
        for (key, character, check) in [(UInt16(19), "2", isOnHistory), (20, "3", isOnInsights), (18, "1", isOnToday)] {
            await host.keyPress(key, characters: character, modifiers: .command)
            #expect(await host.settle { check(host) }, "⌘\(character) did not switch: \(host.names().prefix(8))")
        }
    }

    // MARK: Strips

    @Test("Accessibility and Input Monitoring turned off each show a strip that names the fix, and Dismiss hides it")
    func permissionStrips() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }
        try await host.selectSegment("History")
        await host.settle { isOnHistory(host) }

        controller.accessibilityPermissionStatus = .denied
        #expect(await host.settle { says(host, "Accessibility access is off") }, "\(host.names().prefix(8))")
        controller.inputMonitoringPermissionStatus = .denied
        #expect(await host.settle { says(host, "Input Monitoring is off") })
        #expect(host.nodes(named: "Open System Settings").count == 2)

        let dismissals = host.nodes(named: "Dismiss")
        #expect(dismissals.count == 2)
        #expect(dismissals.first?.press() == true)
        #expect(await host.settle { !says(host, "Accessibility access is off") }, "Dismiss left the strip")
        #expect(says(host, "Input Monitoring is off"), "Dismiss hid the other strip too")

        controller.inputMonitoringPermissionStatus = .granted
        #expect(await host.settle { !says(host, "Input Monitoring is off") }, "the strip stayed after access came back")
    }

    @Test("Microphone access off shows a strip that cannot be dismissed on History, and none on Today, where the stage says it")
    func microphoneStrip() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }
        controller.microphonePermissionStatus = .denied
        #expect(await host.settle { says(host, "Microphone access is off") })
        #expect(host.nodes().filter { $0.text.hasPrefix("Microphone access is off") }.count == 1, "Today says it twice")

        try await host.selectSegment("History")
        #expect(await host.settle { isOnHistory(host) && says(host, "Microphone access is off") })
        #expect(host.node(named: "Dismiss") == nil, "the microphone strip can be dismissed")
        controller.microphonePermissionStatus = .granted
        #expect(await host.settle { !says(host, "Microphone access is off") })
    }

    @Test("A dictation that failed shows a strip with Open Settings, and Dismiss hides it")
    func attentionStrip() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }
        try await host.selectSegment("Insights")
        controller.lastError = "Steno couldn’t start the speech model. Check Speech Model in Settings."
        #expect(await host.settle { host.node { $0.text.contains("couldn’t start the speech model") } != nil }, "\(host.names().prefix(8))")
        #expect(host.node(named: "Open Settings") != nil)
        try await host.press("Dismiss")
        #expect(await host.settle { host.node { $0.text.contains("couldn’t start the speech model") } == nil })
    }

    @Test("A dictation that fails on Today says so once, in the strip, and Today goes back to its stage")
    func failedDictationOnTodayShowsOnce() async throws {
        let session = try await WindowDictation.make()
        defer { Task { await session.close() } }
        await session.coordinator.failNextTranscription("The speech model could not be loaded.")
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }

        try await host.press("Dictate")
        try await host.press("Stop and copy")
        #expect(await host.settle { says(host, "The speech model could not be loaded") }, "no error: \(host.names().prefix(12))")
        // Past the wait for a result that never comes, the stage is back and the error is said once.
        #expect(await host.settle(timeout: .seconds(6)) { isOnToday(host) }, "Today did not go back to its stage: \(host.names().prefix(12))")
        let mentions = host.nodes().filter { $0.text.contains("speech model could not be loaded") }
        #expect(mentions.count == 1, "Today says it \(mentions.count) times: \(mentions.map(\.text))")
        #expect(!says(host, "That dictation didn’t finish"))
        #expect(host.nodes(named: "Open Settings").count == 1)
        #expect(session.controller.recoverySection == .engine, "the strip opens \(session.controller.recoverySection)")

        try await host.selectSegment("History")
        #expect(await host.settle { isOnHistory(host) && says(host, "The speech model could not be loaded") }, "History lost the strip")
    }

    @Test("A missing speech model shows a strip on every section that names the fix and cannot be dismissed")
    func speechModelMissingStrip() async throws {
        SpeechModelAvailability.previewMissing = true
        defer { SpeechModelAvailability.previewMissing = false }
        let host = host(F.sampleController())
        defer { host.close() }
        for (segment, check) in [("Today", isOnToday), ("History", isOnHistory), ("Insights", isOnInsights)] {
            if segment != "Today" { try await host.selectSegment(segment) }
            #expect(await host.settle { check(host) && says(host, "Speech model not found") }, "\(segment): \(host.names().prefix(8))")
            #expect(host.node(named: "Open Speech Model Settings") != nil)
            #expect(host.node(named: "Dismiss") == nil, "the missing-model strip can be dismissed on \(segment)")
        }
    }

    // MARK: Resizing

    /// Named elements that stick out of the window on the left or right.
    private func overflowing(_ host: TransitionHost) -> [String] {
        let window = host.window.frame.insetBy(dx: -1, dy: -1)
        return host.nodes().filter { node in
            let frame = node.screenFrame
            return !node.name.isEmpty && frame.width > 0 && (frame.minX < window.minX || frame.maxX > window.maxX)
        }.map { "\($0.name.prefix(30)) \(Int($0.screenFrame.minX - window.minX))…\(Int($0.screenFrame.maxX - window.minX))" }
    }

    @Test("From the minimum to a large window and back, every section keeps everything inside the window")
    func resizingKeepsEveryThingInside() async throws {
        let controller = F.sampleController(WindowSampleData.worstCaseEntries())
        let host = host(controller, size: GroveRenderHarness.minimumSize)
        defer { host.close() }
        await host.settle { isOnToday(host) }
        let sizes = [GroveRenderHarness.minimumSize, CGSize(width: 1600, height: 1100), GroveRenderHarness.windowSize,
                     GroveRenderHarness.minimumSize]
        for (segment, check) in [("Today", isOnToday), ("History", isOnHistory), ("Insights", isOnInsights)] {
            try await host.selectSegment(segment)
            #expect(await host.settle { check(host) })
            for size in sizes {
                await host.resize(to: size)
                #expect(await host.settle { check(host) }, "\(segment) went away at \(size)")
                let out = overflowing(host)
                #expect(out.isEmpty, "\(segment) at \(Int(size.width))×\(Int(size.height)): \(out.prefix(6))")
            }
        }
        // The text follows the width up to the column's limit: the reader is wider at the large size.
        try await host.selectSegment("History")
        await host.resize(to: GroveRenderHarness.minimumSize)
        let narrow = try #require(host.transcriptViews().first).bounds.width
        await host.resize(to: CGSize(width: 1600, height: 1100))
        let wide = try #require(host.transcriptViews().first).bounds.width
        #expect(wide > narrow, "the reader stayed \(Int(narrow)) pt wide in a 1600 pt window (\(Int(wide)) pt)")
    }
}
