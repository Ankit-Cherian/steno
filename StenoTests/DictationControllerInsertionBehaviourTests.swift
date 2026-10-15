import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// Undo after discard, Copy and Paste Last Dictation, and what the overlay
/// says after an insertion, through the real controller and coordinator.
@Suite(.serialized)
@MainActor
struct DictationControllerInsertionBehaviourTests {
    // MARK: - Undo after discard

    @Test("Discarding a long recording offers Undo for the window, then deletes the audio and inserts nothing")
    func undoWindowExpires() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller
        controller.undoDiscardWindow = .milliseconds(300)
        let window = UndoWindowEnd()
        controller.undoDiscardWait = window.wait

        let before = Date()
        try await harness.recordThenDiscard()
        let after = Date()

        let undoUntil = try #require(harness.presenter.hostedEvidenceRequestedStates().compactMap { state -> Date? in
            if case .discarded(let until) = state { return until }
            return nil
        }.first)
        // The island counts down to the discard time plus the window.
        #expect(undoUntil >= before.addingTimeInterval(0.3) && undoUntil <= after.addingTimeInterval(0.3))
        #expect(window.requested == [.milliseconds(300)])
        #expect(controller.canUndoDiscard)
        #expect(controller.recordingLifecycleState == .idle)
        #expect(harness.media.ended == harness.media.begun)

        let audio = try #require(await harness.capture.endedURLs().first)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        window.end()
        #expect(await insertionEventually { @MainActor in !controller.canUndoDiscard })
        #expect(await insertionEventually { !FileManager.default.fileExists(atPath: audio.path) })
        #expect(controller.status == "Recording discarded.")

        controller.undoDiscard()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.transport.texts().isEmpty)
        #expect(await harness.history.recent(limit: 10).isEmpty)
        #expect(await harness.engine.transcriptionCount() == 0)
        await harness.finish()
    }

    @Test("Undo inserts the discarded recording once, as Stop would, without touching media")
    func undoInsertsOnce() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        try await harness.recordThenDiscard()
        let mediaCallsAfterDiscard = harness.media.callCount
        #expect(harness.media.ended == harness.media.begun)

        controller.undoDiscard()
        #expect(await insertionEventually { @MainActor in controller.status == "Transcript inserted." })
        controller.undoDiscard()
        try await Task.sleep(for: .milliseconds(100))

        let entries = await harness.history.recent(limit: 10)
        #expect(entries.count == 1)
        #expect(await harness.transport.texts() == entries.map(\.cleanText))
        #expect(!controller.canUndoDiscard)
        #expect(controller.recordingLifecycleState == .idle)
        #expect(harness.media.callCount == mediaCallsAfterDiscard)
        #expect(harness.presenter.hostedEvidenceRequestedStates().contains(
            .result(.inserted(appName: "Test Editor", method: .typed), showsWords: true)
        ))
        await harness.finish()
    }

    @Test("Undo after the user moved to another app copies the text instead and says so")
    func undoAfterAppChangeCopies() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        try await harness.recordThenDiscard()
        harness.frontmost = AppContext(bundleIdentifier: "com.example.other", appName: "Other")
        controller.undoDiscard()

        #expect(await insertionEventually { @MainActor in
            controller.recordingLifecycleState == .idle && !controller.lastTranscript.isEmpty
        })
        let entry = try #require(await harness.history.recent(limit: 1).first)
        #expect(await harness.clipboard.latestValue == entry.cleanText)
        #expect(await harness.transport.texts().isEmpty)
        #expect(controller.status == "Another app was in front—final text copied.")
        #expect(harness.presenter.hostedEvidenceRequestedStates().contains(
            .result(.copied(.appChanged), showsWords: true)
        ))
        #expect(await harness.history.recent(limit: 10).map(\.insertionStatus) == [.copiedOnly])
        await harness.finish()
    }

    @Test("Canceling while a restored recording transcribes inserts nothing")
    func cancelDuringUndoInsertsNothing() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller
        await harness.engine.blockUntilCanceled()

        try await harness.recordThenDiscard()
        controller.undoDiscard()
        #expect(await insertionEventually { await harness.engine.transcriptionCount() == 1 })
        #expect(controller.recordingLifecycleState == .transcribing)

        controller.cancelActiveRecording()

        #expect(await insertionEventually { @MainActor in controller.recordingLifecycleState == .idle })
        #expect(controller.status == "Transcription canceled.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.transport.texts().isEmpty)
        #expect(await harness.history.recent(limit: 10).isEmpty)
        #expect(harness.media.ended == harness.media.begun)
        await harness.finish()
    }

    @Test("Memory pressure inside the Undo window waits for the window, so Undo still works")
    func memoryPressureWaitsForUndoWindow() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        try await harness.recordThenDiscard()
        let audio = try #require(await harness.capture.endedURLs().first)
        await controller.unloadRuntimeForMemoryPressureTesting()

        #expect(controller.canUndoDiscard)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(await harness.engine.unloadCount() == 0)

        controller.undoDiscard()
        #expect(await insertionEventually { @MainActor in controller.status == "Transcript inserted." })
        #expect(await harness.transport.texts().count == 1)
        // The deferred unload runs once the restored dictation is finished.
        #expect(await insertionEventually { await harness.engine.unloadCount() == 1 })
        await harness.finish()
    }

    @Test("Memory pressure deferred by the Undo window unloads once the window expires")
    func memoryPressureRunsAfterWindowExpires() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller
        let window = UndoWindowEnd()
        controller.undoDiscardWait = window.wait

        try await harness.recordThenDiscard()
        await controller.unloadRuntimeForMemoryPressureTesting()
        #expect(await harness.engine.unloadCount() == 0)

        window.end()
        #expect(await insertionEventually { @MainActor in !controller.canUndoDiscard })
        #expect(await insertionEventually { await harness.engine.unloadCount() == 1 })
        #expect(controller.status == "Recording discarded.")
        await harness.finish()
    }

    @Test("Sleep inside the Undo window ends the window first; Undo then does nothing")
    func sleepEndsUndoWindow() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        try await harness.recordThenDiscard()
        let audio = try #require(await harness.capture.endedURLs().first)
        await controller.unloadRuntimeForLifecycleTesting()

        #expect(!controller.canUndoDiscard)
        #expect(controller.status == "Recording discarded.")
        #expect(await insertionEventually { !FileManager.default.fileExists(atPath: audio.path) })
        controller.undoDiscard()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.engine.transcriptionCount() == 0)
        #expect(await harness.transport.texts().isEmpty)
        await harness.finish()
    }

    @Test("The acceptance sleep trigger ends the Undo window through the app's own sleep path")
    func acceptanceSleepTriggerEndsUndoWindow() async throws {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        let harness = try InsertionBehaviourHarness(workspaceNotificationCenter: workspace)
        defer { harness.removeDirectory() }
        let controller = harness.controller
        let trigger = AcceptanceSleepTrigger(source: distributed, workspaceCenter: workspace)

        try await harness.recordThenDiscard()
        let audio = try #require(await harness.capture.endedURLs().first)
        #expect(controller.canUndoDiscard)

        distributed.post(name: AcceptanceSleepTrigger.notificationName, object: nil)

        #expect(await insertionEventually { @MainActor in !controller.canUndoDiscard })
        #expect(controller.status == "Recording discarded.")
        #expect(await insertionEventually { !FileManager.default.fileExists(atPath: audio.path) })
        withExtendedLifetime(trigger) {}
        await harness.finish()
    }

    @Test("Undo for a recording that is already gone says so quietly, not as a transcription error")
    func undoAfterRecordingIsGone() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        try await harness.recordThenDiscard()
        #expect(await insertionEventually { @MainActor in controller.canUndoDiscard })
        try await Task.sleep(for: .milliseconds(50))
        // Something outside the Undo window dropped every parked recording.
        await harness.coordinator.unloadTranscriptionRuntime()
        controller.undoDiscard()

        #expect(await insertionEventually { @MainActor in controller.recordingLifecycleState == .idle })
        #expect(await insertionEventually { @MainActor in
            controller.status == "The discarded recording is no longer available."
        })
        #expect(controller.lastError.isEmpty)
        #expect(!harness.presenter.hostedEvidenceRequestedStates().contains {
            if case .result = $0 { return true }
            if case .failure = $0 { return true }
            return false
        })
        await harness.finish()
    }

    @Test("A new dictation during the Undo window ends it and deletes the discarded audio")
    func newDictationEndsWindow() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        try await harness.recordThenDiscard()
        let discardedAudio = try #require(await harness.capture.endedURLs().first)

        controller.pressToTalkStart()
        #expect(await insertionEventually { await harness.capture.startedCount() == 2 })
        #expect(!controller.canUndoDiscard)
        #expect(await insertionEventually { !FileManager.default.fileExists(atPath: discardedAudio.path) })
        controller.undoDiscard()

        #expect(await insertionEventually { @MainActor in controller.isRecording })
        controller.pressToTalkStop()
        #expect(await insertionEventually { @MainActor in controller.status == "Transcript inserted." })
        #expect(await harness.transport.texts().count == 1)
        #expect(await harness.engine.transcriptionCount() == 1)
        await harness.finish()
    }

    @Test("The hands-free key during the Undo window starts a new dictation and never undoes")
    func handsFreeKeyNeverUndoes() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        try await harness.recordThenDiscard()
        controller.toggleHandsFree()

        #expect(await insertionEventually { await harness.capture.startedCount() == 2 })
        #expect(await insertionEventually { @MainActor in controller.recordingLifecycleState == .recordingHandsFree })
        #expect(!controller.canUndoDiscard)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.transport.texts().isEmpty)
        #expect(await harness.engine.transcriptionCount() == 0)
        controller.cancelActiveRecording()
        await harness.finish()
    }

    @Test("A short recording is discarded at once, as before")
    func shortRecordingDiscardsAtOnce() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller
        controller.undoDiscardMinimumRecording = 30

        try await harness.recordThenDiscard()

        #expect(controller.status == "Recording canceled.")
        #expect(!controller.canUndoDiscard)
        #expect(!harness.presenter.hostedEvidenceRequestedStates().contains {
            if case .discarded = $0 { return true }
            return false
        })
        let directory = harness.directory
        #expect(await insertionEventually { recordedAudio(in: directory).isEmpty })
        #expect(await insertionEventually { @MainActor in harness.media.ended == harness.media.begun })
        controller.undoDiscard()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.transport.texts().isEmpty)
        await harness.finish()
    }

    // MARK: - Concealed copies

    @Test("Undo after an app change copies a secure-field dictation concealed")
    func undoFromSecureFieldCopiesConcealed() async throws {
        let harness = try InsertionBehaviourHarness(focusedFieldIsSecure: true)
        defer { harness.removeDirectory() }
        let controller = harness.controller

        try await harness.recordThenDiscard()
        harness.frontmost = AppContext(bundleIdentifier: "com.example.other", appName: "Other")
        controller.undoDiscard()

        #expect(await insertionEventually { await !harness.clipboard.concealedValues().isEmpty })
        #expect(await harness.clipboard.plainValues().isEmpty)
        #expect(await harness.transport.texts().isEmpty)
        await harness.finish()
    }

    @Test("Copy Last Dictation keeps a concealed dictation concealed")
    func copyLastKeepsConcealment() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        try await harness.history.append(entry: TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "hunter two",
            cleanText: "Hunter two",
            audioURL: nil,
            insertionStatus: .copiedOnly,
            concealedCopy: true
        ))

        harness.controller.copyLastDictation()

        #expect(await insertionEventually { await harness.clipboard.concealedValues() == ["Hunter two"] })
        #expect(await harness.clipboard.plainValues().isEmpty)
        await harness.finish()
    }

    @Test("Copy Corrected Text keeps a concealed dictation concealed and copies others plainly")
    func copyCorrectedKeepsConcealment() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let secret = TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "hunter too",
            cleanText: "Hunter too",
            audioURL: nil,
            insertionStatus: .copiedOnly,
            concealedCopy: true
        )
        let note = TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "send it to sam",
            cleanText: "Send it to Sam",
            audioURL: nil,
            insertionStatus: .inserted
        )
        try await harness.history.append(entry: secret)
        try await harness.history.append(entry: note)
        await harness.controller.refreshHistory()
        _ = try await harness.controller.applyWordFix(
            entryID: secret.id, original: "too", occurrence: 0, replacement: "two", appliesToFuture: false
        )

        await harness.controller.copyCorrectedText(entryID: secret.id)
        await harness.controller.copyCorrectedText(entryID: note.id)

        #expect(await harness.clipboard.concealedValues() == ["Hunter two"])
        #expect(await harness.clipboard.plainValues() == ["Send it to Sam"])
        await harness.finish()
    }

    @Test("The overlay's Copy keeps a secure-field result concealed")
    func overlayCopyKeepsConcealment() async throws {
        let harness = try InsertionBehaviourHarness(focusedFieldIsSecure: true)
        defer { harness.removeDirectory() }
        let controller = harness.controller
        controller.pressToTalkStart()
        try #require(await insertionEventually { @MainActor in controller.isRecording })
        controller.pressToTalkStop()
        try #require(await insertionEventually { await harness.clipboard.concealedValues().count == 1 })
        try #require(await insertionEventually { @MainActor in controller.recordingLifecycleState == .idle })

        harness.presenter.onCopyResult?()

        #expect(await insertionEventually { await harness.clipboard.concealedValues().count == 2 })
        #expect(await harness.clipboard.plainValues().isEmpty)
        await harness.finish()
    }

    // MARK: - Copy and Paste Last Dictation

    @Test("Paste Last Dictation inserts the latest dictation exactly once per invocation and saves nothing new")
    func pasteLastOnce() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller
        try await harness.history.append(entry: TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "earlier words",
            cleanText: "Earlier words.",
            audioURL: nil,
            insertionStatus: .inserted
        ))

        controller.pasteLastDictation()
        controller.pasteLastDictation()
        #expect(await insertionEventually { @MainActor in controller.status == "Last dictation inserted." })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.transport.texts() == ["Earlier words."])

        controller.pasteLastDictation()
        #expect(await insertionEventually { await harness.transport.texts().count == 2 })
        #expect(await harness.history.recent(limit: 10).count == 1)
        #expect(await harness.engine.transcriptionCount() == 0)
        await harness.finish()
    }

    @Test("Paste Last Dictation copies instead when a secure field is focused")
    func pasteLastSecureField() async throws {
        let harness = try InsertionBehaviourHarness(focusedFieldIsSecure: true)
        defer { harness.removeDirectory() }
        let controller = harness.controller
        try await harness.history.append(entry: TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "earlier words",
            cleanText: "Earlier words.",
            audioURL: nil,
            insertionStatus: .inserted
        ))

        controller.pasteLastDictation()

        #expect(await insertionEventually { await harness.clipboard.latestValue == "Earlier words." })
        #expect(await harness.transport.texts().isEmpty)
        #expect(controller.status == "Secure text field—final text copied instead of typed.")
        #expect(harness.presenter.hostedEvidenceRequestedStates().contains(
            .result(.copied(.secureField), showsWords: true)
        ))
        await harness.finish()
    }

    @Test("Option held past the press window, then the Paste Last chord, pastes the last dictation once")
    func optionHeldThenPasteLastPastesOnce() async throws {
        let hotkey = ChordHotkey()
        let harness = try InsertionBehaviourHarness(hotkey: hotkey)
        defer { harness.removeDirectory() }
        let controller = harness.controller
        // As released: a short press is canceled, not held for Undo.
        controller.undoDiscardMinimumRecording = 30
        try await harness.history.append(entry: TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "earlier words",
            cleanText: "Earlier words.",
            audioURL: nil,
            insertionStatus: .inserted
        ))

        // Option held past the press window.
        hotkey.onPressToTalkStart?()
        hotkey.onPressToTalkConfirmed?()
        try #require(await insertionEventually { @MainActor in controller.isRecording })
        // The chord's key: the monitor delivers the press's discard, then the paste.
        hotkey.onPressToTalkDiscarded?()
        hotkey.onPasteLastShortcut?()

        #expect(await insertionEventually { await harness.transport.texts() == ["Earlier words."] })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.transport.texts() == ["Earlier words."])
        #expect(await harness.engine.transcriptionCount() == 0)
        #expect(await harness.history.recent(limit: 10).count == 1)
        #expect(controller.status == "Last dictation inserted.")
        await harness.finish()
    }

    @Test("Copy Last Dictation copies the latest dictation")
    func copyLast() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        try await harness.history.append(entry: TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "earlier words",
            cleanText: "Earlier words.",
            audioURL: nil,
            insertionStatus: .inserted
        ))

        harness.controller.copyLastDictation()

        #expect(await insertionEventually { await harness.clipboard.latestValue == "Earlier words." })
        #expect(await harness.transport.texts().isEmpty)
        await harness.finish()
    }

    // MARK: - After inserting

    @Test("Show nothing shows no result and announces where the text went")
    func showNothing() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        harness.controller.preferences.recording.afterInserting = "nothing"

        try await harness.dictate()

        #expect(harness.announcements == ["Inserted into Test Editor"])
        #expect(!harness.presenter.hostedEvidenceRequestedStates().contains {
            if case .result = $0 { return true }
            return false
        })
        await harness.finish()
    }

    @Test("Only when it matters names the app for the first 20 dictations and counts them")
    func mattersCountsFirstTwenty() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller
        controller.preferences.general.successNoticesShown = 19

        try await harness.dictate()
        #expect(harness.presenter.hostedEvidenceRequestedStates().last
            == .result(.inserted(appName: "Test Editor", method: .typed), showsWords: true))
        #expect(controller.preferences.general.successNoticesShown == 20)

        try await harness.dictate()
        #expect(harness.presenter.hostedEvidenceRequestedStates().last
            == .result(.inserted(appName: "Test Editor", method: .typed), showsWords: false))
        #expect(controller.preferences.general.successNoticesShown == 20)
        #expect(harness.announcements.isEmpty)

        let saved = await harness.preferencesStore.load()
        #expect(saved.general.successNoticesShown == 20)
        await harness.finish()
    }

    @Test("A Settings save and a dictation's count both reach the saved file")
    func settingsSaveAndCountBothSurvive() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller
        var draft = controller.preferences
        draft.media.pauseDuringHandsFree = false
        let save = controller.applySettingsDraft(preferences: draft)

        try await harness.dictate()
        #expect(await save.value)
        try await Task.sleep(for: .milliseconds(100))

        let saved = await harness.preferencesStore.load()
        #expect(saved.media.pauseDuringHandsFree == false)
        #expect(saved.general.successNoticesShown == 1)
        await harness.finish()
    }

    @Test("A save from the Settings window and a dictation's count both reach the saved file")
    func settingsWindowSaveAndCountBothSurvive() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller
        let session = SettingsSession(microphone: .preview(devices: [], testingAt: nil))
        session.attach(to: controller.preferences)
        var edited = session.preferences
        edited.media.pauseDuringHandsFree = false
        session.edit(edited)
        session.save(controller: controller)

        try await harness.dictate()
        try await Task.sleep(for: .milliseconds(200))

        let saved = await harness.preferencesStore.load()
        #expect(saved.media.pauseDuringHandsFree == false)
        #expect(saved.general.successNoticesShown == 1)
        #expect(controller.preferences.media.pauseDuringHandsFree == false)
        await harness.finish()
    }

    @Test("A typed result offers the overlay the first line of what was inserted")
    func offersInsertedWords() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        try await harness.dictate()

        let typed = try #require(await harness.transport.texts().last)
        let states = harness.presenter.hostedEvidenceRequestedStates()
        let words = harness.presenter.hostedEvidenceRequestedWords()
        let index = try #require(states.lastIndex(of: .result(.inserted(appName: "Test Editor", method: .typed), showsWords: true)))
        #expect(words[index] == DictationResultPresentation.insertedWordsLine(of: typed))
        #expect(words[index] != nil)
        await harness.finish()
    }

    @Test("The brief confirmation after the first 20 offers no words")
    func briefOffersNoWords() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        harness.controller.preferences.general.successNoticesShown = 20

        try await harness.dictate()

        let states = harness.presenter.hostedEvidenceRequestedStates()
        let index = try #require(states.lastIndex(of: .result(.inserted(appName: "Test Editor", method: .typed), showsWords: false)))
        #expect(harness.presenter.hostedEvidenceRequestedWords()[index] == nil)
        await harness.finish()
    }

    @Test("Show nothing shows no overlay result, so no words are offered")
    func showNothingOffersNoWords() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        harness.controller.preferences.recording.afterInserting = "nothing"

        try await harness.dictate()

        let states = harness.presenter.hostedEvidenceRequestedStates()
        #expect(!states.contains { if case .result = $0 { return true } else { return false } })
        #expect(harness.presenter.hostedEvidenceRequestedWords().allSatisfy { $0 == nil })
        await harness.finish()
    }

    @Test("A secure-field dictation is copied concealed and offers no words")
    func secureFieldOffersNoWords() async throws {
        let harness = try InsertionBehaviourHarness(focusedFieldIsSecure: true)
        defer { harness.removeDirectory() }
        harness.controller.preferences.recording.afterInserting = "always"

        harness.controller.pressToTalkStart()
        try #require(await insertionEventually { @MainActor in harness.controller.isRecording })
        harness.controller.pressToTalkStop()
        try #require(await insertionEventually { await !harness.clipboard.concealedValues().isEmpty })
        try #require(await insertionEventually { @MainActor in harness.controller.recordingLifecycleState == .idle })

        let states = harness.presenter.hostedEvidenceRequestedStates()
        #expect(states.contains(.result(.copied(.secureField), showsWords: true)))
        #expect(harness.presenter.hostedEvidenceRequestedWords().allSatisfy { $0 == nil })
        await harness.finish()
    }

    @Test("Always say where names the app after the first 20")
    func alwaysSaysWhere() async throws {
        let harness = try InsertionBehaviourHarness()
        defer { harness.removeDirectory() }
        harness.controller.preferences.recording.afterInserting = "always"
        harness.controller.preferences.general.successNoticesShown = 40

        try await harness.dictate()

        #expect(harness.presenter.hostedEvidenceRequestedStates().last
            == .result(.inserted(appName: "Test Editor", method: .typed), showsWords: true))
        await harness.finish()
    }
}

// MARK: - Harness

/// A hotkey service that keeps every callback the controller sets, so a test
/// can play a held Option and a Paste Last chord in `MacHotkeyMonitor`'s order.
private final class ChordHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var onPressToTalkConfirmed: (() -> Void)?
    var onPressToTalkDiscarded: (() -> Void)?
    var onPasteLastShortcut: (() -> Void)?
    var pasteLastShortcut: GlobalShortcut?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?
    var confirmsPressToTalk: Bool { true }
    func start() {}
    func stop() {}
}

@MainActor
private final class InsertionBehaviourHarness {
    let directory: URL
    let capture: TranscriptionCancelCapture
    let engine = RestoredWordsEngine()
    let transport = TranscriptionCancelTransport()
    let clipboard = ConcealmentRecordingClipboard()
    let media = CountingMediaService()
    let history: HistoryStore
    let preferencesStore: AppPreferencesStore
    let coordinator: SessionCoordinator
    let presenter: WaveformOverlayPresenter
    let controller: DictationController
    var frontmost = AppContext(bundleIdentifier: "com.example.steno-test-editor", appName: "Test Editor")
    private(set) var announcements: [String] = []

    init(
        focusedFieldIsSecure: Bool = false,
        workspaceNotificationCenter: NotificationCenter? = nil,
        hotkey: any HotkeyService = TranscriptionCancelHotkey()
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoInsertionBehaviour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture = TranscriptionCancelCapture(directory: directory)
        history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json")
        )
        preferencesStore = AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json"))
        let focusedField: EditorTargetUnavailableReason = focusedFieldIsSecure
            ? .secureOrProtectedElement
            : .unsupportedElement
        let lookup: @Sendable (AppContext) -> Result<EditorTargetHandle, EditorTargetUnavailableReason> = { _ in
            .failure(focusedField)
        }
        coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: engine,
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [
                transport,
                ClipboardInsertionTransport(clipboard: clipboard),
            ]),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: lookup
        )
        presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        var provider: (@MainActor () -> AppContext)?
        controller = DictationController(
            hotkey: hotkey,
            clipboardService: clipboard,
            overlay: presenter,
            mediaInterruption: media,
            preferencesStore: preferencesStore,
            coordinator: coordinator,
            runtimeRebuildOverride: { nil },
            overlayDismissDelay: { try? await Task.sleep(for: .seconds(60)) },
            historyStore: history,
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            appContextProvider: { provider?() ?? .unknown },
            targetDisplayPointProvider: { CGPoint(x: 400, y: 300) },
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        provider = { [unowned self] in self.frontmost }
        controller.undoDiscardMinimumRecording = 0
        controller.undoDiscardWindow = .seconds(30)
        controller.announce = { [unowned self] in self.announcements.append($0) }
    }

    /// Records with Option, then discards with the overlay's ×.
    func recordThenDiscard() async throws {
        let starts = await capture.startedCount()
        controller.pressToTalkStart()
        try #require(await insertionEventually { await self.capture.startedCount() == starts + 1 })
        try #require(await insertionEventually { @MainActor in self.controller.isRecording })
        try #require(await insertionEventually { @MainActor in self.media.begun.count == 1 })
        try await Task.sleep(for: .milliseconds(20))
        presenter.hostedEvidencePressCancel()
        try #require(await insertionEventually { @MainActor in !self.controller.isRecording })
        try #require(await insertionEventually { @MainActor in self.media.ended == self.media.begun })
    }

    /// Records with Option and inserts.
    func dictate() async throws {
        let inserted = await transport.texts().count
        controller.pressToTalkStart()
        try #require(await insertionEventually { @MainActor in self.controller.isRecording })
        controller.pressToTalkStop()
        try #require(await insertionEventually { await self.transport.texts().count == inserted + 1 })
        try #require(await insertionEventually { @MainActor in self.controller.recordingLifecycleState == .idle })
    }

    func finish() async {
        await controller.teardownAndWait()
        await coordinator.shutdown()
    }

    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RestoredWordsEngine: TranscriptionEngine {
    private var count = 0
    private var blocksUntilCanceled = false
    private var blocked: CheckedContinuation<Void, Never>?

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        count += 1
        if blocksUntilCanceled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { blocked = $0 }
            } onCancel: {
                Task { await self.release() }
            }
            throw CancellationError()
        }
        return RawTranscript(text: "restored words")
    }

    private var unloads = 0
    func unloadRetainedResources() async { unloads += 1 }
    func unloadCount() -> Int { unloads }

    func blockUntilCanceled() { blocksUntilCanceled = true }
    private func release() {
        blocked?.resume()
        blocked = nil
    }
    func transcriptionCount() -> Int { count }
}

/// Grants every Pause and records each media call.
@MainActor
private final class CountingMediaService: MediaInterruptionService {
    private(set) var begun: [UUID] = []
    private(set) var ended: [UUID] = []
    var callCount: Int { begun.count + ended.count }

    func beginInterruption() async -> MediaInterruptionToken? {
        let token = MediaInterruptionToken()
        begun.append(token.id)
        return token
    }

    func endInterruption(token: MediaInterruptionToken) async {
        ended.append(token.id)
    }

    func endedMatchesBegun() -> Bool { ended == begun }
}

/// An in-memory clipboard that records which writes were concealed.
private actor ConcealmentRecordingClipboard: ClipboardService {
    private(set) var latestValue = ""
    private var plain: [String] = []
    private var concealed: [String] = []

    func setString(_ text: String) async throws {
        latestValue = text
        plain.append(text)
    }

    func setConcealedString(_ text: String) async throws {
        latestValue = text
        concealed.append(text)
    }

    func plainValues() -> [String] { plain }
    func concealedValues() -> [String] { concealed }
}

private func recordedAudio(in directory: URL) -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "wav" }
}

/// Ends the Undo window when the test says, instead of after its duration.
@MainActor
final class UndoWindowEnd {
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var ended = false

    var wait: @MainActor (Duration) async -> Void {
        { [self] duration in
            requested.append(duration)
            guard !ended else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func end() {
        ended = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private func insertionEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    await cancelTestEventually(condition)
}

// MARK: - A dictation History couldn't save

@MainActor
@Suite(.serialized)
struct UnsavedLastDictationTests {
    private func makeController(
        history: HistoryStore,
        clipboard: MemoryClipboardService,
        coordinator: UnsavedHistoryCoordinator
    ) -> DictationController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoUnsavedLast-\(UUID().uuidString)", isDirectory: true)
        return DictationController(
            hotkey: TranscriptionCancelHotkey(),
            clipboardService: clipboard,
            overlay: WaveformOverlayPresenter(observeAccessibilityChanges: false),
            mediaInterruption: IsolatedTestMediaService(),
            preferencesStore: AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
            coordinator: coordinator,
            runtimeRebuildOverride: { nil },
            overlayDismissDelay: {},
            historyStore: history,
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            appContextProvider: { AppContext(bundleIdentifier: "com.example.steno-test-editor", appName: "Test Editor") },
            targetDisplayPointProvider: { CGPoint(x: 400, y: 300) }
        )
    }

    private func dictateUnsaved(_ controller: DictationController) async throws {
        controller.pressToTalkStart()
        try #require(await insertionEventually { @MainActor in controller.isRecording })
        controller.pressToTalkStop()
        try #require(await insertionEventually { @MainActor in controller.storageNotice != nil })
        try #require(await insertionEventually { @MainActor in controller.recordingLifecycleState == .idle })
    }

    @Test("After Delete All History, Copy and Paste Last Dictation find nothing, not the unsaved dictation")
    func deleteAllClearsUnsaved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoUnsavedLast-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = MemoryClipboardService()
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        let coordinator = UnsavedHistoryCoordinator()
        let controller = makeController(history: history, clipboard: clipboard, coordinator: coordinator)
        try await dictateUnsaved(controller)

        // Before deleting, the unsaved dictation is still reachable.
        controller.copyLastDictation()
        #expect(await insertionEventually { await clipboard.latestValue == "Private words" })
        try await clipboard.setString("")

        await controller.deleteAllHistory()
        controller.copyLastDictation()
        #expect(await insertionEventually { @MainActor in controller.status == "No dictation to copy yet." })
        controller.pasteLastDictation()
        #expect(await insertionEventually { @MainActor in controller.status == "No dictation to paste yet." })
        #expect(await clipboard.latestValue == "")
        #expect(await coordinator.insertedTexts().isEmpty)
        await controller.teardownAndWait()
    }

    @Test("Deleting that dictation from History also forgets the unsaved copy")
    func deleteEntryClearsUnsaved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoUnsavedLast-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = MemoryClipboardService()
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        let coordinator = UnsavedHistoryCoordinator()
        let controller = makeController(history: history, clipboard: clipboard, coordinator: coordinator)
        try await dictateUnsaved(controller)
        let entry = TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "private words",
            cleanText: "Private words",
            audioURL: nil,
            insertionStatus: .inserted
        )
        try await history.append(entry: entry)
        await controller.refreshHistory()

        controller.deleteEntry(entry)
        #expect(await insertionEventually { @MainActor in controller.status == "Transcript deleted." })
        controller.pasteLastDictation()
        #expect(await insertionEventually { @MainActor in controller.status == "No dictation to paste yet." })
        #expect(await coordinator.insertedTexts().isEmpty)
        await controller.teardownAndWait()
    }
}

/// Inserts every dictation but reports that History couldn't save it.
private actor UnsavedHistoryCoordinator: DictationSessionCoordinating {
    private var inserted: [String] = []

    func startPressToTalk(appContext: AppContext) async throws -> SessionID { SessionID() }
    func endPressToTalkCapture(sessionID: SessionID) async throws {}
    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        var result = InsertResult(status: .inserted, method: .direct, insertedText: "Private words")
        result.historyWarning = HistoryStoreError.persistenceFailed.localizedDescription
        return result
    }
    func insertText(_ text: String, into target: AppContext) async -> InsertResult {
        inserted.append(text)
        return InsertResult(status: .inserted, method: .direct, insertedText: text)
    }
    func cancel(sessionID: SessionID) async {}
    func setHandsFreeEnabled(_ enabled: Bool) async {}
    func insertedTexts() -> [String] { inserted }
}

// MARK: - Paste Last Dictation shortcut registration

@MainActor
@Suite(.serialized)
struct PasteLastShortcutRegistrationTests {
    private func makeController(hotkey: ShortcutRecordingHotkey) -> DictationController {
        makeTestDictationController(hotkey: hotkey)
    }

    private func apply(_ controller: DictationController, shortcut: String?, handsFree: UInt16? = 79) async {
        var preferences = controller.preferences
        preferences.recording.pasteLastShortcut = shortcut
        preferences.hotkeys.handsFreeGlobalKeyCode = handsFree
        _ = await controller.applySettingsDraft(preferences: preferences).value
    }

    @Test("A usable shortcut is registered and nothing is reported")
    func usableShortcut() async {
        let hotkey = ShortcutRecordingHotkey()
        let controller = makeController(hotkey: hotkey)
        await apply(controller, shortcut: "control+option+command+9")
        #expect(hotkey.pasteLastShortcut?.preferenceValue == "control+option+command+9")
        #expect(controller.pasteLastShortcutMessage.isEmpty)
        await controller.teardownAndWait()
    }

    @Test("Every chord Settings offers is saved as text the hotkey service registers, and none collides with the hands-free key")
    func offeredChordsRegister() async {
        let handsFree: UInt16 = 79
        let offered = PasteLastShortcutChoices.options(handsFreeKeyCode: handsFree, saved: nil).compactMap(\.value)
        #expect(offered.count == 2)
        for value in offered {
            #expect(GlobalShortcut.problem(withPreferenceValue: value) == nil)
            let hotkey = ShortcutRecordingHotkey()
            let controller = makeController(hotkey: hotkey)
            await apply(controller, shortcut: value)
            #expect(hotkey.pasteLastShortcut == GlobalShortcut(preferenceValue: value))
            #expect(controller.pasteLastShortcutMessage.isEmpty)
            await controller.teardownAndWait()
        }
        // A saved change reaches a running hotkey service, and clearing it unregisters.
        let hotkey = ShortcutRecordingHotkey()
        let controller = makeController(hotkey: hotkey)
        await apply(controller, shortcut: offered[0])
        #expect(hotkey.pasteLastShortcut != nil)
        await apply(controller, shortcut: nil)
        #expect(hotkey.pasteLastShortcut == nil)
        await controller.teardownAndWait()
    }

    @Test("A chord on the hands-free key is not offered, and a saved one that is no longer offered stays listed")
    func offeredChordsFollowHandsFreeKey() {
        let onV = PasteLastShortcutChoices.options(handsFreeKeyCode: 9, saved: nil)
        #expect(onV.map(\.value) == [nil])
        let kept = PasteLastShortcutChoices.options(handsFreeKeyCode: 9, saved: "control+option+9")
        #expect(kept.map(\.value) == [nil, "control+option+9"])
        #expect(kept.last?.title == "⌃⌥V")
    }

    @Test("A shortcut on the hands-free key is not registered and says why")
    func handsFreeCollision() async {
        let hotkey = ShortcutRecordingHotkey()
        let controller = makeController(hotkey: hotkey)
        await apply(controller, shortcut: "command+105", handsFree: 105)
        #expect(hotkey.pasteLastShortcut == nil)
        #expect(controller.pasteLastShortcutMessage == "The Paste Last Dictation shortcut uses the hands-free key. Choose another.")
        await controller.teardownAndWait()
    }

    @Test("A reserved saved shortcut is not registered and says why")
    func reservedShortcut() async {
        let hotkey = ShortcutRecordingHotkey()
        let controller = makeController(hotkey: hotkey)
        await apply(controller, shortcut: "command+9")
        #expect(hotkey.pasteLastShortcut == nil)
        #expect(controller.pasteLastShortcutMessage == "The Paste Last Dictation shortcut is already used by macOS or most apps. Choose another.")
        await controller.teardownAndWait()
    }

    @Test("An event tap that can't be installed is reported, then cleared when it works")
    func tapFailureSurfaces() async {
        let hotkey = ShortcutRecordingHotkey()
        let controller = makeController(hotkey: hotkey)
        await apply(controller, shortcut: "control+option+command+9")
        hotkey.onPasteLastShortcutStatusChanged?(.unavailable(reason: "The Paste Last Dictation shortcut needs Accessibility permission."))
        #expect(controller.pasteLastShortcutMessage == "The Paste Last Dictation shortcut needs Accessibility permission.")
        hotkey.onPasteLastShortcutStatusChanged?(.registered)
        #expect(controller.pasteLastShortcutMessage.isEmpty)
        await controller.teardownAndWait()
    }
}

@MainActor
private final class ShortcutRecordingHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?
    var pasteLastShortcut: GlobalShortcut?
    var onPasteLastShortcut: (() -> Void)?
    var onPasteLastShortcutStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    func start() {}
    func stop() {}
}

// MARK: - Paste Last Dictation never overlaps a dictation

@MainActor
@Suite(.serialized)
struct PasteLastOverlapTests {
    @Test("A press while Paste Last Dictation is inserting starts no recording and says it is still finishing")
    func pressDuringPasteLast() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoPasteOverlap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        try await history.append(entry: TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "earlier words",
            cleanText: "Earlier words.",
            audioURL: nil,
            insertionStatus: .inserted
        ))
        let coordinator = BlockingInsertCoordinator()
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        let controller = makeTestDictationController(
            hotkey: TranscriptionCancelHotkey(),
            overlay: presenter,
            coordinator: coordinator,
            historyStore: history
        )

        controller.pasteLastDictation()
        #expect(controller.recordingLifecycleState == .transcribing)
        #expect(await insertionEventually { await coordinator.insertStarted() })

        controller.pressToTalkStart()
        controller.toggleHandsFree()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await coordinator.startCount() == 0)
        #expect(presenter.hostedEvidenceRequestedStates().contains(.busy(.stillFinishing)))

        await coordinator.releaseInsert()
        #expect(await insertionEventually { @MainActor in controller.status == "Last dictation inserted." })
        #expect(controller.recordingLifecycleState == .idle)

        controller.pressToTalkStop()
        controller.pressToTalkStart()
        #expect(await insertionEventually { await coordinator.startCount() == 1 })
        await controller.teardownAndWait()
    }

    @Test("Cancel while Paste Last Dictation waits inserts nothing")
    func cancelDuringPasteLast() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoPasteOverlap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        try await history.append(entry: TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "earlier words",
            cleanText: "Earlier words.",
            audioURL: nil,
            insertionStatus: .inserted
        ))
        let coordinator = BlockingInsertCoordinator()
        let controller = makeTestDictationController(
            hotkey: TranscriptionCancelHotkey(),
            coordinator: coordinator,
            historyStore: history
        )

        controller.pasteLastDictation()
        #expect(await insertionEventually { await coordinator.insertStarted() })
        controller.cancelActiveRecording()

        #expect(await insertionEventually { await coordinator.insertWasCanceled() })
        #expect(controller.recordingLifecycleState == .idle)
        #expect(await coordinator.committedTexts().isEmpty)
        await controller.teardownAndWait()
    }
}

/// Holds Paste Last Dictation's insertion until released, and commits only
/// if it was not canceled first.
private actor BlockingInsertCoordinator: DictationSessionCoordinating {
    private var starts = 0
    private var started = false
    private var canceled = false
    private var committed: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        starts += 1
        return SessionID()
    }
    func endPressToTalkCapture(sessionID: SessionID) async throws {}
    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }
    func insertText(_ text: String, into target: AppContext) async -> InsertResult {
        started = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { gate = continuation }
            }
        } onCancel: {
            Task { await self.cancelInsert() }
        }
        guard !canceled, !Task.isCancelled else {
            canceled = true
            return InsertResult(status: .failed, method: .none, insertedText: text, errorMessage: "Insertion canceled.")
        }
        committed.append(text)
        return InsertResult(status: .inserted, method: .direct, insertedText: text)
    }
    private func cancelInsert() {
        canceled = true
        gate?.resume()
        gate = nil
    }
    func releaseInsert() {
        released = true
        gate?.resume()
        gate = nil
    }
    func cancel(sessionID: SessionID) async {}
    func setHandsFreeEnabled(_ enabled: Bool) async {}
    func startCount() -> Int { starts }
    func insertStarted() -> Bool { started }
    func insertWasCanceled() -> Bool { canceled }
    func committedTexts() -> [String] { committed }
}
