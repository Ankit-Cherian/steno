import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Every place the window shows the voice quill, light and dark: Today's stage (idle, listening,
/// transcribing, result), the empty Today and History, the setup guide's welcome and its final
/// step, and Settings' name and version line. Motion is on, so the stage shows the moving frames.
/// Output goes to `STENO_UI_RENDER_OUTPUT/grove/quill`, named `<place>-<look>`.
@Suite("The quill's placements", .serialized)
@MainActor
struct GroveQuillPlacementRenderingTests {
    typealias Variant = GroveRenderHarness.Variant
    typealias Harness = GroveRenderHarness

    static let looks: [Variant] = [.light, .dark]

    private func directory() throws -> URL {
        let directory = try Harness.outputDirectory.appendingPathComponent("quill", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write<V: View>(_ view: V, controller: DictationController, variant: Variant,
                                size: CGSize = Harness.windowSize, place: String,
                                prepare: (@MainActor () -> Void)? = nil) async throws {
        let data = try await Harness.render(view.environment(\._accessibilityReduceMotion, false), controller: controller,
                                            variant: variant, size: size,
                                            // Motion is on: let the window's own transitions finish first.
                                            settle: .milliseconds(1200), prepare: prepare)
        #expect(data.count > 8_000, "\(place)")
        try data.write(to: directory().appendingPathComponent("\(place)-\(variant.rawValue).png"))
    }

    @Test("Today: the idle stage, listening, transcribing and the result")
    func today() async throws {
        for variant in Self.looks {
            let ready = Harness.sampleController(variant)
            try await write(ContentView(initialTab: .today), controller: ready, variant: variant, place: "today-ready")
            await ready.teardownAndWait()

            let listening = Harness.sampleController(variant)
            listening.stageIsolatedPreviewLifecycle(.recordingHandsFree)
            listening.recordingStartedAt = Date().addingTimeInterval(-14)
            listening.stageIsolatedPreviewRecording(
                targetApp: "Mail",
                words: DictationController.LiveWords(stable: "Remind me to call the venue ", tail: "about the deposit"))
            try await write(ContentView(initialTab: .today), controller: listening, variant: variant,
                            place: "today-listening",
                            prepare: { for level: Float in [0.3, 0.8, 0.5, 0.9, 0.6, 0.75, 0.7] { listening.inputLevels.send(level) } })
            await listening.teardownAndWait()

            let transcribing = Harness.sampleController(variant)
            transcribing.stageIsolatedPreviewLifecycle(.transcribing)
            transcribing.stageIsolatedPreviewRecording(
                targetApp: nil, words: DictationController.LiveWords(stable: "Remind me to call the venue about the deposit", tail: ""))
            try await write(ContentView(initialTab: .today), controller: transcribing, variant: variant,
                            place: "today-transcribing")
            await transcribing.teardownAndWait()

            let settled = Harness.sampleController(variant)
            let text = "Remind me to call the venue about the deposit before Friday."
            let entry = TranscriptEntry(createdAt: Date(), appBundleID: "com.apple.mail", rawText: text, cleanText: text,
                                        durationMS: 14_000, audioURL: nil, insertionStatus: .inserted)
            let previous = settled.recentEntries.first?.id
            settled.recentEntries.insert(entry, at: 0)
            let flow = GroveTodayFlow(timing: .init(resultWait: .seconds(120), settleHold: .seconds(120), quietNote: .seconds(120)))
            flow.lifecycle(.recordingHandsFree, latestID: previous, canUndoDiscard: false)
            flow.lifecycle(.idle, latestID: previous, canUndoDiscard: false)
            flow.latestEntry(entry, appName: "Mail")
            try await write(Harness.window(.today, controller: settled) { GroveTodayView(flow: flow) }, controller: settled,
                            variant: variant, place: "today-result")
            await settled.teardownAndWait()
        }
    }

    @Test("The empty Today and History")
    func emptyStates() async throws {
        for variant in Self.looks {
            for (tab, place) in [(StenoTab.today, "today-empty"), (.history, "history-empty")] {
                let controller = Harness.sampleController(variant, populated: false)
                try await write(ContentView(initialTab: tab), controller: controller, variant: variant, place: place)
                await controller.teardownAndWait()
            }
        }
    }

    @Test("The setup guide: the welcome and the first dictation done")
    func onboarding() async throws {
        let base = SettingsWindowRenderingTests()
        for variant in Self.looks {
            for (place, step, entry) in [("onboarding-welcome", 0, nil), ("onboarding-done", 2, GroveOnboardingRenderingTests.firstDictation)]
                as [(String, Int, TranscriptEntry?)] {
                let controller = base.makeController(variant.scheme == .dark ? .dark : .light, populated: false)
                let view = OnboardingView(initialStep: step, previewFirstDictation: entry)
                    .environment(\.controlActiveState, .active)
                try await write(view, controller: controller, variant: variant,
                                size: GroveOnboardingRenderingTests.size, place: place)
                await controller.teardownAndWait()
            }
        }
    }

    @Test("Settings: the quill beside the name and version")
    func settings() async throws {
        let base = SettingsWindowRenderingTests()
        for variant in Self.looks {
            let controller = base.makeController(variant.scheme == .dark ? .dark : .light)
            let view = SettingsView(session: base.session(for: controller, section: .general))
                .environment(\.controlActiveState, .active)
            try await write(view, controller: controller, variant: variant,
                            size: GroveSettingsRenderingTests.windowSize, place: "settings")
            await controller.teardownAndWait()
        }
    }
}
