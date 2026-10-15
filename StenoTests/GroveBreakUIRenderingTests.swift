import AppKit
@testable import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Worst-case content for every Grove surface: long, unbreakable, one word, no speech, CJK,
/// right-to-left, emoji with joiners, padded whitespace, very long app and microphone names, huge
/// counts and calendar extremes. Output goes to `STENO_UI_RENDER_OUTPUT/break-ui`, one folder per
/// surface, named `<scene>-<look>`.
/// Everything here is synthetic and stays in isolated preview controllers.
@Suite("Grove worst-case renders", .serialized)
@MainActor
struct GroveBreakUIRenderingTests {
    typealias Variant = GroveRenderHarness.Variant
    typealias Harness = GroveRenderHarness

    static let largeSize = CGSize(width: 1440, height: 1000)
    static let longApp = "Northwind-Industries-Holdings-Desktop-Client"
    static let longMicrophone = "Shure MV7+ Podcast Microphone (USB Audio Device)"

    static func directory(_ surface: String) throws -> URL {
        let directory = try Harness.outputDirectory.deletingLastPathComponent()
            .appendingPathComponent("break-ui", isDirectory: true).appendingPathComponent(surface, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write<V: View>(_ view: V, controller: DictationController?, surface: String, scene: String,
                                variant: Variant = .light, size: CGSize = Harness.windowSize,
                                textSize: DynamicTypeSize = .large) async throws {
        let data = try await Harness.render(view, controller: controller, variant: variant, size: size, textSize: textSize)
        let name = "\(scene)-\(variant.rawValue).png"
        try data.write(to: Self.directory(surface).appendingPathComponent(name))
        #expect(data.count > 5_000, "\(surface)/\(name)")
    }

    /// An isolated controller holding the worst-case History, optionally with `first` moved to the top.
    private func worstController(_ variant: Variant, first: ((TranscriptEntry) -> Bool)? = nil) -> DictationController {
        let controller = Harness.sampleController(variant)
        var entries = WindowSampleData.worstCaseEntries()
        if let first, let index = entries.firstIndex(where: first) {
            // The newest dictation leads the list, so the moved one is made the newest.
            var entry = entries.remove(at: index)
            entry.createdAt = max(Date(), (entries.first?.createdAt ?? .distantPast).addingTimeInterval(60))
            entries.insert(entry, at: 0)
        }
        controller.recentEntries = entries
        return controller
    }

    static func id(of text: String) -> (TranscriptEntry) -> Bool { { $0.cleanText == text } }

    /// Each extreme dictation, by a short name, as the latest dictation or the open one.
    static let extremes: [(String, (TranscriptEntry) -> Bool)] = [
        ("email-560", { $0.id == WindowSampleData.worstLatestID }),
        ("url-in-sentence", id(of: WindowSampleData.dictatedURL)),
        ("token-300", id(of: WindowSampleData.unbreakableToken)),
        ("one-word", id(of: "Yes.")),
        ("no-speech", { $0.insertionStatus == .noSpeech }),
        ("cjk", { $0.appBundleID == "com.tinyspeck.slackmacgap" }),
        ("arabic", { $0.insertionStatus == .failed && $0.cleanText.hasPrefix("س") }),
        ("hebrew", id(of: WindowSampleData.hebrew)),
        ("emoji-zwj", id(of: WindowSampleData.zwjEmoji)),
        ("emoji-newline", { $0.cleanText.hasPrefix("Sounds great") }),
        ("padded", id(of: WindowSampleData.padded)),
    ]

    // MARK: Today

    @Test("Today with the worst-case History, at every window size")
    func todayWorst() async throws {
        for (size, label) in [(Harness.minimumSize, "minimum"), (Harness.windowSize, "default"), (Self.largeSize, "large")] {
            for variant in [Variant.light, .dark] where label == "default" || variant == .light {
                let controller = worstController(variant)
                try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                                scene: "worst-\(label)", variant: variant, size: size)
                await controller.teardownAndWait()
            }
        }
        for variant in [Variant.contrast, .contrastDark] {
            let controller = worstController(variant)
            try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                            scene: "worst-default", variant: variant)
            await controller.teardownAndWait()
        }
        let controller = worstController(.light)
        try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                        scene: "worst-larger-text", textSize: .xxLarge)
        try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                        scene: "worst-larger-text-minimum", size: Harness.minimumSize, textSize: .xxLarge)
        await controller.teardownAndWait()
    }

    @Test("Today with each extreme as the latest dictation")
    func todayLatest() async throws {
        for (name, match) in Self.extremes {
            let controller = worstController(.light, first: match)
            try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                            scene: "latest-\(name)", size: Harness.minimumSize)
            await controller.teardownAndWait()
        }
    }

    @Test("Today's Earlier list ends with how many more are in History, at the default and a larger text size, light and dark")
    func todayEarlierMore() async throws {
        // Tall enough for the whole list: the latest card, twelve rows and the last line.
        let tall = CGSize(width: Harness.minimumSize.width, height: 2_000)
        for variant in [Variant.light, .dark] {
            let controller = Harness.sampleController(variant)
            controller.recentEntries = WindowSampleData.heavyDay()
            for (suffix, textSize) in [("", DynamicTypeSize.large), ("-xxlarge", .xxLarge)] {
                try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                                scene: "earlier-more-1000\(suffix)", variant: variant, size: tall, textSize: textSize)
            }
            await controller.teardownAndWait()
        }
    }

    @Test("Today's header with the most it can count, one dictation and none")
    func todayCounts() async throws {
        let heavy = Harness.sampleController(.light)
        heavy.recentEntries = WindowSampleData.heavyDay()
        try await write(ContentView(initialTab: .today), controller: heavy, surface: "today",
                        scene: "counts-1000-dictations", size: Harness.minimumSize)
        // 1,000 dictations of an hour each: about ten million words.
        let hour = Array(repeating: WindowSampleData.longEmail, count: 18).joined(separator: "\n\n")
        heavy.recentEntries = WindowSampleData.heavyDay(text: hour)
        try await write(ContentView(initialTab: .today), controller: heavy, surface: "today",
                        scene: "counts-ten-million-words", size: Harness.minimumSize)
        await heavy.teardownAndWait()

        // Chinese and Japanese count their words, not their spaces: 1,000 long dictations in each look.
        let chinese = String(repeating: "我们明天下午三点开会讨论新的设计方案，请把议程和预算表发给大家。", count: 40)
        for variant in [Variant.light, .dark] {
            let cjk = Harness.sampleController(variant)
            cjk.recentEntries = WindowSampleData.heavyDay(text: chinese)
            try await write(ContentView(initialTab: .today), controller: cjk, surface: "today",
                            scene: "counts-cjk-1000", variant: variant, size: Harness.minimumSize)
            cjk.recentEntries = [TranscriptEntry(createdAt: Date(), appBundleID: "com.apple.mail", rawText: "今日は東京で会議があります。",
                                                 cleanText: "今日は東京で会議があります。", durationMS: 2_100, audioURL: nil,
                                                 insertionStatus: .inserted)]
            try await write(ContentView(initialTab: .today), controller: cjk, surface: "today",
                            scene: "counts-japanese-one", variant: variant, size: Harness.minimumSize)
            await cjk.teardownAndWait()
        }

        let one = Harness.sampleController(.light)
        one.recentEntries = WindowSampleData.oneEntry()
        try await write(ContentView(initialTab: .today), controller: one, surface: "today",
                        scene: "counts-one", size: Harness.minimumSize)
        one.recentEntries = [TranscriptEntry(createdAt: Date(), appBundleID: "com.apple.mail", rawText: "Yes.", cleanText: "Yes.",
                                             durationMS: 900, audioURL: nil, insertionStatus: .inserted)]
        try await write(ContentView(initialTab: .today), controller: one, surface: "today",
                        scene: "counts-one-word", size: Harness.minimumSize)
        await one.teardownAndWait()

        let empty = Harness.sampleController(.light, populated: false)
        try await write(ContentView(initialTab: .today), controller: empty, surface: "today",
                        scene: "empty-minimum", size: Harness.minimumSize)
        try await write(ContentView(initialTab: .today), controller: empty, surface: "today",
                        scene: "empty-larger-text", size: Harness.minimumSize, textSize: .xxLarge)
        await empty.teardownAndWait()
    }

    @Test("Today's idle stage with a very long microphone name, and with the microphone and shortcuts off")
    func todayStage() async throws {
        let saved = TodayMicrophone.previewChoice
        defer { TodayMicrophone.previewChoice = saved }
        TodayMicrophone.previewChoice = TodayMicrophoneChoice(id: "usb", name: Self.longMicrophone)
        for (size, label) in [(Harness.minimumSize, "minimum"), (Harness.windowSize, "default")] {
            let controller = worstController(.light)
            try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                            scene: "stage-long-microphone-\(label)", size: size)
            try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                            scene: "stage-long-microphone-larger-text-\(label)", size: size, textSize: .xxLarge)
            controller.microphonePermissionStatus = .denied
            try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                            scene: "stage-microphone-off-\(label)", size: size)
            controller.microphonePermissionStatus = .granted
            controller.preferences.hotkeys.optionPressToTalkEnabled = false
            controller.preferences.hotkeys.handsFreeGlobalKeyCode = nil
            try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                            scene: "stage-shortcuts-off-\(label)", size: size)
            await controller.teardownAndWait()
        }
    }

    @Test("Today's live stage with words longer than it can show, right to left, CJK and a long app")
    func todayLive() async throws {
        let samples: [(String, DictationController.LiveWords, String?)] = [
            ("email", .init(stable: WindowSampleData.longEmail, tail: " and then the signature"), "Mail"),
            ("long-app", .init(stable: "Remind me to call the venue ", tail: "about the deposit"), Self.longApp),
            ("token", .init(stable: WindowSampleData.unbreakableToken, tail: ""), "Safari"),
            ("arabic", .init(stable: "سأتصل بك بعد الاجتماع لنراجع العقد ", tail: "معًا قبل يوم الخميس"), "Mail"),
            ("hebrew", .init(stable: "אני אתקשר אליך אחרי הפגישה ", tail: "כדי לעבור על החוזה"), "Mail"),
            ("cjk", .init(stable: "明天上午十点开会，请把议程和预算表发给大家，", tail: "我们需要在周五之前确认所有细节。"), "Slack"),
            ("cjk-long", .init(stable: String(repeating: "明天上午十点开会，请把议程和预算表发给大家，我们需要在周五之前确认所有细节。", count: 6), tail: "谢谢。"), "Slack"),
            ("emoji", .init(stable: WindowSampleData.zwjEmoji + " ", tail: "see you at 7"), "Messages"),
        ]
        for (name, words, app) in samples {
            for (size, label) in [(Harness.minimumSize, "minimum"), (Harness.windowSize, "default")] where label == "minimum" || name == "email" {
                let controller = worstController(.light)
                controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
                controller.recordingStartedAt = Date().addingTimeInterval(-3_541)
                controller.stageIsolatedPreviewRecording(targetApp: app, words: words)
                try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                                scene: "live-\(name)-\(label)", size: size)
                await controller.teardownAndWait()
            }
        }
        let controller = worstController(.dark)
        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date().addingTimeInterval(-14)
        controller.stageIsolatedPreviewRecording(targetApp: Self.longApp, words: samples[0].1)
        try await write(ContentView(initialTab: .today), controller: controller, surface: "today",
                        scene: "live-email-larger-text", variant: .dark, size: Harness.minimumSize, textSize: .xxLarge)
        await controller.teardownAndWait()
    }

    @Test("Today's result and problem with long words and a long app")
    func todayResult() async throws {
        let held = GroveTodayFlow.Timing(resultWait: .seconds(120), settleHold: .seconds(120), quietNote: .seconds(120))
        for (name, text, status) in [("email", WindowSampleData.longEmail, InsertionStatus.inserted),
                                     ("token", WindowSampleData.unbreakableToken, .copiedOnly),
                                     ("arabic", "سأتصل بك بعد الاجتماع لنراجع العقد معًا قبل يوم الخميس", .inserted),
                                     ("problem", WindowSampleData.longEmail, .failed)] {
            let controller = worstController(.light)
            let entry = TranscriptEntry(createdAt: Date(), appBundleID: "com.example.Northwind-Industries-Holdings-Desktop-Client",
                                        rawText: text, cleanText: text, durationMS: 241_000, audioURL: nil, insertionStatus: status,
                                        record: DictationRecord(copyReason: status == .copiedOnly ? "appChanged" : nil, appName: Self.longApp))
            let previous = controller.recentEntries.first?.id
            controller.recentEntries.insert(entry, at: 0)
            let flow = GroveTodayFlow(timing: held)
            flow.lifecycle(.recordingHandsFree, latestID: previous, canUndoDiscard: false)
            flow.lifecycle(.idle, latestID: previous, canUndoDiscard: false)
            flow.latestEntry(entry, appName: Self.longApp)
            let view = Harness.window(.today, controller: controller) { GroveTodayView(flow: flow) }
            try await write(view, controller: controller, surface: "today", scene: "result-\(name)-minimum",
                            size: Harness.minimumSize)
            await controller.teardownAndWait()
        }
    }

    /// The live stage's worst cases.
    static let liveSamples: [(String, DictationController.LiveWords?, String?)] = [
        ("email", .init(stable: WindowSampleData.longEmail, tail: " and then the signature"), "Mail"),
        ("long-app", .init(stable: "Remind me to call the venue ", tail: "about the deposit"), longApp),
        ("token", .init(stable: WindowSampleData.unbreakableToken, tail: ""), "Safari"),
        ("arabic", .init(stable: "سأتصل بك بعد الاجتماع لنراجع العقد ", tail: "معًا قبل يوم الخميس"), "Mail"),
        ("hebrew", .init(stable: "אני אתקשר אליך אחרי הפגישה ", tail: "כדי לעבור על החוזה"), "Mail"),
        ("cjk-long", .init(stable: String(repeating: "明天上午十点开会，请把议程和预算表发给大家，我们需要在周五之前确认所有细节。", count: 6), tail: "谢谢。"), "Slack"),
        ("emoji", .init(stable: WindowSampleData.zwjEmoji + " ", tail: "see you at 7"), "Messages"),
        ("padded", .init(stable: WindowSampleData.padded, tail: ""), "Notes"),
        ("one-word", .init(stable: "Yes.", tail: ""), "Mail"),
        ("no-words", nil, "Mail"),
    ]

    // MARK: History

    @Test("History with the worst case, at every window size and look")
    func historyWorst() async throws {
        let start = ContentView.InitialState(historyEntryID: WindowSampleData.worstLatestID)
        for (size, label) in [(Harness.minimumSize, "minimum"), (Harness.windowSize, "default"), (Self.largeSize, "large")] {
            let controller = worstController(.light)
            try await write(ContentView(initialTab: .history, initialState: start), controller: controller, surface: "history",
                            scene: "worst-\(label)", size: size)
            await controller.teardownAndWait()
        }
        for variant in [Variant.dark, .contrast, .contrastDark] {
            let controller = worstController(variant)
            try await write(ContentView(initialTab: .history, initialState: start), controller: controller, surface: "history",
                            scene: "worst-default", variant: variant)
            await controller.teardownAndWait()
        }
        let controller = worstController(.light)
        try await write(ContentView(initialTab: .history, initialState: start), controller: controller, surface: "history",
                        scene: "worst-larger-text-minimum", size: Harness.minimumSize, textSize: .xxLarge)
        await controller.teardownAndWait()
    }

    @Test("History's reader with each extreme open")
    func historyReader() async throws {
        let entries = WindowSampleData.worstCaseEntries()
        var cases = Self.extremes
        cases.append(("three-years-old", { $0.createdAt < Date().addingTimeInterval(-2 * 365 * 86_400) }))
        cases.append(("new-years-eve", { $0.cleanText.hasPrefix("Last one of the year") }))
        cases.append(("new-years-day", { $0.cleanText.hasPrefix("Happy new year") }))
        for (name, match) in cases {
            let id = try #require(entries.first(where: match)?.id, "\(name)")
            let controller = worstController(.light)
            controller.recentEntries = entries
            try await write(ContentView(initialTab: .history, initialState: .init(historyEntryID: id)), controller: controller,
                            surface: "history", scene: "reader-\(name)-minimum", size: Harness.minimumSize)
            await controller.teardownAndWait()
        }
        // How it was written for a four-minute dictation through a long-named microphone.
        let latest = try #require(entries.first { $0.id == WindowSampleData.worstLatestID })
        let record = try #require(latest.record)
        let model = try #require(GroveHowItWasWritten.Model.make(entry: latest, record: record, appName: "Microsoft Word"))
        #expect(model.steps.first?.time == "4 min 1 s")
        for variant in [Variant.light, .contrastDark] {
            let section = GroveHowItWasWrittenSample(model: model).groveTheme(accentStyle: .citron)
            try await write(section, controller: nil, surface: "history", scene: "how-it-was-written-four-minutes", variant: variant,
                            size: CGSize(width: 560, height: 220))
        }
    }

    @Test("History's search, filters, Before cleanup, Fix a word and the delete dialog with extremes")
    func historyStates() async throws {
        let controller = worstController(.light)
        // Before cleanup on the long email, with a long raw text.
        if let index = controller.recentEntries.firstIndex(where: { $0.id == WindowSampleData.worstLatestID }) {
            controller.recentEntries[index].rawText = "Um, so, " + WindowSampleData.longEmail.replacingOccurrences(of: "Thanks", with: "Uh, thanks")
        }
        var start = ContentView.InitialState(historyEntryID: WindowSampleData.worstLatestID)
        start.historyBeforeCleanupExpanded = true
        try await write(ContentView(initialTab: .history, initialState: start), controller: controller, surface: "history",
                        scene: "before-cleanup-email-minimum", size: Harness.minimumSize)

        start = ContentView.InitialState(historyEntryID: WindowSampleData.worstLatestID)
        start.historyQuery = String(WindowSampleData.unbreakableToken.prefix(120))
        try await write(ContentView(initialTab: .history, initialState: start), controller: controller, surface: "history",
                        scene: "search-long-query-minimum", size: Harness.minimumSize)
        start.historyQuery = "Exampletta Sampleberg-Testerton from Northwind-Industries-Holdings"
        try await write(ContentView(initialTab: .history, initialState: start), controller: controller, surface: "history",
                        scene: "search-no-matches-minimum", size: Harness.minimumSize)
        start.historyQuery = "الاجتماع"
        try await write(ContentView(initialTab: .history, initialState: start), controller: controller, surface: "history",
                        scene: "search-arabic-minimum", size: Harness.minimumSize)

        for filter in HistoryFilter.allCases {
            var filtered = ContentView.InitialState(historyEntryID: nil)
            filtered.historyFilter = filter
            try await write(ContentView(initialTab: .history, initialState: filtered), controller: controller, surface: "history",
                            scene: "filter-\(filter.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))-minimum", size: Harness.minimumSize)
        }

        let tokenEntry = try #require(controller.recentEntries.first(where: Self.id(of: WindowSampleData.unbreakableToken)))
        var fix = ContentView.InitialState(historyEntryID: tokenEntry.id)
        let word = "northwind-industries-holdings"
        fix.fix = FixWordState(entryID: tokenEntry.id, range: (tokenEntry.cleanText as NSString).range(of: word),
                               word: word, replacement: "northwind-industries-holdings-international-group")
        try await write(ContentView(initialTab: .history, initialState: fix), controller: controller, surface: "history",
                        scene: "fix-word-token-minimum", size: Harness.minimumSize)

        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        feedback.confirm(title: HistoryRules.deleteAllConfirmationTitle(listedCount: 1_000), message: HistoryRules.deleteAllMessage,
                         confirmTitle: HistoryRules.deleteAllButton) {}
        let dialog = Harness.window(.history, controller: controller, feedback: feedback) {
            GroveHistoryView(initialSelectedEntryID: WindowSampleData.worstLatestID)
        }
        try await write(dialog, controller: controller, surface: "history", scene: "delete-all-1000-minimum",
                        size: Harness.minimumSize)
        try await write(dialog, controller: controller, surface: "history", scene: "delete-all-1000-larger-text",
                        size: Harness.minimumSize, textSize: .xxLarge)
        await controller.teardownAndWait()
    }

    @Test("History with one dictation, 1,000, and none")
    func historyCounts() async throws {
        let controller = Harness.sampleController(.light)
        controller.recentEntries = WindowSampleData.oneEntry()
        try await write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.latestID)),
                        controller: controller, surface: "history", scene: "one")
        controller.recentEntries = WindowSampleData.worstCaseEntries() + WindowSampleData.thousandEntries()
        try await write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.worstLatestID)),
                        controller: controller, surface: "history", scene: "thousand", size: Self.largeSize)
        await controller.teardownAndWait()
        let empty = Harness.sampleController(.light, populated: false)
        try await write(ContentView(initialTab: .history), controller: empty, surface: "history",
                        scene: "first-run-minimum", size: Harness.minimumSize)
        await empty.teardownAndWait()
    }

    // MARK: Insights

    static let usageCases: [(String, UsageAnalyticsSnapshot)] = {
        let normal = Dictionary(uniqueKeysWithValues: (0..<180).compactMap { day in day % 3 == 0 ? (day, 300 + day * 7) : nil })
        var enormous = normal
        enormous[9] = 9_999_999
        return [
            ("huge-total", WindowSampleData.usageSnapshot(dailyWords: Dictionary(uniqueKeysWithValues: (0..<180).map { ($0, 55_555) }))),
            ("enormous-day", WindowSampleData.usageSnapshot(dailyWords: enormous)),
            ("enormous-today", WindowSampleData.usageSnapshot(dailyWords: [0: 9_999_999, 3: 420])),
            ("all-zero", WindowSampleData.usageSnapshot(dailyWords: [:])),
            ("single-day", WindowSampleData.usageSnapshot(dailyWords: [12: 840])),
            ("one-word", WindowSampleData.usageSnapshot(dailyWords: [0: 1])),
            ("counts-start-today", WindowSampleData.usageSnapshot(dailyWords: [0: 120], countedFromDaysAgo: 0)),
            ("counts-start-week", WindowSampleData.usageSnapshot(dailyWords: [0: 120, 2: 340, 5: 60], countedFromDaysAgo: 6)),
        ]
    }()

    @Test("Insights with a chosen day fills the panel at every width")
    func insightsChosenDay() async throws {
        let calendar = Calendar.current
        let chosen = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!
        for (size, label) in [(Harness.minimumSize, "minimum"), (Harness.windowSize, "default"), (Self.largeSize, "large")] {
            for variant in [Variant.light, .dark] {
                let controller = Harness.sampleController(variant)
                controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot()
                try await write(ContentView(initialTab: .insights, initialState: .init(insightsDay: chosen)), controller: controller,
                                surface: "insights", scene: "chosen-day-\(label)", variant: variant, size: size)
                await controller.teardownAndWait()
            }
        }
    }

    @Test("Insights with huge counts and calendar extremes")
    func insightsExtremes() async throws {
        for (name, snapshot) in Self.usageCases {
            let controller = Harness.sampleController(.light)
            controller.usageAnalyticsSnapshot = snapshot
            try await write(ContentView(initialTab: .insights), controller: controller, surface: "insights",
                            scene: "\(name)-minimum", size: Harness.minimumSize)
            if name == "enormous-day" || name == "huge-total" {
                try await write(ContentView(initialTab: .insights), controller: controller, surface: "insights",
                                scene: "\(name)-default")
                try await write(ContentView(initialTab: .insights), controller: controller, surface: "insights",
                                scene: "\(name)-large", size: Self.largeSize)
                try await write(ContentView(initialTab: .insights), controller: controller, surface: "insights",
                                scene: "\(name)-larger-text-minimum", size: Harness.minimumSize, textSize: .xxLarge)
                for variant in [Variant.dark, .contrast, .contrastDark] {
                    let other = Harness.sampleController(variant)
                    other.usageAnalyticsSnapshot = snapshot
                    try await write(ContentView(initialTab: .insights), controller: other, surface: "insights",
                                    scene: "\(name)-default", variant: variant)
                    await other.teardownAndWait()
                }
            }
            await controller.teardownAndWait()
        }
        // Loading and error, at the minimum width and with larger text.
        let controller = Harness.sampleController(.light)
        controller.usageAnalyticsSnapshot = .empty
        controller.isLoadingUsageAnalytics = true
        try await write(ContentView(initialTab: .insights), controller: controller, surface: "insights",
                        scene: "loading-minimum", size: Harness.minimumSize)
        controller.isLoadingUsageAnalytics = false
        controller.usageAnalyticsError = "The usage file couldn’t be read because it isn’t in the correct format. "
            + "/Users/example-person-with-a-very-long-account-name/Library/Application Support/Steno/usage-analytics.json"
        try await write(ContentView(initialTab: .insights), controller: controller, surface: "insights",
                        scene: "error-long-minimum", size: Harness.minimumSize, textSize: .xxLarge)
        await controller.teardownAndWait()
    }

    // MARK: Menu bar panel

    @Test("The menu bar panel with worst-case dictations, devices and a long app")
    func menuPanel() async throws {
        let devices = [
            InputDeviceOption(id: "built-in", name: "MacBook Pro Microphone", isDefault: true),
            InputDeviceOption(id: "usb", name: Self.longMicrophone, isDefault: false),
            InputDeviceOption(id: "aggregate", name: "Example Owner’s AirPods Pro – Find My", isDefault: false),
        ]
        let worst = WindowSampleData.worstCaseEntries()
        let ordered = [worst[0], worst[2], worst[3], worst[1]] + Array(worst.dropFirst(4))
        var cases: [(String, MenuBarSnapshot, String?, GroveMenuSection?)] = []
        var idle = MenuBarSnapshot(entries: Array(ordered.prefix(4)), pasteShortcut: GlobalShortcut(keyCode: 9, modifiers: [.control, .option]),
                                   canPasteLast: true, devices: devices, selectedDeviceID: "usb")
        cases.append(("idle", idle, nil, nil))
        cases.append(("earlier", idle, nil, .earlier))
        cases.append(("microphone", idle, nil, .microphone))
        idle.entries = Array(worst.filter { [WindowSampleData.unbreakableToken, WindowSampleData.hebrew, WindowSampleData.zwjEmoji,
                                               WindowSampleData.padded].contains($0.cleanText) || $0.insertionStatus == .noSpeech })
        cases.append(("extremes", idle, nil, .earlier))
        var recording = idle
        recording.lifecycle = .recordingHandsFree
        recording.isRecording = true
        recording.recordingStartedAt = Date().addingTimeInterval(-3_541)
        cases.append(("recording-long-app", recording, Self.longApp, nil))
        // The header names only a shortcut that works, and says when Steno can't dictate.
        var handsFreeOnly = idle
        handsFreeOnly.shortcuts = TodayShortcuts(optionHold: false, handsFreeKey: "F18")
        cases.append(("header-hands-free-only", handsFreeOnly, nil, nil))
        var shortcutsOff = idle
        shortcutsOff.shortcuts = TodayShortcuts(optionHold: false, handsFreeKey: nil)
        cases.append(("header-shortcuts-off", shortcutsOff, nil, nil))
        var microphoneOff = idle
        microphoneOff.microphoneDenied = true
        cases.append(("header-microphone-off", microphoneOff, nil, nil))
        for (name, snapshot, app, section) in cases {
            for look in [GroveMenuRenderingTests.Look.light, .dark] where look == .light || name == "idle" {
                let state = GroveMenuState()
                state.reset(snapshot: snapshot, targetAppName: app, usesKeyboard: false)
                if let section { state.toggle(section) }
                let data = try await GroveMenuRenderingTests.render(state: state, look: look,
                                                                    level: snapshot.isRecording ? 0.7 : nil)
                let file = "\(name)-\(look.rawValue).png"
                try data.write(to: Self.directory("menu").appendingPathComponent(file))
                #expect(data.count > 8_000, "\(file)")
            }
        }
    }

    @Test("The menu bar panel's header in every state, light and dark")
    func menuHeader() async throws {
        let entries = Array(WindowSampleData.worstCaseEntries().prefix(2))
        let base = MenuBarSnapshot(entries: entries, canPasteLast: true)
        var states: [(String, MenuBarSnapshot, String?)] = [("ready-option", base, nil)]
        var handsFree = base
        handsFree.shortcuts = TodayShortcuts(optionHold: false, handsFreeKey: "F18")
        states.append(("ready-hands-free-only", handsFree, nil))
        var off = base
        off.shortcuts = TodayShortcuts(optionHold: false, handsFreeKey: nil)
        states.append(("ready-shortcuts-off", off, nil))
        var denied = base
        denied.microphoneDenied = true
        states.append(("not-ready-microphone-off", denied, nil))
        var deniedHandsFree = handsFree
        deniedHandsFree.microphoneDenied = true
        states.append(("not-ready-microphone-off-hands-free-only", deniedHandsFree, nil))
        var recording = base
        recording.lifecycle = .recordingPressToTalk
        recording.isRecording = true
        recording.recordingStartedAt = Date().addingTimeInterval(-14)
        states.append(("listening", recording, Self.longApp))
        var transcribing = base
        transcribing.lifecycle = .transcribing
        states.append(("transcribing", transcribing, nil))
        for (name, snapshot, app) in states {
            for look in [GroveMenuRenderingTests.Look.light, .dark] {
                let state = GroveMenuState()
                state.reset(snapshot: snapshot, targetAppName: app, usesKeyboard: false)
                let data = try await GroveMenuRenderingTests.render(state: state, look: look,
                                                                    level: snapshot.isRecording ? 0.7 : nil)
                let file = "\(name)-\(look.rawValue).png"
                try data.write(to: Self.directory("menu-header").appendingPathComponent(file))
                #expect(data.count > 8_000, "\(file)")
            }
        }
    }

    // MARK: Status pill

    @Test("The window's status pill in every state, light and dark")
    func statusPill() async throws {
        let start = Date().addingTimeInterval(-3_541)
        let states: [(String, WindowStatusInputs)] = [
            ("ready", WindowStatusInputs()),
            ("listening", WindowStatusInputs(lifecycle: .recordingHandsFree, recordingStartedAt: start)),
            ("transcribing", WindowStatusInputs(lifecycle: .transcribing)),
            ("microphone-off", WindowStatusInputs(microphone: .denied)),
            ("no-speech-model", WindowStatusInputs(speechModelMissing: true)),
            ("copy-only", WindowStatusInputs(accessibility: .denied)),
            ("option-key-off", WindowStatusInputs(inputMonitoring: .denied, optionHold: true, handsFreeKeyName: nil)),
            ("f18-key-off", WindowStatusInputs(inputMonitoring: .denied, optionHold: false, handsFreeKeyName: "F18")),
            ("shortcuts-off-both-on", WindowStatusInputs(inputMonitoring: .denied, optionHold: true, handsFreeKeyName: "F18")),
            ("shortcuts-off-neither-on", WindowStatusInputs(inputMonitoring: .denied, optionHold: false, handsFreeKeyName: nil)),
            ("downloading", WindowStatusInputs(downloadPercent: 100)),
        ]
        for variant in [Variant.light, .dark] {
            let controller = Harness.sampleController(variant)
            for (name, inputs) in states {
                let view = GroveWindowContent(accent: controller.preferences.appearance.accent, feedback: GroveFeedback()) {
                    InlineWindowChrome(tab: .constant(.history), inputs: inputs)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                try await write(view, controller: controller, surface: "status-pill", scene: name, variant: variant,
                                size: CGSize(width: Harness.minimumSize.width, height: 72))
            }
            await controller.teardownAndWait()
        }
    }

    // MARK: Settings

    @Test("Media and Cleanup, light and dark, at the minimum and default sizes")
    func mediaAndCleanup() async throws {
        let base = SettingsWindowRenderingTests()
        for section in [SettingsSection.media, .cleanup] {
            for variant in [Variant.light, .dark] {
                for (size, label) in [(SettingsWindowRoot.minimumSize, "minimum"), (CGSize(width: 860, height: 900), "default")] {
                    let controller = base.makeController(variant == .dark ? .dark : .light)
                    controller.preferences.hotkeys.optionPressToTalkEnabled = false
                    let session = base.session(for: controller, section: section)
                    let view = SettingsView(session: session)
                        .overlay(alignment: .topLeading) { GroveInlineTrafficLights().padding(.leading, 20).padding(.top, 20) }
                        .environment(\.controlActiveState, .active)
                    try await write(view, controller: controller, surface: "settings-media-cleanup",
                                    scene: "\(section.rawValue)-\(label)", variant: variant, size: size)
                    await controller.teardownAndWait()
                }
            }
        }
    }

    private static func worstPreferences(_ preferences: inout AppPreferences) {
        preferences.lexiconEntries = [
            LexiconEntry(term: "Exampletta Sampleberg-Testerton", preferred: "Exampletta Sampleberg-Testerton (Northwind Industries Holdings)",
                         scope: .global, aliases: ["eksamplette sampleberg", "exampletta sampleberg testerton", "eksampleta sampleberg-testeton"]),
            LexiconEntry(term: "northwindindustriesholdingsdesktopclient", preferred: "Northwind-Industries-Holdings-Desktop-Client",
                         scope: .app(bundleID: "com.example.Northwind-Industries-Holdings-Desktop-Client")),
            LexiconEntry(term: "王秀英", preferred: "王秀英 (Wang Xiuying)", scope: .global),
            LexiconEntry(term: "نور الهدى", preferred: "نور الهدى عبد الرحمن", scope: .global),
        ] + (0..<40).map { LexiconEntry(term: "term \($0)", preferred: "Preferred Term \($0)", scope: .global) }
        preferences.snippets = [
            Snippet(trigger: "signature for the northwind legal team", expansion: WindowSampleData.longEmail, scope: .global),
            Snippet(trigger: "link", expansion: WindowSampleData.unbreakableToken,
                    scope: .app(bundleID: "com.example.Northwind-Industries-Holdings-Desktop-Client")),
            Snippet(trigger: "شكرا", expansion: "شكرا جزيلا على وقتك", scope: .global),
        ] + (0..<40).map { Snippet(trigger: "shortcut \($0)", expansion: "Expansion number \($0).", scope: .global) }
        let deep = "/Users/example-person-with-a-very-long-account-name/Library/Application Support/Steno/Models/Custom Whisper Models (imported 2026-10-08)"
        preferences.dictation.updateModelPath(deep + "/ggml-large-v3-turbo-q5_0-northwind-fine-tuned-final-v12.bin")
        preferences.dictation.vadModelPath = deep + "/ggml-silero-v6.2.0-custom-voice-activity-detection.bin"
        preferences.dictation.whisperCLIPath = deep + "/bin/whisper-cli"
        preferences.inputDeviceID = "usb"
        var style = preferences.globalStyleProfile
        style.structureMode = .paragraph
        preferences.appStyleProfiles["com.example.Northwind-Industries-Holdings-Desktop-Client"] = style
        preferences.appStyleProfiles["com.example.unknown-capture-tool"] = style
    }

    @Test("Every Settings pane with long and many entries, long paths and a long microphone")
    func settingsWorst() async throws {
        let base = SettingsWindowRenderingTests()
        let devices = [InputDeviceOption(id: "builtin", name: "MacBook Pro Microphone", isDefault: true),
                       InputDeviceOption(id: "usb", name: Self.longMicrophone, isDefault: false)]
        for section in SettingsSection.allCases {
            for (size, label, textSize) in [(SettingsWindowRoot.minimumSize, "minimum", DynamicTypeSize.large),
                                            (CGSize(width: 860, height: 900), "default", .large),
                                            (CGSize(width: 960, height: 900), "larger-text", .xxxLarge)] {
                let controller = base.makeController(.light)
                Self.worstPreferences(&controller.preferences)
                let session = base.session(for: controller, section: section,
                                           microphone: .preview(devices: devices, testingAt: section == .microphone ? 0.58 : nil))
                let view = SettingsView(session: session)
                    .overlay(alignment: .topLeading) { GroveInlineTrafficLights().padding(.leading, 20).padding(.top, 20) }
                    .environment(\.controlActiveState, .active)
                try await write(view, controller: controller, surface: "settings", scene: "\(section.rawValue)-\(label)",
                                size: size, textSize: textSize)
                await controller.teardownAndWait()
            }
        }
        // A draft with many changes, and the dark look of the busiest panes.
        for section in [SettingsSection.corrections, .shortcuts, .engine, .microphone] {
            let controller = base.makeController(.dark)
            let session = base.session(for: controller, section: section, edit: Self.worstPreferences(_:),
                                       microphone: .preview(devices: devices, testingAt: nil))
            let view = SettingsView(session: session)
                .overlay(alignment: .topLeading) { GroveInlineTrafficLights().padding(.leading, 20).padding(.top, 20) }
                .environment(\.controlActiveState, .active)
            try await write(view, controller: controller, surface: "settings", scene: "\(section.rawValue)-draft-minimum",
                            variant: .dark, size: SettingsWindowRoot.minimumSize)
            await controller.teardownAndWait()
        }
    }

    @Test("Speech Model's advanced paths, long, at the minimum width and with larger text")
    func engineAdvanced() async throws {
        let base = SettingsWindowRenderingTests()
        for (label, width, textSize) in [("minimum", CGFloat(500), DynamicTypeSize.large), ("larger-text", 640, .xxxLarge)] {
            let controller = base.makeController(.light)
            Self.worstPreferences(&controller.preferences)
            let binding = Binding(get: { controller.preferences }, set: { controller.preferences = $0 })
            let page = ScrollView {
                EngineSettingsSection(preferences: binding, controller: controller, previewSetupCheckStages: [])
                    .padding(.horizontal, 36).padding(.top, 36)
            }
            .groveSettingsPage()
            try await write(page, controller: controller, surface: "settings", scene: "engine-advanced-\(label)",
                            size: CGSize(width: width, height: 1_100), textSize: textSize)
            await controller.teardownAndWait()
        }
    }

    // MARK: Island

    struct IslandCase {
        let name: String
        let state: OverlayState
        var after: OverlayState?
        var stable = ""
        var tail = ""
        var words: String?
    }

    static let islandCases: [IslandCase] = {
        let inserted = OverlayState.result(.inserted(appName: longApp, method: .typed), showsWords: true)
        let listening = OverlayState.listening(handsFree: true, elapsedSeconds: 3_541)
        return [
            IslandCase(name: "inserted-long-app", state: .listening(handsFree: false, elapsedSeconds: 4),
                       after: .result(.inserted(appName: longApp, method: .typed), showsWords: false)),
            IslandCase(name: "card-long-app-email", state: listening, after: inserted, words: "Hi Dana,"),
            IslandCase(name: "card-token", state: listening, after: inserted, words: WindowSampleData.unbreakableToken),
            IslandCase(name: "card-arabic", state: listening, after: inserted, words: "سأتصل بك بعد الاجتماع لنراجع العقد معًا قبل يوم الخميس"),
            IslandCase(name: "card-hebrew", state: listening, after: inserted, words: WindowSampleData.hebrew + " כדי לעבור על החוזה"),
            IslandCase(name: "card-arabic-short", state: .listening(handsFree: true, elapsedSeconds: 4),
                       after: .result(.inserted(appName: "Mail", method: .typed), showsWords: true), words: "شكرا"),
            IslandCase(name: "card-cjk", state: listening, after: inserted,
                       words: String(repeating: "明天上午十点开会，请把议程和预算表发给大家。", count: 4)),
            IslandCase(name: "card-emoji", state: listening, after: inserted, words: WindowSampleData.zwjEmoji),
            IslandCase(name: "live-email", state: listening, stable: WindowSampleData.longEmail, tail: " and then the signature"),
            IslandCase(name: "live-token", state: listening, stable: WindowSampleData.unbreakableToken),
            IslandCase(name: "live-arabic", state: listening, stable: "سأتصل بك بعد الاجتماع لنراجع العقد ", tail: "معًا قبل يوم الخميس"),
            IslandCase(name: "live-hebrew", state: listening, stable: WindowSampleData.hebrew + " ", tail: "כדי לעבור על החוזה"),
            IslandCase(name: "live-cjk", state: listening,
                       stable: String(repeating: "明天上午十点开会，请把议程和预算表发给大家，", count: 5), tail: "我们需要在周五之前确认所有细节。"),
            IslandCase(name: "live-emoji", state: listening, stable: WindowSampleData.zwjEmoji + " ", tail: "see you at 7"),
            IslandCase(name: "live-padded", state: listening, stable: WindowSampleData.padded),
            IslandCase(name: "live-one-word", state: .listening(handsFree: false, elapsedSeconds: 2), stable: "Yes."),
            IslandCase(name: "live-blank-lines", state: listening, stable: "Hi Dana,\n\n\n", tail: "Thanks for the notes."),
            IslandCase(name: "no-speech", state: .listening(handsFree: false, elapsedSeconds: 1), after: .noSpeechDetected),
            IslandCase(name: "pasted-long-app", state: listening,
                       after: .result(.inserted(appName: longApp, method: .pasted), showsWords: false)),
            IslandCase(name: "copied-app-not-responding", state: listening,
                       after: .result(.copied(.appNotResponding), showsWords: true), words: WindowSampleData.longEmail),
        ]
    }()

    @Test("The island with long app names and live or inserted words it cannot show in full")
    func island() throws {
        let display = GroveOverlayRenderingTests.display
        for notch in [true, false] {
            for dark in [false, true] {
                for item in Self.islandCases {
                    let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
                    presenter.hostedEvidencePrepareOffscreen()
                    presenter.hostedEvidenceSetPlacement(notch ? .notch(display: display, notch: display.notch!) : .capsule(display: display))
                    presenter.appearance = .grove
                    presenter.updateAppearance(NSAppearance(named: dark ? .darkAqua : .aqua))
                    presenter.setHostedAccessibilityPreferences(.init(reduceMotion: true, reduceTransparency: false,
                                                                      increaseContrast: false, preferredBodyPointSize: 13))
                    presenter.setLiveTranscriptEnabled(item.after == nil)
                    presenter.setStopAction {}
                    presenter.onCopyResult = {}
                    presenter.show(state: item.state, insertedWords: nil)
                    if !item.stable.isEmpty || !item.tail.isEmpty {
                        let session = LiveTranscriptionSession(sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1,
                                                               runtimeIdentity: .pending)
                        presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
                            session: session, stablePrefix: item.stable, revisableTail: item.tail,
                            lastAcceptedRevision: 1, decodedAudioWatermark: 1_600))
                        presenter.hostedEvidenceFlushLiveTranscript()
                    }
                    if let after = item.after { presenter.show(state: after, insertedWords: item.words) }
                    let backdrop = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1)
                    let data = try #require(presenter.hostedEvidenceRenderCurrentPNG(backdrop: backdrop, scale: 2))
                    let file = "\(item.name)-\(notch ? "notch" : "capsule")-\(dark ? "dark" : "light").png"
                    try data.write(to: Self.directory("island").appendingPathComponent(file))
                    presenter.hide()
                }
            }
        }
    }

    /// A small display (a 13-inch Mac at its largest text setting), where the island must still
    /// fit inside the screen.
    static let smallDisplay = OverlayDisplayDescriptor(
        id: 2, frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
        visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 616), isBuiltIn: false, safeAreaTop: 0,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )

    @Test("The island as a capsule with every worst case, light, dark and Increase Contrast, staying on screen")
    func islandFits() throws {
        let looks: [(String, Bool, Bool, CGFloat)] = [("light", false, false, 13), ("dark", true, false, 13),
                                                      ("contrast", false, true, 13), ("contrast-dark", true, true, 13),
                                                      ("large-text", false, false, 20)]
        for (look, dark, contrast, bodySize) in looks {
            for (displayName, display) in [("display", GroveOverlayRenderingTests.display), ("small-display", Self.smallDisplay)]
            where displayName == "display" || look == "large-text" {
                for item in Self.islandCases {
                    let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
                    presenter.hostedEvidencePrepareOffscreen()
                    presenter.hostedEvidenceSetPlacement(.capsule(display: display))
                    presenter.appearance = .grove
                    presenter.updateAppearance(NSAppearance(named: dark ? .darkAqua : .aqua))
                    presenter.setHostedAccessibilityPreferences(.init(reduceMotion: true, reduceTransparency: false,
                                                                      increaseContrast: contrast, preferredBodyPointSize: bodySize))
                    presenter.setLiveTranscriptEnabled(item.after == nil)
                    presenter.setStopAction {}
                    presenter.onCopyResult = {}
                    presenter.show(state: item.state, insertedWords: nil)
                    if !item.stable.isEmpty || !item.tail.isEmpty {
                        let session = LiveTranscriptionSession(sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1,
                                                               runtimeIdentity: .pending)
                        presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
                            session: session, stablePrefix: item.stable, revisableTail: item.tail,
                            lastAcceptedRevision: 1, decodedAudioWatermark: 1_600))
                        presenter.hostedEvidenceFlushLiveTranscript()
                    }
                    if let after = item.after { presenter.show(state: after, insertedWords: item.words) }
                    let label = "\(item.name)/\(look)/\(displayName)"
                    // The island stays inside its panel, and the panel inside the screen.
                    let layout = presenter.hostedEvidenceGroveLayout()
                    let island = try #require(presenter.hostedEvidenceCapsuleFrame(), "\(label)")
                    #expect(island.minX >= 0 && island.maxX <= layout.panelSize.width, "\(label): \(island) in \(layout.panelSize)")
                    #expect(display.frame.contains(layout.panelFrame), "\(label): \(layout.panelFrame)")
                    let backdrop = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1)
                    let data = try #require(presenter.hostedEvidenceRenderCurrentPNG(backdrop: backdrop, scale: 2))
                    let file = "\(item.name)-\(look)\(displayName == "display" ? "" : "-small").png"
                    try data.write(to: Self.directory("island-fit").appendingPathComponent(file))
                    presenter.hide()
                }
            }
        }
    }

    // MARK: Onboarding

    @Test("Onboarding with extreme first dictations, and larger text")
    func onboarding() async throws {
        let base = SettingsWindowRenderingTests()
        for (name, text) in [("email", WindowSampleData.longEmail), ("token", WindowSampleData.unbreakableToken),
                             ("arabic", "سأتصل بك بعد الاجتماع لنراجع العقد معًا قبل يوم الخميس"), ("one-word", "Yes.")] {
            var entry = GroveOnboardingRenderingTests.firstDictation
            entry.cleanText = text
            entry.rawText = text
            let controller = base.makeController(.light, populated: false)
            let view = OnboardingView(initialStep: 2, previewFirstDictation: entry)
                .overlay(alignment: .topLeading) { GroveInlineTrafficLights().padding(.leading, 20).padding(.top, 20) }
                .environment(\.controlActiveState, .active)
            try await write(view, controller: controller, surface: "onboarding", scene: "4-done-\(name)",
                            size: GroveOnboardingRenderingTests.size)
            await controller.teardownAndWait()
        }
        // The practice names the shortcut that is on, or says the shortcuts are off.
        for variant in [Variant.light, .dark] {
            for (name, optionHold, key, noSpeech) in [("hands-free-only", false, UInt16?.some(79), false),
                                                      ("hands-free-only-no-speech", false, UInt16?.some(79), true),
                                                      ("shortcuts-off", false, UInt16?.none, false),
                                                      ("option-no-speech", true, UInt16?.some(79), true)] {
                let controller = base.makeController(variant == .dark ? .dark : .light, populated: false)
                controller.preferences.hotkeys.optionPressToTalkEnabled = optionHold
                controller.preferences.hotkeys.handsFreeGlobalKeyCode = key
                if noSpeech { controller.status = "No speech detected." }
                let view = OnboardingView(initialStep: 2, previewFirstDictation: nil, previewTriedDictation: noSpeech)
                    .overlay(alignment: .topLeading) { GroveInlineTrafficLights().padding(.leading, 20).padding(.top, 20) }
                    .environment(\.controlActiveState, .active)
                try await write(view, controller: controller, surface: "onboarding", scene: "3-\(name)", variant: variant,
                                size: GroveOnboardingRenderingTests.size)
                await controller.teardownAndWait()
            }
        }
        for (name, step) in [("1-welcome", 0), ("2-permissions", 1), ("3-first-dictation", 2)] {
            let controller = base.makeController(.light, populated: false)
            if step == 1 { controller.permissionPreview(microphone: .granted, accessibility: .denied, inputMonitoring: .denied) }
            let view = OnboardingView(initialStep: step, previewFirstDictation: nil)
                .overlay(alignment: .topLeading) { GroveInlineTrafficLights().padding(.leading, 20).padding(.top, 20) }
                .environment(\.controlActiveState, .active)
            try await write(view, controller: controller, surface: "onboarding", scene: "\(name)-larger-text",
                            size: GroveOnboardingRenderingTests.size, textSize: .xxLarge)
            await controller.teardownAndWait()
        }
    }
}

/// The rules behind the worst-case fixes: previews, the live stage's window, dates from another
/// year, shares near 100% and right-to-left paragraphs.
@Suite("Grove worst-case rules")
@MainActor
struct GroveBreakUIRulesTests {
    @Test("A preview reads a paragraph break or padding as one space")
    func preview() {
        #expect(GrovePreviewText.make("Hi Dana,\n\nThanks for the draft.") == "Hi Dana, Thanks for the draft.")
        #expect(GrovePreviewText.make(WindowSampleData.padded) == "Call me back when you land.")
        #expect(GrovePreviewText.make("  \n ").isEmpty)
        #expect(GrovePreviewText.make(WindowSampleData.longEmail).count <= 400)
        #expect(GrovePreviewText.make(WindowSampleData.unbreakableToken) == WindowSampleData.unbreakableToken)
    }

    @Test("Hebrew and Arabic start at the right; Latin, CJK, digits first and emoji do not")
    func direction() {
        #expect(GrovePreviewText.isRightToLeft(WindowSampleData.hebrew))
        #expect(GrovePreviewText.isRightToLeft("7 سأتصل بك"))
        #expect(!GrovePreviewText.isRightToLeft("Call שלום"))
        #expect(!GrovePreviewText.isRightToLeft("明天上午十点开会"))
        #expect(!GrovePreviewText.isRightToLeft(WindowSampleData.zwjEmoji))
    }

    @Test("Right-to-left paragraphs are set right-aligned; the others keep the left edge")
    func paragraphs() {
        let metrics = TranscriptMetrics(flowing: 17, measure: 400)
        let text = "Hello there.\n" + WindowSampleData.hebrew
        let string = TranscriptTypesetter.attributedString(text, metrics: metrics, color: .black)
        let first = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let second = string.attribute(.paragraphStyle, at: (text as NSString).length - 1, effectiveRange: nil) as? NSParagraphStyle
        #expect(first?.alignment != .right)
        #expect(second?.alignment == .right && second?.baseWritingDirection == .rightToLeft)
    }

    @Test("The live stage keeps the newest words: blank lines collapse and wide characters count double")
    func liveWords() {
        let shown = GroveLiveWords.display(stable: WindowSampleData.longEmail, tail: " and then")
        #expect(!(shown.stable + shown.tail).contains("\n"))
        #expect(shown.tail == " and then")
        #expect(shown.stable.hasSuffix("Sam Lee"))
        let cjk = String(repeating: "明天上午十点开会，请把议程和预算表发给大家。", count: 10)
        let wide = GroveLiveWords.display(stable: cjk, tail: "谢谢。")
        #expect(wide.tail == "谢谢。")
        #expect(wide.stable.count <= GroveLiveWords.characterLimit / 2 + 1)
        #expect(GroveLiveWords.width(of: "明") == 2 && GroveLiveWords.width(of: "a") == 1)
    }

    @Test("A reader names the year of a dictation from another year")
    func otherYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 10))!
        func entry(_ components: DateComponents) -> TranscriptEntry {
            TranscriptEntry(createdAt: calendar.date(from: components)!, appBundleID: "com.apple.mail", rawText: "a", cleanText: "a",
                            durationMS: 1, audioURL: nil, insertionStatus: .inserted)
        }
        let eve = entry(DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 58))
        #expect(GroveEntryMeta.whenText(eve, showsDay: true, now: now, calendar: calendar) == "Yesterday, 23:58")
        let older = entry(DateComponents(year: 2023, month: 1, day: 1, hour: 14, minute: 0))
        let text = GroveEntryMeta.whenText(older, showsDay: true, now: now, calendar: calendar)
        #expect(text.contains("2023") && text.hasSuffix(", 14:00"))
        let sameYear = entry(DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 1))
        #expect(GroveEntryMeta.whenText(sameYear, showsDay: true, now: now, calendar: calendar) == "00:01")
    }

    @Test("An app's share is 100% only when it holds every word")
    func nearlyAll() {
        #expect(GroveAppWordRows.share(10_010_922, of: 10_044_276) == ">99%")
        #expect(GroveAppWordRows.share(5, of: 5) == "100%")
        #expect(GroveAppWordRows.share(9_850, of: 10_000) == "99%")
    }

    @Test("The window's times are 24-hour whatever the locale")
    func clock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 17, minute: 5))!
        #expect(TranscriptMargin.timeText(date, calendar: calendar) == "17:05")
        #expect(ClockTime.string(date, timeZone: calendar.timeZone) == "17:05")
    }
}

/// How it was written on the panel colour, for a render of that section alone.
private struct GroveHowItWasWrittenSample: View {
    let model: GroveHowItWasWritten.Model
    @Environment(\.groveTheme) private var theme

    var body: some View {
        GroveHowItWasWritten(model: model)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.panelColor)
    }
}
