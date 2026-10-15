import AppKit
import Testing
@testable import Steno
@testable import StenoKit

/// Renders the earlier quill overlay, which the app no longer shows, for every state on its
/// board, offscreen, in light and dark, with Increase Contrast, Reduce Motion and larger text,
/// at 1x and 2x.
/// Output goes to `STENO_UI_RENDER_OUTPUT/overlay`: one PNG per case plus a contact sheet
/// per variant for side-by-side review against the board.
@Suite("Overlay renders for every state", .serialized)
@MainActor
struct OverlayRenderingTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let title: String
        let state: OverlayState
        var stable = ""
        var wet = ""
        var live = false
        var limitSeconds: Int?
        var previewStopped = false
        var after: [OverlayState] = []
        let capsuleWidth: CGFloat

        var testDescription: String { name }
    }

    struct Variant: Sendable, CustomTestStringConvertible {
        let name: String
        let dark: Bool
        let increaseContrast: Bool
        let reduceMotion: Bool
        let bodySize: CGFloat
        let scale: CGFloat

        var testDescription: String { name }
        var textScale: CGFloat { max(1, bodySize / 13) }
    }

    nonisolated static let longText = "The parties agree that the closing date will move from September 18 to September 25, and that the escrow instructions will be updated to reflect the new date. Please keep the exact wording of section four, and do not change the meaning of the indemnity clause. Send the revised draft to both counsel before Thursday so there is time for review, and note that the signature pages can be exchanged electronically. "

    nonisolated static let cases: [Case] = [
        Case(name: "01-holding", title: "Holding Option", state: .listening(handsFree: false, elapsedSeconds: 3), capsuleWidth: 220),
        Case(name: "02-holding-past-10s", title: "Holding past 10 s", state: .listening(handsFree: false, elapsedSeconds: 14), capsuleWidth: 220),
        Case(name: "03-hands-free", title: "Hands-free", state: .listening(handsFree: true, elapsedSeconds: 130), capsuleWidth: 300),
        Case(name: "04-last-minute", title: "Last minute", state: .listening(handsFree: true, elapsedSeconds: 3_558), limitSeconds: 3_600, capsuleWidth: 300),
        Case(name: "05-transcribing", title: "Transcribing", state: .listening(handsFree: false, elapsedSeconds: 4), after: [.transcribing], capsuleWidth: 220),
        Case(name: "06-still-finishing", title: "Still finishing", state: .busy(.stillFinishing), capsuleWidth: 300),
        Case(name: "07-hands-free-waits", title: "Hands-free waits", state: .busy(.handsFreeDeferred), capsuleWidth: 300),
        Case(name: "08-inserted-default", title: "Inserted · default", state: .result(.inserted(appName: "Mail", method: .typed), showsWords: false), capsuleWidth: 220),
        Case(name: "09-inserted-saying-where", title: "Inserted · saying where", state: .result(.inserted(appName: "Mail", method: .typed), showsWords: true), capsuleWidth: 220),
        Case(name: "10-pasted", title: "Pasted", state: .result(.inserted(appName: "Terminal", method: .pasted), showsWords: true), capsuleWidth: 220),
        Case(name: "11-copied-password", title: "Copied: password field", state: .result(.copied(.secureField), showsWords: true), capsuleWidth: 300),
        Case(name: "12-copied-app-changed", title: "Copied: app changed", state: .result(.copied(.appChanged), showsWords: true), capsuleWidth: 300),
        Case(name: "13-no-speech", title: "No speech", state: .noSpeechDetected, capsuleWidth: 220),
        Case(name: "14-discarded-undo", title: "Discarded, with Undo", state: .discarded(undoUntil: Date().addingTimeInterval(60)), capsuleWidth: 300),
        Case(name: "15-couldnt-insert", title: "Couldn’t insert", state: .result(.failed(savedInHistory: true), showsWords: true), capsuleWidth: 340),
        Case(name: "16-not-pasted", title: "Not pasted", state: .result(.notPasted, showsWords: true), capsuleWidth: 340),
        Case(name: "17-microphone-off", title: "Microphone off", state: .result(.microphoneAccessOff, showsWords: true), capsuleWidth: 340),
        Case(name: "18-microphone-disconnected", title: "Microphone disconnected", state: .result(.microphoneDisconnected(insertedPartial: true), showsWords: true), capsuleWidth: 340),
        Case(name: "19-couldnt-transcribe", title: "Couldn’t transcribe", state: .result(.transcriptionFailed, showsWords: true), capsuleWidth: 340),
        Case(name: "20-not-ready", title: "Not ready", state: .busy(.modelLoading), capsuleWidth: 300),
        Case(name: "21-legacy-failure", title: "1.0 failure message", state: .failure(message: "The document closed. Your words are ready to copy."), capsuleWidth: 340),
        Case(name: "22-live-waiting", title: "Live words: waiting", state: .listening(handsFree: true, elapsedSeconds: 9), live: true, capsuleWidth: 300),
        Case(name: "23-live-wet-dry", title: "Live words: wet and dry ink", state: .listening(handsFree: true, elapsedSeconds: 9),
             stable: "Move the planning meeting from Thursday to Friday. Send the updated agenda ", wet: "before lunch so every",
             live: true, capsuleWidth: 300),
        Case(name: "24-live-long", title: "Live words: long dictation", state: .listening(handsFree: true, elapsedSeconds: 271),
             stable: longText, wet: "The second set of originals will follow", live: true, capsuleWidth: 300),
        Case(name: "25-live-preview-stopped", title: "Preview stopped", state: .listening(handsFree: true, elapsedSeconds: 72),
             live: true, previewStopped: true, capsuleWidth: 300),
    ]

    nonisolated static let variants: [Variant] = [
        Variant(name: "light-2x", dark: false, increaseContrast: false, reduceMotion: false, bodySize: 13, scale: 2),
        Variant(name: "dark-2x", dark: true, increaseContrast: false, reduceMotion: false, bodySize: 13, scale: 2),
        Variant(name: "light-1x", dark: false, increaseContrast: false, reduceMotion: false, bodySize: 13, scale: 1),
        Variant(name: "dark-1x", dark: true, increaseContrast: false, reduceMotion: false, bodySize: 13, scale: 1),
        Variant(name: "light-increase-contrast-2x", dark: false, increaseContrast: true, reduceMotion: false, bodySize: 13, scale: 2),
        Variant(name: "dark-increase-contrast-2x", dark: true, increaseContrast: true, reduceMotion: false, bodySize: 13, scale: 2),
        Variant(name: "light-reduce-motion-2x", dark: false, increaseContrast: false, reduceMotion: true, bodySize: 13, scale: 2),
        Variant(name: "light-larger-text-2x", dark: false, increaseContrast: false, reduceMotion: false, bodySize: 17, scale: 2),
    ]

    private var outputDirectory: URL {
        get throws {
            let root = ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering", isDirectory: true)
            let directory = root.appendingPathComponent("overlay", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    @Test("Every overlay state renders at its board width", arguments: variants)
    func renderEveryState(variant: Variant) throws {
        let directory = try outputDirectory.appendingPathComponent(variant.name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sheetRows: [(String, Data)] = []
        for item in Self.cases {
            let presenter = makePresenter(variant: variant, live: item.live)
            let data = try #require(render(item, with: presenter, variant: variant))
            let capsule = presenter.hostedEvidenceCapsuleSize()
            let expectedWidth = (item.capsuleWidth * (1 + 0.8 * (variant.textScale - 1))).rounded()
            #expect(capsule.width == expectedWidth, "\(variant.name)/\(item.name)")
            #expect(data.count > 2_000, "\(variant.name)/\(item.name)")
            try data.write(to: directory.appendingPathComponent(item.name + ".png"))
            sheetRows.append((item.title, data))
        }
        let sheet = try #require(contactSheet(rows: sheetRows, dark: variant.dark, scale: variant.scale))
        try sheet.write(to: outputDirectory.appendingPathComponent("sheet-\(variant.name).png"))
    }

    @Test("The quill shows the input level: still in silence, longer barbs at speech level")
    func levelRenders() throws {
        let variant = Self.variants[0]
        for level: Float in [0, 0.5, 1] {
            let presenter = makePresenter(variant: variant, live: false)
            presenter.setStopAction {}
            let data = try #require(presenter.hostedEvidenceRenderPNG(
                state: .listening(handsFree: true, elapsedSeconds: 130), level: level,
                backdrop: backdrop(dark: false), scale: 4))
            try data.write(to: outputDirectory.appendingPathComponent("level-\(Int(level * 100)).png"))
        }
    }

    // MARK: - Helpers

    private func makePresenter(variant: Variant, live: Bool) -> WaveformOverlayPresenter {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.appearance = .quill
        presenter.hostedEvidencePrepareOffscreen()
        presenter.updateAppearance(NSAppearance(named: variant.dark ? .darkAqua : .aqua))
        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: variant.reduceMotion, reduceTransparency: false,
            increaseContrast: variant.increaseContrast, preferredBodyPointSize: variant.bodySize
        ))
        presenter.setLiveTranscriptEnabled(live)
        presenter.setStopAction {}
        presenter.onCopyResult = {}
        presenter.onUndoDiscard = {}
        presenter.onOpenSettings = { _ in }
        return presenter
    }

    private func render(_ item: Case, with presenter: WaveformOverlayPresenter, variant: Variant) -> Data? {
        presenter.show(state: item.state)
        if let limit = item.limitSeconds { presenter.showRecordingLimitWarning(limitSeconds: limit) }
        if !item.stable.isEmpty || !item.wet.isEmpty {
            let session = LiveTranscriptionSession(sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1, runtimeIdentity: .pending)
            presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
                session: session, stablePrefix: item.stable, revisableTail: item.wet,
                lastAcceptedRevision: 1, decodedAudioWatermark: 1_600))
            presenter.hostedEvidenceFlushLiveTranscript()
        }
        if item.previewStopped { presenter.showLiveTranscriptUnavailable() }
        for next in item.after { presenter.show(state: next) }
        if case .listening = item.state, item.after.isEmpty { presenter.updateInputLevel(0.55) }
        defer { presenter.hide() }
        return presenter.hostedEvidenceRenderCurrentPNG(backdrop: backdrop(dark: variant.dark), scale: variant.scale)
    }

    /// The board's page colour behind the light renders; a dark app window behind the dark ones.
    private func backdrop(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0x15 / 255.0, green: 0x17 / 255.0, blue: 0x1D / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xE4 / 255.0, green: 0xE9 / 255.0, blue: 0xF1 / 255.0, alpha: 1)
    }

    /// Stacks renders with their board titles, for one-glance review.
    private func contactSheet(rows: [(String, Data)], dark: Bool, scale: CGFloat) -> Data? {
        let images = rows.compactMap { title, data in NSBitmapImageRep(data: data).map { (title, $0) } }
        let captionHeight = 22 * scale
        let width = images.map { $0.1.pixelsWide }.max() ?? 0
        let height = images.reduce(0) { $0 + $1.1.pixelsHigh + Int(captionHeight) }
        guard width > 0, let sheet = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        backdrop(dark: dark).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var top = CGFloat(height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * scale, weight: .semibold),
            .foregroundColor: dark ? NSColor.white : NSColor(srgbRed: 0.055, green: 0.078, blue: 0.2, alpha: 1),
        ]
        for (title, image) in images {
            top -= captionHeight
            (title as NSString).draw(at: NSPoint(x: 12 * scale, y: top + 4 * scale), withAttributes: attributes)
            top -= CGFloat(image.pixelsHigh)
            image.draw(in: NSRect(x: 0, y: top, width: CGFloat(image.pixelsWide), height: CGFloat(image.pixelsHigh)))
        }
        NSGraphicsContext.restoreGraphicsState()
        return sheet.representation(using: .png, properties: [:])
    }
}
