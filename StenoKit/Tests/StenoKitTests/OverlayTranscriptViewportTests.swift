#if os(macOS)
import AppKit
import Testing
@testable import StenoKit

@Suite("Live card transcript layout")
struct OverlayTranscriptViewportTests {

    private func layout(_ text: String, stable: Int? = nil, width: CGFloat = 404, lines: Int = 4) -> OverlayTranscriptLayout {
        OverlayTranscriptLayout.make(source: text, stableCount: stable ?? text.count, width: width, maximumLines: lines) { wet in
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
            if wet { attributes[.overlayWetInk] = true }
            return attributes
        }
    }

    @Test("A short passage is shown whole, with every space and mark")
    func shortPassageShownWhole() {
        let text = " First. Second. Third.  "
        let result = layout(text)
        #expect(result.snapshot.sourceText == text)
        #expect(result.snapshot.visibleText == text)
        #expect(result.snapshot.pageRanges == [0..<text.count])
        #expect(result.visibleLineCount == 1)
        #expect(!result.hasPeekLine)
    }

    @Test("Blank lines and runs of spaces draw as one space and take no row; ranges stay exact")
    func whitespaceCollapses() {
        let text = "  \n\nHi Dana,\n\n\nThanks for the notes.   \n"
        let result = layout(text)
        #expect(result.visibleLineCount == 1, "one line of words, not five rows")
        #expect(result.snapshot.sourceText == text)
        assertExactPartition(result.snapshot)
        let drawn = result.drawnText.string.replacingOccurrences(of: "\u{200B}", with: "")
        #expect(drawn.trimmingCharacters(in: .whitespaces) == "Hi Dana, Thanks for the notes.")
    }

    @Test("Right-to-left words are set flush right; Latin, CJK and emoji keep the left edge")
    func rightToLeft() {
        #expect(layout("سأتصل بك بعد الاجتماع لنراجع العقد معًا قبل يوم الخميس").isRightToLeft)
        #expect(layout("אני אתקשר אליך אחרי הפגישה").isRightToLeft)
        #expect(!layout("Remind me to call the venue").isRightToLeft)
        #expect(!layout("明天上午十点开会").isRightToLeft)
        #expect(!layout("👩🏽‍💻 see you at 7").isRightToLeft)
    }

    @Test("The newest live words: whitespace collapses, wide characters count double, an hour reads only its end")
    func newestLiveWords() {
        let shown = LiveWordsText.newest(stable: "Hi Dana,\n\n\nThanks ", tail: "for   the notes.", limit: 120)
        #expect(shown.stable + shown.tail == "Hi Dana, Thanks for the notes.")
        let cjk = LiveWordsText.newest(stable: String(repeating: "明天上午十点开会，", count: 40), tail: "", limit: 20)
        #expect(cjk.stable.hasPrefix("…") && cjk.stable.count <= 11)
        let hour = String(repeating: "word ", count: 40_000)
        let tail = LiveWordsText.newest(stable: hour, tail: "and the newest", limit: 60)
        #expect((tail.stable + tail.tail).hasSuffix("and the newest") && tail.stable.hasPrefix("…"))
        // A cut keeps the space between the settled words and the part that may change.
        let cut = LiveWordsText.newest(stable: String(repeating: "Send the revised draft electronically. ", count: 10),
                                       tail: "The second set", limit: 60)
        #expect((cut.stable + cut.tail).hasSuffix("electronically. The second set"))
    }

    @Test("Long passages keep the newest four lines and one faded line above them")
    func newestLinesAtTheBottom() {
        let text = String(repeating: "Earlier words remain part of the source. ", count: 12) + "Newest words."
        let result = layout(text)
        #expect(result.visibleLineCount == 4)
        #expect(result.hasPeekLine)
        #expect(result.snapshot.visibleText.hasSuffix("Newest words."))
        #expect(result.drawnText.string.hasSuffix(result.snapshot.visibleText))
        assertExactPartition(result.snapshot)
    }

    @Test("Each update replaces the text; an earlier hypothesis is never stitched in")
    func revisionsReplaceWithoutStitching() {
        _ = layout(String(repeating: "Earlier sentence. ", count: 20) + "Their result is green.")
        let corrected = "The result is blue. It is not green."
        let result = layout(corrected)
        #expect(result.snapshot.visibleText == corrected)
        #expect(!result.drawnText.string.contains("Earlier"))
        #expect(result.snapshot.visibleRange.lowerBound == 0)
        let erased = layout("")
        #expect(erased.snapshot == .empty)
        #expect(erased.lines.isEmpty)
    }

    @Test("Words the model may still change carry the wet-ink attribute, settled words do not")
    func wetInkMarksOnlyTheTail() {
        let stable = "Move the planning meeting from Thursday to Friday. Send the updated agenda "
        let tail = "before lunch so every"
        let result = layout(stable + tail, stable: stable.count)
        let drawn = result.drawnText
        var wetText = ""
        drawn.enumerateAttribute(.overlayWetInk, in: NSRange(location: 0, length: drawn.length)) { value, range, _ in
            if value as? Bool == true { wetText += (drawn.string as NSString).substring(with: range) }
        }
        #expect(wetText == tail)
    }

    @Test("Line cuts never split extended graphemes or alter multilingual text", arguments: [
        "👨‍👩‍👧‍👦👩🏽‍💻🇮🇳", "e\u{301}a\u{308} ", "第一句。第二句。", "مرحبا بالعالم ", "antidisestablishmentarianism"
    ])
    func unicodeAndUnbrokenText(fragment: String) {
        let text = String(repeating: fragment, count: 60)
        let result = layout(text, width: 180)
        #expect(result.snapshot.sourceText == text)
        #expect(!result.snapshot.visibleText.isEmpty)
        #expect(!result.snapshot.visibleText.contains("\u{FFFD}"))
        #expect(result.visibleLineCount <= 4)
        assertExactPartition(result.snapshot)
    }

    @Test("A very large hypothesis typesets only its end")
    func boundedLayoutWork() {
        let source = String(repeating: "word ", count: 4_000) + "last"
        let result = layout(source)
        #expect(result.drawnText.length <= OverlayTranscriptLayout.typesetCharacterLimit)
        #expect(result.snapshot.visibleText.hasSuffix("last"))
        assertExactPartition(result.snapshot)
    }

    @Test("Trailing whitespace never becomes a blank newest line")
    func trailingWhitespaceDoesNotAddALine() {
        let text = "The exact words." + String(repeating: " ", count: 400)
        let result = layout(text, width: 180)
        #expect(result.snapshot.visibleText.hasPrefix("The exact words."))
        assertExactPartition(result.snapshot)
    }

    @Test("Native layout keeps every visible line within the measure", arguments: [240.0, 400.0, 720.0], [15.0, 26.0, 52.0])
    @MainActor
    func nativeLayout(width: Double, pointSize: Double) {
        let font = NSFont.systemFont(ofSize: pointSize)
        let fixtures = [String(repeating: "UnbrokenIdentifier", count: 40), String(repeating: "👨‍👩‍👧‍👦", count: 100),
                        String(repeating: "مرحبا بالعالم. ", count: 20), String(repeating: "第一句。第二句。\n", count: 20)]
        for source in fixtures {
            let result = OverlayTranscriptLayout.make(source: source, stableCount: source.count, width: width, maximumLines: 4) { _ in
                [.font: font]
            }
            #expect(!result.snapshot.visibleText.isEmpty)
            #expect(result.visibleLineCount <= 4)
            for line in result.lines {
                let used = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
                #expect(used <= width + 0.5)
            }
            assertExactPartition(result.snapshot)
        }
    }

    @Test("Listening grows within a fixed width and resets after every terminal outcome")
    @MainActor
    func presenterGrowthAndLifecycle() {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.appearance = .quill
        presenter.hostedEvidencePrepareOffscreen()
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        let compact = presenter.hostedEvidencePanelSize()
        let session = makeSession()
        let controlFrames = presenter.hostedEvidenceControlScreenFrames()
        var maximumHeight = compact.height
        for (index, text) in ["A short start.", "A short start. This is a longer passage that now needs additional lines to keep every recognized word readable.", "A short start. This is a longer passage that now needs additional lines to keep every recognized word readable. Another paragraph arrives and keeps growing with more words.", "Corrected."].enumerated() {
            presenter.updateLiveTranscript(makeSnapshot(session, text, revision: UInt64(index + 1)))
            presenter.hostedEvidenceFlushLiveTranscript()
            let size = presenter.hostedEvidencePanelSize()
            #expect(size.width == compact.width)
            #expect(presenter.hostedEvidenceControlScreenFrames() == controlFrames)
            #expect(size.height >= maximumHeight)
            #expect(size.height <= compact.height * 2.4)
            maximumHeight = size.height
            #expect(presenter.hostedEvidenceViewport().sourceText == text)
            assertExactPartition(presenter.hostedEvidenceViewport())
        }
        #expect(maximumHeight > compact.height)
        for terminal in [OverlayState.transcribing, .inserted, .copiedOnly, .failure(message: "Synthetic failure"), .noSpeechDetected] {
            presenter.show(state: terminal)
            #expect(presenter.hostedEvidenceViewport().sourceText.isEmpty)
            #expect(presenter.hostedEvidenceTextSurfacesAreEmpty())
        }
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        #expect(presenter.hostedEvidencePanelSize() == compact)
        presenter.hide()
        #expect(presenter.hostedEvidenceViewport().sourceText.isEmpty)
    }

    @Test("Stop fires once and blocks late cancel while the panel stays nonactivating")
    @MainActor
    func stopAndCancelRemainSeparate() {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        var stops = 0
        var cancellations = 0
        presenter.setStopAction { stops += 1 }
        presenter.setCancelAction { cancellations += 1 }
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceControlsAreNonactivating())
        #expect(presenter.hostedEvidenceStopIsAvailable())
        presenter.hostedEvidencePressStop()
        presenter.hostedEvidencePressStop()
        presenter.hostedEvidencePressCancel()
        #expect(stops == 1)
        #expect(cancellations == 0)
        presenter.show(state: .transcribing)
        #expect(!presenter.hostedEvidenceStopIsAvailable())
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        presenter.hostedEvidencePressCancel()
        presenter.hostedEvidencePressCancel()
        presenter.hostedEvidencePressStop()
        #expect(cancellations == 1)
        #expect(stops == 1)
        presenter.hide()
    }

    @Test("Dynamic blue resolves for the selected appearance even when accent arrives first")
    @MainActor
    func appearanceResolvesDynamicAccent() {
        let blue = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 134.0 / 255, green: 191.0 / 255, blue: 1, alpha: 1)
                : NSColor(srgbRed: 21.0 / 255, green: 93.0 / 255, blue: 168.0 / 255, alpha: 1)
        }
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        presenter.updateAccentColor(blue)
        presenter.updateAppearance(NSAppearance(named: .darkAqua))
        presenter.prepareWindow()
        #expect(presenter.hostedEvidenceUsesDarkAppearance())
        #expect(abs(presenter.hostedEvidenceAccentColor().redComponent - 134.0 / 255) < 0.01)
        presenter.updateAppearance(NSAppearance(named: .aqua))
        #expect(!presenter.hostedEvidenceUsesDarkAppearance())
        #expect(abs(presenter.hostedEvidenceAccentColor().redComponent - 21.0 / 255) < 0.01)
        presenter.updateAppearance(nil)
        #expect(presenter.hostedEvidenceUsesDarkAppearance() == (NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
        presenter.hide()
    }

    @Test("Trailing whitespace and blank lines never replace readable speech with a blank card")
    @MainActor
    func trailingWhitespaceDoesNotPage() {
        let text = "The exact words." + String(repeating: " \n\t", count: 80)
        let result = OverlayTranscriptLayout.make(source: text, stableCount: text.count, width: 180, maximumLines: 2) { _ in
            [.font: NSFont.systemFont(ofSize: 15)]
        }
        #expect(result.snapshot.visibleText == text)
        #expect(result.snapshot.pageRanges.count == 1)
        #expect(result.visibleLineCount == 1)
        assertExactPartition(result.snapshot)
    }

    @Test("Production overlay states render offscreen with synthetic passage sequences")
    @MainActor
    func nativeProductionRenders() throws {
        let output = ProcessInfo.processInfo.environment["STENO_OVERLAY_RENDER_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoOverlayNativeRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let first = "A quiet place for your next thought."
        let expanded = first + " The words stay readable as the sentence grows, then the next passage takes its place."
        let rollover = expanded + " " + String(repeating: "Earlier words remain part of the source. ", count: 8)
            + "The next passage is ready. Every visible character comes from the current hypothesis."
        let cases: [(String, [String], Double)] = [
            ("compact", [], 13), ("one-line", [first], 13),
            ("three-lines", [first, expanded], 13),
            ("page-turn", [first, expanded, rollover], 13),
            ("short-revision", [first, expanded, rollover, "A corrected thought."], 13),
            ("large-text", [expanded, rollover], 52)
        ]
        var receipt: [String] = ["appearance,state,width,height,page_start,source_graphemes,visible_graphemes,png_bytes"]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, texts, pointSize) in cases {
                let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
                presenter.hostedEvidencePrepareOffscreen()
                presenter.setStopAction { }
                presenter.updateAppearance(NSAppearance(named: appearance))
                let dark = appearance == .darkAqua
                presenter.updateAccentColor(dark
                    ? NSColor(srgbRed: 134.0 / 255, green: 191.0 / 255, blue: 1, alpha: 1)
                    : NSColor(srgbRed: 21.0 / 255, green: 93.0 / 255, blue: 168.0 / 255, alpha: 1))
                presenter.setHostedAccessibilityPreferences(.init(reduceMotion: true, reduceTransparency: true,
                    increaseContrast: pointSize > 13, preferredBodyPointSize: pointSize))
                let session = makeSession()
                let updates = texts.enumerated().map { makeSnapshot(session, $0.element, revision: UInt64($0.offset + 1)) }
                var size = CGSize.zero
                var viewport = OverlayTranscriptViewportSnapshot.empty
                presenter.setHostedEvidenceHandler { event in
                    if case .previewRendered = event {
                        size = presenter.hostedEvidencePanelSize()
                        viewport = presenter.hostedEvidenceViewport()
                    } else if case .listeningPresented = event {
                        size = presenter.hostedEvidencePanelSize()
                    }
                }
                let data = try #require(presenter.hostedEvidenceRenderPNG(
                    state: .listening(handsFree: false, elapsedSeconds: 12), snapshots: updates))
                let variant = dark ? "dark" : "light"
                try data.write(to: output.appendingPathComponent("production-\(variant)-\(name).png"))
                #expect(data.count > 600)
                #expect(!texts.isEmpty ? viewport.sourceText == texts.last : viewport.sourceText.isEmpty)
                assertExactPartition(viewport)
                receipt.append("\(variant),\(name),\(size.width),\(size.height),\(viewport.visibleRange.lowerBound),\(viewport.sourceText.count),\(viewport.visibleText.count),\(data.count)")
                presenter.setHostedEvidenceHandler(nil)
            }
        }
        try (receipt.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("production-render-receipt.csv"), atomically: true, encoding: .utf8)
    }

    @Test("Long terminal failures use the problem width and keep the full explanation for reading and VoiceOver")
    @MainActor
    func terminalFailurePresentation() throws {
        let message = "The document closed. Your words are ready to copy. Open a document and try again."
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.appearance = .quill
        presenter.hostedEvidencePrepareOffscreen()
        presenter.updateAppearance(NSAppearance(named: .aqua))
        presenter.show(state: .failure(message: message))
        #expect(presenter.hostedEvidenceCapsuleSize().width == 340)
        #expect(presenter.hostedEvidenceUserFacingStrings().contains(message))
        #expect(presenter.hostedEvidenceAnnouncementLog().last == message)
        #expect(presenter.hostedEvidenceTerminalPresentationIsCompact())
        let data = try #require(presenter.hostedEvidenceRenderPNG(state: .failure(message: message)))
        let output = ProcessInfo.processInfo.environment["STENO_OVERLAY_RENDER_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoOverlayNativeRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("production-light-failure.png"))
        #expect(data.count > 600)
    }

    private func assertExactPartition(_ result: OverlayTranscriptViewportSnapshot, sourceLocation: SourceLocation = #_sourceLocation) {
        let characters = Array(result.sourceText)
        let reconstructed = result.pageRanges.map { String(characters[$0]) }.joined()
        #expect(Array(reconstructed.utf8) == Array(result.sourceText.utf8), sourceLocation: sourceLocation)
        #expect(result.sourceText.hasSuffix(result.visibleText), sourceLocation: sourceLocation)
        #expect(String(characters[result.visibleRange]) == result.visibleText, sourceLocation: sourceLocation)
        #expect(result.visibleRange.upperBound == characters.count, sourceLocation: sourceLocation)
        #expect(result.pageRanges.allSatisfy { !$0.isEmpty }, sourceLocation: sourceLocation)
    }

    private func makeSession() -> LiveTranscriptionSession {
        LiveTranscriptionSession(sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1, runtimeIdentity: .pending)
    }

    private func makeSnapshot(_ session: LiveTranscriptionSession, _ text: String, revision: UInt64) -> LiveTranscriptionSnapshot {
        LiveTranscriptionSnapshot(session: session, stablePrefix: text, revisableTail: "", lastAcceptedRevision: revision, decodedAudioWatermark: revision * 1_600)
    }
}
#endif
