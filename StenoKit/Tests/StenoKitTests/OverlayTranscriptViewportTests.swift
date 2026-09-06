#if os(macOS)
import AppKit
import Testing
@testable import StenoKit

@Suite("Exact overlay transcript viewport")
struct OverlayTranscriptViewportTests {
    @Test("Short passages retain every sentence, space, and punctuation until capacity is full")
    func fillsCapacityBeforeTurningThePage() {
        let text = " First. Second. Third.  \n"
        var viewport = OverlayTranscriptViewport()
        let result = viewport.update(text) { $0.count <= 40 }
        #expect(result.sourceText == text)
        #expect(result.visibleText == text)
        #expect(result.pageRanges == [0..<text.count])
    }

    @Test("Incremental additions preserve the page origin until its capacity is full")
    func stableOriginAcrossAppends() {
        var viewport = OverlayTranscriptViewport()
        let text = "One complete sentence. Then another sentence with a longer final portion."
        var prefix = ""
        var previous = viewport.snapshot
        for character in text {
            prefix.append(character)
            let result = viewport.update(prefix) { $0.count <= 28 }
            if (previous.visibleText + String(character)).count <= 28 {
                #expect(result.visibleRange.lowerBound == previous.visibleRange.lowerBound)
            }
            #expect(result.visibleText.count <= 28)
            assertExactPartition(result)
            previous = result
        }
    }

    @Test("Revisions before the old page boundary invalidate all stale ranges")
    func backtracksAndEarlierCorrections() {
        var viewport = OverlayTranscriptViewport()
        _ = viewport.update(String(repeating: "Earlier sentence. ", count: 7) + "Their result is green.") { $0.count <= 36 }
        let corrected = "The result is blue. It is not green."
        let result = viewport.update(corrected) { $0.count <= 36 }
        #expect(result.visibleText == corrected)
        #expect(!result.sourceText.contains("Earlier"))
        #expect(result.visibleRange.lowerBound == 0)
        assertExactPartition(result)
        let erased = viewport.update("") { $0.count <= 36 }
        #expect(erased.visibleText.isEmpty)
        #expect(erased.pageRanges.isEmpty)
    }

    @Test("A rewrite within the current page replaces spelling without stitching old words")
    func revisesCurrentPageInPlace() {
        var viewport = OverlayTranscriptViewport()
        let first = viewport.update("The first sentence. Their word is green") { $0.count <= 24 }
        let corrected = viewport.update("The first sentence. Their word is blue") { $0.count <= 24 }
        #expect(corrected.visibleRange.lowerBound == first.visibleRange.lowerBound)
        #expect(corrected.visibleText == "Their word is blue")
        assertExactPartition(corrected)
    }

    @Test("A replaced rolling window and new session cannot reuse an old page origin")
    func continuityEpochAndReset() {
        var viewport = OverlayTranscriptViewport()
        _ = viewport.update("An earlier sentence. A current passage.", continuityEpoch: 1) { $0.count <= 23 }
        let replacement = viewport.update("An earlier sentence. A current passage.", continuityEpoch: 2) { $0.count <= 80 }
        #expect(replacement.visibleRange.lowerBound == 0)
        viewport.reset()
        #expect(viewport.snapshot.sourceText.isEmpty)
        let fresh = viewport.update("New session.") { $0.count <= 23 }
        #expect(fresh.visibleText == "New session.")
        #expect(fresh.pageRanges == [0..<12])
    }

    @Test("Large initial hypotheses and coalesced bursts retain all source ranges without a reading backlog")
    func burstDeliveryRetainsAnExactCurrentSuffix() {
        var viewport = OverlayTranscriptViewport()
        let initial = String(repeating: "Complete phrase. ", count: 50) + "Newest words."
        let result = viewport.update(initial) { $0.count <= 50 }
        #expect(result.pageRanges.count > 1)
        #expect(result.visibleText.hasSuffix("Newest words."))
        #expect(result.sourceText == initial)
        assertExactPartition(result)
        let burst = initial + String(repeating: " More speech arrives.", count: 100)
        let next = viewport.update(burst) { $0.count <= 50 }
        #expect(next.sourceText == burst)
        #expect(next.visibleText.hasSuffix("More speech arrives."))
        assertExactPartition(next)
    }

    @Test("Page boundaries never split extended graphemes or alter multilingual source text", arguments: [
        "👨‍👩‍👧‍👦👩🏽‍💻🇮🇳", "e\u{301}a\u{308}", "第一句。第二句。", "مرحبا بالعالم ", "antidisestablishmentarianism"
    ])
    func unicodeAndUnbrokenText(fragment: String) {
        let text = String(repeating: fragment, count: 60)
        var viewport = OverlayTranscriptViewport()
        let result = viewport.update(text) { $0.count <= 17 }
        #expect(result.visibleText.count <= 17)
        #expect(result.sourceText == text)
        #expect(!result.visibleText.contains("�"))
        assertExactPartition(result)
    }

    @Test("Backtracking exactly to a page origin returns to content rather than an empty page")
    func exactBoundaryBacktrack() {
        var viewport = OverlayTranscriptViewport()
        let result = viewport.update("abcdefghijklmno") { $0.count <= 5 }
        let backtrack = String(result.sourceText.prefix(result.visibleRange.lowerBound))
        let revised = viewport.update(backtrack) { $0.count <= 5 }
        #expect(!revised.visibleText.isEmpty)
        #expect(revised.visibleText == "fghij")
        assertExactPartition(revised)
    }

    @Test("Maximum payload paging never repeatedly measures an entire remaining hypothesis")
    func boundedLayoutWorkForLargeInitialSnapshot() {
        let source = String(repeating: "x", count: 16_384)
        var viewport = OverlayTranscriptViewport()
        var largestMeasurement = 0
        let result = viewport.update(source) {
            largestMeasurement = max(largestMeasurement, $0.count)
            return $0.count <= 144
        }
        #expect(largestMeasurement <= 1_024)
        #expect(result.visibleText.count <= 144)
        assertExactPartition(result)
    }

    @Test("Native layout fits long tokens, RTL, emoji, paragraphs, and large preferred text", arguments: [240.0, 400.0, 720.0], [15.0, 26.0, 52.0])
    @MainActor
    func nativeLayout(width: Double, pointSize: Double) {
        let size = CGSize(width: width, height: pointSize * 5.6 + 2)
        let font = NSFont.systemFont(ofSize: pointSize)
        let fixtures = [String(repeating: "UnbrokenIdentifier", count: 40), String(repeating: "👨‍👩‍👧‍👦", count: 100),
                        String(repeating: "مرحبا بالعالم. ", count: 20), String(repeating: "第一句。第二句。\n", count: 20)]
        for source in fixtures {
            var viewport = OverlayTranscriptViewport()
            let result = viewport.update(source) {
                OverlayTranscriptTypesetter.fits(OverlayTranscriptTypesetter.attributed($0, font: font, color: .black), in: size)
            }
            #expect(!result.visibleText.isEmpty)
            #expect(OverlayTranscriptTypesetter.fits(OverlayTranscriptTypesetter.attributed(result.visibleText, font: font, color: .black), in: size))
            assertExactPartition(result)
        }
    }

    @Test("Listening grows within a fixed width and resets after every terminal outcome")
    @MainActor
    func presenterGrowthAndLifecycle() {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
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

    @Test("Trailing whitespace never replaces readable speech with a blank page")
    @MainActor
    func trailingWhitespaceDoesNotPage() {
        let font = NSFont.systemFont(ofSize: 15)
        let size = CGSize(width: 180, height: 42)
        var viewport = OverlayTranscriptViewport()
        let text = "The exact words." + String(repeating: " \n\t", count: 80)
        let result = viewport.update(text) {
            OverlayTranscriptTypesetter.fits(OverlayTranscriptTypesetter.attributed($0, font: font, color: .black), in: size)
        }
        #expect(result.visibleText == text)
        #expect(result.pageRanges.count == 1)
        assertExactPartition(result)
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
                var viewport = OverlayTranscriptViewport().snapshot
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

    @Test("Long terminal failures wrap in a wider panel with the full explanation preserved")
    @MainActor
    func terminalFailurePresentation() throws {
        let message = "The document closed. Your words are ready to copy. Open a document and try again."
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        presenter.updateAppearance(NSAppearance(named: .aqua))
        presenter.show(state: .failure(message: message))
        #expect(presenter.hostedEvidencePanelSize().width >= 440)
        #expect(presenter.hostedEvidenceUserFacingStrings().contains("Error: " + message))
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
