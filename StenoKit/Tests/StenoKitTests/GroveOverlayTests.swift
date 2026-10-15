#if os(macOS)
import AppKit
import Testing
@testable import StenoKit

/// Displays as the placement decision sees them. Frames are in global points, y up.
private enum Displays {
    /// A 16-inch MacBook Pro at its default scaled resolution: a 185 x 32 notch, a 33 pt menu bar.
    static let notched = OverlayDisplayDescriptor(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 56, width: 1728, height: 1028),
        isBuiltIn: true, safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771, height: 32),
        auxiliaryTopRight: CGRect(x: 956, y: 1085, width: 772, height: 32)
    )
    static let builtInWithoutNotch = OverlayDisplayDescriptor(
        id: 2, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 836),
        isBuiltIn: true, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
    static let external = OverlayDisplayDescriptor(
        id: 3, frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1728, y: 0, width: 2560, height: 1415),
        isBuiltIn: false, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
}

@Suite("Grove overlay placement")
struct GroveOverlayPlacementTests {
    @Test("The only display is the built-in one with a notch: the notch form")
    func builtInNotchOnly() {
        let placement = OverlayPlacementPolicy.resolve(displays: [Displays.notched], onlineDisplayCount: 1, targetPoint: CGPoint(x: 100, y: 100))
        guard case .notch(let display, let notch)? = placement else {
            Issue.record("expected the notch form, got \(String(describing: placement))")
            return
        }
        #expect(display.id == 1)
        #expect(notch.width == 185)
        #expect(notch.height == 32)
        #expect(notch.centerX == 863.5)
    }

    @Test("An external display makes it a capsule, on the display under the cursor")
    func externalDisplayPresent() {
        let displays = [Displays.notched, Displays.external]
        let onBuiltIn = OverlayPlacementPolicy.resolve(displays: displays, onlineDisplayCount: 2, targetPoint: CGPoint(x: 400, y: 400))
        #expect(onBuiltIn == .capsule(display: Displays.notched))
        let onExternal = OverlayPlacementPolicy.resolve(displays: displays, onlineDisplayCount: 2, targetPoint: CGPoint(x: 3000, y: 700))
        #expect(onExternal == .capsule(display: Displays.external))
    }

    @Test("The pointer on the top pixel row of the external display places the capsule on the external display")
    func pointerOnTopRowOfExternalDisplay() {
        let builtIn = OverlayDisplayDescriptor(
            id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 56, width: 1512, height: 893),
            isBuiltIn: true, safeAreaTop: 32, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )
        let external = OverlayDisplayDescriptor(
            id: 3, frame: CGRect(x: 1512, y: -229, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1512, y: -229, width: 2560, height: 1415),
            isBuiltIn: false, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )
        let displays = [builtIn, external]
        func placed(_ point: CGPoint) -> UInt32? {
            OverlayPlacementPolicy.resolve(displays: displays, onlineDisplayCount: 2, targetPoint: point)?.display.id
        }

        #expect(placed(CGPoint(x: external.frame.midX, y: external.frame.midY)) == 3)
        #expect(placed(CGPoint(x: external.frame.midX, y: external.frame.minY)) == 3)
        #expect(placed(CGPoint(x: external.frame.minX, y: external.frame.midY)) == 3)
        #expect(placed(CGPoint(x: external.frame.maxX - 0.5, y: external.frame.midY)) == 3)
        #expect(placed(CGPoint(x: builtIn.frame.midX, y: builtIn.frame.midY)) == 1)
        // The top pixel row reports y == frame.maxY.
        #expect(placed(CGPoint(x: external.frame.midX, y: external.frame.maxY)) == 3)
        #expect(placed(CGPoint(x: builtIn.frame.midX, y: builtIn.frame.maxY)) == 1)
    }

    @Test("The pointer on the top row of the lower display of a stacked pair places the capsule on the lower display")
    func pointerOnTopRowOfLowerStackedDisplay() {
        let lower = OverlayDisplayDescriptor(
            id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 56, width: 1512, height: 893),
            isBuiltIn: true, safeAreaTop: 32, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )
        let upper = OverlayDisplayDescriptor(
            id: 4, frame: CGRect(x: -524, y: 982, width: 2560, height: 1440),
            visibleFrame: CGRect(x: -524, y: 982, width: 2560, height: 1415),
            isBuiltIn: false, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )
        // Precondition: the stacked layout shares the edge the pointer sits on.
        #expect(lower.frame.maxY == upper.frame.minY)

        func placed(_ point: CGPoint, _ displays: [OverlayDisplayDescriptor]) -> UInt32? {
            OverlayPlacementPolicy.resolve(displays: displays, onlineDisplayCount: 2, targetPoint: point)?.display.id
        }
        // The lower display's top pixel row is also the upper display's minY, whatever the list order.
        let top = CGPoint(x: 756, y: lower.frame.maxY)
        #expect(placed(top, [lower, upper]) == 1)
        #expect(placed(top, [upper, lower]) == 1)
        // Rows inside either display, and the upper display's own top row, still resolve to it.
        #expect(placed(CGPoint(x: 756, y: lower.frame.maxY - 1), [lower, upper]) == 1)
        #expect(placed(CGPoint(x: 756, y: upper.frame.minY + 1), [lower, upper]) == 4)
        #expect(placed(CGPoint(x: 756, y: upper.frame.maxY), [lower, upper]) == 4)
        // Beside the lower display, the edge still belongs to the upper one.
        #expect(placed(CGPoint(x: -100, y: lower.frame.maxY), [lower, upper]) == 4)
    }

    @Test("A cursor outside every display falls back to the first display")
    func cursorOffscreen() {
        let placement = OverlayPlacementPolicy.resolve(displays: [Displays.external, Displays.notched], onlineDisplayCount: 2, targetPoint: CGPoint(x: -9000, y: -9000))
        #expect(placement == .capsule(display: Displays.external))
        #expect(OverlayPlacementPolicy.resolve(displays: [Displays.external], onlineDisplayCount: 1, targetPoint: nil) == .capsule(display: Displays.external))
    }

    @Test("A mirrored or Sidecar display counts as external even though only one screen is listed")
    func mirroredDisplay() {
        let placement = OverlayPlacementPolicy.resolve(displays: [Displays.notched], onlineDisplayCount: 2, targetPoint: CGPoint(x: 10, y: 10))
        #expect(placement == .capsule(display: Displays.notched))
    }

    @Test("Clamshell: the only display is an external one, so a capsule")
    func clamshell() {
        let placement = OverlayPlacementPolicy.resolve(displays: [Displays.external], onlineDisplayCount: 1, targetPoint: CGPoint(x: 2000, y: 500))
        #expect(placement == .capsule(display: Displays.external))
    }

    @Test("A built-in display without a notch gets the capsule")
    func builtInWithoutNotch() {
        let placement = OverlayPlacementPolicy.resolve(displays: [Displays.builtInWithoutNotch], onlineDisplayCount: 1, targetPoint: .zero)
        #expect(placement == .capsule(display: Displays.builtInWithoutNotch))
    }

    @Test("A notch needs the inset and both top areas, with the right area to the right")
    func incompleteNotchReports() {
        var noRight = Displays.notched
        noRight.auxiliaryTopRight = nil
        var noInset = Displays.notched
        noInset.safeAreaTop = 0
        var overlapping = Displays.notched
        overlapping.auxiliaryTopRight = CGRect(x: 700, y: 1085, width: 1028, height: 32)
        for display in [noRight, noInset, overlapping] {
            #expect(display.notch == nil)
            #expect(OverlayPlacementPolicy.resolve(displays: [display], onlineDisplayCount: 1, targetPoint: .zero) == .capsule(display: display))
        }
    }

    @Test("No displays at all gives no placement")
    func noDisplays() {
        #expect(OverlayPlacementPolicy.resolve(displays: [], onlineDisplayCount: 0, targetPoint: .zero) == nil)
    }

    @Test("Plugging in and unplugging a display changes the form at the next decision")
    func displayChange() {
        func resolve(_ displays: [OverlayDisplayDescriptor]) -> OverlayPlacement? {
            OverlayPlacementPolicy.resolve(displays: displays, onlineDisplayCount: displays.count, targetPoint: CGPoint(x: 100, y: 100))
        }
        #expect(resolve([Displays.notched])?.isNotch == true)
        #expect(resolve([Displays.notched, Displays.external])?.isNotch == false)
        #expect(resolve([Displays.notched])?.isNotch == true)
    }

    @Test("The menu bar height is the gap between the frame and the visible frame")
    func menuBarHeight() {
        #expect(Displays.notched.menuBarHeight == 33)
        #expect(Displays.external.menuBarHeight == 25)
    }
}

@Suite("Grove overlay geometry")
struct GroveOverlayGeometryTests {
    private func metrics(textScale: CGFloat = 13) -> OverlayAccessibilityMetrics {
        OverlayAccessibilityMetrics(
            preferences: .init(reduceMotion: false, reduceTransparency: false, increaseContrast: false, preferredBodyPointSize: textScale),
            appearance: .grove
        )
    }

    private func notchLayout(showsTranscript: Bool = true, textScale: CGFloat = 13) -> GroveLayout {
        GroveLayout.make(
            placement: .notch(display: Displays.notched, notch: Displays.notched.notch!), metrics: metrics(textScale: textScale),
            showsTranscript: showsTranscript, transcriptLines: 3
        )
    }

    @Test("At menu-bar height the notch shape is never wider than the notch", arguments: [13.0, 17.0, 22.0])
    func notchWidthAtMenuBarHeight(bodySize: Double) {
        let layout = notchLayout(textScale: bodySize)
        let neckHeight = try! #require(layout.neckHeight)
        #expect(neckHeight >= Displays.notched.menuBarHeight)
        let half = layout.neckWidth! / 2
        let left = layout.centerX - half, right = layout.centerX + half
        // Every width a row takes: the narrowest, a result, a problem, and the live-words container.
        let widths: [CGFloat] = [100, layout.minimumRowWidth, 236, 330, layout.maximumRowWidth, layout.cardWidth]
        for width in widths {
            for lines in [nil, 1, 3] as [Int?] {
                let path = layout.shellPath(rowWidth: width, lines: lines)
                for y in stride(from: 0.25, to: Displays.notched.menuBarHeight, by: 0.5) {
                    for x in stride(from: 0.0, to: layout.panelSize.width, by: 0.5) where x < left - 0.01 || x > right + 0.01 {
                        #expect(!path.contains(CGPoint(x: x, y: y)), "a \(width) pt row reaches (\(x), \(y)) beside the notch")
                    }
                }
                // The neck itself is there, down to the menu bar's bottom edge.
                #expect(path.contains(CGPoint(x: layout.centerX, y: 5)))
                #expect(path.contains(CGPoint(x: layout.centerX, y: neckHeight - 0.5)))
                let row = layout.rowRect(width: width)
                #expect(row.minY >= Displays.notched.menuBarHeight)
                // The body below the shoulders is as wide as the row.
                #expect(path.contains(CGPoint(x: row.minX + 2, y: row.midY)))
                #expect(path.contains(CGPoint(x: row.maxX - 2, y: row.midY)))
            }
        }
    }

    @Test("Every notch body has 10 pt shoulders: the narrowest is the notch plus 20 pt")
    func shouldersAlwaysAppear() throws {
        let layout = notchLayout(showsTranscript: false)
        let notchWidth = try #require(layout.neckWidth)
        #expect(layout.minimumRowWidth == notchWidth + 20)
        #expect(layout.rowWidth(for: 100) == notchWidth + 20)
        let neckHeight = try #require(layout.neckHeight)
        let path = layout.shellPath(rowWidth: 0)
        let right = layout.centerX + notchWidth / 2
        // Just below the menu bar the shoulder has begun to flare; ten points down it has reached
        // the body's side. A concave fillet leaves the corner outside the curve empty.
        #expect(!path.contains(CGPoint(x: right + 9, y: neckHeight + 1)))
        #expect(!path.contains(CGPoint(x: right + 9.5, y: neckHeight + 9.5)))
        #expect(path.contains(CGPoint(x: right + 9.5, y: neckHeight + 10.5)))
        #expect(path.contains(CGPoint(x: right + 1, y: neckHeight + 6)))
        #expect(GroveShapes.ear == 10)
    }

    @Test("The notch row is 32 pt tall below the shoulders; the capsule is 34 pt")
    func rowHeights() {
        #expect(notchLayout().rowHeight == 32)
        #expect(notchLayout().rowTop == notchLayout().neckHeight! + GroveShapes.ear)
        let capsule = GroveLayout.make(placement: .capsule(display: Displays.external), metrics: metrics(), showsTranscript: false, transcriptLines: 1)
        #expect(capsule.rowHeight == 34)
    }

    @Test("The folded shell is the neck alone")
    func closedShellIsTheNeck() throws {
        let layout = notchLayout(showsTranscript: false)
        let closed = try #require(layout.closedShellPath)
        #expect(closed.contains(CGPoint(x: layout.centerX, y: 5)))
        #expect(!closed.contains(CGPoint(x: layout.centerX, y: layout.rowTop + 10)))
        #expect(layout.closedShadowPath != nil)
        #expect(GroveLayout.make(placement: .capsule(display: Displays.external), metrics: metrics(), showsTranscript: false, transcriptLines: 1).closedShellPath == nil)
    }

    @Test("The panel is placed flush with the top of the screen in notch mode, centred on the notch")
    func notchPanelFrame() throws {
        let frame = notchLayout().panelFrame
        #expect(frame.maxY == Displays.notched.frame.maxY)
        #expect(frame.midX == 863.5)
        #expect(frame.width == notchLayout().panelSize.width)
    }

    @Test("The capsule sits a fixed gap below the menu bar, centred on its display")
    func capsulePanelFrame() {
        let layout = GroveLayout.make(
            placement: .capsule(display: Displays.external), metrics: metrics(), showsTranscript: false, transcriptLines: 1
        )
        let row = layout.rowRect(width: 300)
        let rowTopOnScreen = layout.panelFrame.maxY - row.minY
        #expect(rowTopOnScreen == Displays.external.visibleFrame.maxY - GroveLayout.capsuleTopGap)
        #expect(layout.panelFrame.midX == Displays.external.frame.midX)
        #expect(row.height == 34)
    }

    @Test("Live words grow the same shape downward: one container, radius 18")
    func containerHoldsTheWords() throws {
        let layout = GroveLayout.make(
            placement: .capsule(display: Displays.external), metrics: metrics(), showsTranscript: true, transcriptLines: 3
        )
        #expect(layout.cardWidth == 412)
        #expect(layout.maximumLines == 3)
        let row = layout.rowRect(width: layout.cardWidth)
        let one = layout.shellPath(rowWidth: layout.cardWidth, lines: 1).boundingBoxOfPath
        let three = layout.shellPath(rowWidth: layout.cardWidth, lines: 3).boundingBoxOfPath
        #expect(one.minY == row.minY && three.minY == row.minY)
        #expect(one.height == 34 + layout.wordsHeight(lines: 1))
        #expect(three.height - one.height == 2 * layout.lineHeight)
        #expect(three.width == layout.cardWidth)
        // A capsule's radius is half its height; the container's is 18.
        let capsule = layout.shellPath(rowWidth: 100).boundingBoxOfPath
        #expect(capsule.height == 34)
        #expect(layout.containerRadius == 18)
        // The words sit directly under the row, inside the container.
        let words = layout.cardRect(lines: 3, metrics: metrics())
        #expect(words.minY == layout.rowBottom)
        #expect(layout.shellPath(rowWidth: layout.cardWidth, lines: 3).contains(CGPoint(x: words.midX, y: words.maxY - 2)))
        #expect(layout.panelSize.height >= words.maxY + OverlayPanelLayoutPolicy.shadowMargins.bottom)
    }

    @Test("Every shape builder emits one fixed sequence of segments, so paths can spring")
    func segmentStructureIsFixed() {
        func count(_ path: CGPath) -> Int {
            var n = 0
            path.applyWithBlock { _ in n += 1 }
            return n
        }
        let layout = notchLayout(showsTranscript: false)
        let open = count(layout.shellPath(rowWidth: 220))
        #expect(count(layout.shellPath(rowWidth: 340)) == open)
        #expect(count(layout.shellPath(rowWidth: 0)) == open)
        #expect(count(layout.shellPath(rowWidth: 412, lines: 3)) == open)
        #expect(count(try! #require(layout.closedShellPath)) == open)
        let capsule = GroveLayout.make(placement: .capsule(display: Displays.external), metrics: metrics(), showsTranscript: false, transcriptLines: 1)
        #expect(count(capsule.shellPath(rowWidth: 220)) == count(capsule.shellPath(rowWidth: 340)))
        #expect(count(capsule.shellPath(rowWidth: 412, lines: 2)) == count(capsule.shellPath(rowWidth: 100)))
        #expect(count(layout.shadowPath(rowWidth: 220)) == count(try! #require(layout.closedShadowPath)))
        #expect(count(layout.shadowPath(rowWidth: 412, lines: 3)) == count(try! #require(layout.closedShadowPath)))
    }

    @Test("Springs convert from duration and bounce, and settle without overstaying")
    func springs() {
        for spring in [GroveSpring.emergence, .widthChange, .retract] {
            let animation = spring.animation(keyPath: "path", from: nil, to: nil)
            #expect(animation.mass == 1)
            #expect(animation.stiffness == CGFloat(pow(2 * Double.pi / spring.duration, 2)))
            #expect(animation.damping == CGFloat(4 * Double.pi * (1 - spring.bounce) / spring.duration))
            #expect(animation.duration > spring.duration * 0.5)
            #expect(animation.duration < 1.2)
        }
        // Opening is the spring with response 0.42 and damping 0.8.
        #expect(GroveSpring.emergence == GroveSpring(duration: 0.42, bounce: 0.2))
        #expect(GroveSpring.widthChange == GroveSpring(duration: 0.35, bounce: 0))
        #expect(GroveSpring.retract == GroveSpring(duration: 0.28, bounce: 0))
        // No bounce means critically damped: damping = 2 sqrt(stiffness).
        let flat = GroveSpring.widthChange
        #expect(abs(Double(flat.damping) - 2 * Double(flat.stiffness).squareRoot()) < 0.001)
        #expect(GroveMotion.controlsDelay == 0.09)
    }

    @Test("Reduce Motion replaces each movement with a short cross-fade")
    func motionPolicy() {
        #expect(GroveMotion.widthChange(reduceMotion: false) == .widthSpring)
        #expect(GroveMotion.widthChange(reduceMotion: true) == .crossFade(0.14))
        #expect(GroveMotion.appear(isNotch: true, reduceMotion: false) == .emergence)
        #expect(GroveMotion.appear(isNotch: false, reduceMotion: false) == .none)
        #expect(GroveMotion.appear(isNotch: true, reduceMotion: true) == .crossFade(0.14))
        #expect(GroveMotion.appear(isNotch: false, reduceMotion: true) == .none)
        #expect(GroveMotion.disappear(isNotch: true, reduceMotion: false) == .retract)
        #expect(GroveMotion.disappear(isNotch: false, reduceMotion: false) == .crossFade(0.15))
        #expect(GroveMotion.disappear(isNotch: true, reduceMotion: true) == .crossFade(0.15))
        for fade in [GroveMotion.reducedMotionFade, 0.15] { #expect((0.12...0.15).contains(fade)) }
    }
}

@Suite("Grove palette")
struct GrovePaletteTests {
    @Test("The forest and the graphite fills, and one hairline")
    func fills() {
        #expect(GrovePalette.gradient(.forest) == [0x213A2B, 0x0F2419])
        #expect(GrovePalette.gradient(.graphite) == [0x2A2C2B, 0x1B1C1B])
        let top = GrovePalette.hairlineTop.usingColorSpace(.sRGB)!, bottom = GrovePalette.hairlineBottom.usingColorSpace(.sRGB)!
        #expect(abs(top.alphaComponent - 0.14) < 0.001 && abs(bottom.alphaComponent - 0.03) < 0.001)
        #expect(GrovePalette.hairlineWidth == 0.75)
        #expect(GrovePalette.shadowOpacity == 0.30 && GrovePalette.shadowRadius == 10 && GrovePalette.shadowDrop == 4)
        #expect(GrovePalette.increasedContrastRim.alphaComponent >= 0.6)
    }

    @Test("The fill interpolates from the top colour to the bottom colour")
    func fillInterpolation() throws {
        let top = try #require(GrovePalette.fill(.forest, at: 0).usingColorSpace(.sRGB))
        let bottom = try #require(GrovePalette.fill(.forest, at: 1).usingColorSpace(.sRGB))
        #expect(abs(top.redComponent - 0x21 / 255.0) < 0.002 && abs(bottom.greenComponent - 0x24 / 255.0) < 0.002)
    }
}

@Suite("Grove row model and layout")
@MainActor
struct GroveRowTests {
    private func model(_ state: OverlayState, limit: Int? = nil, result: OverlayResult? = nil) -> GroveRowModel {
        var resolved = result
        if resolved == nil, case .result(let r, _) = state { resolved = r }
        return GroveRowModel.make(for: OverlayPresentation.make(for: state, limitSeconds: limit), result: resolved)
    }

    @Test("Listening: only the bars; hands-free adds a timer and Stop")
    func listening() {
        let hold = model(.listening(handsFree: false, elapsedSeconds: 3))
        #expect(hold.lead == .bars(11) && hold.primary == nil && hold.time == nil && !hold.showsStop && hold.showsDiscard)
        #expect(hold.tone == .forest)
        let handsFree = model(.listening(handsFree: true, elapsedSeconds: 130))
        #expect(handsFree.lead == .bars(7) && handsFree.time == "2:10" && handsFree.showsStop && handsFree.showsDiscard)
        let late = model(.listening(handsFree: false, elapsedSeconds: 14))
        #expect(late.lead == .bars(7) && late.time == "0:14" && !late.showsStop)
        let last = model(.listening(handsFree: true, elapsedSeconds: 3_558), limit: 3_600)
        #expect(last.primary == "Stops in 0:42" && last.primaryStyle == .countdown && last.time == nil)
    }

    @Test("Transcribing is the mark, working, the word Transcribing in the subtext, and a way to cancel")
    func transcribing() {
        let working = model(.transcribing)
        #expect(working.lead == .mark(done: false) && working.primary == "Transcribing" && working.primaryStyle == .working)
        #expect(working.showsDiscard && working.tone == .forest && working.detail == nil)
    }

    @Test("Results that worked are forest and lead with the mark")
    func results() {
        let inserted = model(.result(.inserted(appName: "Mail", method: .typed), showsWords: true))
        #expect(inserted.lead == .mark(done: true) && inserted.primary == "Inserted" && inserted.appName == "Mail" && inserted.tone == .forest)
        let brief = model(.result(.inserted(appName: "Mail", method: .typed), showsWords: false))
        #expect(brief.primary == "Inserted" && brief.appName == nil)
        let pasted = model(.result(.inserted(appName: "Terminal", method: .pasted), showsWords: true))
        #expect(pasted.primary == "Pasted" && pasted.appName == "Terminal" && pasted.lead == .mark(done: true))
        let copied = model(.result(.copied(.noTextField), showsWords: true))
        #expect(copied.lead == .mark(done: true) && copied.primary == "Copied" && copied.secondary == "No text field")
        #expect(copied.keyHint == "\u{2318}V" && copied.tone == .forest)
        let other = model(.copiedOnly)
        #expect(other.secondary == nil && other.keyHint == "\u{2318}V")
    }

    @Test("Notices and problems are graphite; green means working or worked")
    func graphite() {
        let cases: [(OverlayState, GroveGlyph?, String?)] = [
            (.noSpeechDetected, .noSpeech, "No speech detected"),
            (.result(.failed(savedInHistory: true), showsWords: true), .caution, "Couldn\u{2019}t insert. Saved in History."),
            (.result(.notPasted, showsWords: true), .caution, nil),
            (.result(.microphoneAccessOff, showsWords: true), .microphoneOff, "Microphone access is off"),
            (.result(.microphoneDisconnected(insertedPartial: true), showsWords: true), .microphoneOff, nil),
            (.result(.transcriptionFailed, showsWords: true), .caution, nil),
            (.discarded(undoUntil: Date().addingTimeInterval(5)), nil, "Discarded"),
            (.busy(.modelLoading), nil, "Still loading the speech model"),
            (.busy(.stillFinishing), nil, nil),
        ]
        for (state, glyph, text) in cases {
            let m = model(state)
            #expect(m.tone == .graphite, "\(state)")
            #expect(m.glyph == glyph, "\(state)")
            if let text { #expect(m.primary == text, "\(state)") }
        }
        #expect(GroveGlyph.caution.color == GrovePalette.warning && GroveGlyph.microphoneOff.color == GrovePalette.warning)
        #expect(GroveGlyph.noSpeech.color == GrovePalette.neutralGlyph)
        #expect(GroveGlyph.mark.color == GrovePalette.mint)
        #expect(model(.discarded(undoUntil: Date().addingTimeInterval(5))).actionTitle == "Undo")
        #expect(model(.result(.microphoneAccessOff, showsWords: true)).actionTitle == "Open Settings")
        #expect(model(.result(.failed(savedInHistory: true), showsWords: true)).actionTitle == "Copy")
    }

    private func layout(_ model: GroveRowModel, hasIcon: Bool = true, height: CGFloat = 34, fixed: CGFloat? = nil, minimum: CGFloat = 0) -> GroveRowLayout {
        GroveRowLayout.make(
            model: model, hasAppIcon: hasIcon, height: height, geometryScale: 1, textScale: 1, fixedWidth: fixed, minimumWidth: minimum,
            measure: { text, _ in CGFloat(text.count) * 6 }
        )
    }

    @Test("A capsule hugs its content; the bars with their cancel are 102.5 pt wide, the bars alone 88.5")
    func hugging() throws {
        var barsOnly = model(.listening(handsFree: false, elapsedSeconds: 0))
        barsOnly.showsDiscard = false
        let alone = layout(barsOnly)
        #expect(alone.width == 88.5)
        let bars = try #require(alone.frames[.bars])
        #expect(bars.width == 52.5 && bars.height == 18 && bars.minX == 18 && bars.midY == 17)
        let hold = layout(model(.listening(handsFree: false, elapsedSeconds: 0)))
        #expect(hold.width == 102.5)
        let working = layout(model(.transcribing))
        let mark = try #require(working.frames[.mark])
        #expect(mark.width == 22 && mark.height == 22)
        // The mark keeps its place when the shell widens for a result.
        let done = layout(model(.result(.inserted(appName: "Mail", method: .typed), showsWords: true)))
        #expect(try #require(done.frames[.mark]).minX == 12)
        #expect(done.width > working.width)
    }

    @Test("Hands-free: bars, timer, Stop, with Stop's radius concentric inside the capsule")
    func handsFree() throws {
        let row = layout(model(.listening(handsFree: true, elapsedSeconds: 130)))
        let stop = try #require(row.frames[.stop])
        #expect(stop.width == 22 && stop.height == 22)
        // Capsule radius 17, 6 pt of padding, disc radius 11.
        #expect(row.width - stop.maxX == 6 && stop.minY == 6)
        let bars = try #require(row.frames[.bars]), time = try #require(row.frames[.time])
        let cancel = try #require(row.frames[.cancel])
        #expect(bars.width == 32.5 && time.minX - bars.maxX == 10 && cancel.minX - time.maxX == 10 && stop.minX - cancel.maxX == 8)
    }

    @Test("A button ends its row at the same padding as it has above and below")
    func buttonInset() throws {
        let row = layout(model(.result(.failed(savedInHistory: true), showsWords: true)))
        let button = try #require(row.frames[.action])
        #expect(button.height == 22 && row.width - button.maxX == 6)
        let notchRow = layout(model(.result(.failed(savedInHistory: true), showsWords: true)), height: 32, minimum: 205)
        let notchButton = try #require(notchRow.frames[.action])
        #expect(notchRow.width - notchButton.maxX == 5)
    }

    @Test("In the notch a short row is as wide as the notch plus shoulders, with its content centred")
    func notchMinimum() throws {
        let row = layout(model(.transcribing), height: 32, minimum: 205)
        #expect(row.width == 205)
        let mark = try #require(row.frames[.mark]), word = try #require(row.frames[.primary])
        #expect(abs((mark.minX + word.maxX) / 2 - 102.5) < 0.5)
    }

    @Test("In a container the row spans the card: bars and timer left, Stop right")
    func container() throws {
        let row = layout(model(.listening(handsFree: true, elapsedSeconds: 9)), fixed: 412)
        #expect(row.width == 412)
        let bars = try #require(row.frames[.bars]), stop = try #require(row.frames[.stop])
        #expect(bars.minX == 16 && row.width - stop.maxX == 6)
    }

    @Test("Copied: mark, verb, reason, then the keycap")
    func copiedOrder() throws {
        let row = layout(model(.result(.copied(.noTextField), showsWords: true)))
        let order = [GroveRowLayout.Part.mark, .primary, .secondary, .keycap].map { row.frames[$0]!.minX }
        #expect(order == order.sorted())
        #expect(try #require(row.frames[.keycap]).height == 20)
    }

    @Test("Text gives way before the row grows past its maximum")
    func truncation() throws {
        let long = GroveRowModel(tone: .graphite, lead: .symbol(.caution), primary: String(repeating: "x", count: 200), actionTitle: "Copy")
        let row = GroveRowLayout.make(
            model: long, hasAppIcon: false, height: 34, geometryScale: 1, textScale: 1, maximumWidth: 412,
            measure: { text, _ in CGFloat(text.count) * 6 }
        )
        #expect(row.width == 412)
        let action = try #require(row.frames[.action])
        #expect(action.maxX <= row.width)
    }
}

@Suite("Grove overlay presenter", .serialized)
@MainActor
struct GroveOverlayPresenterTests {
    private let notch = OverlayPlacement.notch(display: Displays.notched, notch: Displays.notched.notch!)
    private let capsule = OverlayPlacement.capsule(display: Displays.notched)

    private func makePresenter(
        appearance: OverlayAppearanceStyle = .grove, placement: OverlayPlacement? = nil,
        reduceMotion: Bool = false, reduceTransparency: Bool = false, increaseContrast: Bool = false
    ) -> WaveformOverlayPresenter {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast, preferredBodyPointSize: 13
        ))
        presenter.hostedEvidenceSetPlacement(placement ?? notch)
        presenter.setLiveTranscriptEnabled(false)
        presenter.setStopAction {}
        presenter.onCopyResult = {}
        presenter.onUndoDiscard = {}
        presenter.onOpenSettings = { _ in }
        presenter.groveAppIconProvider = { _ in nil }
        presenter.appearance = appearance
        return presenter
    }

    @Test("A presenter nobody configures draws the Grove overlay, the look the app ships")
    func defaultsToGrove() {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        presenter.hostedEvidenceSetPlacement(capsule)
        presenter.groveAppIconProvider = { _ in nil }
        presenter.setLiveTranscriptEnabled(false)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceCapsuleSize().height == 34)
        #expect(presenter.hostedEvidenceWindowLevel() == NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3))
        #expect(presenter.hostedEvidenceRowSurfaceIsVisible())
        #expect(presenter.hostedEvidenceGroveBarsVisible())
        #expect(!presenter.hostedEvidenceQuillIsVisible())
        presenter.hide()
    }

    @Test("Switching the appearance restyles a live overlay and switches back cleanly")
    func switchingAppearance() {
        let presenter = makePresenter(appearance: .quill, placement: capsule)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceCapsuleSize().height == 40)
        #expect(presenter.hostedEvidenceWindowLevel() == .statusBar)

        presenter.appearance = .grove
        #expect(presenter.hostedEvidenceCapsuleSize().height == 34)
        #expect(presenter.hostedEvidenceWindowLevel() == NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3))
        #expect(presenter.hostedEvidenceCollectionBehavior() == [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        #expect(presenter.hostedEvidenceRowSurfaceIsVisible())
        #expect(presenter.hostedEvidenceGroveBarsVisible())
        #expect(!presenter.hostedEvidenceQuillIsVisible())
        #expect(presenter.hostedEvidenceIsVisible())
        #expect(presenter.hostedEvidenceStopIsAvailable())

        presenter.appearance = .quill
        #expect(presenter.hostedEvidenceCapsuleSize() == CGSize(width: 300, height: 40))
        #expect(presenter.hostedEvidenceWindowLevel() == .statusBar)
        #expect(presenter.hostedEvidenceCollectionBehavior() == [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
        #expect(!presenter.hostedEvidenceRowSurfaceIsVisible())
        #expect(presenter.hostedEvidenceQuillIsVisible())
        #expect(presenter.hostedEvidenceNibPalette() == .onWorking)
        presenter.hide()
    }

    @Test("The grove panel never becomes key; the bars lead only while listening, the mark or a symbol after")
    func panelAndLeads() {
        let presenter = makePresenter()
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceWindowCanBecomeKey() == false)
        #expect(presenter.hostedEvidenceGroveBarsVisible())
        #expect(!presenter.hostedEvidenceQuillIsVisible())
        #expect(presenter.hostedEvidenceGroveGlyph() == nil)
        let glyphs: [(OverlayState, GroveGlyph?, GroveTone)] = [
            (.result(.inserted(appName: "Mail", method: .typed), showsWords: true), .mark, .forest),
            (.result(.inserted(appName: "Terminal", method: .pasted), showsWords: true), .mark, .forest),
            (.result(.copied(.secureField), showsWords: true), .mark, .forest),
            (.result(.microphoneAccessOff, showsWords: true), .microphoneOff, .graphite),
            (.result(.failed(savedInHistory: true), showsWords: true), .caution, .graphite),
            (.noSpeechDetected, .noSpeech, .graphite),
            (.discarded(undoUntil: Date().addingTimeInterval(5)), nil, .graphite),
        ]
        for (state, glyph, tone) in glyphs {
            presenter.show(state: state)
            #expect(presenter.hostedEvidenceGroveGlyph() == glyph, "\(state)")
            #expect(presenter.hostedEvidenceGroveTone() == tone, "\(state)")
            #expect(!presenter.hostedEvidenceGroveBarsVisible())
            #expect(!presenter.hostedEvidenceQuillIsVisible())
        }
        presenter.show(state: .transcribing)
        #expect(presenter.hostedEvidenceGroveGlyph() == .mark)
        #expect(!presenter.hostedEvidenceGroveBarsVisible())
        #expect(presenter.hostedEvidenceGroveTone() == .forest)
        presenter.hide()
    }

    @Test("The quill writes while transcribing and completes its line on the result, in either motion setting")
    func markMotion() {
        for reduceMotion in [false, true] {
            let presenter = makePresenter(reduceMotion: reduceMotion)
            presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
            #expect(presenter.hostedEvidenceGroveMarkMotion() == nil, "glass keeps its voice bars")
            presenter.show(state: .transcribing)
            #expect(presenter.hostedEvidenceGroveMarkMotion() == .writing)
            #expect(presenter.hostedEvidenceGroveMark()?.reduceMotion == reduceMotion)
            presenter.show(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: true))
            #expect(presenter.hostedEvidenceGroveMarkMotion() == .written)
            #expect(presenter.hostedEvidenceGroveMark()?.lineEnd == 1)
            presenter.show(state: .noSpeechDetected)
            #expect(presenter.hostedEvidenceGroveMarkMotion() == nil)
            presenter.hide()
            #expect(!presenter.hostedEvidenceGroveMarkIsAnimating())
        }
    }

    @Test("The bars rest as dots in silence and follow the voice")
    func barsFollowTheVoice() {
        let presenter = makePresenter(placement: capsule)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceGroveBarHeights() == Array(repeating: 3, count: 11))
        for _ in 0..<GroveBarsView.delayedSamples { presenter.updateInputLevel(0.6) }
        let heights = presenter.hostedEvidenceGroveBarHeights()
        #expect(heights.count == 11)
        // At the reference level each bar reaches its profile height, 18 pt at most.
        #expect(abs(heights[3] - 18) < 0.5 && abs(heights[0] - 4.5) < 0.5)
        #expect(heights.allSatisfy { $0 >= 3 && $0 <= 18 })
        presenter.updateInputLevel(1)
        #expect(presenter.hostedEvidenceGroveBarHeights()[5] > heights[5])
        presenter.hide()
    }

    @Test("Under Reduce Motion the bars hold their shape and show the level in opacity")
    func barsReduceMotion() {
        let bars = GroveBarsView(frame: CGRect(x: 0, y: 0, width: 52.5, height: 18))
        bars.reduceMotion = true
        let still = bars.heights
        bars.setLevel(1)
        #expect(bars.heights == still)
    }

    @Test("The notch form puts the status row below the menu bar and the panel flush with the screen top")
    func notchPlacementApplies() throws {
        let presenter = makePresenter(placement: notch)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        let window = try #require(presenter.hostedEvidenceWindowFrame())
        #expect(window.maxY == Displays.notched.frame.maxY)
        let row = try #require(presenter.hostedEvidenceCapsuleFrame())
        #expect(row.minY >= Displays.notched.menuBarHeight)
        #expect(row.height == 32)
        #expect(presenter.hostedEvidencePlacement()?.isNotch == true)
        presenter.hide()
    }

    @Test("A display change while showing snaps to the new form without animating")
    func displayChangeSnaps() throws {
        let presenter = makePresenter(placement: notch)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        let notchFrame = try #require(presenter.hostedEvidenceWindowFrame())
        presenter.hostedEvidenceSetPlacement(.capsule(display: Displays.external))
        presenter.hostedEvidenceDisplaysChanged()
        let capsuleFrame = try #require(presenter.hostedEvidenceWindowFrame())
        #expect(presenter.hostedEvidencePlacement()?.isNotch == false)
        #expect(capsuleFrame != notchFrame)
        #expect(capsuleFrame.midX == Displays.external.frame.midX)
        #expect(!presenter.hostedEvidenceGroveIsAnimating())
        // And back.
        presenter.hostedEvidenceSetPlacement(notch)
        presenter.hostedEvidenceDisplaysChanged()
        let back = try #require(presenter.hostedEvidenceWindowFrame())
        // A window snaps to its screen's pixel grid; an unattached test window has a 1x grid.
        #expect(abs(back.midX - 863.5) <= 0.5)
        presenter.hide()
    }

    @Test("A hidden overlay decides again at its next show, not at the display change")
    func hiddenOverlayWaits() throws {
        let presenter = makePresenter(placement: notch)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        presenter.hide()
        presenter.hostedEvidenceSetPlacement(.capsule(display: Displays.external))
        presenter.hostedEvidenceDisplaysChanged()
        #expect(presenter.hostedEvidencePlacement() == nil)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(presenter.hostedEvidencePlacement() == .capsule(display: Displays.external))
        presenter.hide()
    }

    @Test("Reduce Motion: width changes, appearing and disappearing are cross-fades; otherwise the springs")
    func reduceMotionPaths() {
        for reduceMotion in [false, true] {
            for (placement, isNotch) in [(notch, true), (capsule, false)] {
                let presenter = makePresenter(placement: placement, reduceMotion: reduceMotion)
                presenter.show(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: true))
                presenter.show(state: .result(.microphoneAccessOff, showsWords: true))
                presenter.hostedEvidenceFinishPresentation()
                let log = presenter.hostedEvidenceMotionLog()
                let expected: [GroveMotion] = [
                    .appear(isNotch: isNotch, reduceMotion: reduceMotion),
                    .widthChange(reduceMotion: reduceMotion),
                    .disappear(isNotch: isNotch, reduceMotion: reduceMotion),
                ]
                #expect(log == expected, "reduceMotion \(reduceMotion), notch \(isNotch)")
                if reduceMotion {
                    // Nothing moves: a capsule appears at once, everything else cross-fades.
                    #expect(log.allSatisfy { if case .crossFade = $0 { true } else { $0 == GroveMotion.none } })
                    #expect(log.first == (isNotch ? .crossFade(0.14) : GroveMotion.none))
                } else {
                    #expect(log.contains(.widthSpring))
                    #expect(log.contains(isNotch ? .emergence : .none))
                    #expect(log.contains(isNotch ? .retract : .crossFade(0.15)))
                }
                #expect(!presenter.hostedEvidenceGroveIsAnimating())
            }
        }
    }

    @Test("A redraw nobody animates never cross-fades: the time ticking or the last-minute countdown")
    func tickDoesNotFade() {
        for reduceMotion in [false, true] {
            let presenter = makePresenter(placement: capsule, reduceMotion: reduceMotion)
            presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
            presenter.showRecordingLimitWarning(limitSeconds: 3600)
            #expect(presenter.hostedEvidenceSwapFades().isEmpty, "reduceMotion \(reduceMotion)")
            presenter.show(state: .transcribing)
            #expect(presenter.hostedEvidenceSwapFades() == [reduceMotion ? GroveMotion.reducedMotionFade : 0.12],
                    "reduceMotion \(reduceMotion)")
            presenter.hide()
        }
        #expect(WaveformOverlayPresenter.swapFade(changed: true, animated: false, reduceMotion: false, grove: true) == nil)
        #expect(WaveformOverlayPresenter.swapFade(changed: true, animated: false, reduceMotion: true, grove: true) == nil)
        #expect(WaveformOverlayPresenter.swapFade(changed: false, animated: true, reduceMotion: false, grove: true) == nil)
    }

    @Test("Nothing animates while hidden or idle")
    func nothingRunsWhileHidden() {
        let presenter = makePresenter()
        presenter.show(state: .transcribing)
        presenter.hide()
        #expect(!presenter.hostedEvidenceIsVisible())
        #expect(!presenter.hostedEvidenceGroveIsAnimating())
        #expect(presenter.hostedEvidenceGroveMarkMotion() == nil)
    }

    @Test("Reduce Transparency drops the shadow; Increase Contrast keeps a visible rim")
    func accessibilityStyles() throws {
        let transparent = makePresenter(reduceTransparency: true)
        transparent.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(transparent.hostedEvidenceGroveStyle()?.reduceTransparency == true)
        transparent.hide()
        let contrast = makePresenter(increaseContrast: true)
        contrast.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(contrast.hostedEvidenceGroveStyle()?.increaseContrast == true)
        contrast.hide()
    }

    @Test("The live words merge into the island: one container, three lines at most, radius 18")
    func cardInsideTheShape() throws {
        for form in [notch, capsule] {
            let presenter = makePresenter(placement: form)
            presenter.setLiveTranscriptEnabled(true)
            presenter.show(state: .listening(handsFree: true, elapsedSeconds: 9))
            let row = try #require(presenter.hostedEvidenceCapsuleFrame())
            let card = try #require(presenter.hostedEvidenceCardSize())
            #expect(card.width == 412)
            #expect(row.width == 412)
            let shape = try #require(presenter.hostedEvidenceGroveShape())
            // The shape reaches below the row to hold the words.
            #expect(shape.boundingBoxOfPath.maxY >= row.maxY + card.height - 0.5)
            #expect(presenter.hostedEvidencePanelSize().height > row.maxY + card.height)
            #expect(presenter.hostedEvidenceGroveLayout().maximumLines <= 3)
            presenter.hide()
        }
    }

    @Test("Leaving the live view folds the container back to a row as wide as the container was")
    func containerFolds() throws {
        let presenter = makePresenter(placement: capsule)
        presenter.setLiveTranscriptEnabled(true)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 9))
        let open = try #require(presenter.hostedEvidenceGroveShape()).boundingBoxOfPath
        presenter.show(state: .transcribing)
        let folded = try #require(presenter.hostedEvidenceGroveShape()).boundingBoxOfPath
        // Shorter, and never narrower than the listening island was.
        #expect(folded.height == 34 && folded.height < open.height && folded.width == open.width)
        presenter.hide()
    }

    @Test("A capsule hugs the state it shows, 34 pt tall")
    func widths() throws {
        let presenter = makePresenter(placement: capsule)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceCapsuleSize() == CGSize(width: 102.5, height: 34))
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        let handsFree = presenter.hostedEvidenceCapsuleSize()
        #expect(handsFree.height == 34 && handsFree.width > 102.5 && handsFree.width < 160)
        presenter.show(state: .result(.copied(.secureField), showsWords: true))
        let copied = presenter.hostedEvidenceCapsuleSize().width
        presenter.show(state: .result(.microphoneAccessOff, showsWords: true))
        let problem = presenter.hostedEvidenceCapsuleSize().width
        #expect(copied > handsFree.width && problem > 150 && problem < 412)
        presenter.hide()
    }

    @Test("Cancel stays available while holding, in hands-free and while transcribing")
    func cancelAvailability() {
        let presenter = makePresenter()
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceCancelIsAvailable() && !presenter.hostedEvidenceStopIsAvailable())
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceCancelIsAvailable() && presenter.hostedEvidenceStopIsAvailable())
        presenter.show(state: .transcribing)
        #expect(presenter.hostedEvidenceCancelIsAvailable() && !presenter.hostedEvidenceStopIsAvailable())
        presenter.hide()
    }
}

@Suite("Grove insert moment: the rules")
@MainActor
struct GroveInsertMomentRuleTests {
    private let inserted = OverlayState.result(.inserted(appName: "Mail", method: .typed), showsWords: true)

    @Test("The presenter applies the same rule to what it is offered")
    func presenterRule() {
        #expect(GroveInsertMoment.words(for: inserted, offered: "Hello") == "Hello")
        #expect(GroveInsertMoment.words(for: inserted, offered: nil) == nil)
        #expect(GroveInsertMoment.words(for: .result(.copied(.secureField), showsWords: true), offered: "hunter2") == nil)
        #expect(GroveInsertMoment.words(for: .result(.inserted(appName: "Mail", method: .typed), showsWords: false), offered: "Hello") == nil)
        #expect(GroveInsertMoment.words(for: .transcribing, offered: "Hello") == nil)
    }

    @Test("Never narrower than listening: the floor is the wider of the shell's minimum and the listening width")
    func floor() {
        #expect(GroveInsertMoment.minimumWidth(shell: 0, listening: 150) == 150)
        #expect(GroveInsertMoment.minimumWidth(shell: 205, listening: 150) == 205)
        #expect(GroveInsertMoment.minimumWidth(shell: 205, listening: nil) == 205)
    }

    private func model(_ state: OverlayState, words: String?) -> GroveRowModel {
        var result: OverlayResult?
        if case .result(let r, _) = state { result = r }
        return GroveRowModel.make(for: OverlayPresentation.make(for: state), result: result, insertWords: words)
    }

    @Test("The card says where it went in one string, with the words under it")
    func cardModel() {
        let card = model(inserted, words: "Move the planning meeting")
        #expect(card.primary == "Inserted into Mail" && card.primaryStyle == .verb && card.detail == "Move the planning meeting")
        #expect(card.appName == nil && card.lead == .mark(done: true) && card.tone == .forest)
        let pasted = model(.result(.inserted(appName: "Terminal", method: .pasted), showsWords: true), words: "ls -la")
        #expect(pasted.primary == "Pasted into Terminal" && pasted.detail == "ls -la")
        // Without words the result is the one line it always was.
        let plain = model(inserted, words: nil)
        #expect(plain.primary == "Inserted" && plain.appName == "Mail" && plain.detail == nil)
        // Words are ignored on anything that is not a successful insertion with words.
        #expect(model(.result(.copied(.secureField), showsWords: true), words: "hunter2").detail == nil)
        #expect(model(.result(.inserted(appName: "Mail", method: .typed), showsWords: false), words: "x").detail == nil)
    }

    @Test("The card is 62 pt tall, flush at 14 pt, with its words at most 360 pt wide")
    func cardLayout() throws {
        let measure: (String, NSFont) -> CGFloat = { text, _ in CGFloat(text.count) * 6 }
        let short = model(inserted, words: "Hello there")
        let layout = GroveRowLayout.makeCard(model: short, geometryScale: 1, textScale: 1, measure: measure)
        #expect(layout.height == 62)
        let mark = try #require(layout.frames[.mark]), verb = try #require(layout.frames[.primary]), words = try #require(layout.frames[.secondary])
        #expect(mark.minX == 14 && mark.minY == 10 && mark.size == CGSize(width: 22, height: 22))
        #expect(verb.minX == mark.maxX + 7 && words.minX == 14 && words.minY == mark.maxY + 5)
        #expect(layout.width == 2 * 14 + (22 + 7 + CGFloat("Inserted into Mail".count) * 6))
        let long = model(inserted, words: String(repeating: "x", count: 150))
        let wide = GroveRowLayout.makeCard(model: long, geometryScale: 1, textScale: 1, measure: measure)
        let wideWords = try #require(wide.frames[.secondary])
        #expect(wideWords.width == 360 && wide.width == 360 + 28)
        let floored = GroveRowLayout.makeCard(model: short, geometryScale: 1, textScale: 1, minimumWidth: 300, measure: measure)
        #expect(floored.width == 300)
        let capped = GroveRowLayout.makeCard(model: long, geometryScale: 1, textScale: 1, maximumWidth: 300, measure: measure)
        let cappedWords = try #require(capped.frames[.secondary])
        #expect(capped.width == 300 && cappedWords.width <= 300 - 28)
    }

    @Test("Right-to-left inserted words sit at the card's right inset; the verb stays at the left")
    func cardRightToLeft() throws {
        let measure: (String, NSFont) -> CGFloat = { text, _ in CGFloat(text.count) * 6 }
        for words in ["שלום, נדבר מחר", "سأتصل بك بعد الاجتماع"] {
            let card = GroveRowLayout.makeCard(model: model(inserted, words: words), geometryScale: 1, textScale: 1,
                                               minimumWidth: 400, measure: measure)
            let mark = try #require(card.frames[.mark]), verb = try #require(card.frames[.primary])
            let line = try #require(card.frames[.secondary])
            #expect(card.width == 400)
            #expect(line.maxX == 400 - 14 && line.width == CGFloat(words.count) * 6, "\(words)")
            #expect(mark.minX == 14 && verb.minX == mark.maxX + 7)
        }
        let latin = GroveRowLayout.makeCard(model: model(inserted, words: "Hello there"), geometryScale: 1, textScale: 1,
                                            minimumWidth: 400, measure: measure)
        #expect(try #require(latin.frames[.secondary]).minX == 14)
    }
}

@Suite("Grove insert moment: the island", .serialized)
@MainActor
struct GroveInsertMomentPresenterTests {
    private let notch = OverlayPlacement.notch(display: Displays.notched, notch: Displays.notched.notch!)
    private let capsule = OverlayPlacement.capsule(display: Displays.notched)
    private let mail = OverlayState.result(.inserted(appName: "Mail", method: .typed), showsWords: true)
    private let words = "Move the planning meeting from Thursday to Friday and send the agenda"

    private func makePresenter(placement: OverlayPlacement, reduceMotion: Bool = false, live: Bool = false) -> WaveformOverlayPresenter {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: reduceMotion, reduceTransparency: false, increaseContrast: false, preferredBodyPointSize: 13
        ))
        presenter.hostedEvidenceSetPlacement(placement)
        presenter.setLiveTranscriptEnabled(live)
        presenter.setStopAction {}
        presenter.onCopyResult = {}
        presenter.onUndoDiscard = {}
        presenter.onOpenSettings = { _ in }
        presenter.groveAppIconProvider = { _ in nil }
        presenter.appearance = .grove
        return presenter
    }

    private func width(_ presenter: WaveformOverlayPresenter) -> CGFloat { presenter.hostedEvidenceCapsuleSize().width }

    @Test("Nothing between listening and its result is narrower than listening", arguments: [true, false])
    func neverShrinks(notch isNotch: Bool) {
        for handsFree in [false, true] {
            for live in [false, true] {
                let presenter = makePresenter(placement: isNotch ? notch : capsule, live: live)
                presenter.show(state: .listening(handsFree: handsFree, elapsedSeconds: 3))
                let listening = width(presenter)
                #expect(presenter.hostedEvidenceListeningWidth() == listening)
                let after: [(String, OverlayState, String?)] = [
                    ("transcribing", .transcribing, nil),
                    ("inserted", mail, words),
                    ("inserted without words", mail, nil),
                    ("brief", .result(.inserted(appName: "Mail", method: .typed), showsWords: false), nil),
                    ("pasted", .result(.inserted(appName: "Terminal", method: .pasted), showsWords: true), "ls -la"),
                    ("copied", .result(.copied(.other), showsWords: true), nil),
                    ("password copy", .result(.copied(.secureField), showsWords: true), nil),
                    ("no speech", .noSpeechDetected, nil),
                    ("error", .result(.transcriptionFailed, showsWords: true), nil),
                    ("problem", .result(.failed(savedInHistory: true), showsWords: true), nil),
                ]
                for (name, state, offered) in after {
                    presenter.show(state: state, insertedWords: offered)
                    #expect(width(presenter) >= listening, "\(isNotch ? "notch" : "capsule") handsFree=\(handsFree) live=\(live) \(name)")
                    presenter.show(state: .listening(handsFree: handsFree, elapsedSeconds: 3))
                    #expect(width(presenter) == listening)
                    presenter.show(state: .transcribing)
                }
                presenter.hide()
                #expect(presenter.hostedEvidenceListeningWidth() == nil)
            }
        }
    }

    @Test("Transcribing keeps the width and says Transcribing beside the mark", arguments: [true, false])
    func writing(notch isNotch: Bool) throws {
        let presenter = makePresenter(placement: isNotch ? notch : capsule)
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 2))
        let listening = width(presenter)
        presenter.show(state: .transcribing)
        let model = try #require(presenter.hostedEvidenceGroveModel())
        #expect(model.primary == "Transcribing" && model.lead == .mark(done: false))
        #expect(width(presenter) >= listening && presenter.hostedEvidenceCapsuleSize().height == (isNotch ? 32 : 34))
        let frames = presenter.hostedEvidenceGroveRowFrames()
        let mark = try #require(frames[.mark]), word = try #require(frames[.primary]), cancel = try #require(frames[.cancel])
        #expect(mark.maxX < word.minX && word.maxX < cancel.minX)
        presenter.hide()
    }

    @Test("A successful result grows into a two-line card at least as wide as listening", arguments: [true, false])
    func card(notch isNotch: Bool) throws {
        let presenter = makePresenter(placement: isNotch ? notch : capsule)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 2))
        let listening = width(presenter)
        presenter.show(state: mail, insertedWords: words)
        let size = presenter.hostedEvidenceCapsuleSize()
        #expect(size.height == 62 && size.width >= listening && size.width <= 360 + 28)
        #expect(presenter.hostedEvidenceInsertDetail() == words)
        let shape = try #require(presenter.hostedEvidenceGroveShape()).boundingBoxOfPath
        let layout = presenter.hostedEvidenceGroveLayout()
        #expect(abs(shape.maxY - (layout.rowTop + 62)) < 0.5)
        #expect(presenter.hostedEvidencePanelSize().height >= layout.rowTop + 62)
        let frames = presenter.hostedEvidenceGroveRowFrames()
        let line2 = try #require(frames[.secondary])
        #expect(line2.width <= 360 && line2.maxX <= size.width - 14 + 0.5)
        presenter.show(state: .result(.inserted(appName: "Terminal", method: .pasted), showsWords: true), insertedWords: "ls -la")
        #expect(presenter.hostedEvidenceGroveModel()?.primary == "Pasted into Terminal" && presenter.hostedEvidenceCapsuleSize().height == 62)
        presenter.hide()
    }

    @Test("The card stays at full size with its words until the overlay hides; no timer narrows it", arguments: [true, false])
    func staysAtFullSize(notch isNotch: Bool) throws {
        let presenter = makePresenter(placement: isNotch ? notch : capsule)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 2))
        presenter.show(state: mail, insertedWords: words)
        let card = presenter.hostedEvidenceCapsuleSize()
        let motions = presenter.hostedEvidenceMotionLog()
        // Long enough for the timer that used to fold the card (0.4 s into a 2 s result) to have fired.
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        #expect(presenter.hostedEvidenceCapsuleSize() == card && card.height == 62)
        #expect(presenter.hostedEvidenceInsertDetail() == words)
        #expect(presenter.hostedEvidenceGroveModel()?.primary == "Inserted into Mail")
        #expect(presenter.hostedEvidenceMotionLog() == motions)
        presenter.hide()
        #expect(!presenter.hostedEvidenceHoldsInsertedWords())
    }

    @Test("Reduce Motion keeps the card at full size too")
    func reducedMotionKeepsCard() {
        let presenter = makePresenter(placement: capsule, reduceMotion: true)
        presenter.show(state: mail, insertedWords: words)
        let motions = presenter.hostedEvidenceMotionLog()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        #expect(presenter.hostedEvidenceCapsuleSize().height == 62 && presenter.hostedEvidenceInsertDetail() == words)
        #expect(presenter.hostedEvidenceMotionLog() == motions)
        presenter.hide()
    }

    @Test("Words never show for a concealed copy, a copy, a brief confirmation, or when none are offered")
    func noWords() {
        let presenter = makePresenter(placement: capsule)
        let refused: [(String, OverlayState, String?)] = [
            ("secure field copy", .result(.copied(.secureField), showsWords: true), "hunter2"),
            ("copy", .result(.copied(.other), showsWords: true), "hunter2"),
            ("brief", .result(.inserted(appName: "Mail", method: .typed), showsWords: false), "hunter2"),
            ("no words", mail, nil),
            ("blank words", mail, "   \n "),
            ("problem", .result(.failed(savedInHistory: true), showsWords: true), "hunter2"),
            ("transcribing", .transcribing, "hunter2"),
        ]
        for (name, state, offered) in refused {
            presenter.show(state: state, insertedWords: offered)
            #expect(presenter.hostedEvidenceInsertDetail() == nil, "\(name)")
            #expect(!presenter.hostedEvidenceHoldsInsertedWords(), "\(name)")
            #expect(presenter.hostedEvidenceCapsuleSize().height == 34, "\(name)")
        }
        presenter.hide()
    }

    @Test("A new state drops the words; the quill overlay never shows them")
    func wordsAreEphemeral() {
        let presenter = makePresenter(placement: capsule)
        presenter.show(state: mail, insertedWords: words)
        #expect(presenter.hostedEvidenceHoldsInsertedWords())
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(!presenter.hostedEvidenceHoldsInsertedWords())
        presenter.hide()

        let quill = makePresenter(placement: capsule)
        quill.appearance = .quill
        quill.show(state: mail, insertedWords: words)
        #expect(!quill.hostedEvidenceHoldsInsertedWords() && quill.hostedEvidenceCapsuleSize().height == 40)
        quill.hide()
    }

    @Test("Nothing animates once the overlay hides")
    func quietWhenHidden() {
        let presenter = makePresenter(placement: notch)
        presenter.show(state: .transcribing)
        presenter.show(state: mail, insertedWords: words)
        presenter.hide()
        #expect(!presenter.hostedEvidenceGroveIsAnimating())
    }
}
#endif
