import AppKit
@testable import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Worst-case content for the surfaces that changed after the first two worst-case passes:
/// Insights' full-width calendar, Fix a Word in its real popover, and the island's states. Green
/// only. Fix a Word runs in a real window (`TransitionHost`), driven through its own controls.
/// Output goes to `STENO_UI_RENDER_OUTPUT/break-ui/<surface>`. Everything here is synthetic.
@Suite("Grove worst-case renders: calendar, Fix a Word and island", .serialized)
@MainActor
struct GroveBreakUIFollowUpRenderingTests {
    typealias Harness = GroveRenderHarness

    static let longApp = GroveBreakUIRenderingTests.longApp

    private static func save(_ bitmap: NSBitmapImageRep?, surface: String, name: String,
                             sourceLocation: SourceLocation = #_sourceLocation) throws {
        let image = try #require(bitmap, "\(surface)/\(name): nothing drawn", sourceLocation: sourceLocation)
        let data = try #require(image.representation(using: .png, properties: [:]), sourceLocation: sourceLocation)
        try data.write(to: GroveBreakUIRenderingTests.directory(surface).appendingPathComponent(name + ".png"))
        #expect(data.count > 5_000, "\(surface)/\(name)", sourceLocation: sourceLocation)
    }

    // MARK: Dictation text

    /// A 31-word note, the length most dictations have.
    static let typical = "Can you move the design review to Thursday at two and ask Priya to bring the updated mockups? "
        + "I also need the budget sheet before the meeting starts, please."

    /// 1,284 words, far past the 12 lines a long dictation shows before Show All.
    static let thousands: String = {
        let sentence = "The quarterly review covers revenue, hiring, the office move and the launch plan in detail."
        var text = Array(repeating: sentence, count: 85).joined(separator: " ")
        while WordCount.count(text) < 1_284 { text += " more" }
        return text
    }()

    private func textHost(_ surface: String, text: String, knobs: TransitionKnobs) -> TransitionHost {
        let entry = TransitionFixtures.entry(text)
        let controller = TransitionFixtures.sampleController([entry, TransitionFixtures.entry(WindowSampleData.groceries, minutesAgo: 4)])
        return TransitionHost(size: Harness.minimumSize, controller: controller, knobs: knobs) {
            if surface == "today" {
                Harness.window(.today, controller: controller) { GroveTodayView() }
            } else {
                Harness.window(.history, controller: controller) { GroveHistoryView(initialSelectedEntryID: entry.id) }
            }
        }
    }

    @Test("A typical and a 1,284-word dictation at the minimum window, at the default and a larger text size",
          arguments: ["today", "history"])
    func dictationText(surface: String) async throws {
        for textSize in [DynamicTypeSize.large, .accessibility3] {
            let size = textSize == .large ? "minimum" : "minimum-accessibility"
            for (name, text) in [("typical", Self.typical), ("thousands", Self.thousands)] {
                let knobs = TransitionKnobs()
                knobs.textSize = textSize
                let host = textHost(surface, text: text, knobs: knobs)
                defer { host.close() }
                #expect(await host.settle { !host.transcriptViews().isEmpty }, "\(surface)/\(name): no words")
                try Self.save(host.bitmap(), surface: "dictation-text", name: "\(surface)-\(name)-\(size)")
            }
        }
    }

    // MARK: Insights calendar

    /// The day in the calendar whose name is longest, as the chosen-day line and Busiest day write it.
    static func longestNamedDay(daysAgo range: ClosedRange<Int>, now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return range.max { a, b in
            func length(_ offset: Int) -> Int {
                let date = calendar.date(byAdding: .day, value: -offset, to: today)!
                return date.formatted(.dateTime.weekday(.wide).month(.wide).day()).count
            }
            return length(a) < length(b)
        }!
    }

    @Test("The calendar at every window size and larger text: a long chosen day, huge, one and zero counts, a partial first month")
    func calendar() async throws {
        let longDay = Self.longestNamedDay(daysAgo: 1...170)
        let calendar = Calendar.current
        let chosen = calendar.date(byAdding: .day, value: -longDay, to: calendar.startOfDay(for: Date()))!
        var normal = Dictionary(uniqueKeysWithValues: (0..<180).compactMap { day in day % 3 == 0 ? (day, 300 + day * 7) : nil })
        normal[longDay] = 9_999_999
        let snapshots: [(String, UsageAnalyticsSnapshot, Date?)] = [
            ("long-day-huge-count", WindowSampleData.usageSnapshot(dailyWords: normal), chosen),
            ("one-word-chosen", WindowSampleData.usageSnapshot(dailyWords: [longDay: 1]), chosen),
            ("all-zero-chosen", WindowSampleData.usageSnapshot(dailyWords: [:]), chosen),
        ]
        let sizes: [(String, CGSize, DynamicTypeSize)] = [
            ("minimum", Harness.minimumSize, .large), ("default", Harness.windowSize, .large),
            ("large", GroveBreakUIRenderingTests.largeSize, .large), ("minimum-xxlarge", Harness.minimumSize, .xxLarge),
            ("minimum-accessibility", Harness.minimumSize, .accessibility3), ("default-xxxlarge", Harness.windowSize, .xxxLarge),
        ]
        for (name, snapshot, day) in snapshots {
            for (label, size, textSize) in sizes where name == "long-day-huge-count" || label == "minimum" || label == "minimum-xxlarge" {
                for variant in [Harness.Variant.light, .dark] where variant == .light || label == "default" {
                    let controller = Harness.sampleController(variant)
                    controller.usageAnalyticsSnapshot = snapshot
                    let data = try await Harness.render(ContentView(initialTab: .insights, initialState: .init(insightsDay: day)),
                                                        controller: controller, variant: variant, size: size, textSize: textSize)
                    try data.write(to: GroveBreakUIRenderingTests.directory("insights-calendar")
                        .appendingPathComponent("\(name)-\(label)-\(variant.rawValue).png"))
                    await controller.teardownAndWait()
                }
            }
        }
        // The first week of the calendar holds only the last days of a month, for each such start.
        for back in 0..<35 {
            let now = calendar.date(byAdding: .day, value: -back, to: Date())!
            let start = calendar.date(byAdding: .day, value: -7 * 26, to: calendar.startOfDay(for: now))!
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: start)!.start
            let daysLeft = calendar.range(of: .day, in: .month, for: weekStart)!.count - calendar.component(.day, from: weekStart)
            guard (0...6).contains(daysLeft) || calendar.component(.day, from: start) > 24 else { continue }
            let controller = Harness.sampleController(.light)
            controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot(dailyWords: normal, now: now)
            for (label, size) in [("minimum", Harness.minimumSize), ("large", GroveBreakUIRenderingTests.largeSize)] {
                let data = try await Harness.render(ContentView(initialTab: .insights), controller: controller, variant: .light, size: size)
                try data.write(to: GroveBreakUIRenderingTests.directory("insights-calendar")
                    .appendingPathComponent("partial-month-\(back)-days-back-\(label)-light.png"))
            }
            await controller.teardownAndWait()
        }
    }

    // MARK: Fix a Word, in its popover

    struct FixCase {
        let name: String
        let text: String
        let word: String
        let correction: String
        var scope: FixWordState.Scope = .thisDictation
    }

    static let fixCases: [FixCase] = [
        FixCase(name: "long-correction", text: WindowSampleData.contract, word: "escrow",
                correction: "Northwind Industries Holdings International escrow and settlement services", scope: .future),
        FixCase(name: "long-word", text: "Please forward the onboarding notes to Exampletta Sampleberg-Testerton before Thursday's kickoff.",
                word: "Sampleberg-Testerton", correction: "Sampleberg-Testerton-Mockowicz-Fixtureton", scope: .future),
        FixCase(name: "unbreakable", text: "Open " + WindowSampleData.unbreakableToken + " before the call.",
                word: "before", correction: "northwindindustriesholdingsinternationalgroupdesktopclientsettings", scope: .future),
        FixCase(name: "right-to-left", text: "سأتصل بك بعد الاجتماع لنراجع العقد معًا قبل يوم الخميس", word: "الاجتماع",
                correction: "الاجتماع الأسبوعي مع فريق المبيعات", scope: .future),
        FixCase(name: "cjk", text: "明天上午十点开会，请把议程和预算表发给大家。", word: "议程", correction: "会议议程和预算表", scope: .future),
    ]

    private func fixHost(_ surface: String, entry: TranscriptEntry, knobs: TransitionKnobs) -> TransitionHost {
        let controller = TransitionFixtures.sampleController([entry, TransitionFixtures.entry(WindowSampleData.groceries, minutesAgo: 4)])
        return TransitionHost(size: Harness.minimumSize, controller: controller, knobs: knobs) {
            if surface == "today" {
                Harness.window(.today, controller: controller) { GroveTodayView() }
            } else {
                Harness.window(.history, controller: controller) { GroveHistoryView(initialSelectedEntryID: entry.id) }
            }
        }
    }

    /// The popover's whole window, frame and all, as drawn now.
    private func popoverBitmap(_ host: TransitionHost) -> NSBitmapImageRep? {
        guard let window = host.popoverWindows.last, let content = window.contentView else { return nil }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    @Test("Fix a Word's real popover with long corrections, long and unbreakable words, right to left, CJK and larger text",
          arguments: ["today", "history"])
    func fixAWord(surface: String) async throws {
        let looks: [(String, DynamicTypeSize, ColorScheme)] = [("light", .large, .light), ("dark", .large, .dark),
                                                                 ("xxlarge", .xxLarge, .light), ("accessibility", .accessibility3, .light)]
        for item in Self.fixCases {
            for (look, textSize, scheme) in looks where item.name == "long-correction" || look == "light" || look == "xxlarge" {
                let knobs = TransitionKnobs()
                knobs.textSize = textSize
                knobs.scheme = scheme
                let host = fixHost(surface, entry: TransitionFixtures.entry(item.text), knobs: knobs)
                defer { host.close() }
                let label = "\(surface)/\(item.name)/\(look)"
                #expect(await host.settle { host.transcriptViews().first != nil }, "\(label): no text")
                try await host.press("Fix a Word")
                let view = try #require(host.transcriptViews().first)
                #expect(await host.settle { (view.delegate as? TranscriptTextView.Coordinator)?.picksWord == true }, "\(label)")
                let range = ((view.textStorage?.string ?? "") as NSString).range(of: item.word)
                try #require(range.location != NSNotFound, "\(label): no \(item.word)")
                view.setSelectedRange(range)
                let field = { host.views(NSTextField.self).first { $0.placeholderString == "Correct spelling" && $0.window != nil } }
                #expect(await host.settle { field() != nil }, "\(label): no form")
                let editor = try #require(host.popoverWindows.compactMap { $0.firstResponder as? NSTextView }.first, "\(label): field not focused")
                editor.selectAll(nil)
                editor.insertText(item.correction, replacementRange: editor.selectedRange())
                await host.settle()
                if item.scope == .future {
                    let radio = try #require(host.node(named: "This and future dictations"), "\(label): no scope choice")
                    radio.press()
                    await host.settle()
                }
                let popover = try #require(host.popoverWindows.last, "\(label): no popover window")
                // Every control of the form is inside the popover.
                for name in ["Correct spelling", "Just this dictation", "This and future dictations", "Cancel", "Fix"] {
                    let inPopover = host.nodes().filter { popover.frame.intersects($0.screenFrame) }
                    let node = try #require(inPopover.first { $0.name == name || $0.text == name },
                                            "\(label): no \(name) in \(inPopover.map { "\($0.role) \($0.name)|\($0.text)" })")
                    #expect(popover.frame.insetBy(dx: -0.5, dy: -0.5).contains(node.screenFrame),
                            "\(label): \(name) at \(node.screenFrame) outside \(popover.frame)")
                }
                try Self.save(popoverBitmap(host), surface: "fix-a-word", name: "\(surface)-\(item.name)-popover-\(look)")
                try Self.save(host.bitmap(), surface: "fix-a-word", name: "\(surface)-\(item.name)-window-\(look)")
                // The fix and its note under the words.
                await host.keyPress(36, characters: "\r")
                #expect(await host.settle { host.node(named: "Copy Corrected Text") != nil }, "\(label): the fix was not made")
                try Self.save(host.bitmap(), surface: "fix-a-word", name: "\(surface)-\(item.name)-result-\(look)")
            }
        }
    }

    @Test("The Fix a Word form at larger text, drawn in place (a real popover takes the system's text size)")
    func fixAWordLargerText() async throws {
        for item in Self.fixCases where ["long-correction", "right-to-left", "long-word"].contains(item.name) {
            for textSize in [DynamicTypeSize.xxLarge, .accessibility3] {
                let entry = TransitionFixtures.entry(item.text)
                let controller = TransitionFixtures.sampleController([entry])
                var start = ContentView.InitialState(historyEntryID: entry.id)
                let range = (item.text as NSString).range(of: item.word)
                start.fix = FixWordState(entryID: entry.id, range: range, word: item.word, replacement: item.correction, scope: item.scope)
                let data = try await Harness.render(ContentView(initialTab: .history, initialState: start), controller: controller,
                                                    variant: .light, size: Harness.minimumSize, textSize: textSize)
                try data.write(to: GroveBreakUIRenderingTests.directory("fix-a-word")
                    .appendingPathComponent("inline-\(item.name)-\(textSize == .xxLarge ? "xxlarge" : "accessibility").png"))
                await controller.teardownAndWait()
            }
        }
    }

    // MARK: Island

    static let islandCases: [GroveBreakUIRenderingTests.IslandCase] = {
        typealias Case = GroveBreakUIRenderingTests.IslandCase
        let hour = OverlayState.listening(handsFree: true, elapsedSeconds: 3_599)
        return [
            Case(name: "listening-last-second", state: hour),
            Case(name: "transcribing-after-an-hour", state: hour, after: .transcribing),
            Case(name: "inserted-long-app-typed", state: hour, after: .result(.inserted(appName: longApp, method: .typed), showsWords: false)),
            Case(name: "inserted-long-app-card", state: hour, after: .result(.inserted(appName: longApp, method: .accessibility), showsWords: true),
                 words: WindowSampleData.longEmail),
            Case(name: "copied-app-changed", state: hour, after: .result(.copied(.appChanged), showsWords: true), words: WindowSampleData.unbreakableToken),
            Case(name: "copied-secure-field", state: hour, after: .result(.copied(.secureField), showsWords: true), words: "سأتصل بك بعد الاجتماع"),
            Case(name: "not-pasted", state: hour, after: .result(.notPasted, showsWords: true), words: WindowSampleData.zwjEmoji),
            Case(name: "couldnt-insert", state: hour, after: .result(.failed(savedInHistory: true), showsWords: true), words: WindowSampleData.longEmail),
            Case(name: "microphone-disconnected", state: hour, after: .result(.microphoneDisconnected(insertedPartial: true), showsWords: true)),
            Case(name: "microphone-off", state: .listening(handsFree: false, elapsedSeconds: 0), after: .result(.microphoneAccessOff, showsWords: true)),
            Case(name: "shortcuts-unavailable", state: .listening(handsFree: false, elapsedSeconds: 0), after: .result(.shortcutsUnavailable, showsWords: true)),
            Case(name: "speech-model-missing", state: .listening(handsFree: false, elapsedSeconds: 0), after: .result(.speechModelMissing, showsWords: true)),
            Case(name: "couldnt-transcribe", state: hour, after: .result(.transcriptionFailed, showsWords: true)),
            Case(name: "failure-message", state: hour, after: .failure(message: "The audio device “Shure MV7+ Podcast Microphone (USB Audio Device)” stopped responding.")),
            Case(name: "microphone-stopped-no-speech", state: hour, after: .failure(message: DictationController.microphoneStoppedWithoutSpeech)),
            Case(name: "discarded-undo", state: hour, after: .discarded(undoUntil: Date().addingTimeInterval(60))),
            Case(name: "still-finishing", state: hour, after: .busy(.stillFinishing)),
            Case(name: "not-ready", state: .listening(handsFree: false, elapsedSeconds: 0), after: .busy(.modelLoading)),
        ]
    }()

    @Test("The glass island's states with an hour on the clock, long apps and words, at both text sizes, inside the screen")
    func island() throws {
        let looks: [(String, Bool, Bool, CGFloat, OverlayDisplayDescriptor, Bool)] = [
            ("notch-light", false, false, 13, GroveOverlayRenderingTests.display, true),
            ("capsule-dark", true, false, 13, GroveOverlayRenderingTests.display, false),
            ("capsule-contrast", false, true, 13, GroveOverlayRenderingTests.display, false),
            ("capsule-large-text-small", false, false, 20, GroveBreakUIRenderingTests.smallDisplay, false),
            ("notch-large-text", true, false, 20, GroveOverlayRenderingTests.display, true),
        ]
        for (look, dark, contrast, bodySize, display, notch) in looks {
            for item in Self.islandCases {
                let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
                presenter.hostedEvidencePrepareOffscreen()
                presenter.hostedEvidenceSetPlacement(notch ? .notch(display: display, notch: display.notch!) : .capsule(display: display))
                presenter.appearance = .grove
                presenter.updateAppearance(NSAppearance(named: dark ? .darkAqua : .aqua))
                presenter.setHostedAccessibilityPreferences(.init(reduceMotion: true, reduceTransparency: false,
                                                                  increaseContrast: contrast, preferredBodyPointSize: bodySize))
                presenter.setLiveTranscriptEnabled(false)
                presenter.setStopAction {}
                presenter.onCopyResult = {}
                presenter.onUndoDiscard = {}
                presenter.onOpenSettings = { _ in }
                presenter.show(state: item.state, insertedWords: nil)
                if let after = item.after { presenter.show(state: after, insertedWords: item.words) }
                let label = "\(item.name)/\(look)"
                let layout = presenter.hostedEvidenceGroveLayout()
                let island = try #require(presenter.hostedEvidenceCapsuleFrame(), "\(label)")
                #expect(island.minX >= 0 && island.maxX <= layout.panelSize.width, "\(label): \(island) in \(layout.panelSize)")
                #expect(display.frame.contains(layout.panelFrame), "\(label): \(layout.panelFrame)")
                let backdrop = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1)
                let data = try #require(presenter.hostedEvidenceRenderCurrentPNG(backdrop: backdrop, scale: 2))
                try data.write(to: GroveBreakUIRenderingTests.directory("island-states").appendingPathComponent("\(item.name)-\(look).png"))
                presenter.hide()
            }
        }
    }
}
