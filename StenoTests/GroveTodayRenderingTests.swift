import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Draws Grove's Today in every state to PNG, to be read against the reference renders.
@Suite("Grove Today renders", .serialized)
@MainActor
struct GroveTodayRenderingTests {
    typealias Variant = GroveRenderHarness.Variant
    typealias Harness = GroveRenderHarness

    private static let words = DictationController.LiveWords(
        stable: "Remind me to call the venue about the deposit ", tail: "before Friday")
    private static let held = GroveTodayFlow.Timing(resultWait: .seconds(120), settleHold: .seconds(120), quietNote: .seconds(120))

    /// A dictation finished a few minutes after the sample's newest one.
    private static func newEntry(_ status: InsertionStatus = .inserted, reason: String? = nil) -> TranscriptEntry {
        let text = "Remind me to call the venue about the deposit before Friday."
        return TranscriptEntry(createdAt: Date(), appBundleID: "com.apple.mail", rawText: text, cleanText: text,
                               durationMS: 14_000, audioURL: nil, insertionStatus: status,
                               record: reason.map { DictationRecord(copyReason: $0) })
    }

    // MARK: Ready, recording and the result

    @Test("Ready", arguments: Variant.allCases)
    func ready(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: variant,
                                name: "today-ready-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Recording, with live words and a destination", arguments: Variant.allCases)
    func recording(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date().addingTimeInterval(-14)
        controller.stageIsolatedPreviewRecording(targetApp: "Mail", words: Self.words)
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: variant,
                                name: "today-recording-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Recording from this window, before any words arrive")
    func recordingHere() async throws {
        let controller = Harness.sampleController(.light)
        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date().addingTimeInterval(-3)
        try await Harness.write(ContentView(initialTab: .today, initialState: .init(todayStartedHere: true)),
                                controller: controller, variant: .light, name: "today-recording-here-light")
        await controller.teardownAndWait()
    }

    @Test("Transcribing", arguments: [Variant.light, .dark])
    func transcribing(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        controller.stageIsolatedPreviewLifecycle(.transcribing)
        controller.stageIsolatedPreviewRecording(targetApp: nil, words: Self.words)
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: variant,
                                name: "today-transcribing-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    /// A flow that has just settled on `entry`, with the controller holding it as the newest dictation.
    private func settledFlow(_ entry: TranscriptEntry, on controller: DictationController) -> GroveTodayFlow {
        let previous = controller.recentEntries.first?.id
        controller.recentEntries.insert(entry, at: 0)
        let flow = GroveTodayFlow(timing: Self.held)
        flow.lifecycle(.recordingHandsFree, latestID: previous, canUndoDiscard: false)
        flow.lifecycle(.idle, latestID: previous, canUndoDiscard: false)
        flow.latestEntry(entry, appName: "Mail")
        return flow
    }

    @Test("The result on the plate: words settled, check drawn", arguments: [Variant.light, .dark, .contrast])
    func settled(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        let flow = settledFlow(Self.newEntry(), on: controller)
        let view = Harness.window(.today, controller: controller) { GroveTodayView(flow: flow) }
        try await Harness.write(view, controller: controller, variant: variant, name: "today-settled-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("A copy on the plate names the reason")
    func settledCopied() async throws {
        let controller = Harness.sampleController(.light)
        let flow = settledFlow(Self.newEntry(.copiedOnly, reason: "appChanged"), on: controller)
        let view = Harness.window(.today, controller: controller) { GroveTodayView(flow: flow) }
        try await Harness.write(view, controller: controller, variant: .light, name: "today-settled-copied-light")
        await controller.teardownAndWait()
    }

    @Test("The plate has folded: the new dictation is the latest card", arguments: [Variant.light, .dark])
    func folded(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        controller.recentEntries.insert(Self.newEntry(), at: 0)
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: variant,
                                name: "today-folded-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("A problem becomes a note with its action", arguments: [Variant.light, .dark])
    func problem(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        let flow = settledFlow(Self.newEntry(.failed), on: controller)
        let view = Harness.window(.today, controller: controller) { GroveTodayView(flow: flow) }
        try await Harness.write(view, controller: controller, variant: variant, name: "today-problem-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("A discard offers Undo")
    func discarded() async throws {
        let controller = Harness.sampleController(.light)
        let flow = GroveTodayFlow(timing: Self.held)
        flow.lifecycle(.recordingHandsFree, latestID: controller.recentEntries.first?.id, canUndoDiscard: false)
        flow.lifecycle(.idle, latestID: controller.recentEntries.first?.id, canUndoDiscard: true, hint: .canceled)
        let view = Harness.window(.today, controller: controller) { GroveTodayView(flow: flow) }
        try await Harness.write(view, controller: controller, variant: .light, name: "today-discarded-light")
        await controller.teardownAndWait()
    }

    // MARK: Other states

    @Test("No dictations yet", arguments: [Variant.light, .dark])
    func empty(variant: Variant) async throws {
        let controller = Harness.sampleController(variant, populated: false)
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: variant,
                                name: "today-empty-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Microphone off")
    func microphoneOff() async throws {
        let controller = Harness.sampleController(.light)
        controller.microphonePermissionStatus = .denied
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: .light, name: "today-microphone-off-light")
        await controller.teardownAndWait()
    }

    @Test("Shortcuts off")
    func shortcutsOff() async throws {
        let controller = Harness.sampleController(.light)
        controller.preferences.hotkeys.optionPressToTalkEnabled = false
        controller.preferences.hotkeys.handsFreeGlobalKeyCode = nil
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: .light, name: "today-shortcuts-off-light")
        await controller.teardownAndWait()
    }

    @Test("Fix a word open on the latest dictation", arguments: [Variant.light, .dark])
    func fixWord(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        let fix = FixWordState(entryID: WindowSampleData.latestID,
                               range: (WindowSampleData.latestText as NSString).range(of: "Dana"),
                               word: "Dana", replacement: "Danna")
        try await Harness.write(ContentView(initialTab: .today, initialState: .init(fix: fix)), controller: controller,
                                variant: variant, name: "today-fix-word-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("The minimum window")
    func minimum() async throws {
        let controller = Harness.sampleController(.light)
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: .light,
                                size: Harness.minimumSize, name: "today-minimum-light")
        await controller.teardownAndWait()
    }

    @Test("A note over Today after Copy")
    func copiedNote() async throws {
        let controller = Harness.sampleController(.light)
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        feedback.post("Copied to the clipboard", systemImage: "doc.on.doc")
        let view = Harness.window(.today, controller: controller, feedback: feedback) { GroveTodayView() }
        try await Harness.write(view, controller: controller, variant: .light, name: "today-copied-note-light")
        await controller.teardownAndWait()
    }
}
