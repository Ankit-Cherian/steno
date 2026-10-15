import AppKit
import Testing
@testable import Steno
@testable import StenoKit

/// Renders the Grove overlay for every state, in both forms (the notch and the capsule), in
/// light and dark, with Increase Contrast and with Reduce Transparency. Output goes to
/// `STENO_UI_RENDER_OUTPUT/overlay-grove`: one PNG per state plus a contact sheet per variant.
///
/// The island is always dark, so light and dark render the same; only the stand-in desktop
/// behind it differs. The renders are drawn offscreen with the quill and the bars as still frames.
@Suite("Grove overlay renders for every state", .serialized)
@MainActor
struct GroveOverlayRenderingTests {
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
        var glyph: GroveGlyph?
        var tone = GroveTone.forest
        /// The first line of the inserted words offered with a result, as the controller offers it.
        var words: String?
        /// The island is the two-line card.
        var card = false

        var testDescription: String { name }
    }

    struct Variant: Sendable, CustomTestStringConvertible {
        let name: String
        let dark: Bool
        let increaseContrast: Bool
        let reduceTransparency: Bool

        var testDescription: String { name }
    }

    struct Form: Sendable, CustomTestStringConvertible {
        let name: String
        let notch: Bool

        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        Case(name: "01-holding", title: "Holding Option", state: .listening(handsFree: false, elapsedSeconds: 3)),
        Case(name: "02-holding-past-10s", title: "Holding past 10 s", state: .listening(handsFree: false, elapsedSeconds: 14)),
        Case(name: "03-hands-free", title: "Hands-free", state: .listening(handsFree: true, elapsedSeconds: 130)),
        Case(name: "04-last-minute", title: "Last minute", state: .listening(handsFree: true, elapsedSeconds: 3_558), limitSeconds: 3_600),
        Case(name: "05-transcribing", title: "Transcribing", state: .listening(handsFree: false, elapsedSeconds: 4), after: [.transcribing]),
        Case(name: "06-still-finishing", title: "Still finishing", state: .busy(.stillFinishing), tone: .graphite),
        Case(name: "07-hands-free-waits", title: "Hands-free waits", state: .busy(.handsFreeDeferred), tone: .graphite),
        Case(name: "08-inserted-default", title: "Inserted · default", state: .result(.inserted(appName: "Mail", method: .typed), showsWords: false), glyph: .mark),
        Case(name: "09-inserted-saying-where", title: "Inserted · saying where", state: .result(.inserted(appName: "Mail", method: .typed), showsWords: true), glyph: .mark),
        Case(name: "10-pasted", title: "Pasted", state: .result(.inserted(appName: "Terminal", method: .pasted), showsWords: true), glyph: .mark),
        Case(name: "11-copied-password", title: "Copied: password field", state: .result(.copied(.secureField), showsWords: true), glyph: .mark),
        Case(name: "12-copied-field-changed", title: "Copied: field changed", state: .result(.copied(.fieldChanged), showsWords: true), glyph: .mark),
        Case(name: "13-copied-app-changed", title: "Copied: app changed", state: .result(.copied(.appChanged), showsWords: true), glyph: .mark),
        Case(name: "14-copied-no-text-field", title: "Copied: no text field", state: .result(.copied(.noTextField), showsWords: true), glyph: .mark),
        Case(name: "15-no-speech", title: "No speech", state: .noSpeechDetected, glyph: .noSpeech, tone: .graphite),
        Case(name: "16-discarded-undo", title: "Discarded, with Undo", state: .discarded(undoUntil: Date().addingTimeInterval(60)), tone: .graphite),
        Case(name: "17-couldnt-insert", title: "Couldn’t insert", state: .result(.failed(savedInHistory: true), showsWords: true), glyph: .caution, tone: .graphite),
        Case(name: "18-not-pasted", title: "Not pasted", state: .result(.notPasted, showsWords: true), glyph: .caution, tone: .graphite),
        Case(name: "19-microphone-off", title: "Microphone off", state: .result(.microphoneAccessOff, showsWords: true), glyph: .microphoneOff, tone: .graphite),
        Case(name: "20-microphone-disconnected", title: "Microphone disconnected", state: .result(.microphoneDisconnected(insertedPartial: true), showsWords: true), glyph: .microphoneOff, tone: .graphite),
        Case(name: "21-couldnt-transcribe", title: "Couldn’t transcribe", state: .result(.transcriptionFailed, showsWords: true), glyph: .caution, tone: .graphite),
        Case(name: "22-not-ready", title: "Not ready", state: .busy(.modelLoading), tone: .graphite),
        Case(name: "23-live-waiting", title: "Live words: waiting", state: .listening(handsFree: true, elapsedSeconds: 9), live: true),
        Case(name: "24-live-words", title: "Live words", state: .listening(handsFree: true, elapsedSeconds: 9),
             stable: "Move the planning meeting from Thursday to Friday. Send the updated agenda ", wet: "before lunch so every",
             live: true),
        Case(name: "25-live-long", title: "Live words: long dictation", state: .listening(handsFree: true, elapsedSeconds: 271),
             stable: OverlayRenderingTests.longText, wet: "The second set of originals will follow", live: true),
        Case(name: "27-writing-hands-free", title: "Transcribing, after hands-free", state: .listening(handsFree: true, elapsedSeconds: 31), after: [.transcribing]),
        Case(name: "28-insert-card", title: "Inserted: the card, with words", state: .listening(handsFree: false, elapsedSeconds: 4),
             after: [.result(.inserted(appName: "Mail", method: .typed), showsWords: true)],
             glyph: .mark, words: "Move the planning meeting from Thursday to Friday and send the updated agenda before lunch", card: true),
        Case(name: "30-pasted-card", title: "Pasted: the card", state: .listening(handsFree: true, elapsedSeconds: 12),
             after: [.result(.inserted(appName: "Terminal", method: .pasted), showsWords: true)],
             glyph: .mark, words: "git log --oneline --since=yesterday", card: true),
        Case(name: "31-inserted-no-words", title: "Inserted: no words to show", state: .listening(handsFree: false, elapsedSeconds: 4),
             after: [.result(.inserted(appName: "Mail", method: .typed), showsWords: true)], glyph: .mark),
        Case(name: "32-copied-secure-after-listening", title: "Copied: password field, after listening",
             state: .listening(handsFree: true, elapsedSeconds: 31), after: [.result(.copied(.secureField), showsWords: true)], glyph: .mark),
        Case(name: "33-copied-after-listening", title: "Copied, after hands-free", state: .listening(handsFree: true, elapsedSeconds: 31),
             after: [.result(.copied(.other), showsWords: true)], glyph: .mark),
        Case(name: "34-error-after-listening", title: "Couldn’t transcribe, after hands-free", state: .listening(handsFree: true, elapsedSeconds: 31),
             after: [.result(.transcriptionFailed, showsWords: true)], glyph: .caution, tone: .graphite),
        Case(name: "26-live-preview-stopped", title: "Preview stopped", state: .listening(handsFree: true, elapsedSeconds: 72),
             live: true, previewStopped: true),
    ]

    nonisolated static let variants: [Variant] = [
        Variant(name: "light", dark: false, increaseContrast: false, reduceTransparency: false),
        Variant(name: "dark", dark: true, increaseContrast: false, reduceTransparency: false),
        Variant(name: "light-increase-contrast", dark: false, increaseContrast: true, reduceTransparency: false),
        Variant(name: "dark-increase-contrast", dark: true, increaseContrast: true, reduceTransparency: false),
        Variant(name: "dark-reduce-transparency", dark: true, increaseContrast: false, reduceTransparency: true),
    ]

    nonisolated static let forms: [Form] = [Form(name: "notch", notch: true), Form(name: "capsule", notch: false)]

    /// A 16-inch MacBook Pro at its default scaled resolution: a 185 x 32 notch, a 33 pt menu bar.
    static let display = OverlayDisplayDescriptor(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 56, width: 1728, height: 1028),
        isBuiltIn: true, safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771, height: 32),
        auxiliaryTopRight: CGRect(x: 956, y: 1085, width: 772, height: 32)
    )

    private var outputDirectory: URL {
        get throws {
            let root = ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering", isDirectory: true)
            let directory = root.appendingPathComponent("overlay-grove", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    @Test("Every Grove overlay state renders at its width in both forms", arguments: forms, variants)
    func renderEveryState(form: Form, variant: Variant) throws {
        let directory = try outputDirectory.appendingPathComponent("\(form.name)-\(variant.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sheetRows: [(String, Data)] = []
        let scale: CGFloat = 2
        for item in Self.cases {
            let presenter = makePresenter(form: form, variant: variant, live: item.live)
            let (overlay, size) = try #require(render(item, with: presenter))
            let layout = presenter.hostedEvidenceGroveLayout()
            let row = presenter.hostedEvidenceCapsuleSize()
            let label = "\(form.name)/\(variant.name)/\(item.name)"
            #expect(row.height == (item.card ? 62 : (form.notch ? 32 : 34)), "\(label)")
            #expect(row.width >= layout.minimumRowWidth && row.width <= layout.maximumRowWidth, "\(label)")
            if item.card { #expect(presenter.hostedEvidenceInsertDetail() == item.words, "\(label)") }
            if item.words == nil { #expect(presenter.hostedEvidenceInsertDetail() == nil, "\(label)") }
            if item.live { #expect(row.width == 412, "\(label)") }
            if item.glyph != nil { #expect(presenter.hostedEvidenceGroveGlyph() == item.glyph, "\(label)") }
            #expect(presenter.hostedEvidenceGroveTone() == item.tone, "\(label)")
            #expect(overlay.count > 2_000)
            if ["03-hands-free", "19-microphone-off", "24-live-words", "28-insert-card", "30-pasted-card"].contains(item.name) {
                try checkPixels(overlay, layout: layout, rowWidth: row.width, scale: scale, form: form, tone: item.tone, name: label)
            }
            let composed = try #require(compose(overlay, form: form, dark: variant.dark, size: size, scale: scale))
            try composed.write(to: directory.appendingPathComponent(item.name + ".png"))
            sheetRows.append((item.title, composed))
            presenter.hide()
        }
        let sheet = try #require(contactSheet(rows: sheetRows, dark: variant.dark, scale: scale))
        try sheet.write(to: outputDirectory.appendingPathComponent("sheet-\(form.name)-\(variant.name).png"))
    }

    @Test("The listening render follows the level: still in silence, longer barbs at speech level")
    func levelRenders() throws {
        for level: Float in [0, 0.5, 1] {
            let form = Self.forms[1]
            let variant = Self.variants[1]
            let presenter = makePresenter(form: form, variant: variant, live: false)
            presenter.show(state: .listening(handsFree: true, elapsedSeconds: 130))
            for _ in 0..<GroveBarsView.delayedSamples { presenter.updateInputLevel(level) }
            let overlay = try #require(presenter.hostedEvidenceRenderCurrentPNG(backdrop: nil, scale: 4))
            let size = presenter.hostedEvidencePanelSize()
            let composed = try #require(compose(overlay, form: form, dark: true, size: size, scale: 4))
            try composed.write(to: outputDirectory.appendingPathComponent("level-\(Int(level * 100)).png"))
            presenter.hide()
        }
    }

    // MARK: - Helpers

    private func makePresenter(form: Form, variant: Variant, live: Bool) -> WaveformOverlayPresenter {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        presenter.hostedEvidenceSetPlacement(
            form.notch ? .notch(display: Self.display, notch: Self.display.notch!) : .capsule(display: Self.display)
        )
        presenter.appearance = .grove
        presenter.updateAppearance(NSAppearance(named: variant.dark ? .darkAqua : .aqua))
        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: false, reduceTransparency: variant.reduceTransparency,
            increaseContrast: variant.increaseContrast, preferredBodyPointSize: 13
        ))
        presenter.setLiveTranscriptEnabled(live)
        presenter.setStopAction {}
        presenter.onCopyResult = {}
        presenter.onUndoDiscard = {}
        presenter.onOpenSettings = { _ in }
        return presenter
    }

    private func render(_ item: Case, with presenter: WaveformOverlayPresenter) -> (Data, CGSize)? {
        presenter.show(state: item.state, insertedWords: item.words)
        if let limit = item.limitSeconds { presenter.showRecordingLimitWarning(limitSeconds: limit) }
        if !item.stable.isEmpty || !item.wet.isEmpty {
            let session = LiveTranscriptionSession(sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1, runtimeIdentity: .pending)
            presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
                session: session, stablePrefix: item.stable, revisableTail: item.wet,
                lastAcceptedRevision: 1, decodedAudioWatermark: 1_600))
            presenter.hostedEvidenceFlushLiveTranscript()
        }
        if item.previewStopped { presenter.showLiveTranscriptUnavailable() }
        // Hands-free and hold listening widths are what a result must not be narrower than.
        var listeningWidth: CGFloat?
        if case .listening = item.state { listeningWidth = presenter.hostedEvidenceCapsuleSize().width }
        for next in item.after {
            presenter.show(state: next, insertedWords: item.words)
            if let listeningWidth { #expect(presenter.hostedEvidenceCapsuleSize().width >= listeningWidth, "\(item.name) is never narrower than listening") }
        }
        // A steady speech level, held long enough for every bar to show it.
        if case .listening = item.state, item.after.isEmpty {
            for _ in 0..<GroveBarsView.delayedSamples { presenter.updateInputLevel(GroveBarsView.referenceLevel) }
        }
        let size = presenter.hostedEvidencePanelSize()
        guard let data = presenter.hostedEvidenceRenderCurrentPNG(backdrop: nil, scale: 2) else { return nil }
        return (data, size)
    }

    /// The panel's own pixels: transparent at the corners, forest inside the row, black in the neck.
    private func checkPixels(_ png: Data, layout: GroveLayout, rowWidth: CGFloat, scale: CGFloat, form: Form, tone: GroveTone, name: String) throws {
        let rep = try #require(NSBitmapImageRep(data: png))
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        }
        #expect(color(1, 1)?.alphaComponent == 0, "top-left corner is transparent, so clicks pass through: \(name)")
        let corner = color(layout.panelSize.width - 2, layout.panelSize.height - 2)
        #expect(corner?.alphaComponent == 0, "bottom-right corner is transparent: \(name)")
        let row = layout.rowRect(width: rowWidth)
        let inside = try #require(color(row.minX + 6, row.midY))
        #expect(inside.alphaComponent > 0.9, "\(name)")
        switch tone {
        case .forest:
            #expect(inside.greenComponent > inside.redComponent && inside.greenComponent >= inside.blueComponent, "forest, not indigo: \(name)")
        case .graphite:
            #expect(abs(inside.greenComponent - inside.redComponent) < 0.03 && abs(inside.greenComponent - inside.blueComponent) < 0.03, "graphite is neutral: \(name)")
        }
        #expect(inside.brightnessComponent < 0.4, "\(name)")
        if form.notch {
            let neck = try #require(color(layout.centerX, 4))
            #expect(neck.alphaComponent == 1 && neck.redComponent < 0.01 && neck.greenComponent < 0.01 && neck.blueComponent < 0.01,
                    "the neck is pure black: \(name)")
            let beside = color(layout.centerX - layout.neckWidth! / 2 - 4, 4)
            #expect(beside?.alphaComponent == 0, "nothing beside the notch at menu-bar height: \(name)")
            // A hard seam: black to the menu bar's bottom edge, the island's fill from there.
            let seam = layout.neckHeight!
            let above = try #require(color(layout.centerX + 40, seam - 1.5))
            let below = try #require(color(layout.centerX + 40, seam + 1.5))
            #expect(above.redComponent < 0.01 && above.greenComponent < 0.01 && above.blueComponent < 0.01, "black above the seam: \(name)")
            #expect(below.greenComponent > 0.1 || tone == .graphite, "the fill starts at the seam: \(name)")
            #expect(below.brightnessComponent > 0.08, "no gradient blend into the seam: \(name)")
        }
    }

    /// The overlay over a stand-in desktop: a wallpaper, and in the notch form a menu bar and the camera housing.
    private func compose(_ overlay: Data, form: Form, dark: Bool, size: CGSize, scale: CGFloat) -> Data? {
        guard let overlayRep = NSBitmapImageRep(data: overlay),
              let out = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let rect = NSRect(origin: .zero, size: size)
        let wallpaper = dark
            ? [NSColor(srgbRed: 0x0B / 255.0, green: 0x11 / 255.0, blue: 0x0E / 255.0, alpha: 1), NSColor(srgbRed: 0x1E / 255.0, green: 0x27 / 255.0, blue: 0x22 / 255.0, alpha: 1)]
            : [NSColor(srgbRed: 0xCF / 255.0, green: 0xDE / 255.0, blue: 0xD4 / 255.0, alpha: 1), NSColor(srgbRed: 0xEC / 255.0, green: 0xF2 / 255.0, blue: 0xED / 255.0, alpha: 1)]
        NSGradient(colors: wallpaper)?.draw(in: rect, angle: -20)
        if form.notch {
            let bar = Self.display.menuBarHeight
            (dark ? NSColor(white: 0.1, alpha: 0.85) : NSColor(white: 1, alpha: 0.55)).setFill()
            NSRect(x: 0, y: size.height - bar, width: size.width, height: bar).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: dark ? NSColor.white : NSColor.black,
            ]
            ("  Mail   File   Edit   View   Window" as NSString).draw(at: NSPoint(x: 4, y: size.height - 24), withAttributes: attributes)
            ("Wi-Fi   9:41" as NSString).draw(at: NSPoint(x: size.width - 92, y: size.height - 24), withAttributes: attributes)
            let notch = Self.display.notch!
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: size.width / 2 - notch.width / 2, y: size.height - notch.height - 9, width: notch.width, height: notch.height + 18),
                xRadius: 9, yRadius: 9
            ).fill()
        }
        overlayRep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        return out.representation(using: .png, properties: [:])
    }

    /// Stacks renders with their titles, for one-glance review.
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
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        (dark ? NSColor(srgbRed: 0.04, green: 0.06, blue: 0.05, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.95, blue: 0.93, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var top = CGFloat(height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * scale, weight: .semibold),
            .foregroundColor: dark ? NSColor.white : NSColor(srgbRed: 0.06, green: 0.12, blue: 0.09, alpha: 1),
        ]
        for (title, image) in images {
            top -= captionHeight
            (title as NSString).draw(at: NSPoint(x: 12 * scale, y: top + 4 * scale), withAttributes: attributes)
            top -= CGFloat(image.pixelsHigh)
            image.draw(in: NSRect(x: 0, y: top, width: CGFloat(image.pixelsWide), height: CGFloat(image.pixelsHigh)))
        }
        return sheet.representation(using: .png, properties: [:])
    }
}
