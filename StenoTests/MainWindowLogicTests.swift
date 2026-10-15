import AppKit
import Combine
import CoreText
import Foundation
import StenoKit
import SwiftUI
import Testing
@testable import Steno

// MARK: - Flowing text

@Suite("Flowing dictation text", .serialized)
@MainActor
struct TranscriptFlowTests {
    static let paragraph = "The parties agree that the closing date will move from September 18 to September 25, and that the escrow instructions will be updated to reflect the new date. Please keep the exact wording of section four, and do not change the meaning of the indemnity clause."

    @Test("Size, line and measure follow the base size, the text-size step and the width")
    func metrics() {
        let metrics = TranscriptMetrics(flowing: 15, measure: 468.7)
        #expect(metrics.fontSize == 15)
        #expect(metrics.lineHeight == 23)
        #expect(metrics.measure == 468)
        #expect(TranscriptMetrics(flowing: 15, measure: 468, scale: 1.24).fontSize == 18.5)
        #expect(TranscriptMetrics(flowing: 24, measure: 468).lineHeight == 33)
        #expect(TranscriptMetrics(flowing: 15, measure: 40).measure == 80)
        #expect(TranscriptTypesetter.font(metrics).familyName == NSFont.systemFont(ofSize: 15).familyName)
    }

    @Test("Wrapped lines are counted at the measure, and a wider measure needs fewer")
    func wrappedLines() {
        let narrow = TranscriptLineCounter.lineCount(Self.paragraph, metrics: TranscriptMetrics(flowing: 15, measure: 300))
        let wide = TranscriptLineCounter.lineCount(Self.paragraph, metrics: TranscriptMetrics(flowing: 15, measure: 700))
        #expect(narrow > wide)
        #expect(wide >= 2)
        #expect(TranscriptLineCounter.lineCount("Keep this sentence.", metrics: TranscriptMetrics(flowing: 15, measure: 468)) == 1)
        #expect(TranscriptLineCounter.lineCount("", metrics: TranscriptMetrics(flowing: 15, measure: 468)) == 0)
        // Repeated layout gives the same count.
        #expect(TranscriptLineCounter.fragments(Self.paragraph, metrics: TranscriptMetrics(flowing: 15, measure: 300)).count == narrow)
    }

    @Test("Every line fragment fills the line height and stays inside the measure")
    func fixedLineHeight() {
        let metrics = TranscriptMetrics(flowing: 15, measure: 468)
        let fragments = TranscriptLineCounter.fragments(Self.paragraph, metrics: metrics)
        #expect(fragments.allSatisfy { abs($0.height - metrics.lineHeight) < 0.01 })
        #expect(fragments.allSatisfy { $0.maxX <= 468.5 })
    }

    @Test("The counter matches the lines the text view lays out")
    func counterMatchesView() async throws {
        for text in [Self.paragraph, "One.", String(repeating: "https://example.com/a/very/long/path/without/spaces/", count: 3)] {
            let metrics = TranscriptMetrics(flowing: 15, measure: 468)
            let hosting = NSHostingView(rootView: TranscriptTextView(text: text, metrics: metrics).frame(width: 900, height: 600))
            hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
            hosting.layoutSubtreeIfNeeded()
            let view = try #require(Self.textView(in: hosting))
            let layout = try #require(view.layoutManager)
            let container = try #require(view.textContainer)
            layout.ensureLayout(for: container)
            var drawn = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in drawn += 1 }
            #expect(drawn == TranscriptLineCounter.lineCount(text, metrics: metrics), "\(text.prefix(20))")
        }
    }

    @Test("A word to fix is found on its line, inside the measure")
    func locateWord() throws {
        let metrics = TranscriptMetrics(flowing: 15, measure: 300)
        let text = Self.paragraph
        let range = (text as NSString).range(of: "indemnity")
        let located = try #require(TranscriptLineCounter.locate(range, in: text, metrics: metrics))
        #expect(located.line > 0 && located.line < TranscriptLineCounter.lineCount(text, metrics: metrics))
        #expect(located.rect.width > 0 && located.rect.maxX <= 300.5)
        let first = try #require(TranscriptLineCounter.locate(NSRange(location: 0, length: 3), in: text, metrics: metrics))
        #expect(first.line == 0 && first.rect.minX < 1)
        #expect(TranscriptLineCounter.locate(NSRange(location: 0, length: 0), in: text, metrics: metrics) == nil)
    }

    private static func textView(in view: NSView) -> TranscriptNSTextView? {
        if let match = view as? TranscriptNSTextView { return match }
        for subview in view.subviews { if let match = textView(in: subview) { return match } }
        return nil
    }
}

// MARK: - App names and times

@Suite("Transcript margin")
struct TranscriptMarginTests {
    @Test("An app that isn't installed keeps the name stored with the dictation")
    func appNameFallbacks() {
        #expect(AppNames.resolve(installed: "Mail", stored: "Apple Mail", bundleID: "com.apple.mail") == "Mail")
        #expect(AppNames.resolve(installed: nil, stored: "Steno", bundleID: "io.stenoapp.steno") == "Steno")
        #expect(AppNames.resolve(installed: nil, stored: "  ", bundleID: "io.stenoapp.steno") == "steno")
        #expect(AppNames.resolve(installed: nil, stored: nil, bundleID: "io.stenoapp.steno") == "steno")
        #expect(AppNames.resolve(installed: nil, stored: nil, bundleID: "") == "Unknown app")
        #expect(AppNames.resolve(installed: nil, stored: "Unknown", bundleID: "unknown") == "Unknown app")
        #expect(AppNames.resolve(installed: nil, stored: "Terminal", bundleID: "") == "Terminal")
    }

    @MainActor
    @Test("The onboarding sample is dictated into Steno itself, so its margin reads Steno")
    func onboardingSampleApp() {
        #expect(SettingsPreviewData.firstDictation.appBundleID == Bundle.main.bundleIdentifier)
        #expect(AppNames.name(for: SettingsPreviewData.firstDictation) == "Steno")
    }

    @Test("Times print on a 24-hour clock")
    func time() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 16, minute: 12)))
        #expect(TranscriptMargin.timeText(date, calendar: calendar) == "16:12")
    }
}

// MARK: - Insights durations

@Suite("Insights durations")
struct InsightsDurationTests {
    @Test("Durations read as minutes and hours", arguments: [
        (240_000, "4 min"), (8_700_000, "2 h 25 min"), (3_600_000, "1 h"), (111_000, "1 min 51 s")
    ])
    func durations(milliseconds: Int, expected: String) {
        if expected.hasSuffix(" s") {
            #expect(InsightsDuration.minutesSecondsText(milliseconds) == expected)
        } else {
            #expect(InsightsDuration.minutesText(milliseconds) == expected)
        }
    }
}

// MARK: - Status

@Suite("Window status")
struct WindowStatusTests {
    @Test("The pill states the most important truth", arguments: [
        (WindowStatusInputs(), QuillStatusPillState.ready),
        (WindowStatusInputs(lifecycle: .transcribing, microphone: .denied), .transcribing),
        (WindowStatusInputs(microphone: .denied, accessibility: .denied), .microphoneOff),
        (WindowStatusInputs(accessibility: .denied, speechModelMissing: true), .noSpeechModel),
        (WindowStatusInputs(accessibility: .denied, inputMonitoring: .denied), .copyOnly),
        (WindowStatusInputs(inputMonitoring: .denied), .shortcutKeyOff("Option")),
        (WindowStatusInputs(inputMonitoring: .denied, optionHold: false, handsFreeKeyName: "F18"), .shortcutKeyOff("F18")),
        (WindowStatusInputs(inputMonitoring: .denied, optionHold: true, handsFreeKeyName: "F18"), .shortcutKeyOff(nil)),
        (WindowStatusInputs(inputMonitoring: .denied, optionHold: false, handsFreeKeyName: nil), .shortcutKeyOff(nil)),
        (WindowStatusInputs(downloadPercent: 62), .downloading(percent: 62)),
        (WindowStatusInputs(microphone: .unknown, accessibility: .unknown, inputMonitoring: .unknown), .ready)
    ])
    func derive(inputs: WindowStatusInputs, expected: QuillStatusPillState) {
        #expect(QuillStatusPillState.derive(inputs) == expected)
    }

    @Test("Listening shows the time since the recording started")
    func listening() {
        let start = Date(timeIntervalSince1970: 1_000)
        let inputs = WindowStatusInputs(lifecycle: .recordingHandsFree, recordingStartedAt: start)
        #expect(QuillStatusPillState.derive(inputs, now: start.addingTimeInterval(102)) == .listening(elapsedSeconds: 102))
        #expect(QuillStatusPillState.listening(elapsedSeconds: 102).title == "Listening 1:42")
    }

    @Test("Today hides the pill when its own status line says the same thing")
    func hiddenOnToday() {
        #expect(!QuillStatusPillState.ready.isShown(onToday: true))
        #expect(!QuillStatusPillState.microphoneOff.isShown(onToday: true))
        #expect(QuillStatusPillState.copyOnly.isShown(onToday: true))
        #expect(QuillStatusPillState.ready.isShown(onToday: false))
        #expect(QuillStatusPillState.copyOnly.settingsSection == .permissions)
        #expect(QuillStatusPillState.noSpeechModel.settingsSection == .engine)
        #expect(QuillStatusPillState.ready.settingsSection == nil)
    }

    @Test("The Input Monitoring strip names the shortcuts that are on, or says your shortcuts")
    func inputMonitoringKeys() {
        func body(optionHold: Bool, key: String?) -> String? {
            let context = RecoveryStrips.Context(status: WindowStatusInputs(inputMonitoring: .denied), handsFreeKeyName: key,
                                                 optionHold: optionHold)
            return RecoveryStrips.strips(for: context, onToday: true).first { $0.kind == .inputMonitoringOff }?.body
        }
        #expect(body(optionHold: true, key: "F18")?.hasPrefix("Steno can’t detect Option or F18 while") == true)
        #expect(body(optionHold: true, key: nil)?.hasPrefix("Steno can’t detect Option while") == true)
        #expect(body(optionHold: false, key: "F18")?.hasPrefix("Steno can’t detect F18 while") == true)
        #expect(body(optionHold: false, key: nil)?.hasPrefix("Steno can’t detect your shortcuts while") == true)
    }

    @Test("Strips name each problem once, never the microphone twice on Today")
    func strips() {
        let context = RecoveryStrips.Context(
            status: WindowStatusInputs(microphone: .denied, accessibility: .denied),
            handsFreeKeyName: "F18", modelName: "Small", downloadingModelName: "Medium")
        let elsewhere = RecoveryStrips.strips(for: context, onToday: false).map(\.kind)
        let today = RecoveryStrips.strips(for: context, onToday: true).map(\.kind)
        #expect(elsewhere == [.microphoneOff, .accessibilityOff, .downloading])
        #expect(today == [.accessibilityOff, .downloading])
        let download = RecoveryStrips.strips(for: context, onToday: true).last
        #expect(download?.tone == .info)
        #expect(download?.title == "Downloading Medium")
        #expect(download?.body == "Dictation keeps using Small until it finishes.")
    }

    @Test("A notice's first sentence is its title")
    func splitSentence() {
        let (title, body) = RecoveryStrips.splitFirstSentence("History couldn’t be read. Steno kept the file.")
        #expect(title == "History couldn’t be read")
        #expect(body == "Steno kept the file.")
    }

    @Test("Today's status line follows the recording state", arguments: [
        (RecordingLifecycleState.idle, PermissionDiagnostics.AccessStatus.granted, TodayStatus.ready),
        (.idle, .denied, .microphoneOff),
        (.idle, .unknown, .ready),
        (.transcribing, .granted, .transcribing),
        (.recordingPressToTalk, .granted, .recording(startedAt: nil, startedHere: false))
    ])
    func todayStatus(lifecycle: RecordingLifecycleState, microphone: PermissionDiagnostics.AccessStatus, expected: TodayStatus) {
        #expect(TodayStatus.derive(lifecycle: lifecycle, microphone: microphone, recordingStartedAt: nil, startedHere: false) == expected)
    }
}

// MARK: - History

@Suite("History rules")
@MainActor
struct HistoryRulesTests {
    @Test("Search matches text or app; filters narrow by result")
    func search() {
        let entries = WindowSampleData.entries()
        #expect(HistoryRules.entries(entries, matching: "agenda", filter: .all).map(\.id) == [WindowSampleData.latestID])
        #expect(HistoryRules.entries(entries, matching: "  AGENDA ", filter: .all).count == 1)
        #expect(HistoryRules.entries(entries, matching: "", filter: .notInserted).map(\.id) == [WindowSampleData.bookingID])
        #expect(HistoryRules.entries(entries, matching: "", filter: .copied).map(\.id) == [WindowSampleData.groceriesID])
        #expect(HistoryRules.entries(entries, matching: "Lisbonn", filter: .all).isEmpty)
        #expect(HistoryRules.matchRanges(of: "the", in: "The cat and the hat") == [NSRange(location: 0, length: 3), NSRange(location: 12, length: 3)])
        #expect(HistoryRules.matchRanges(of: " ", in: "a b").isEmpty)
    }

    @Test("Days group as Today, Yesterday, then dates")
    func groups() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
        let entries = WindowSampleData.entries(now: now, calendar: calendar)
        let groups = HistoryDayGroup.groups(entries, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Yesterday"])
        #expect(groups.map(\.entries.count) == [4, 2])
    }

    @Test("Earlier today excludes the latest and older days")
    func earlierToday() {
        let entries = WindowSampleData.entries()
        #expect(TodayEntries.earlierToday(entries).map(\.id) == [WindowSampleData.groceriesID, WindowSampleData.contractID, WindowSampleData.bookingID])
    }

    @Test("Delete dialogs use the board copy")
    func deleteCopy() {
        #expect(HistoryRules.deleteOneTitle == "Delete this dictation?")
        #expect(HistoryRules.deleteAllConfirmationTitle(listedCount: 412) == "Delete all 412 dictations?")
        #expect(HistoryRules.deleteAllMessage.hasSuffix("This can’t be undone."))
    }

    @Test("Fix a word targets one occurrence of the word")
    func occurrence() {
        let text = "Send it to Dana, then call Dana."
        let second = (text as NSString).range(of: "Dana", options: .backwards)
        #expect(FixWordState.occurrence(of: second, in: text) == 1)
        #expect(FixWordState.occurrence(of: (text as NSString).range(of: "Dana"), in: text) == 0)
        let fixed = [WordFix(original: "Dana", replacement: "Danna", occurrence: 1, appliesToFuture: false, date: Date(), location: nil)]
        #expect(FixWordState.fixedRanges(for: fixed, in: "Send it to Danna, then call Danna.") == [NSRange(location: 28, length: 5)])
    }

    @Test("The result note says where the old text still is")
    func fixResult() {
        #expect(FixWordResult(entryID: UUID(), original: "Dana", replacement: "Danna", appliedToFuture: true, appName: "Mail").message
                == "Fixed here and added to Word Corrections. Mail still has the old text.")
    }

    @Test("The Fix a word helper reads as an addition to the chosen scope")
    func futureNote() {
        // The isolates around each word are invisible.
        #expect(FixWordState.futureNote(word: "Dana", replacement: "Danna").filter { $0 != "\u{2068}" && $0 != "\u{2069}" }
                == "Also adds “Dana” → “Danna” to Word Corrections.")
    }

    @Test("Fix a Word's note keeps a right-to-left word and its correction on their own sides of the arrow")
    func futureNoteOrder() {
        for (word, replacement) in [("الاجتماع", "الاجتماع الأسبوعي مع فريق المبيعات"), ("אני", "אני אתקשר"),
                                    ("Dana", "דנה"), ("שלום", "Shalom")] {
            let note = FixWordState.futureNote(word: word, replacement: replacement)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            let source = note as NSString
            let arrow = CTLineGetOffsetForStringIndex(line, source.range(of: "→").location, nil)
            func offsets(_ range: NSRange) -> [CGFloat] {
                (range.location..<NSMaxRange(range)).map { CTLineGetOffsetForStringIndex(line, $0, nil) }
            }
            let wordRange = source.range(of: word)
            let replacementRange = source.range(of: replacement, options: .backwards)
            #expect(offsets(wordRange).allSatisfy { $0 <= arrow }, "“\(word)” is drawn after the arrow")
            #expect(offsets(replacementRange).allSatisfy { $0 > arrow }, "“\(replacement)” is drawn before the arrow")
        }
    }

    @Test("What happened lists each step with its time")
    func whatHappened() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let created = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 10, minute: 24, second: 14)))
        let entry = TranscriptEntry(createdAt: created, appBundleID: "com.apple.mail", rawText: "", cleanText: "", audioURL: nil, insertionStatus: .inserted)
        let summary = WhatHappenedSummary.make(entry: entry, record: WindowSampleData.latestRecord, appName: "Mail", calendar: calendar)
        #expect(summary.rows.map(\.step) == ["Recorded", "Transcribed", "Cleaned up", "Inserted"])
        #expect(summary.rows.map(\.time) == ["12.0 s", "0.84 s", "0.02 s", "0.05 s"])
        #expect(summary.rows[0].detail == "MacBook Pro Microphone · 10:24:01 to 10:24:13")
        #expect(summary.rows[2].detail == "2 changes: removed “um”, added a period")
        #expect(summary.rows[3].detail == "into Mail")
        #expect(summary.summary == "12.9 s from start to text. Each step ran on this Mac.")
    }
}

// MARK: - Before cleanup

@Suite("Before cleanup")
struct CleanupDiffTests {
    @Test("The legend names only the changes this dictation has")
    func legend() {
        #expect(BeforeCleanupView.legend(for: CleanupDiff.segments(before: "same words", after: "same words"))
                == "Cleanup changed nothing in this dictation.")
        #expect(BeforeCleanupView.legend(for: CleanupDiff.segments(before: "Um, move it", after: "move it"))
                == "Cleanup removed the struck-out words.")
        #expect(BeforeCleanupView.legend(for: CleanupDiff.segments(before: "Um, move it", after: "Move it."))
                == "Cleanup removed the struck-out words and added the underlined ones.")
    }

    @Test("Removed and added words are marked; case-only changes are shown by letter")
    func segments() {
        let segments = CleanupDiff.segments(before: "Um, move the meeting to Friday", after: "Move the meeting to Friday.")
        #expect(segments.first == CleanupDiff.Segment(kind: .removed, text: "Um, "))
        #expect(segments[1] == CleanupDiff.Segment(kind: .added, text: "M"))
        #expect(segments.last == CleanupDiff.Segment(kind: .added, text: "."))
        let rebuiltAfter = segments.filter { $0.kind != .removed }.map(\.text).joined()
        #expect(rebuiltAfter == "Move the meeting to Friday.")
    }

    @Test("Identical text has no changes")
    func identical() {
        #expect(CleanupDiff.changeCount(before: "Same words.", after: "Same words.") == 0)
        #expect(CleanupDiff.segments(before: "Same words.", after: "Same words.") == [CleanupDiff.Segment(kind: .same, text: "Same words.")])
    }
}

// MARK: - Scenes and app state

@Suite("Scenes do not observe app state")
@MainActor
struct SceneObservationTests {
    @Test("A change of app state notifies the window's content, not the object the scenes observe")
    func holderStaysQuiet() {
        let controller = TransitionFixtures.sampleController()
        let holder = ControllerHolder(controller)
        var holderChanges = 0
        var controllerChanges = 0
        let watchers = [holder.objectWillChange.sink { _ in holderChanges += 1 },
                        controller.objectWillChange.sink { _ in controllerChanges += 1 }]
        defer { watchers.forEach { $0.cancel() } }
        controller.status = "Hands-free listening..."
        controller.recentEntries = WindowSampleData.entries()
        controller.preferences.appearance.accent = .citron
        #expect(controllerChanges == 3)
        #expect(holderChanges == 0, "the scenes would re-evaluate for every change of app state")
        #expect(holder.controller === controller)
    }
}
