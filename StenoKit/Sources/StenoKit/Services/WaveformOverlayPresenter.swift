#if os(macOS)
import AppKit
import QuartzCore

#if DEBUG
enum WaveformOverlayHostedEvidenceEvent: Equatable {
    case listeningPresented(elapsedMilliseconds: Double)
    case previewAccepted(queueDepth: Int, totalCoalesced: UInt64)
    case previewRendered(
        mainActorWorkMilliseconds: Double,
        renderStartedMonotonicMilliseconds: Double,
        sessionID: UUID,
        revision: UInt64?
    )
    case previewCleared
}
#endif

/// The recording overlay: the forest glass island at the top of the active display, grown out of
/// the notch where there is one, with an optional live-words card below it.
///
/// AppKit and Core Animation only. The panel is created once, never becomes key and passes
/// clicks through everywhere except its buttons. Input level writes go straight to the quill's
/// layers; nothing here publishes state to SwiftUI.
@MainActor
public final class WaveformOverlayPresenter: OverlayPresenter {
    private var window: NSPanel?
    private var wrapperView: OverlayPassthroughContainer?
    private var capsule: OverlayCapsuleView?
    private var nibView: OverlayNibView?
    private var textField: NSTextField?
    private var timeField: NSTextField?
    private var keyHintView: OverlayCapsuleControl?
    private var stopButton: OverlayCapsuleControl?
    private var actionButton: OverlayCapsuleControl?
    private var cancelButton: OverlayCapsuleControl?
    private var card: OverlayCardView?
    private var transcriptField: OverlayTranscriptView?
    private var cardMessageField: NSTextField?

    private var transcriptLayout: OverlayTranscriptLayout?
    private var transcriptSnapshot = OverlayTranscriptViewportSnapshot.empty
    /// Lines the card has grown to this session. It never shrinks while listening.
    private var attainedTranscriptLines = 1
    private var lastRenderedSnapshot: LiveTranscriptionSnapshot?

    private var selectedAppearance: NSAppearance?
    private var stopAction: (() -> Void)?
    private var cancelAction: (() -> Void)?
    public var onUndoDiscard: (() -> Void)?
    public var onCopyResult: (() -> Void)?
    /// Opens the settings that fix a problem result, such as the Microphone privacy pane.
    public var onOpenSettings: ((OverlayResult) -> Void)?

    private var cancelButtonVisible = false
    /// Cancel stays available while the final transcription runs, so a slow
    /// or stalled transcription can always be abandoned.
    private var transcriptionCancelAvailable = false
    private var elapsedTimer: Timer?
    private var listeningStartDate: Date?
    private var listeningHandsFree = false
    /// Set once the session nears its length limit; the elapsed time then
    /// gives way to a countdown.
    private var recordingLimitSeconds: Int?
    /// Advances on every state change, so a timer never overwrites a newer state.
    private var presentationGeneration: UInt64 = 0
    private var wasHidden = true
    private var configuredLiveTranscriptEnabled = true
    private var liveTranscriptEnabled = true
    private var listeningSessionIsActive = false
    private var liveTranscriptSession: LiveTranscriptionSession?
    private var lastReceivedLiveRevision: UInt64?
    private var liveRenderBuffer = OverlayLiveRenderBuffer()
    private var liveRenderTimer: Timer?
    private var liveRenderTimerToken: UUID?
    private var lastLiveRenderTime: TimeInterval?
    private var livePreviewUnavailable = false
    private var liveUpdateGate = OverlayLiveUpdateGate()
    private var pinnedScreenFrame: NSRect?
    private var captureTargetPoint: NSPoint?
    private var lastAnnouncement: OverlayAnnouncement?
    private var announcementGate = OverlayAnnouncementGate()
    private var accentColor = WaveformOverlayPresenter.defaultAccent
    private var sourceAccentColor = WaveformOverlayPresenter.defaultAccent
    private var accessibilityObserver: NSObjectProtocol?

    /// The look of the overlay. `.grove`, the look the app ships, is the forest glass overlay that
    /// grows out of the notch on a notched built-in display and floats as a capsule everywhere
    /// else. `.quill`, the earlier indigo capsule, is drawn only when a caller sets it. A change
    /// takes effect at once.
    public var appearance: OverlayAppearanceStyle = .grove {
        didSet {
            guard appearance != oldValue else { return }
            appearanceStyleChanged()
        }
    }
    private var groveRow: GroveSurfaceView?
    private var groveBars: GroveBarsView?
    private var groveMark: BrandMarkView?
    private var groveSymbol: GroveSymbolView?
    /// The visible words of the row. The status field keeps the presentation's own label, hidden,
    /// for VoiceOver and for anything that reads what the overlay says.
    private var groveLabelField: NSTextField?
    private var groveSecondaryField: NSTextField?
    private var groveAppIcon: NSImageView?
    /// What the row shows now; the layout and the views follow it.
    private var groveModel: GroveRowModel?
    /// The words and result behind the current presentation, for what a presentation does not carry.
    private var groveResultContext: OverlayResult?
    /// Finds the icon of the app a result went to. Replaced in tests.
    var groveAppIconProvider: (String) -> NSImage? = { WaveformOverlayPresenter.defaultAppIcon(named: $0) }
    private var grovePlacement: OverlayPlacement?
    /// Where the session's capsule goes: the display under this point.
    private var groveTargetPoint: CGPoint?
    private let groveContentMask = CAShapeLayer()
    private var groveRowWidth: CGFloat?
    private var groveRowHeight: CGFloat?
    private var groveRowRadius: CGFloat?
    /// The width of the listening island, kept until the overlay hides: nothing that follows it
    /// is narrower.
    private var groveListeningWidth: CGFloat?
    /// The first line of the inserted words, while a result that may show them is up.
    private var groveInsertWords: String?
    private var groveScreenObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var groveScreenChangeGeneration: UInt64 = 0
    private var isRetracting = false
    /// Set at the start of a show: the overlay was hidden, so this show is its appearance.
    private var groveIsAppearing = false
    /// Set around a layout that should spring: live words adding a line.
    private var groveAnimateNextLayout = false

    private var currentState: OverlayState?
    private var currentPresentation: OverlayPresentation?
    private var currentResult: OverlayResult?
    /// What a notice gives way to when its time is up.
    private var noticeReturn: (presentation: OverlayPresentation, timer: OverlayResultTimer)?
    private var noticeReturnsToHidden = false
    private var resultTimer = OverlayResultTimer()
    private var resultTimerTask: Timer?
    private var pointerMovedSinceState = false
    private var isFadingOut = false
    /// Monotonic seconds; replaceable in tests.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    #if DEBUG
    private var hostedEvidenceHandler: ((WaveformOverlayHostedEvidenceEvent) -> Void)?
    private var hostedAccessibilityPreferencesOverride: OverlayAccessibilityPreferences?
    private var hostedPlacement: OverlayPlacement?
    private var hostedMotionLog: [GroveMotion] = []
    private var hostedSwapFades: [TimeInterval] = []
    private var rendersOffscreen = false
    private var hostedEvidencePresentedStates: [OverlayState] = []
    private var hostedEvidenceOfferedWords: [String?] = []
    private var hostedEvidenceAnnouncements: [String] = []
    private var hostedTraceHandler: ((String) -> Void)?
    #endif

    private static let defaultAccent = NSColor(red: 21.0 / 255.0, green: 93.0 / 255.0, blue: 168.0 / 255.0, alpha: 1.0)

    private var accessibilityPreferences: OverlayAccessibilityPreferences {
        #if DEBUG
        if let hostedAccessibilityPreferencesOverride {
            return hostedAccessibilityPreferencesOverride
        }
        #endif
        return OverlayAccessibilityPreferences(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            preferredBodyPointSize: NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize
        )
    }

    private var metrics: OverlayAccessibilityMetrics {
        OverlayAccessibilityMetrics(preferences: accessibilityPreferences, appearance: appearance)
    }

    private var increaseContrast: Bool { accessibilityPreferences.increaseContrast }

    private var visibleFrameSize: CGSize? {
        if appearance == .grove, let grovePlacement { return grovePlacement.display.visibleFrame.size }
        return pinnedScreenFrame?.size ?? window?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size
    }

    private var transcriptLineCapacity: Int {
        OverlayPanelLayoutPolicy.transcriptLineCapacity(metrics: metrics, visibleFrameSize: visibleFrameSize)
    }

    private var activePanelSize: NSSize {
        if appearance == .grove { return groveLayout.panelSize }
        return OverlayPanelLayoutPolicy.panelSize(
            metrics: metrics,
            showsTranscript: showsLiveTranscriptPanel,
            transcriptLines: min(attainedTranscriptLines, transcriptLineCapacity),
            visibleFrameSize: visibleFrameSize
        )
    }

    private var showsLiveTranscriptPanel: Bool {
        listeningSessionIsActive && liveTranscriptEnabled
    }

    // MARK: - Lifecycle

    public init(observeAccessibilityChanges: Bool = true) {
        guard observeAccessibilityChanges else { return }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accessibilityChanged()
            }
        }
        // The notch overlay re-resolves where it goes when the displays change and after sleep.
        let screenChanges: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
        ]
        for (center, name) in screenChanges {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.groveDisplaysChanged()
                }
            }
            groveScreenObservers.append((center, token))
        }
    }

    isolated deinit {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        resultTimerTask?.invalidate()
        resultTimerTask = nil
        liveRenderTimer?.invalidate()
        liveRenderTimer = nil
        liveRenderTimerToken = nil
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
        for observer in groveScreenObservers { observer.center.removeObserver(observer.token) }
        groveScreenObservers = []
    }

    // MARK: - OverlayPresenter

    public func prepareWindow() {
        ensureWindow()
    }

    public func setCancelAction(_ action: (() -> Void)?) {
        cancelAction = action
    }

    public func setStopAction(_ action: (() -> Void)?) {
        stopAction = action
        if listeningSessionIsActive, let currentPresentation { apply(currentPresentation, animated: false) }
    }

    /// The overlay keeps its own colours whatever the accent; the accent is kept for callers
    /// that read it back.
    public func updateAccentColor(_ color: NSColor, glowColor: NSColor? = nil) {
        sourceAccentColor = color
        resolveAccentColor()
        _ = glowColor
    }

    /// Follow the app's explicit appearance; nil follows the system appearance.
    public func updateAppearance(_ appearance: NSAppearance?) {
        selectedAppearance = appearance
        window?.appearance = appearance
        resolveAccentColor()
        applyAccessibilityAppearance()
        rerenderCurrentTranscriptIfNeeded()
    }

    public func setLiveTranscriptEnabled(_ isEnabled: Bool) {
        configuredLiveTranscriptEnabled = isEnabled
        liveUpdateGate.setConfiguredEnabled(isEnabled)
        guard !listeningSessionIsActive else { return }
        liveTranscriptEnabled = isEnabled
    }

    public func pinNextSessionToDisplay(containing targetPoint: CGPoint?) {
        guard !listeningSessionIsActive else { return }
        captureTargetPoint = targetPoint
        pinnedScreenFrame = nil
    }

    /// 0...1, already smoothed by the meter. Writes one layer property path on the quill.
    public func updateInputLevel(_ level: Float) {
        guard listeningSessionIsActive else { return }
        if appearance == .grove {
            groveBars?.setLevel(level)
            groveMark?.setLevel(level)
        } else {
            nibView?.nib.setLevel(level)
        }
    }

    public func updateLiveTranscript(_ snapshot: LiveTranscriptionSnapshot) {
        guard liveUpdateGate.accept(snapshot) else { return }

        liveTranscriptSession = snapshot.session
        lastReceivedLiveRevision = snapshot.lastAcceptedRevision

        liveRenderBuffer.enqueue(snapshot)
        #if DEBUG
        hostedEvidenceHandler?(.previewAccepted(
            queueDepth: liveRenderBuffer.pendingSnapshot == nil ? 0 : 1,
            totalCoalesced: liveRenderBuffer.coalescedSnapshotCount
        ))
        #endif
        scheduleLiveRenderIfNeeded()
    }

    public func showLiveTranscriptUnavailable() {
        guard liveUpdateGate.markUnavailable() else { return }
        livePreviewUnavailable = true
        liveRenderBuffer.clear()
        liveRenderTimer?.invalidate()
        liveRenderTimer = nil
        liveRenderTimerToken = nil
        clearLiveTranscriptContent()
        updateCardMessage()
        resizePanelForCurrentSession()
        centerWindowNearTop()
    }

    public func show(state: OverlayState) {
        show(state: state, insertedWords: nil)
    }

    public func show(state: OverlayState, insertedWords: String?) {
        #if DEBUG
        let hostedCallStart: TimeInterval? = ProcessInfo.processInfo.systemUptime
        hostedEvidencePresentedStates.append(state)
        hostedEvidenceOfferedWords.append(insertedWords)
        #else
        let hostedCallStart: TimeInterval? = nil
        #endif
        hostedTrace("show \(state) hidden=\(wasHidden) fading=\(isFadingOut)")
        if case .listening = state, !listeningSessionIsActive, !wasHidden, currentState != .transcribing {
            // A new dictation over a result or a notice, or over its leaving, starts from nothing,
            // as one over a hidden overlay does: never out of the card's shape or with its words.
            let target = captureTargetPoint
            hide()
            captureTargetPoint = target
        }
        ensureWindow()
        if appearance == .grove {
            groveIsAppearing = wasHidden
            groveResolvePlacement(for: state)
        }

        if case .listening(let handsFree, _) = state, listeningSessionIsActive {
            listeningHandsFree = handsFree
            currentState = state
            refreshListeningPresentation(animated: true)
            scheduleElapsedTimer()
            return
        }

        let previous = currentPresentation
        let wasShowing = !wasHidden && !isFadingOut
        presentationGeneration &+= 1
        cancelFadeOut()
        cancelResultTimer()
        wasHidden = false
        currentResult = nil

        let presentation: OverlayPresentation
        switch state {
        case .listening(let handsFree, let elapsedSeconds):
            liveTranscriptEnabled = configuredLiveTranscriptEnabled
            listeningSessionIsActive = true
            liveUpdateGate.beginListening()
            liveTranscriptSession = nil
            lastReceivedLiveRevision = nil
            livePreviewUnavailable = false
            liveRenderBuffer.clear()
            lastLiveRenderTime = nil
            lastAnnouncement = nil
            announcementGate.beginSession()
            pinnedScreenFrame = nil
            groveInsertWords = nil
            groveListeningWidth = nil
            clearLiveTranscriptContent()
            attainedTranscriptLines = 1
            listeningHandsFree = handsFree
            recordingLimitSeconds = nil
            noticeReturn = nil
            listeningStartDate = Date().addingTimeInterval(-TimeInterval(max(0, elapsedSeconds)))
            transcriptionCancelAvailable = false
            presentation = OverlayPresentation.make(for: state)
            currentState = state
            nibView?.nib.setLevel(0)
            groveBars?.reset()
            resizePanelForCurrentSession()
            apply(presentation, animated: false)
            updateCardMessage()
            scheduleElapsedTimer()
            announceOnce(.sessionStarted, message: presentation.announcement ?? "Listening")

        case .busy:
            presentation = OverlayPresentation.make(for: state)
            presentNotice(presentation, returningTo: wasShowing ? previous : nil)
            postAnnouncement(presentation.announcement)
            finishShow(state: state, hostedCallStart: nil)
            return

        default:
            let previousWidth = previous?.width
            endListeningPresentation()
            stopElapsedTimer()
            noticeReturn = nil
            transcriptionCancelAvailable = state == .transcribing
            presentation = OverlayPresentation.make(for: state, previousWidth: previousWidth)
            currentState = state
            if case .result(let result, _) = state { currentResult = result }
            groveInsertWords = appearance == .grove ? GroveInsertMoment.words(for: state, offered: insertedWords) : nil
            groveResultContext = currentResult
            resizePanelForCurrentSession()
            apply(presentation, animated: wasShowing)
            announce(for: state, presentation: presentation)
            startResultTimerIfNeeded(for: presentation)
        }

        finishShow(state: state, hostedCallStart: hostedCallStart)
    }

    private func finishShow(state: OverlayState, hostedCallStart: TimeInterval?) {
        centerWindowNearTop()
        presentWindow()
        #if DEBUG
        if case .listening = state, let hostedCallStart {
            hostedEvidenceHandler?(.listeningPresented(
                elapsedMilliseconds: max(0, (ProcessInfo.processInfo.systemUptime - hostedCallStart) * 1_000)
            ))
        }
        #endif
    }

    /// Announces a result to VoiceOver without showing anything, for a successful insert
    /// when the overlay is set to show nothing.
    public func announce(result: OverlayResult) {
        let presentation = OverlayPresentation.make(for: .result(result, showsWords: true))
        postAnnouncement(presentation.announcement)
    }

    /// Called when the controller has nothing more to show for a dictation. A timed result
    /// keeps its own time (and stays while the pointer rests on it); anything else hides now.
    public func finishResultPresentation() {
        if !wasHidden, currentPresentation?.isTimed == true, resultTimer.isRunning || isFadingOut {
            return
        }
        hide()
    }

    /// Warns that the listening session stops automatically once it has run
    /// for `limitSeconds`, replacing the elapsed time with a countdown.
    public func showRecordingLimitWarning(limitSeconds: Int) {
        guard listeningSessionIsActive, recordingLimitSeconds == nil else { return }
        recordingLimitSeconds = limitSeconds
        refreshListeningPresentation(animated: false)
        scheduleElapsedTimer()
        postAnnouncement("Recording stops in one minute", priority: .high)
    }

    /// Briefly shows a message without changing the current state. The previous
    /// content returns afterwards, and an overlay that was hidden hides again.
    public func showNotice(_ message: String, duration: Duration = .seconds(1.6)) {
        ensureWindow()
        if appearance == .grove {
            groveIsAppearing = wasHidden
            groveResolvePlacement(for: nil)
        }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let notice = OverlayPresentation(
            width: .handsFree, nib: .working, mark: nil, label: message, tone: .quiet, time: nil,
            keyHint: nil, action: nil, showsStop: false, showsDiscard: false, duration: seconds,
            restoresPrevious: true, announcement: message
        )
        let wasShowing = !wasHidden && !isFadingOut
        presentNotice(notice, returningTo: wasShowing ? currentPresentation : nil)
        postAnnouncement("Steno: \(message)")
        centerWindowNearTop()
        presentWindow()
    }

    public func hide() {
        hostedTrace("hide begin")
        presentationGeneration &+= 1
        if listeningSessionIsActive {
            announceOnce(.cancelled, message: "Steno dictation canceled")
        }
        endListeningPresentation()
        stopElapsedTimer()
        cancelResultTimer()
        // A fade or retraction in progress is not undone on screen: the panel leaves as it is.
        isFadingOut = false
        hideCancelControl()
        noticeReturn = nil
        wasHidden = true
        currentState = nil
        currentPresentation = nil
        currentResult = nil
        groveInsertWords = nil
        groveListeningWidth = nil
        pinnedScreenFrame = nil
        captureTargetPoint = nil
        liveTranscriptSession = nil
        lastReceivedLiveRevision = nil
        lastAnnouncement = nil
        announcementGate.endPresentation()
        if appearance == .grove { groveWillOrderOut() }
        // The card's words are not kept once the overlay is off screen.
        groveModel?.detail = nil
        hostedTrace("orderOut")
        window?.orderOut(nil)
        // Restored only once off screen: a faded panel made opaque while still ordered in shows
        // its last state again.
        window?.contentView?.layer?.removeAnimation(forKey: Self.fadeOutKey)
        window?.alphaValue = 1
    }

    // MARK: - Presentation

    private func presentNotice(_ notice: OverlayPresentation, returningTo previous: OverlayPresentation?) {
        presentationGeneration &+= 1
        cancelFadeOut()
        if noticeReturn == nil {
            if let previous {
                noticeReturn = (previous, resultTimer)
                noticeReturnsToHidden = false
            } else {
                noticeReturnsToHidden = true
            }
        }
        resultTimerTask?.invalidate()
        resultTimerTask = nil
        if wasHidden {
            wasHidden = false
            resizePanelForCurrentSession()
        }
        apply(notice, animated: previous != nil)
        startResultTimerIfNeeded(for: notice)
    }

    private func refreshListeningPresentation(animated: Bool) {
        guard listeningSessionIsActive else { return }
        let elapsed = listeningStartDate.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let presentation = OverlayPresentation.make(
            for: .listening(handsFree: listeningHandsFree, elapsedSeconds: elapsed),
            limitSeconds: recordingLimitSeconds
        )
        if noticeReturn != nil {
            noticeReturn?.presentation = presentation
            return
        }
        apply(presentation, animated: animated && presentation.width != currentPresentation?.width)
    }

    /// How long new content cross-fades over the old, or nil for none. Only a change the caller
    /// animates fades: 0.12 s, or under Reduce Motion 0.14 s in place of the Grove width spring.
    /// A redraw the caller does not animate, such as the elapsed time ticking, never fades.
    static func swapFade(changed: Bool, animated: Bool, reduceMotion: Bool, grove: Bool) -> TimeInterval? {
        guard changed, animated else { return nil }
        if !reduceMotion { return 0.12 }
        return grove ? GroveMotion.reducedMotionFade : nil
    }

    /// Draws `presentation` into the capsule. Width changes animate once; content swaps
    /// cross-fade. Neither runs under Reduce Motion.
    private func apply(_ presentation: OverlayPresentation, animated: Bool) {
        ensureWindow()
        guard let capsule, let nibView, let textField, let timeField else { return }
        let previous = currentPresentation
        currentPresentation = presentation
        let reduceMotion = accessibilityPreferences.reduceMotion
        let shouldAnimate = animated && !reduceMotion && previous != nil
        #if DEBUG
        let animate = shouldAnimate && !rendersOffscreen
        #else
        let animate = shouldAnimate
        #endif

        let swapFade = Self.swapFade(changed: previous != nil && previous != presentation, animated: animated,
                                     reduceMotion: reduceMotion, grove: appearance == .grove)
        #if DEBUG
        if let swapFade { hostedSwapFades.append(swapFade) }
        #endif
        if let swapFade, !isOffscreenRender {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = swapFade
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            capsule.layer?.add(fade, forKey: "steno.overlay.swap")
        }

        if appearance == .grove {
            groveApply(presentation, previous: previous, animate: animate, animated: animated, reduceMotion: reduceMotion)
            return
        }

        nibView.nib.reduceMotion = reduceMotion
        nibView.nib.setMode(presentation.nib)
        nibView.isHidden = false
        nibView.nib.setResultMark(presentation.mark)

        textField.stringValue = presentation.label
        textField.toolTip = presentation.label
        textField.setAccessibilityValue(presentation.label)
        textField.font = labelFont(for: presentation.tone)
        textField.textColor = labelColor(for: presentation.tone)
        timeField.stringValue = presentation.time ?? ""
        timeField.isHidden = presentation.time == nil
        timeField.font = timeFont
        timeField.textColor = quietColor

        keyHintView?.title = presentation.keyHint ?? ""
        keyHintView?.isHidden = presentation.keyHint == nil

        let stopAvailable = presentation.showsStop && stopAction != nil && listeningSessionIsActive
        stopButton?.isHidden = !stopAvailable
        stopButton?.isEnabled = stopAvailable

        let action = presentation.action.flatMap { actionIsWired($0) ? $0 : nil }
        actionButton?.title = action?.title ?? ""
        actionButton?.setAccessibilityLabel(action?.title)
        actionButton?.isHidden = action == nil
        actionButton?.isEnabled = action != nil

        if presentation.showsDiscard {
            cancelButtonVisible = true
            // A notice hides the control and clears this flag; showing the control again while
            // the transcription still runs must make its press work again.
            if currentState == .transcribing { transcriptionCancelAvailable = true }
            cancelButton?.isHidden = false
            cancelButton?.isEnabled = true
            cancelButton?.alphaValue = 1
        } else {
            hideCancelControl()
        }

        let width = capsuleWidth(for: presentation)
        layoutCapsule(width: width, animated: animate && previous?.width != presentation.width)
        pointerMovedSinceState = false
        capsule.setAccessibilityLabel(presentation.announcement ?? presentation.label)
    }

    private func actionIsWired(_ action: OverlayPresentation.Action) -> Bool {
        switch action {
        case .copy: onCopyResult != nil
        case .undo: onUndoDiscard != nil
        case .openSettings: onOpenSettings != nil
        }
    }

    private func capsuleWidth(for presentation: OverlayPresentation) -> CGFloat {
        let inner = (window?.contentView?.bounds.width ?? activePanelSize.width) - OverlayPanelLayoutPolicy.shadowMargins.horizontal
        return min(metrics.capsuleWidth(presentation.width), max(metrics.capsuleHeight * 2, inner))
    }

    // MARK: - Window setup

    private func ensureWindow() {
        if window != nil { return }

        if appearance == .grove { groveResolvePlacement(for: nil) }
        let size = activePanelSize
        let contentRect = NSRect(origin: .zero, size: size)
        let panel = OverlayPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.appearance = selectedAppearance
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        // The layers draw the only shadows.
        panel.hasShadow = false
        // ignoresMouseEvents stays unset: a click on the transparent margin around the capsule
        // then goes to the window below. Setting it to false makes the panel take every click
        // in its frame.
        panel.becomesKeyOnlyIfNeeded = true
        // The overlay draws its own appearance and leaving. The system's fade on order-out would
        // run after them, from whatever the panel last showed, and hold back the next show.
        panel.animationBehavior = .none
        configureWindowLevel(of: panel)

        let wrapper = OverlayPassthroughContainer(frame: contentRect)
        wrapper.autoresizingMask = [.width, .height]
        wrapper.wantsLayer = true
        wrapper.appearanceDidChange = { [weak self] in
            guard let self else { return }
            self.resolveAccentColor()
            self.applyAccessibilityAppearance()
        }

        let card = OverlayCardView(frame: .zero)
        card.isHidden = true
        let transcript = OverlayTranscriptView(frame: .zero)
        transcript.setAccessibilityValue("")
        card.addSubview(transcript)
        let cardMessage = NSTextField(labelWithString: "")
        cardMessage.lineBreakMode = .byTruncatingTail
        cardMessage.maximumNumberOfLines = 1
        cardMessage.isHidden = true
        card.addSubview(cardMessage)

        let capsule = OverlayCapsuleView(frame: .zero)
        capsule.hoverChanged = { [weak self] event in self?.pointerEvent(event) }
        let nib = OverlayNibView(frame: .zero)
        capsule.addSubview(nib)

        let label = NSTextField(labelWithString: "")
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.setAccessibilityLabel("Dictation status")
        capsule.addSubview(label)

        let time = NSTextField(labelWithString: "")
        time.alignment = .left
        time.isHidden = true
        time.setAccessibilityLabel("Elapsed time")
        capsule.addSubview(time)

        let keyHint = OverlayCapsuleControl(style: .keycap)
        keyHint.isHidden = true
        capsule.addSubview(keyHint)

        let stop = OverlayCapsuleControl(style: .stop)
        stop.title = "Stop"
        stop.toolTip = "Stop and insert"
        // Starts with the visible word, so Voice Control's "Click Stop" still finds it.
        stop.setAccessibilityLabel("Stop and insert")
        stop.isHidden = true
        stop.isEnabled = false
        stop.pressAction = { [weak self] in self?.handleStopButtonPressed() }
        capsule.addSubview(stop)

        let action = OverlayCapsuleControl(style: .chip)
        action.isHidden = true
        action.pressAction = { [weak self] in self?.handleActionButtonPressed() }
        capsule.addSubview(action)

        let cancel = OverlayCapsuleControl(style: .discard)
        cancel.toolTip = "Discard"
        cancel.setAccessibilityLabel("Discard")
        cancel.isHidden = true
        cancel.alphaValue = 0
        cancel.pressAction = { [weak self] in self?.handleCancelButtonPressed() }
        capsule.addSubview(cancel)

        wrapper.addSubview(capsule)
        // The card hangs below the capsule and covers the capsule's shadow, as on the board.
        wrapper.addSubview(card)
        wrapper.interactiveButtons = [stop, action, cancel]

        panel.contentView = wrapper
        self.window = panel
        self.wrapperView = wrapper
        self.capsule = capsule
        self.nibView = nib
        self.textField = label
        self.timeField = time
        self.keyHintView = keyHint
        self.stopButton = stop
        self.actionButton = action
        self.cancelButton = cancel
        self.card = card
        self.transcriptField = transcript
        self.cardMessageField = cardMessage
        if appearance == .grove { installGroveSurfaces() }
        layoutPanel(size: size)
        applyAccessibilityAppearance()
    }

    /// The quill overlay floats at the status bar level. The grove overlay sits above the menu bar
    /// and the status items (it draws over the notch) and below open menus, on every Space and
    /// beside full-screen apps, and stays put in Mission Control.
    private func configureWindowLevel(of panel: NSPanel) {
        switch appearance {
        case .quill:
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        case .grove:
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        }
    }

    private func resizePanelForCurrentSession() {
        ensureWindow()
        resolvePinnedScreenFrameIfNeeded()
        guard let window else { return }
        let size = activePanelSize
        if window.frame.size != size {
            window.setContentSize(size)
            wrapperView?.frame = NSRect(origin: .zero, size: size)
        }
        layoutPanel(size: size)
        applyAccessibilityAppearance()
    }

    private func layoutPanel(size: NSSize) {
        let m = metrics
        let margins = OverlayPanelLayoutPolicy.shadowMargins
        let grove = appearance == .grove
        let groveLayout = grove ? self.groveLayout : nil
        if let currentPresentation {
            layoutCapsule(width: capsuleWidth(for: currentPresentation), animated: false)
        } else {
            layoutCapsule(width: min(m.capsuleWidth(.hold), size.width - margins.horizontal), animated: false)
        }
        guard let card, let transcriptField, let cardMessageField else { return }
        card.isHidden = !showsLiveTranscriptPanel
        guard showsLiveTranscriptPanel else { return }
        let cardWidth = min(m.cardWidth, size.width - margins.horizontal)
        let lines = min(attainedTranscriptLines, transcriptLineCapacity)
        let cardHeight = OverlayPanelLayoutPolicy.cardHeight(metrics: m, lines: lines)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let groveLayout {
            card.frame = groveLayout.cardRect(lines: lines, metrics: m)
        } else {
            card.frame = NSRect(
                x: round((size.width - cardWidth) / 2),
                y: margins.top + m.capsuleHeight + m.cardGap,
                width: cardWidth, height: cardHeight
            )
        }
        CATransaction.commit()
        card.cornerRadius = m.cardCornerRadius
        transcriptField.frame = card.bounds
        transcriptField.cornerRadius = m.cardCornerRadius
        transcriptField.contentInsets = m.cardInsets
        transcriptField.lineHeight = m.transcriptLineHeight
        transcriptField.fadeHeight = m.fadeHeight
        let messageFont = transcriptFont(m)
        cardMessageField.font = messageFont
        let messageHeight = ceil(messageFont.ascender - messageFont.descender + messageFont.leading)
        cardMessageField.frame = NSRect(
            x: m.cardInsets.left - 2,
            y: cardHeight - m.cardInsets.bottom - (m.transcriptLineHeight + messageHeight) / 2,
            width: max(0, cardWidth - m.cardInsets.left - m.cardInsets.right + 4),
            height: messageHeight
        )
    }

    /// Lays out the capsule, left to right: quill, label, time; right-aligned keycap, Stop,
    /// action, ×. Controls keep their right edges when the capsule changes width.
    private func layoutCapsule(width: CGFloat, animated: Bool) {
        if appearance == .grove {
            groveLayoutRow(animated: animated)
            return
        }
        guard let capsule, let wrapper = wrapperView else { return }
        let m = metrics
        let height = m.capsuleHeight
        let frame = NSRect(
            x: round((wrapper.bounds.width - width) / 2),
            y: OverlayPanelLayoutPolicy.shadowMargins.top,
            width: width, height: height
        )
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                context.allowsImplicitAnimation = true
                capsule.animator().frame = frame
                layoutCapsuleContent(width: width, height: height, metrics: m, animated: true)
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            capsule.frame = frame
            layoutCapsuleContent(width: width, height: height, metrics: m, animated: false)
            CATransaction.commit()
        }
        capsule.cornerRadius = height / 2
    }

    private func layoutCapsuleContent(width: CGFloat, height: CGFloat, metrics m: OverlayAccessibilityMetrics, animated: Bool) {
        guard let nibView, let textField, let timeField else { return }
        func place(_ view: NSView, _ rect: NSRect) {
            if animated { view.animator().frame = rect } else { view.frame = rect }
        }
        let nibSize = CGSize(width: m.nibWidth, height: round(m.nibWidth * QuillGeometry.aspectRatio))
        let nibRect = NSRect(x: m.leadingInset, y: round((height - nibSize.height) / 2), width: nibSize.width, height: nibSize.height)
        place(nibView, nibRect)

        // Text ends a gap before the first control, or at the leading inset from the edge.
        var textLimit = width - m.leadingInset
        var right = width - m.trailingInset
        for control in [cancelButton, actionButton, stopButton, keyHintView].compactMap({ $0 }) where !control.isHidden {
            control.metricsScale = m.geometryScale
            control.textScale = m.textScale
            let controlHeight = control.style == .keycap ? control.intrinsicHeight : m.controlSize
            let controlWidth = control.style == .discard ? m.controlSize : control.intrinsicWidth
            place(control, NSRect(x: right - controlWidth, y: round((height - controlHeight) / 2), width: controlWidth, height: controlHeight))
            textLimit = right - controlWidth - m.gap
            right -= controlWidth + m.gap
        }

        let left = m.leadingInset + nibSize.width + m.gap
        // NSTextField draws its text 2 pt in from its frame.
        let inset: CGFloat = 2
        let available = max(0, textLimit - left + 2 * inset)
        let labelFont = textField.font ?? OverlayTypography.text(size: m.labelFontSize, weight: .medium)
        let labelHeight = ceil(labelFont.ascender - labelFont.descender + labelFont.leading)
        var timeWidth: CGFloat = 0
        if !timeField.isHidden, let timeFont = timeField.font {
            timeWidth = ceil((timeField.stringValue as NSString).size(withAttributes: [.font: timeFont]).width) + 2 * inset
        }
        let naturalLabel = ceil((textField.stringValue as NSString).size(withAttributes: [.font: labelFont]).width) + 2 * inset
        let labelWidth = min(naturalLabel, max(0, available - (timeWidth > 0 ? timeWidth + m.gap - 2 * inset : 0)))
        place(textField, NSRect(x: left - inset, y: round((height - labelHeight) / 2), width: labelWidth, height: labelHeight))
        if timeWidth > 0, let timeFont = timeField.font {
            let timeHeight = ceil(timeFont.ascender - timeFont.descender + timeFont.leading)
            place(timeField, NSRect(x: left - inset + labelWidth - 2 * inset + m.gap, y: round((height - timeHeight) / 2) + 0.5,
                                    width: timeWidth, height: timeHeight))
        }
    }

    // MARK: - Live transcript

    private func scheduleLiveRenderIfNeeded() {
        guard liveRenderTimer == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = OverlayLiveUpdatePolicy.delay(lastRenderTime: lastLiveRenderTime, now: now)

        if delay == 0 {
            renderPendingLiveSnapshot()
            return
        }

        let expectedEpoch = liveUpdateGate.lifecycleEpoch
        let expectedTimerToken = UUID()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.liveRenderTimerToken == expectedTimerToken,
                      self.liveUpdateGate.lifecycleEpoch == expectedEpoch,
                      self.listeningSessionIsActive else {
                    return
                }
                self.liveRenderTimer = nil
                self.liveRenderTimerToken = nil
                self.renderPendingLiveSnapshot()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        liveRenderTimer = timer
        liveRenderTimerToken = expectedTimerToken
    }

    private func renderPendingLiveSnapshot() {
        #if DEBUG
        let hostedRenderStartedAt = ProcessInfo.processInfo.systemUptime
        #endif
        guard let snapshot = liveRenderBuffer.pendingSnapshot,
              listeningSessionIsActive,
              liveTranscriptEnabled,
              !livePreviewUnavailable
        else {
            liveRenderBuffer.clear()
            return
        }
        _ = liveRenderBuffer.takePending()
        lastLiveRenderTime = ProcessInfo.processInfo.systemUptime
        render(snapshot)

        if liveRenderBuffer.pendingSnapshot != nil {
            scheduleLiveRenderIfNeeded()
        }
        #if DEBUG
        let renderedAt = ProcessInfo.processInfo.systemUptime
        if let renderedRevision = snapshot.lastAcceptedRevision {
            hostedEvidenceHandler?(.previewRendered(
                mainActorWorkMilliseconds: max(0, (renderedAt - hostedRenderStartedAt) * 1_000),
                renderStartedMonotonicMilliseconds: hostedRenderStartedAt * 1_000,
                sessionID: snapshot.session.sessionID,
                revision: renderedRevision
            ))
        }
        #endif
    }

    /// Replaces the card's text with this hypothesis. Never stitches earlier hypotheses.
    private func render(_ snapshot: LiveTranscriptionSnapshot) {
        guard let transcriptField else { return }
        lastRenderedSnapshot = snapshot
        let m = metrics
        let width = max(1, min(m.cardWidth, activePanelSize.width - OverlayPanelLayoutPolicy.shadowMargins.horizontal)
            - m.cardInsets.left - m.cardInsets.right)
        let capacity = transcriptLineCapacity
        let font = transcriptFont(m)
        let ink = inkColor
        let wet = wetColor
        let layout = OverlayTranscriptLayout.make(
            source: snapshot.provisionalText,
            stableCount: snapshot.stablePrefix.count,
            width: width,
            maximumLines: capacity
        ) { isWet in
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isWet ? wet : ink]
            if isWet { attributes[.overlayWetInk] = true }
            return attributes
        }
        transcriptLayout = layout
        transcriptSnapshot = layout.snapshot
        let lines = max(1, min(capacity, layout.visibleLineCount))
        if lines > attainedTranscriptLines {
            // Height only grows during a session, one step per new line.
            attainedTranscriptLines = lines
            // The container grows with a spring in the grove overlay.
            groveAnimateNextLayout = appearance == .grove && !accessibilityPreferences.reduceMotion && !isOffscreenRender
            resizePanelForCurrentSession()
            groveAnimateNextLayout = false
            centerWindowNearTop()
        }
        transcriptField.font = font
        transcriptField.show(layout)
        transcriptField.setAccessibilityValue(layout.snapshot.sourceText)
        updateCardMessage()
    }

    private func rerenderCurrentTranscriptIfNeeded() {
        guard showsLiveTranscriptPanel, !livePreviewUnavailable, let lastRenderedSnapshot else { return }
        render(lastRenderedSnapshot)
    }

    private func updateCardMessage() {
        guard let cardMessageField else { return }
        let hasText = !(transcriptField?.stringValue.isEmpty ?? true)
        if livePreviewUnavailable {
            cardMessageField.stringValue = "Live preview stopped. Still recording."
            cardMessageField.textColor = increaseContrast ? inkColor : inkColor.withAlphaComponent(0.8)
            cardMessageField.isHidden = false
        } else if !hasText {
            cardMessageField.stringValue = "Words appear here as you speak"
            cardMessageField.textColor = inkColor.withAlphaComponent(increaseContrast ? 0.8 : 0.6)
            cardMessageField.isHidden = false
        } else {
            cardMessageField.stringValue = ""
            cardMessageField.isHidden = true
        }
    }

    private func endListeningPresentation() {
        listeningSessionIsActive = false
        recordingLimitSeconds = nil
        liveUpdateGate.endListening()
        liveTranscriptSession = nil
        liveRenderBuffer.clear()
        liveRenderTimer?.invalidate()
        liveRenderTimer = nil
        liveRenderTimerToken = nil
        lastLiveRenderTime = nil
        livePreviewUnavailable = false
        clearLiveTranscriptContent()
        card?.isHidden = true
        #if DEBUG
        hostedEvidenceHandler?(.previewCleared)
        #endif
    }

    private func clearLiveTranscriptContent() {
        lastRenderedSnapshot = nil
        transcriptLayout = nil
        transcriptSnapshot = .empty
        transcriptField?.clear()
        transcriptField?.setAccessibilityValue("")
    }

    // MARK: - Timers

    /// The elapsed time ticks once a second only when it is shown: always in hands-free and
    /// in the last minute, and after 10 s of a hold.
    private func scheduleElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard listeningSessionIsActive, let start = listeningStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        let firesNow = listeningHandsFree || recordingLimitSeconds != nil
            || elapsed >= Double(OverlayPresentation.holdTimerThreshold)
        let firstDelay = firesNow
            ? 1 - elapsed.truncatingRemainder(dividingBy: 1)
            : Double(OverlayPresentation.holdTimerThreshold) - elapsed
        let timer = Timer(timeInterval: max(0.05, firstDelay), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.listeningSessionIsActive else { return }
                self.refreshListeningPresentation(animated: false)
                self.scheduleElapsedTimer()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        listeningStartDate = nil
    }

    private func startResultTimerIfNeeded(for presentation: OverlayPresentation) {
        guard let duration = presentation.duration else { return }
        resultTimer = OverlayResultTimer(duration: duration, now: clock())
        if capsule?.isPointerInside == true, pointerMovedSinceState {
            resultTimer.hold(now: clock())
        }
        scheduleResultTimer()
    }

    private func scheduleResultTimer() {
        resultTimerTask?.invalidate()
        resultTimerTask = nil
        guard let delay = resultTimer.delay(now: clock()) else { return }
        let generation = presentationGeneration
        let timer = Timer(timeInterval: max(0.01, delay), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                self.resultTimerFired()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        resultTimerTask = timer
    }

    private func cancelResultTimer() {
        resultTimer.cancel()
        resultTimerTask?.invalidate()
        resultTimerTask = nil
    }

    private func resultTimerFired() {
        hostedTrace("result timer fired")
        let now = clock()
        guard resultTimer.isExpired(now: now) else {
            scheduleResultTimer()
            return
        }
        resultTimer.cancel()
        resultTimerTask = nil
        if currentPresentation?.restoresPrevious == true {
            endNotice()
        } else {
            fadeOutAndHide()
        }
    }

    private func endNotice() {
        presentationGeneration &+= 1
        guard let noticeReturn, !noticeReturnsToHidden else {
            self.noticeReturn = nil
            if listeningSessionIsActive || transcriptionCancelAvailable || currentState == .transcribing {
                // The session moved on while the notice showed; its own presentation returns.
                restoreCurrentStatePresentation()
            } else {
                fadeOutAndHide()
            }
            return
        }
        self.noticeReturn = nil
        apply(noticeReturn.presentation, animated: true)
        resultTimer = noticeReturn.timer
        if noticeReturn.presentation.isTimed, !resultTimer.isRunning {
            fadeOutAndHide()
            return
        }
        scheduleResultTimer()
        if listeningSessionIsActive { refreshListeningPresentation(animated: false) }
    }

    private func restoreCurrentStatePresentation() {
        guard let currentState else { return }
        let presentation = OverlayPresentation.make(for: currentState, previousWidth: currentPresentation?.width)
        apply(presentation, animated: true)
    }

    private func fadeOutAndHide() {
        guard let window, !wasHidden else { return }
        let groveMotion = GroveMotion.disappear(
            isNotch: grovePlacement?.isNotch == true, reduceMotion: accessibilityPreferences.reduceMotion
        )
        #if DEBUG
        if appearance == .grove { hostedMotionLog.append(groveMotion) }
        if rendersOffscreen {
            hide()
            return
        }
        #endif
        if appearance == .grove, groveMotion == .retract {
            groveRetractAndHide()
            return
        }
        guard let content = window.contentView?.layer else {
            hide()
            return
        }
        isFadingOut = true
        hostedTrace("fade begin")
        let generation = presentationGeneration
        // The content fades, not the window: a window's alpha animation keeps running after its
        // alpha is set again, so a show during the fade could end fully transparent.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isFadingOut, self.presentationGeneration == generation else { return }
                self.isFadingOut = false
                self.hide()
            }
        }
        content.add(fade, forKey: Self.fadeOutKey)
        CATransaction.commit()
    }

    private static let fadeOutKey = "steno.overlay.fadeOut"

    private func cancelFadeOut() {
        guard isFadingOut else { return }
        isFadingOut = false
        window?.contentView?.layer?.removeAnimation(forKey: Self.fadeOutKey)
        if isRetracting { groveCancelRetract() }
    }

    private func pointerEvent(_ event: OverlayCapsuleView.PointerEvent) {
        let now = clock()
        switch event {
        case .moved:
            pointerMovedSinceState = true
            guard resultTimer.deadline != nil else { return }
            resultTimer.hold(now: now)
            resultTimerTask?.invalidate()
            resultTimerTask = nil
            if isFadingOut { cancelFadeOut() }
        case .exited:
            guard resultTimer.isHeld else { return }
            resultTimer.release(now: now)
            scheduleResultTimer()
        }
    }

    // MARK: - Positioning

    private func centerWindowNearTop() {
        if appearance == .grove {
            groveCenterWindow()
            return
        }
        guard let window else { return }
        resolvePinnedScreenFrameIfNeeded()
        guard let screenFrame = pinnedScreenFrame else { return }
        let margins = OverlayPanelLayoutPolicy.shadowMargins
        let x = screenFrame.origin.x + (screenFrame.width - window.frame.width) / 2
        let remaining = max(0, screenFrame.height - window.frame.height)
        let capsuleTop = min(OverlayPanelLayoutPolicy.topOffset, remaining / 2 + margins.top)
        let top = min(screenFrame.maxY, screenFrame.maxY - capsuleTop + margins.top)
        window.setFrameOrigin(NSPoint(x: round(x), y: round(top - window.frame.height)))
    }

    private func resolvePinnedScreenFrameIfNeeded() {
        guard pinnedScreenFrame == nil else { return }
        let candidates = NSScreen.screens.map {
            OverlayDisplayCandidate(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        pinnedScreenFrame = OverlayDisplayPinPolicy.resolvedVisibleFrame(
            pinnedVisibleFrame: nil,
            targetPoint: captureTargetPoint ?? NSEvent.mouseLocation,
            candidates: candidates,
            fallbackVisibleFrame: window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )
    }

    private func presentWindow() {
        #if DEBUG
        if appearance == .grove, groveIsAppearing {
            hostedMotionLog.append(.appear(isNotch: grovePlacement?.isNotch == true, reduceMotion: accessibilityPreferences.reduceMotion))
        }
        guard !rendersOffscreen else { return }
        #endif
        guard let window else { return }
        if appearance == .grove {
            grovePresentWindow(window)
            return
        }
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    // MARK: - Appearance

    private func accessibilityChanged() {
        resizePanelForCurrentSession()
        if let currentPresentation { apply(currentPresentation, animated: false) }
        rerenderCurrentTranscriptIfNeeded()
        if !wasHidden {
            centerWindowNearTop()
        }
    }

    private func resolveAccentColor() {
        let appearance = selectedAppearance ?? window?.effectiveAppearance ?? NSApp?.effectiveAppearance
        let resolve = {
            self.accentColor = self.sourceAccentColor.usingColorSpace(.deviceRGB) ?? self.sourceAccentColor
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(resolve) }
        else { resolve() }
    }

    private var usesDarkAppearance: Bool {
        let appearance = selectedAppearance ?? window?.effectiveAppearance ?? NSApp?.effectiveAppearance
        return appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Working indigo: the capsule and card fill.
    private var fillQuillColor: QuillColor {
        usesDarkAppearance ? OverlayPalette.workingDark : OverlayPalette.workingLight
    }

    private var fillColor: NSColor {
        // The card's top fade runs into the glass, which is darkest-green at the top.
        if appearance == .grove { return GrovePalette.fill(groveModel?.tone ?? .forest, at: 0.35) }
        return NSColor(cgColor: fillQuillColor.cgColor) ?? .systemIndigo
    }
    private var inkColor: NSColor {
        return appearance == .grove ? GrovePalette.cream : OverlayPalette.ink
    }
    /// The mark's colours: the quill in its own colours; under Increase Contrast its barbs are
    /// the lightest of them.
    private func applyGroveMarkColors() {
        var colors = BrandMark.Colors.green
        if increaseContrast { colors.barbLow = colors.barbHigh }
        groveMark?.setColors(colors)
    }

    /// Live words: the system face in the grove overlay, Archivo (when registered) otherwise.
    private func transcriptFont(_ m: OverlayAccessibilityMetrics) -> NSFont {
        appearance == .grove
            ? .systemFont(ofSize: m.transcriptFontSize, weight: .regular)
            : OverlayTypography.text(size: m.transcriptFontSize, weight: .regular)
    }
    private var quietColor: NSColor {
        if appearance == .grove { return increaseContrast ? GrovePalette.cream : GrovePalette.subtext }
        return increaseContrast ? OverlayPalette.ink : OverlayPalette.ink.withAlphaComponent(0.8)
    }
    /// Words the speech model may still change.
    private var wetColor: NSColor {
        if appearance == .grove { return increaseContrast ? GrovePalette.cream : GrovePalette.subtext }
        return increaseContrast ? inkColor : OverlayPalette.wetInk
    }
    private var edgeColor: NSColor { OverlayPalette.ink.withAlphaComponent(metrics.edgeAlpha) }

    private var isOffscreenRender: Bool {
        #if DEBUG
        rendersOffscreen
        #else
        false
        #endif
    }

    private var timeFont: NSFont {
        let m = metrics
        return OverlayTypography.mono(size: m.timeFontSize)
    }

    private func labelColor(for tone: OverlayPresentation.Tone) -> NSColor {
        switch tone {
        case .primary: inkColor
        case .quiet, .brief: quietColor
        case .countdown: OverlayPalette.caution
        }
    }

    private func labelFont(for tone: OverlayPresentation.Tone) -> NSFont {
        let m = metrics
        switch tone {
        case .primary, .quiet: return OverlayTypography.text(size: m.labelFontSize, weight: .medium)
        case .brief: return OverlayTypography.text(size: m.briefFontSize, weight: .medium)
        case .countdown: return OverlayTypography.mono(size: m.countdownFontSize)
        }
    }

    private func applyAccessibilityAppearance() {
        guard let capsule, let card else { return }
        let m = metrics
        let shadowOpacity = m.outerShadowOpacity
        if appearance == .grove {
            groveApplySurfaceStyle()
        } else {
            for surface in [capsule as OverlaySurfaceView, card] {
                surface.fillColor = fillColor
                surface.edgeColor = edgeColor
                surface.edgeWidth = m.borderWidth
                surface.shadowOpacity = shadowOpacity
                surface.shadowSpread = surface === card ? 12 : 10
                surface.shadowOffsetY = surface === card ? 16 : 12
                surface.shadowBlur = surface === card ? 40 : 32
                surface.shadowAlpha = surface === card ? 0.65 : 0.6
            }
            nibView?.nib.markDiscColor = fillQuillColor
            nibView?.nib.palette = .onWorking
        }
        nibView?.nib.reduceMotion = accessibilityPreferences.reduceMotion
        for control in [stopButton, actionButton, cancelButton, keyHintView].compactMap({ $0 }) {
            control.isGrove = appearance == .grove
            control.increaseContrast = increaseContrast
            control.metricsScale = m.geometryScale
            control.textScale = m.textScale
        }
        if appearance == .grove {
            if let groveModel { groveStyleText(groveModel) }
            applyGroveMarkColors()
        } else {
            timeField?.font = timeFont
            timeField?.textColor = quietColor
            if let currentPresentation {
                textField?.font = labelFont(for: currentPresentation.tone)
                textField?.textColor = labelColor(for: currentPresentation.tone)
            } else {
                textField?.font = OverlayTypography.text(size: m.labelFontSize, weight: .medium)
                textField?.textColor = inkColor
            }
        }
        transcriptField?.font = transcriptFont(m)
        transcriptField?.textColor = inkColor
        transcriptField?.fadeColor = fillColor
        // Faded text fails contrast; Increase Contrast clips instead.
        transcriptField?.showsFade = !increaseContrast
        transcriptField?.wetUnderlineColor = increaseContrast ? inkColor
            : (appearance == .grove ? .clear : OverlayPalette.wetUnderline)
        updateCardMessage()
    }

    // MARK: - Grove

    #if DEBUG
    /// Review and benchmark builds can force the form. Nothing else reads this.
    public enum PlacementOverride: Sendable, Equatable {
        /// The built-in display's notch, or a stand-in notch at the top of the first display.
        case notch
        /// The top-centre capsule.
        case capsule
    }

    public var placementOverride: PlacementOverride? {
        didSet {
            guard placementOverride != oldValue else { return }
            grovePlacement = nil
            guard appearance == .grove, window != nil else { return }
            groveReresolveAfterDisplayChange()
        }
    }
    #endif

    private var groveLayout: GroveLayout {
        GroveLayout.make(
            placement: grovePlacement ?? resolveGrovePlacement(),
            metrics: metrics,
            showsTranscript: configuredLiveTranscriptEnabled,
            transcriptLines: transcriptLineCapacity,
            showsInsertCard: groveInsertWords != nil
        )
    }

    /// Where the overlay goes, decided afresh at every show. A placement is never kept past the
    /// next decision, and no screen object is ever stored.
    private func groveResolvePlacement(for state: OverlayState?) {
        var startsSession = false
        if case .listening? = state { startsSession = !listeningSessionIsActive }
        if wasHidden || startsSession || groveTargetPoint == nil {
            groveTargetPoint = captureTargetPoint ?? NSEvent.mouseLocation
        }
        let placement = resolveGrovePlacement()
        if placement != grovePlacement { grovePlacement = placement }
    }

    private func resolveGrovePlacement() -> OverlayPlacement {
        #if DEBUG
        if let hostedPlacement { return hostedPlacement }
        #endif
        let displays = Self.currentDisplays()
        let target = groveTargetPoint ?? NSEvent.mouseLocation
        #if DEBUG
        if let forced = forcedGrovePlacement(displays: displays, target: target) { return forced }
        #endif
        return OverlayPlacementPolicy.resolve(
            displays: displays, onlineDisplayCount: Self.onlineDisplayCount(), targetPoint: target
        ) ?? .capsule(display: Self.fallbackDisplay)
    }

    #if DEBUG
    private func forcedGrovePlacement(displays: [OverlayDisplayDescriptor], target: CGPoint) -> OverlayPlacement? {
        guard let override = placementOverride, !displays.isEmpty else { return nil }
        switch override {
        case .notch:
            if let real = displays.first(where: { $0.notch != nil }), let notch = real.notch {
                return .notch(display: real, notch: notch)
            }
            let display = displays[0]
            let notch = NotchGeometry(width: 185, height: 32, centerX: display.frame.midX)
            return .notch(display: display, notch: notch)
        case .capsule:
            return .capsule(display: displays.first(where: { $0.frame.contains(target) }) ?? displays[0])
        }
    }
    #endif

    static func currentDisplays() -> [OverlayDisplayDescriptor] {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return OverlayDisplayDescriptor(
                id: id, frame: screen.frame, visibleFrame: screen.visibleFrame,
                isBuiltIn: id != 0 && CGDisplayIsBuiltin(id) != 0, safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea
            )
        }
    }

    /// Displays online now, including mirrored, sleeping and Sidecar ones: any of them makes the
    /// built-in display one of several.
    static func onlineDisplayCount() -> Int {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        return Int(count)
    }

    private static let fallbackDisplay = OverlayDisplayDescriptor(
        id: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
        isBuiltIn: false, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )

    private func groveCenterWindow() {
        guard let window else { return }
        let frame = groveLayout.panelFrame
        let resized = window.frame.size != frame.size
        window.setFrame(frame, display: false)
        if resized {
            wrapperView?.frame = NSRect(origin: .zero, size: frame.size)
            layoutPanel(size: frame.size)
        }
    }

    private func installGroveSurfaces() {
        guard let wrapper = wrapperView, let capsule else { return }
        if groveRow == nil {
            let row = GroveSurfaceView(frame: wrapper.bounds)
            wrapper.addSubview(row, positioned: .below, relativeTo: nil)
            groveRow = row
        }
        if groveBars == nil {
            let bars = GroveBarsView(frame: .zero)
            let mark = BrandMarkView(frame: .zero)
            let symbol = GroveSymbolView(frame: .zero)
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
            label.setAccessibilityElement(false)
            let secondary = NSTextField(labelWithString: "")
            secondary.lineBreakMode = .byTruncatingTail
            secondary.maximumNumberOfLines = 1
            secondary.cell?.usesSingleLineMode = true
            secondary.isHidden = true
            secondary.setAccessibilityElement(false)
            let icon = NSImageView(frame: .zero)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.isHidden = true
            icon.setAccessibilityElement(false)
            for view in [bars, mark, symbol, label, secondary, icon] as [NSView] {
                view.isHidden = true
                capsule.addSubview(view)
            }
            groveBars = bars
            groveMark = mark
            groveSymbol = symbol
            groveLabelField = label
            groveSecondaryField = secondary
            groveAppIcon = icon
        }
        groveRow?.isHidden = false
        nibView?.isHidden = true
        capsule.layer?.mask = groveContentMask
        groveContentMask.fillColor = NSColor.black.cgColor
        groveContentMask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    }

    private func removeGroveSurfaces() {
        groveRow?.removeAllMotion()
        groveRow?.isHidden = true
        for view in [groveBars, groveSymbol, groveAppIcon, groveLabelField, groveSecondaryField, groveMark] as [NSView?] {
            view?.isHidden = true
        }
        groveMark?.stop()
        groveModel = nil
        capsule?.layer?.mask = nil
        nibView?.isHidden = false
        for view in [capsule, card] as [NSView?] { view?.alphaValue = 1 }
        isRetracting = false
    }

    private func appearanceStyleChanged() {
        guard let window else { return }
        configureWindowLevel(of: window)
        grovePlacement = nil
        if appearance == .grove { installGroveSurfaces() } else { removeGroveSurfaces() }
        resizePanelForCurrentSession()
        applyAccessibilityAppearance()
        if let currentPresentation { apply(currentPresentation, animated: false) }
        rerenderCurrentTranscriptIfNeeded()
        if !wasHidden { centerWindowNearTop() }
    }

    private func groveApplySurfaceStyle(animated: Bool = false) {
        guard let capsule, let card else { return }
        // The shell layers draw the island; the capsule and card only hold the content.
        for surface in [capsule as OverlaySurfaceView, card] {
            surface.fillColor = .clear
            surface.edgeColor = .clear
            surface.edgeWidth = 0
            surface.shadowOpacity = 0
        }
        groveRow?.applyStyle(
            GroveSurfaceView.Style(
                tone: groveModel?.tone ?? .forest,
                reduceTransparency: accessibilityPreferences.reduceTransparency,
                increaseContrast: increaseContrast
            ),
            animated: animated
        )
    }

    /// The default grove icon for an app: the running app of that name, else one installed in the
    /// usual places.
    static func defaultAppIcon(named name: String) -> NSImage? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let icon = running.icon {
            return icon
        }
        for directory in ["/System/Applications", "/System/Applications/Utilities", "/Applications", "/Applications/Utilities"] {
            let path = "\(directory)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return nil
    }

    /// Draws `presentation` into the grove row: what it shows, what moves, and the controls.
    private func groveApply(
        _ presentation: OverlayPresentation, previous: OverlayPresentation?,
        animate: Bool, animated: Bool, reduceMotion: Bool
    ) {
        guard let capsule, let textField, let timeField else { return }
        let model = GroveRowModel.make(
            for: presentation, result: groveResultContext,
            insertWords: groveInsertWords
        )
        let previousModel = groveModel
        groveModel = model
        let m = metrics
        nibView?.isHidden = true

        // The lead: the live bars, the mark, or a status symbol.
        applyGroveMarkColors()
        if case .bars(let count) = model.lead {
            groveBars?.reduceMotion = reduceMotion
            groveBars?.configure(count: count, scale: m.geometryScale)
            if previousModel?.showsBars != true { groveBars?.reset() }
            groveBars?.isHidden = false
        } else {
            groveBars?.isHidden = true
        }
        // The quill is the working and the result glyph.
        var quillMotion: BrandMarkView.Motion?
        if case .mark(let done) = model.lead { quillMotion = done ? .written : .writing }
        if let quillMotion {
            groveMark?.reduceMotion = reduceMotion
            if groveMark?.motion != quillMotion || groveMark?.isHidden == true {
                groveMark?.play(quillMotion, animated: !isOffscreenRender)
            }
            groveMark?.isHidden = false
        } else {
            groveMark?.stop()
            groveMark?.isHidden = true
        }
        if case .symbol(let glyph) = model.lead {
            groveSymbol?.show(glyph, scale: m.textScale)
            groveSymbol?.isHidden = false
        } else {
            groveSymbol?.show(nil, scale: m.textScale)
            groveSymbol?.isHidden = true
        }

        // The words.
        textField.stringValue = presentation.label
        textField.isHidden = true
        textField.setAccessibilityValue(presentation.label)
        groveLabelField?.stringValue = model.primary ?? ""
        groveLabelField?.isHidden = model.primary == nil
        groveLabelField?.toolTip = model.primary
        timeField.stringValue = model.time ?? ""
        timeField.isHidden = model.time == nil
        // Inserted words in a right-to-left script start at the right, as the live words do. The
        // cell lays a truncated line out by its own direction, so the field carries it.
        let detailIsRightToLeft = model.detail.map { LiveWordsText.isRightToLeft($0) } ?? false
        groveSecondaryField?.baseWritingDirection = detailIsRightToLeft ? .rightToLeft : .natural
        groveSecondaryField?.alignment = detailIsRightToLeft ? .right : .natural
        groveSecondaryField?.stringValue = model.detail ?? model.appName ?? model.secondary ?? ""
        groveSecondaryField?.isHidden = model.detail == nil && model.appName == nil && model.secondary == nil
        if let appName = model.appName, let icon = groveAppIconProvider(appName) {
            groveAppIcon?.image = icon
            groveAppIcon?.isHidden = false
        } else {
            groveAppIcon?.image = nil
            groveAppIcon?.isHidden = true
        }
        groveStyleText(model)

        keyHintView?.title = model.keyHint ?? ""
        keyHintView?.isHidden = model.keyHint == nil

        let stopAvailable = model.showsStop && stopAction != nil && listeningSessionIsActive
        stopButton?.isHidden = !stopAvailable
        stopButton?.isEnabled = stopAvailable

        let action = presentation.action.flatMap { actionIsWired($0) ? $0 : nil }
        let actionTitle = action.map(GroveRowModel.actionTitle)
        actionButton?.title = actionTitle ?? ""
        actionButton?.setAccessibilityLabel(actionTitle)
        actionButton?.isHidden = action == nil
        actionButton?.isEnabled = action != nil
        // The model's layout counts only what is wired.
        var laidOut = model
        laidOut.actionTitle = actionTitle
        laidOut.showsStop = stopAvailable
        groveModel = laidOut

        if model.showsDiscard {
            cancelButtonVisible = true
            // A notice hides the control and clears this flag; showing the control again while
            // the transcription still runs must make its press work again.
            if currentState == .transcribing { transcriptionCancelAvailable = true }
            cancelButton?.isHidden = false
            cancelButton?.isEnabled = true
            cancelButton?.alphaValue = 1
        } else {
            hideCancelControl()
        }

        #if DEBUG
        if animated, previous != nil, previous?.width != presentation.width {
            hostedMotionLog.append(.widthChange(reduceMotion: reduceMotion))
        }
        #endif
        groveApplySurfaceStyle(animated: animate)
        layoutCapsule(width: capsuleWidth(for: presentation), animated: animate)
        if listeningSessionIsActive, laidOut.showsBars, let groveRowWidth { groveListeningWidth = groveRowWidth }

        if animate, previous != presentation {
            groveFadeInControls(previous: previousModel, now: laidOut)
        }
        pointerMovedSinceState = false
        capsule.setAccessibilityLabel(presentation.announcement ?? presentation.label)
    }

    /// Fonts and colours of the row's words, from the model.
    private func groveStyleText(_ model: GroveRowModel) {
        let fonts = GroveFonts(textScale: metrics.textScale)
        let sub = increaseContrast ? GrovePalette.cream : GrovePalette.subtext
        groveLabelField?.font = fonts.primary(model.primaryStyle)
        switch model.primaryStyle {
        case .countdown: groveLabelField?.textColor = GrovePalette.warning
        case .working: groveLabelField?.textColor = sub
        case .verb, .notice: groveLabelField?.textColor = GrovePalette.cream
        }
        timeField?.font = fonts.time
        timeField?.textColor = sub
        groveSecondaryField?.font = fonts.secondary
        groveSecondaryField?.textColor = sub
    }

    /// Controls that have just appeared arrive 0.09 s after the shape starts to move.
    private func groveFadeInControls(previous: GroveRowModel?, now: GroveRowModel) {
        guard !accessibilityPreferences.reduceMotion, !isOffscreenRender else { return }
        var arriving: [NSView?] = []
        if now.showsStop, previous?.showsStop != true { arriving.append(stopButton) }
        if now.showsDiscard, previous?.showsDiscard != true { arriving.append(cancelButton) }
        if now.actionTitle != nil, previous?.actionTitle == nil { arriving.append(actionButton) }
        if now.keyHint != nil, previous?.keyHint == nil { arriving.append(keyHintView) }
        for view in arriving {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            fade.beginTime = CACurrentMediaTime() + GroveMotion.controlsDelay
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view?.layer?.add(fade, forKey: "steno.controlFade")
        }
    }

    /// The layout of the row now showing: a row that hugs its content, never narrower than the
    /// listening island was, or the two-line card.
    private func groveRowLayout(in layout: GroveLayout, model: GroveRowModel) -> GroveRowLayout {
        let m = metrics
        let lines = showsLiveTranscriptPanel ? min(attainedTranscriptLines, transcriptLineCapacity) : nil
        let floor = min(
            GroveInsertMoment.minimumWidth(shell: layout.minimumRowWidth, listening: lines == nil ? groveListeningWidth : nil),
            layout.maximumRowWidth
        )
        if model.detail != nil {
            return GroveRowLayout.makeCard(
                model: model, geometryScale: m.geometryScale, textScale: m.textScale,
                minimumWidth: floor, maximumWidth: layout.maximumRowWidth
            )
        }
        return GroveRowLayout.make(
            model: model, hasAppIcon: groveAppIcon?.isHidden == false, height: layout.rowHeight,
            geometryScale: m.geometryScale, textScale: m.textScale,
            fixedWidth: lines == nil ? nil : m.cardWidth,
            minimumWidth: floor, maximumWidth: layout.maximumRowWidth
        )
    }

    private func groveLayoutRow(animated: Bool) {
        defer { hostedTrace("layout row=\(groveRowWidth ?? 0)x\(groveRowHeight ?? 0) card=\(groveModel?.detail != nil) words=\(showsLiveTranscriptPanel) spring=\(animated || groveAnimateNextLayout)") }
        guard let capsule else { return }
        let layout = groveLayout
        let m = metrics
        let model = groveModel ?? GroveRowModel(tone: .forest, lead: .bars(11))
        let lines = showsLiveTranscriptPanel ? min(attainedTranscriptLines, transcriptLineCapacity) : nil
        let isCard = model.detail != nil
        let rowLayout = groveRowLayout(in: layout, model: model)
        let rect = isCard ? layout.insertCardRect(width: rowLayout.width) : layout.rowRect(width: rowLayout.width)
        let radius = isCard ? layout.containerRadius : rect.height / 2
        let previousSize = groveRowWidth.flatMap { width in groveRowHeight.map { CGSize(width: width, height: $0) } }
        let previousRadius = groveRowRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = rect
        groveFrameContent(rowLayout, model: model, metrics: m)
        CATransaction.commit()
        capsule.cornerRadius = radius
        let top = layout.neckHeight ?? rect.minY
        let bottom = isCard ? rect.maxY : (lines.map { rect.maxY + layout.wordsHeight(lines: $0) } ?? rect.maxY)
        let spring = animated || groveAnimateNextLayout
        groveRow?.setGeometry(
            GroveSurfaceView.Geometry(
                shape: layout.shellPath(rowWidth: rect.width, lines: lines, card: isCard),
                shadow: layout.shadowPath(rowWidth: rect.width, lines: lines, card: isCard),
                gradientRect: CGRect(x: 0, y: top, width: layout.panelSize.width, height: bottom - top),
                neckHeight: layout.neckHeight,
                hasHairline: !layout.placement.isNotch
            ),
            spring: spring ? .widthChange : nil
        )
        groveClipContent(
            to: rect, radius: radius, from: spring ? previousSize : nil, fromRadius: previousRadius
        )
        groveRowWidth = rect.width
        groveRowHeight = rect.height
        groveRowRadius = radius
    }

    /// Puts every part of the row where the layout says.
    private func groveFrameContent(_ rowLayout: GroveRowLayout, model: GroveRowModel, metrics m: OverlayAccessibilityMetrics) {
        func place(_ view: NSView?, _ part: GroveRowLayout.Part, outset: CGFloat = 0) {
            guard let view, let frame = rowLayout.frames[part] else { return }
            view.frame = frame.insetBy(dx: -outset, dy: 0)
        }
        place(groveBars, .bars)
        place(groveMark, .mark)
        place(groveSymbol, .symbol)
        // NSTextField draws its text 2 pt in from its frame.
        place(groveLabelField, .primary, outset: 2)
        place(timeField, .time, outset: 2)
        place(groveSecondaryField, .secondary, outset: 2)
        place(groveAppIcon, .appIcon)
        for control in [stopButton, actionButton, cancelButton, keyHintView].compactMap({ $0 }) {
            control.metricsScale = m.geometryScale
            control.textScale = m.textScale
        }
        place(stopButton, .stop)
        place(actionButton, .action)
        place(cancelButton, .cancel)
        place(keyHintView, .keycap)
    }

    /// Clips the row's content to the shell while the shell changes size, so words never show
    /// outside it.
    private func groveClipContent(
        to rect: CGRect, radius: CGFloat, from previous: CGSize?, fromRadius: CGFloat?
    ) {
        let bounds = CGRect(origin: .zero, size: rect.size)
        let target = GroveShapes.rounded(bounds, radius: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        groveContentMask.removeAllAnimations()
        groveContentMask.frame = bounds
        groveContentMask.path = target
        if let previous, abs(previous.width - rect.width) > 0.5 || abs(previous.height - rect.height) > 0.5 {
            let from = GroveShapes.rounded(
                CGRect(x: (rect.width - previous.width) / 2, y: 0, width: previous.width, height: previous.height),
                radius: fromRadius ?? previous.height / 2
            )
            groveContentMask.add(GroveSpring.widthChange.animation(keyPath: "path", from: from, to: target), forKey: "steno.spring")
        }
        CATransaction.commit()
    }

    /// Shows the panel. A notch grows out of the notch; a capsule appears at once, full size.
    /// Reduce Motion fades either in.
    private func grovePresentWindow(_ window: NSPanel) {
        hostedTrace("present appearing=\(groveIsAppearing) visible=\(window.isVisible) retracting=\(isRetracting)")
        if isRetracting { groveCancelRetract() }
        guard groveIsAppearing || !window.isVisible else {
            window.alphaValue = 1
            window.orderFrontRegardless()
            return
        }
        groveIsAppearing = false
        switch GroveMotion.appear(isNotch: grovePlacement?.isNotch == true, reduceMotion: accessibilityPreferences.reduceMotion) {
        case .crossFade(let duration):
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        case .emergence:
            window.alphaValue = 1
            window.orderFrontRegardless()
            groveEmerge()
        default:
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
    }

    /// The notch's emergence: the shell springs out of the neck; the content arrives once it has
    /// mostly landed.
    private func groveEmerge() {
        let layout = groveLayout
        guard let closed = layout.closedShellPath, let closedShadow = layout.closedShadowPath else { return }
        groveRow?.animateFromClosed(shape: closed, shadow: closedShadow, spring: .emergence)
        let begin = CACurrentMediaTime() + 0.1
        for view in [capsule, card] as [NSView?] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.2
            fade.beginTime = begin
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view?.layer?.add(fade, forKey: "steno.emerge")
        }
    }

    /// The notch's retraction: the content fades, the shell folds back into the neck, then the
    /// panel leaves the screen.
    private func groveRetractAndHide() {
        let layout = groveLayout
        guard let closed = layout.closedShellPath, let closedShadow = layout.closedShadowPath, let window else {
            return
        }
        isFadingOut = true
        isRetracting = true
        hostedTrace("retract begin")
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            // Leaving starts at once: an ease-in would hold the words still while the shell folds.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            capsule?.animator().alphaValue = 0
            card?.animator().alphaValue = 0
        }
        groveRow?.retract(to: closed, shadow: closedShadow, spring: .retract)
        _ = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isFadingOut, self.presentationGeneration == generation else { return }
                self.isFadingOut = false
                self.hide()
            }
        }
    }

    private func groveCancelRetract() {
        isRetracting = false
        groveRow?.removeAllMotion()
        for view in [capsule, card] as [NSView?] { view?.alphaValue = 1 }
        groveLayoutRow(animated: false)
    }

    /// Nothing runs while hidden.
    private func groveWillOrderOut() {
        isRetracting = false
        groveRow?.removeAllMotion()
        groveContentMask.removeAllAnimations()
        groveMark?.stop()
        groveBars?.reset()
        for view in [capsule, card] as [NSView?] {
            view?.layer?.removeAnimation(forKey: "steno.emerge")
            view?.layer?.removeAnimation(forKey: "steno.overlay.swap")
            view?.alphaValue = 1
        }
        for control in [stopButton, actionButton, cancelButton, keyHintView] { control?.layer?.removeAnimation(forKey: "steno.controlFade") }
        nibView?.nib.setMode(.rest)
    }

    /// The displays changed or the Mac woke: decide again, once the burst of notifications ends.
    private func groveDisplaysChanged() {
        guard appearance == .grove else { return }
        groveScreenChangeGeneration &+= 1
        let generation = groveScreenChangeGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.groveScreenChangeGeneration == generation else { return }
            self.groveReresolveAfterDisplayChange()
        }
    }

    private func groveReresolveAfterDisplayChange() {
        guard appearance == .grove else { return }
        let previous = grovePlacement
        // A kept placement is never trusted; a hidden overlay decides at its next show.
        grovePlacement = nil
        guard window != nil, !wasHidden else { return }
        grovePlacement = resolveGrovePlacement()
        guard grovePlacement != previous else { return }
        // The form or the display changed while showing: snap, never morph across displays.
        groveRow?.removeAllMotion()
        resizePanelForCurrentSession()
        if let currentPresentation { apply(currentPresentation, animated: false) }
        centerWindowNearTop()
        rerenderCurrentTranscriptIfNeeded()
    }

    // MARK: - Announcements

    private func announce(for state: OverlayState, presentation: OverlayPresentation) {
        guard let message = presentation.announcement else { return }
        switch state {
        case .transcribing:
            postAnnouncement(message)
        case .discarded:
            postAnnouncement(message)
        case .inserted, .result(.inserted, _):
            announceOnce(.inserted, message: message)
        case .copiedOnly, .result(.copied, _):
            announceOnce(.copiedOnly, message: message)
        case .noSpeechDetected:
            announceOnce(.noSpeech, message: message)
        case .failure, .result:
            announceOnce(.failure, message: message)
        case .listening, .busy:
            break
        }
    }

    private func announceOnce(_ announcement: OverlayAnnouncement, message: String) {
        guard announcementGate.accept(announcement), lastAnnouncement != announcement else { return }
        lastAnnouncement = announcement
        postAnnouncement(message)
    }

    private func postAnnouncement(_ message: String?, priority: NSAccessibilityPriorityLevel = .medium) {
        guard let message else { return }
        #if DEBUG
        hostedEvidenceAnnouncements.append(message)
        guard !rendersOffscreen else { return }
        #endif
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: priority.rawValue]
        )
    }

    // MARK: - Controls

    private func hideCancelControl() {
        cancelButtonVisible = false
        transcriptionCancelAvailable = false
        stopButton?.isHidden = true
        stopButton?.isEnabled = false
        guard let cancelButton else { return }
        cancelButton.alphaValue = 0
        cancelButton.isHidden = true
        cancelButton.isEnabled = false
    }

    private func handleStopButtonPressed() {
        guard listeningSessionIsActive, stopButton?.isEnabled == true, stopButton?.isHidden == false else { return }
        stopButton?.isHidden = true
        stopButton?.isEnabled = false
        hideCancelControl()
        stopAction?()
    }

    private func handleCancelButtonPressed() {
        guard listeningSessionIsActive || transcriptionCancelAvailable,
              cancelButtonVisible else { return }
        hideCancelControl()
        announceOnce(.cancelled, message: "Steno dictation canceled")
        cancelAction?()
    }

    private func handleActionButtonPressed() {
        guard let action = currentPresentation?.action, actionButton?.isHidden == false else { return }
        switch action {
        case .copy:
            onCopyResult?()
            presentationGeneration &+= 1
            cancelResultTimer()
            let confirmation = OverlayPresentation.copyConfirmation
            apply(confirmation, animated: true)
            postAnnouncement(confirmation.announcement)
            startResultTimerIfNeeded(for: confirmation)
        case .undo:
            onUndoDiscard?()
        case .openSettings:
            if let currentResult { onOpenSettings?(currentResult) }
            fadeOutAndHide()
        }
    }

    // MARK: - Hosted evidence

    private func hostedTrace(_ message: @autoclosure () -> String) {
        #if DEBUG
        hostedTraceHandler?(message())
        #endif
    }

    #if DEBUG
    func setHostedEvidenceHandler(_ handler: ((WaveformOverlayHostedEvidenceEvent) -> Void)?) {
        hostedEvidenceHandler = handler
    }

    func hostedEvidenceTextSurfacesAreEmpty() -> Bool {
        [
            transcriptField?.stringValue ?? "",
            transcriptField?.accessibilityValue() as? String ?? "",
            transcriptSnapshot.sourceText,
        ].allSatisfy(\.isEmpty)
    }

    /// Draws the panel offscreen without ordering it in or announcing anything.
    ///
    /// - Parameters:
    ///   - backdrop: painted behind the panel; nil leaves it transparent.
    ///   - scale: pixels per point; nil uses the panel's own backing scale.
    ///   - level: an input level for the quill while listening.
    func hostedEvidenceRenderPNG(
        state: OverlayState,
        snapshot: LiveTranscriptionSnapshot? = nil,
        snapshots: [LiveTranscriptionSnapshot] = [],
        level: Float? = nil,
        limitSeconds: Int? = nil,
        backdrop: NSColor? = nil,
        scale: CGFloat? = nil
    ) -> Data? {
        rendersOffscreen = true
        defer {
            hide()
            rendersOffscreen = false
        }
        show(state: state)
        if let limitSeconds { showRecordingLimitWarning(limitSeconds: limitSeconds) }
        if let snapshot {
            updateLiveTranscript(snapshot)
            renderPendingLiveSnapshot()
        }
        for update in snapshots {
            updateLiveTranscript(update)
            renderPendingLiveSnapshot()
        }
        if let level { updateInputLevel(level) }
        return hostedEvidenceRenderCurrentPNG(backdrop: backdrop, scale: scale)
    }

    /// Draws whatever the panel shows now.
    func hostedEvidenceRenderCurrentPNG(backdrop: NSColor? = nil, scale: CGFloat? = nil) -> Data? {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard let content = wrapperView else { return nil }
        content.layoutSubtreeIfNeeded()
        nibView?.nib.removeAllAnimations()
        nibView?.nib.sublayers?.forEach { layer in
            layer.removeAllAnimations()
            layer.sublayers?.forEach { $0.removeAllAnimations() }
        }
        let size = content.bounds.size
        let pixelScale = scale ?? window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * pixelScale), pixelsHigh: Int(size.height * pixelScale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let backdrop else { return rep.representation(using: .png, properties: [:]) }
        guard let composed = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        composed.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composed)
        backdrop.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return composed.representation(using: .png, properties: [:])
    }

    func hostedEvidenceHasOneTranscriptSurface() -> Bool {
        transcriptField != nil
            && transcriptField?.accessibilityLabel() == "Live transcript, provisional"
    }

    func hostedEvidenceViewport() -> OverlayTranscriptViewportSnapshot { transcriptSnapshot }

    func hostedEvidencePanelSize() -> CGSize { window?.frame.size ?? .zero }

    /// The capsule's size, which carries the state's width.
    func hostedEvidenceCapsuleSize() -> CGSize { capsule?.frame.size ?? .zero }

    func hostedEvidenceCardSize() -> CGSize? {
        guard let card, !card.isHidden else { return nil }
        return card.frame.size
    }

    func hostedEvidenceControlScreenFrames() -> [CGRect] {
        guard let window, let capsule else { return [] }
        return [stopButton, cancelButton].compactMap { button in
            guard let button else { return nil }
            return window.convertToScreen(capsule.convert(button.frame, to: nil))
        }
    }

    func hostedEvidenceControlsAreNonactivating() -> Bool {
        window?.styleMask.contains(.nonactivatingPanel) == true && window?.isKeyWindow == false
    }

    /// Every state passed to `show(state:)`, in order.
    func hostedEvidenceShownStates() -> [OverlayState] { hostedEvidencePresentedStates }

    /// Every state the presenter was asked to show, in order.
    func hostedEvidenceRequestedStates() -> [OverlayState] { hostedEvidencePresentedStates }

    /// The words offered with each requested state, in the same order.
    func hostedEvidenceRequestedWords() -> [String?] { hostedEvidenceOfferedWords }

    /// Every VoiceOver announcement requested, in order (also recorded offscreen).
    func hostedEvidenceAnnouncementLog() -> [String] { hostedEvidenceAnnouncements }

    func hostedEvidencePresentation() -> OverlayPresentation? { currentPresentation }

    func hostedEvidenceNibMode() -> NibLayer.Mode? { nibView?.nib.mode }

    func hostedEvidenceNibLevel() -> Float? { nibView?.nib.level }

    func hostedEvidenceIsVisible() -> Bool { !wasHidden }

    func hostedEvidenceStopIsAvailable() -> Bool {
        stopButton?.isHidden == false && stopButton?.isEnabled == true
    }

    func hostedEvidencePressStop() { stopButton?.performClick(nil) }

    func hostedEvidencePressCancel() { cancelButton?.performClick(nil) }

    func hostedEvidencePressAction() { actionButton?.performClick(nil) }

    func hostedEvidenceActionTitle() -> String? {
        actionButton?.isHidden == false ? actionButton?.title : nil
    }

    func hostedEvidenceCancelIsAvailable() -> Bool {
        cancelButtonVisible && cancelButton?.isHidden == false
    }

    /// Moves the injected clock's view of the pointer: `true` moves inside, `false` leaves.
    func hostedEvidencePointer(inside: Bool) {
        capsule?.isPointerInside = inside
        pointerEvent(inside ? .moved : .exited)
    }

    /// Runs the dismissal check as if the timer fired now.
    func hostedEvidenceFireResultTimer() {
        resultTimerFired()
    }

    /// The status line ends before any visible control begins.
    func hostedEvidenceStatusTextClearsControls() -> Bool {
        guard let textField else { return false }
        let visibleControls = [stopButton, actionButton, cancelButton, keyHintView].compactMap { $0 }.filter { !$0.isHidden }
        let textEnd = timeField?.isHidden == false ? (timeField?.frame.maxX ?? textField.frame.maxX) : textField.frame.maxX
        return visibleControls.allSatisfy { textEnd <= $0.frame.minX }
    }

    func hostedEvidenceAccentColor() -> NSColor { accentColor }

    func hostedEvidenceUsesDarkAppearance() -> Bool { usesDarkAppearance }

    func hostedEvidencePrepareOffscreen() { rendersOffscreen = true }

    func hostedEvidenceFlushLiveTranscript() { renderPendingLiveSnapshot() }

    func hostedEvidenceVisibleTranscript() -> String {
        transcriptField?.stringValue ?? ""
    }

    func hostedEvidenceUsesCompactUnavailableShell() -> Bool {
        livePreviewUnavailable
            && window?.frame.size == activePanelSize
            && attainedTranscriptLines == 1
            && hostedEvidenceTextSurfacesAreEmpty()
            && cardMessageField?.stringValue == "Live preview stopped. Still recording."
            && hostedEvidenceControlsMatchListeningState()
    }

    func hostedEvidenceUsesPreferredTypography() -> Bool {
        let m = metrics
        return abs((textField?.font?.pointSize ?? 0) - m.labelFontSize) < 0.01
            && (transcriptField?.font.pointSize ?? 0) >= accessibilityPreferences.preferredBodyPointSize
    }

    func hostedEvidenceRecordingPresentationIsImmediateAndStatic() -> Bool {
        window?.alphaValue == 1
            && nibView?.nib.mode == .live
            && nibView?.nib.isSweeping == false
            && nibView?.nib.resultMark == nil
            && cancelButton?.isHidden == false
            && cancelButton?.alphaValue == 1
            && capsule?.layer?.animationKeys()?.isEmpty != false
    }

    func hostedEvidenceUserFacingStrings() -> [String] {
        [
            textField?.stringValue ?? "",
            textField?.accessibilityLabel() ?? "",
            textField?.accessibilityValue() as? String ?? "",
            timeField?.isHidden == false ? timeField?.stringValue ?? "" : "",
            transcriptField?.stringValue ?? "",
            transcriptField?.accessibilityLabel() ?? "",
            transcriptField?.accessibilityValue() as? String ?? "",
            cancelButton?.toolTip ?? "",
            cancelButton?.accessibilityLabel() ?? "",
            stopButton?.accessibilityLabel() ?? "",
            cardMessageField?.isHidden == false ? cardMessageField?.stringValue ?? "" : "",
        ]
    }

    func hostedEvidenceControlsMatchListeningState() -> Bool {
        nibView?.nib.mode == .live
            && nibView?.nib.resultMark == nil
            && cancelButtonVisible
            && cancelButton?.isHidden == false
            && (cancelButton?.alphaValue ?? 0) >= 0.99
    }

    func setHostedAccessibilityPreferences(_ preferences: OverlayAccessibilityPreferences?) {
        hostedAccessibilityPreferencesOverride = preferences
        resizePanelForCurrentSession()
        if let currentPresentation { apply(currentPresentation, animated: false) }
        rerenderCurrentTranscriptIfNeeded()
        if !wasHidden {
            centerWindowNearTop()
        }
    }

    func hostedEvidenceLargeTextTranscriptIsFullyVisible(preferredBodyPointSize: CGFloat) -> Bool {
        guard let transcriptField, let window, let pinnedScreenFrame, let card, let transcriptLayout,
              !card.isHidden else { return false }
        let m = metrics
        let visibleText = transcriptField.stringValue
        let textHeight = CGFloat(transcriptLayout.visibleLineCount) * m.transcriptLineHeight
        return transcriptField.font.pointSize >= preferredBodyPointSize
            && window.frame.width <= pinnedScreenFrame.width
            && window.frame.height <= pinnedScreenFrame.height
            && pinnedScreenFrame.insetBy(dx: -0.5, dy: -0.5).contains(window.frame)
            && card.frame.minX >= 0 && card.frame.maxX <= window.frame.width
            && card.frame.maxY <= window.frame.height
            && textHeight + m.cardInsets.top + m.cardInsets.bottom <= card.frame.height + 0.5
            && transcriptLayout.lines.allSatisfy {
                CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth($0))
                    <= card.frame.width - m.cardInsets.left - m.cardInsets.right + 0.5
            }
            && !visibleText.isEmpty
    }

    func hostedEvidenceAccessibilityAppearanceMatchesPreferences() -> Bool {
        let expected = accessibilityPreferences
        let m = OverlayAccessibilityMetrics(preferences: expected, appearance: appearance)
        guard let capsule, let card else { return false }
        return capsule.edgeWidth == m.borderWidth
            && approximatelyEqual(capsule.edgeColor.alphaComponent, m.edgeAlpha)
            && capsule.shadowOpacity == m.outerShadowOpacity
            && card.shadowOpacity == m.outerShadowOpacity
            && colorsApproximatelyEqual(timeField?.textColor, expected.increaseContrast ? OverlayPalette.ink : OverlayPalette.ink.withAlphaComponent(0.8))
            && colorsApproximatelyEqual(transcriptField?.textColor, OverlayPalette.ink)
            && transcriptField?.showsFade == !expected.increaseContrast
            && cancelButton?.increaseContrast == expected.increaseContrast
            && nibView?.nib.reduceMotion == expected.reduceMotion
    }

    // Grove

    /// Fixes where the grove overlay goes, in place of reading the displays. Nil reads them again.
    func hostedEvidenceSetPlacement(_ placement: OverlayPlacement?) {
        hostedPlacement = placement
        grovePlacement = nil
    }

    func hostedEvidenceGroveLayout() -> GroveLayout { groveLayout }

    /// What the displays-changed and wake notifications do, once the burst has ended.
    func hostedEvidenceDisplaysChanged() { groveReresolveAfterDisplayChange() }

    func hostedEvidencePlacement() -> OverlayPlacement? { grovePlacement }

    func hostedEvidenceGroveShape() -> CGPath? { groveRow?.geometry?.shape }

    /// The glyph leading the row: the mark, or a status symbol. Nil for bars and for plain text.
    func hostedEvidenceGroveGlyph() -> GroveGlyph? {
        guard let groveModel else { return nil }
        return groveModel.glyph
    }

    func hostedEvidenceGroveModel() -> GroveRowModel? { groveModel }







    func hostedEvidenceGroveLabelText() -> String? { groveLabelField?.isHidden == false ? groveLabelField?.stringValue : nil }

    func hostedEvidenceControl(_ style: OverlayCapsuleControl.Style) -> OverlayCapsuleControl? {
        [stopButton, actionButton, cancelButton, keyHintView].compactMap { $0 }.first { $0.style == style }
    }

    func hostedEvidenceGroveBarsVisible() -> Bool { groveBars?.isHidden == false }

    func hostedEvidenceGroveBarHeights() -> [CGFloat] { groveBars?.heights ?? [] }

    /// The quill's motion while it shows and moves, or nil when it is hidden or stopped.
    func hostedEvidenceGroveMarkMotion() -> BrandMarkView.Motion? {
        guard let groveMark, !groveMark.isHidden, groveMark.motion != .still else { return nil }
        return groveMark.motion
    }

    func hostedEvidenceGroveMarkIsAnimating() -> Bool { groveMark?.isAnimating == true }

    func hostedEvidenceGroveMark() -> BrandMarkView? { groveMark }

    func hostedEvidenceGroveBars() -> GroveBarsView? { groveBars }

    /// The colour of the row's visible words.
    func hostedEvidenceGroveLabelColor() -> NSColor? { groveLabelField?.textColor }

    func hostedEvidenceGroveTone() -> GroveTone? { groveRow?.currentStyle.tone }

    func hostedEvidenceGroveStyle() -> GroveSurfaceView.Style? { groveRow?.currentStyle }

    func hostedEvidenceGroveRowFrames() -> [GroveRowLayout.Part: CGRect] {
        guard let groveModel else { return [:] }
        return groveRowLayout(in: groveLayout, model: groveModel).frames
    }

    /// The words under the verb while the two-line card is up; nil when none may show.
    func hostedEvidenceInsertDetail() -> String? { groveModel?.detail }

    func hostedEvidenceListeningWidth() -> CGFloat? { groveListeningWidth }

    /// Everything the overlay holds of the inserted words, for a check that none is kept.
    func hostedEvidenceHoldsInsertedWords() -> Bool { groveInsertWords != nil || groveModel?.detail != nil }

    func hostedEvidenceQuillIsVisible() -> Bool { nibView?.isHidden == false }

    func hostedEvidenceWindowLevel() -> NSWindow.Level? { window?.level }

    func hostedEvidenceCollectionBehavior() -> NSWindow.CollectionBehavior? { window?.collectionBehavior }

    func hostedEvidenceWindowFrame() -> CGRect? { window?.frame }

    func hostedEvidenceWindowCanBecomeKey() -> Bool? { window?.canBecomeKey }

    /// Whether the shell, the content clip or the mark is moving: nothing should be while idle.
    func hostedEvidenceGroveIsAnimating() -> Bool {
        groveRow?.isAnimating == true || groveContentMask.animation(forKey: "steno.spring") != nil
            || groveMark?.isAnimating == true
    }

    func hostedEvidenceCapsuleFrame() -> CGRect? { capsule?.frame }

    func hostedEvidenceRowSurfaceIsVisible() -> Bool { groveRow?.isHidden == false }

    func hostedEvidenceNibPalette() -> NibLayer.Palette? { nibView?.nib.palette }

    func hostedEvidenceFinishPresentation() { fadeOutAndHide() }

    /// The motion the grove overlay chose, in order, whether or not the pass drew it.
    func hostedEvidenceMotionLog() -> [GroveMotion] { hostedMotionLog }

    /// Every content cross-fade the presenter chose, in seconds, whether or not the pass drew it.
    func hostedEvidenceSwapFades() -> [TimeInterval] { hostedSwapFades }

    /// Receives a line for every show, hide, layout and motion the presenter starts, as it
    /// starts it, for frame-by-frame transition evidence.
    func setHostedTraceHandler(_ handler: ((String) -> Void)?) { hostedTraceHandler = handler }

    func hostedEvidenceWindowNumber() -> Int? { window?.windowNumber }

    /// Where the row's visible words are, in window points with the origin at the top left.
    func hostedEvidenceGroveLabelWindowRect() -> CGRect? {
        guard let label = groveLabelField, !label.isHidden, let window else { return nil }
        let rect = label.convert(label.bounds, to: nil)
        return CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    func hostedEvidenceTerminalPresentationIsCompact() -> Bool {
        !listeningSessionIsActive
            && !showsLiveTranscriptPanel
            && card?.isHidden == true
            && window?.frame.size == activePanelSize
    }
    #endif
}

// MARK: - Supporting policy

enum OverlayAnnouncement: Equatable {
    case sessionStarted
    case inserted
    case copiedOnly
    case failure
    case noSpeech
    case cancelled
}

struct OverlayAnnouncementGate: Equatable {
    private(set) var sessionIsActive = false
    private(set) var terminalAnnouncementWasSent = false

    mutating func beginSession() {
        sessionIsActive = true
        terminalAnnouncementWasSent = false
    }

    mutating func accept(_ announcement: OverlayAnnouncement) -> Bool {
        switch announcement {
        case .sessionStarted:
            guard sessionIsActive, !terminalAnnouncementWasSent else { return false }
            return true

        case .cancelled:
            guard sessionIsActive, !terminalAnnouncementWasSent else { return false }
            terminalAnnouncementWasSent = true
            sessionIsActive = false
            return true

        case .inserted, .copiedOnly, .failure, .noSpeech:
            // One outcome per session. An outcome shown with no session, such as a problem
            // before recording could start, is announced once too.
            guard !terminalAnnouncementWasSent else { return false }
            terminalAnnouncementWasSent = true
            sessionIsActive = false
            return true
        }
    }

    /// The overlay hid: whatever comes next is a new outcome.
    mutating func endPresentation() {
        sessionIsActive = false
        terminalAnnouncementWasSent = false
    }
}

enum OverlayLiveUpdatePolicy {
    static let minimumRenderInterval: TimeInterval = 0.25

    static func delay(
        lastRenderTime: TimeInterval?,
        now: TimeInterval
    ) -> TimeInterval {
        guard let lastRenderTime else { return 0 }
        return max(0, minimumRenderInterval - (now - lastRenderTime))
    }
}

/// Content-free admission state for one overlay listening lifecycle.
///
/// Keeping this policy independent from AppKit makes identity, ordering, and
/// next-session preference behavior deterministic to test. The presenter uses
/// it before any provisional text reaches the visible view hierarchy.
struct OverlayLiveUpdateGate: Equatable {
    private(set) var configuredEnabled = true
    private(set) var sessionEnabled = true
    private(set) var isListening = false
    private(set) var isUnavailable = false
    private(set) var session: LiveTranscriptionSession?
    private(set) var lastRevision: UInt64?
    private(set) var lastAudioWatermark: UInt64?
    private(set) var lifecycleEpoch: UInt64 = 0

    mutating func setConfiguredEnabled(_ enabled: Bool) {
        configuredEnabled = enabled
        if !isListening {
            sessionEnabled = enabled
        }
    }

    mutating func beginListening() {
        guard !isListening else { return }
        lifecycleEpoch &+= 1
        sessionEnabled = configuredEnabled
        isListening = true
        isUnavailable = false
        session = nil
        lastRevision = nil
        lastAudioWatermark = nil
    }

    mutating func accept(_ snapshot: LiveTranscriptionSnapshot) -> Bool {
        guard isListening,
              sessionEnabled,
              !isUnavailable,
              snapshot.phase == .active,
              let revision = snapshot.lastAcceptedRevision,
              let audioWatermark = snapshot.decodedAudioWatermark
        else { return false }

        if let session, session != snapshot.session {
            return false
        }
        if let lastRevision, revision <= lastRevision {
            return false
        }
        if let lastAudioWatermark, audioWatermark < lastAudioWatermark {
            return false
        }

        session = snapshot.session
        lastRevision = revision
        lastAudioWatermark = audioWatermark
        return true
    }

    mutating func markUnavailable() -> Bool {
        guard isListening, sessionEnabled, !isUnavailable else { return false }
        isUnavailable = true
        return true
    }

    mutating func endListening() {
        guard isListening else { return }
        isListening = false
        isUnavailable = false
        session = nil
        lastRevision = nil
        lastAudioWatermark = nil
    }
}

struct OverlayLiveRenderBuffer: Equatable {
    private(set) var pendingSnapshot: LiveTranscriptionSnapshot?
    private(set) var coalescedSnapshotCount: UInt64 = 0

    mutating func enqueue(_ snapshot: LiveTranscriptionSnapshot) {
        if pendingSnapshot != nil {
            coalescedSnapshotCount &+= 1
        }
        pendingSnapshot = snapshot
    }

    mutating func takePending() -> LiveTranscriptionSnapshot? {
        defer { pendingSnapshot = nil }
        return pendingSnapshot
    }

    mutating func clear() {
        pendingSnapshot = nil
    }
}

struct OverlayAccessibilityPreferences: Equatable {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool
    let preferredBodyPointSize: CGFloat
}

/// Sizes and accessibility treatment of the overlay. Text follows the preferred body size;
/// shapes grow a little slower than text so larger text does not double the capsule.
struct OverlayAccessibilityMetrics: Equatable {
    static let baselineBodyPointSize: CGFloat = 13

    let appearance: OverlayAppearanceStyle
    let textScale: CGFloat
    let geometryScale: CGFloat
    let preferredBodyPointSize: CGFloat
    /// The fill is opaque in every setting.
    let backgroundAlpha: CGFloat
    let borderWidth: CGFloat
    /// Alpha of the light inner edge: stronger under Increase Contrast.
    let edgeAlpha: CGFloat
    let innerShadowOpacity: Float
    let outerShadowOpacity: Float
    let animationDurationScale: Double

    init(preferences: OverlayAccessibilityPreferences, appearance: OverlayAppearanceStyle) {
        self.appearance = appearance
        textScale = max(1, preferences.preferredBodyPointSize / Self.baselineBodyPointSize)
        geometryScale = 1 + 0.8 * (textScale - 1)
        preferredBodyPointSize = preferences.preferredBodyPointSize
        backgroundAlpha = 1
        borderWidth = 1
        edgeAlpha = preferences.increaseContrast ? 0.48 : 0.14
        innerShadowOpacity = preferences.reduceTransparency ? 0 : 1
        outerShadowOpacity = preferences.reduceTransparency ? 0 : 1
        animationDurationScale = preferences.reduceMotion ? 0 : 1
    }

    func scaledFontSize(_ base: CGFloat) -> CGFloat {
        base * textScale
    }

    func duration(_ base: TimeInterval) -> TimeInterval {
        base * animationDurationScale
    }

    private func g(_ value: CGFloat) -> CGFloat { (value * geometryScale).rounded() }

    var capsuleHeight: CGFloat { g(appearance == .grove ? 34 : 40) }
    /// The body below the notch, in the grove overlay.
    var groveNotchRowHeight: CGFloat { g(32) }
    /// The widest a grove row gets; text gives way beyond it.
    var groveMaximumRowWidth: CGFloat { cardWidth }
    var controlSize: CGFloat { max(28, g(28)) }
    var nibWidth: CGFloat { g(appearance == .grove ? 22 : 24) }
    var leadingInset: CGFloat { g(12) }
    var trailingInset: CGFloat { g(6) }
    var gap: CGFloat { g(10) }

    var labelFontSize: CGFloat { (13 * textScale).rounded() }
    var briefFontSize: CGFloat { (12 * textScale).rounded() }
    var timeFontSize: CGFloat { (12 * textScale).rounded() }
    var countdownFontSize: CGFloat { 12.5 * textScale }

    func capsuleWidth(_ width: OverlayPresentation.Width) -> CGFloat { g(width.rawValue) }

    var cardWidth: CGFloat { g(appearance == .grove ? 412 : 440) }
    var cardCornerRadius: CGFloat { g(appearance == .grove ? 18 : 16) }
    var cardGap: CGFloat { 8 }
    var cardInsets: NSEdgeInsets {
        appearance == .grove
            ? NSEdgeInsets(top: g(10), left: g(16), bottom: g(14), right: g(16))
            : NSEdgeInsets(top: g(12), left: g(18), bottom: g(14), right: g(18))
    }
    /// Live words: 15 pt at the default size (13 in the grove overlay), two points above body
    /// text when larger.
    var transcriptFontSize: CGFloat {
        appearance == .grove ? max(13, preferredBodyPointSize) : max(15, preferredBodyPointSize + 2)
    }
    var transcriptLineHeight: CGFloat {
        appearance == .grove ? (transcriptFontSize * 19 / 13).rounded() : (transcriptFontSize * 22 / 15).rounded()
    }
    /// Older lines fade out over the padding above the words.
    var fadeHeight: CGFloat { g(appearance == .grove ? 10 : 20) }
    /// Lines of live words the overlay shows: three in the grove overlay.
    var maximumTranscriptLines: Int { appearance == .grove ? 3 : OverlayPanelLayoutPolicy.maximumTranscriptLines }
}

extension NSEdgeInsets {
    var horizontal: CGFloat { left + right }
    var vertical: CGFloat { top + bottom }
}

enum OverlayPanelLayoutPolicy {
    static let screenEdgeInset: CGFloat = 16
    static let maximumTranscriptLines = 4
    /// The capsule's top edge below the top of the visible frame.
    static let topOffset: CGFloat = 40
    /// Transparent room around the shapes for their shadows.
    static let shadowMargins = NSEdgeInsets(top: 4, left: 24, bottom: 30, right: 24)

    static func cardHeight(metrics: OverlayAccessibilityMetrics, lines: Int) -> CGFloat {
        metrics.cardInsets.vertical + CGFloat(max(1, lines)) * metrics.transcriptLineHeight
    }

    /// Lines the live card may grow to: four, or fewer when very large text leaves less room.
    static func transcriptLineCapacity(metrics: OverlayAccessibilityMetrics, visibleFrameSize: CGSize?) -> Int {
        guard let visibleFrameSize else { return metrics.maximumTranscriptLines }
        let available = visibleFrameSize.height - 2 * screenEdgeInset - shadowMargins.vertical
            - metrics.capsuleHeight - metrics.cardGap - metrics.cardInsets.vertical
        return max(1, min(metrics.maximumTranscriptLines, Int(floor(available / metrics.transcriptLineHeight))))
    }

    /// The panel holds the capsule at its widest state width (or the live card) plus shadow room.
    static func panelSize(
        metrics: OverlayAccessibilityMetrics,
        showsTranscript: Bool,
        transcriptLines: Int,
        visibleFrameSize: CGSize?
    ) -> CGSize {
        let contentWidth = showsTranscript
            ? max(metrics.cardWidth, metrics.capsuleWidth(.problem))
            : metrics.capsuleWidth(.problem)
        var height = shadowMargins.vertical + metrics.capsuleHeight
        if showsTranscript {
            height += metrics.cardGap + cardHeight(metrics: metrics, lines: transcriptLines)
        }
        let desired = CGSize(width: contentWidth + shadowMargins.horizontal, height: height)
        guard let visibleFrameSize else { return desired }
        return CGSize(
            width: min(desired.width, max(1, visibleFrameSize.width - 2 * screenEdgeInset)),
            height: min(desired.height, max(1, visibleFrameSize.height - 2 * screenEdgeInset))
        )
    }
}

struct OverlayDisplayCandidate: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
}

enum OverlayDisplayPinPolicy {
    static func resolvedVisibleFrame(
        pinnedVisibleFrame: CGRect?,
        targetPoint: CGPoint?,
        candidates: [OverlayDisplayCandidate],
        fallbackVisibleFrame: CGRect?
    ) -> CGRect? {
        if let pinnedVisibleFrame {
            return pinnedVisibleFrame
        }
        if let targetPoint,
           let target = candidates.first(where: { $0.frame.contains(targetPoint) }) {
            return target.visibleFrame
        }
        return fallbackVisibleFrame
    }
}

enum OverlayTranscriptFormatter {
    static let maximumVisibleGraphemes = 144

    static func presentation(
        provisionalText: String,
        maximumVisibleGraphemes requestedMaximum: Int = maximumVisibleGraphemes
    ) -> OverlayTranscriptPresentation {
        let trimmed = provisionalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayMaximum = min(maximumVisibleGraphemes, max(0, requestedMaximum))
        guard displayMaximum > 0 else { return OverlayTranscriptPresentation(text: "") }
        return OverlayTranscriptPresentation(
            text: boundedPassage(trimmed, maximumVisibleGraphemes: displayMaximum)
        )
    }

    /// Returns a recent, readable suffix of the accepted provisional speech.
    /// The result is always an exact substring of that speech: display
    /// rollover never invents separators or exposes reducer mechanics.
    private static func boundedPassage(
        _ text: String,
        maximumVisibleGraphemes: Int
    ) -> String {
        let sentenceStarts = sentenceRangeStarts(in: text)

        if sentenceStarts.count >= 2 {
            let lastTwoStart = sentenceStarts[sentenceStarts.count - 2]
            let lastTwoSentences = String(text[lastTwoStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if lastTwoSentences.count <= maximumVisibleGraphemes {
                return lastTwoSentences
            }
        }

        guard text.count > maximumVisibleGraphemes else { return text }
        let hardStart = text.index(
            text.endIndex,
            offsetBy: -maximumVisibleGraphemes
        )

        if let completeSentenceStart = sentenceStarts.first(where: { $0 >= hardStart }) {
            return String(text[completeSentenceStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return wordBoundedSuffix(text, hardStart: hardStart)
    }

    private static func sentenceRangeStarts(in text: String) -> [String.Index] {
        guard !text.isEmpty else { return [] }
        var starts: [String.Index] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let contentStart = text[range]
                .firstIndex(where: { !$0.isWhitespace })
                ?? range.lowerBound
            if contentStart < range.upperBound {
                starts.append(contentStart)
            }
        }
        return starts
    }

    private static func wordBoundedSuffix(
        _ text: String,
        hardStart: String.Index
    ) -> String {
        guard hardStart > text.startIndex else { return text }
        let precedingIndex = text.index(before: hardStart)
        if text[precedingIndex].isWhitespace {
            return String(text[hardStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let firstWhitespace = text[hardStart...].firstIndex(where: { $0.isWhitespace }) else {
            return String(text[hardStart...])
        }
        let completeWordStart = text.index(after: firstWhitespace)
        let suffix = text[completeWordStart...].drop(while: { $0.isWhitespace })
        return suffix.isEmpty ? String(text[hardStart...]) : String(suffix)
    }
}

struct OverlayTranscriptPresentation: Equatable {
    let text: String
}

// MARK: - Colours and type

/// The overlay's own colours. They do not follow the accent: indigo means "Steno has the
/// microphone or your words" wherever it appears.
enum OverlayPalette {
    static let workingLight = QuillColor(hex: 0x142C8C)
    static let workingDark = QuillColor(hex: 0x1B2A7A)
    static let ink = NSColor(srgbRed: 237.0 / 255, green: 242.0 / 255, blue: 1, alpha: 1)
    static let caution = NSColor(srgbRed: 240.0 / 255, green: 179.0 / 255, blue: 122.0 / 255, alpha: 1)
    static let wetInk = NSColor(srgbRed: 142.0 / 255, green: 192.0 / 255, blue: 245.0 / 255, alpha: 1)
    static let wetUnderline = wetInk.withAlphaComponent(0.7)
    static let discardGlyph = NSColor(srgbRed: 214.0 / 255, green: 222.0 / 255, blue: 242.0 / 255, alpha: 1)
    static let stopFill = ink
    static let stopLabel = NSColor(srgbRed: 13.0 / 255, green: 19.0 / 255, blue: 48.0 / 255, alpha: 1)
    static let shadow = NSColor(srgbRed: 6.0 / 255, green: 9.0 / 255, blue: 20.0 / 255, alpha: 1)
}

/// Archivo and Azeret Mono when they are registered in the process, otherwise the system
/// faces at the same size and weight.
@MainActor
enum OverlayTypography {
    private static var cache: [String: NSFont] = [:]

    static func text(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        font(family: "Archivo", size: size, weight: weight) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Times and keys. Falls back to the system face with monospaced digits.
    static func mono(size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        font(family: "Azeret Mono", size: size, weight: weight) ?? .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let key = "\(family)|\(size)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == family else { return nil }
        cache[key] = font
        return font
    }
}

// MARK: - Views

/// A rounded, opaque indigo surface with a light inner edge and one soft shadow drawn from a
/// fixed path.
@MainActor
class OverlaySurfaceView: NSView {
    var fillColor: NSColor = .systemIndigo { didSet { updateLayer() } }
    var edgeColor: NSColor = .clear { didSet { updateLayer() } }
    var edgeWidth: CGFloat = 1 { didSet { updateLayer() } }
    var cornerRadius: CGFloat = 20 { didSet { updateLayer() } }
    var shadowOpacity: Float = 1 { didSet { updateLayer() } }
    var shadowOffsetY: CGFloat = 12
    var shadowBlur: CGFloat = 32
    var shadowSpread: CGFloat = 10
    var shadowAlpha: CGFloat = 0.6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShadowPath()
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fillColor.cgColor
        layer.cornerRadius = cornerRadius
        layer.borderColor = edgeColor.cgColor
        layer.borderWidth = edgeWidth
        layer.masksToBounds = false
        layer.shadowColor = OverlayPalette.shadow.withAlphaComponent(shadowAlpha).cgColor
        layer.shadowOpacity = shadowOpacity
        layer.shadowRadius = shadowBlur / 2
        // Shadow offsets are in Core Animation's y-up space even inside a flipped view.
        layer.shadowOffset = CGSize(width: 0, height: -shadowOffsetY)
        updateShadowPath()
    }

    private func updateShadowPath() {
        guard let layer else { return }
        let rect = bounds.insetBy(dx: shadowSpread, dy: shadowSpread)
        guard rect.width > 0, rect.height > 0 else {
            layer.shadowPath = nil
            return
        }
        let radius = max(0, min(cornerRadius - shadowSpread, rect.height / 2))
        let newPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if let animation = layer.animation(forKey: "bounds.size") {
            let pathAnimation = CABasicAnimation(keyPath: "shadowPath")
            pathAnimation.fromValue = layer.presentation()?.shadowPath ?? layer.shadowPath
            pathAnimation.toValue = newPath
            pathAnimation.duration = animation.duration
            pathAnimation.timingFunction = animation.timingFunction
            layer.add(pathAnimation, forKey: "shadowPath")
        }
        layer.shadowPath = newPath
    }
}

/// The capsule. It reports pointer movement for hover holds and is one accessibility group.
@MainActor
final class OverlayCapsuleView: OverlaySurfaceView {
    enum PointerEvent { case moved, exited }

    var hoverChanged: ((PointerEvent) -> Void)?
    var isPointerInside = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }

    override func mouseMoved(with event: NSEvent) {
        isPointerInside = true
        hoverChanged?(.moved)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        hoverChanged?(.exited)
    }
}

@MainActor
final class OverlayCardView: OverlaySurfaceView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cornerRadius = 16
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Hosts the quill. Hidden from accessibility: the label carries the state in words.
@MainActor
final class OverlayNibView: NSView {
    let nib = NibLayer(palette: .onWorking)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(nib)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nib.frame = bounds
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nib.frame = CGRect(origin: .zero, size: newSize)
        CATransaction.commit()
    }
}

/// The overlay's buttons and keycap, drawn to match the capsule: Stop (light pill with a
/// square), an action chip, the round discard ×, and a ⌘V keycap that is not a button.
/// Responds on press, accepts the first mouse and never takes focus from the frontmost app.
@MainActor
final class OverlayCapsuleControl: NSControl {
    enum Style { case stop, chip, discard, keycap }

    let style: Style
    var title = "" { didSet { needsDisplay = true } }
    var pressAction: (() -> Void)?
    var metricsScale: CGFloat = 1 { didSet { needsDisplay = true } }
    var textScale: CGFloat = 1 { didSet { needsDisplay = true } }
    var increaseContrast = false { didSet { needsDisplay = true } }
    /// The quiet look: a cream disc with a forest square for Stop, cream buttons with forest
    /// text, a soft round ×, and a capsule keycap.
    var isGrove = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        if style == .keycap {
            setAccessibilityElement(false)
        } else {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var controlFont: NSFont {
        if isGrove {
            switch style {
            case .stop: return .systemFont(ofSize: (12 * textScale).rounded(), weight: .semibold)
            case .chip: return GroveFonts(textScale: textScale).chip
            case .keycap: return GroveFonts(textScale: textScale).keycap
            case .discard: return .systemFont(ofSize: 12, weight: .regular)
            }
        }
        return switch style {
        case .stop: OverlayTypography.text(size: (12 * textScale).rounded(), weight: .semibold)
        case .chip: OverlayTypography.text(size: (12 * textScale).rounded(), weight: .medium)
        case .keycap: OverlayTypography.mono(size: (11 * textScale).rounded())
        case .discard: OverlayTypography.text(size: 12, weight: .regular)
        }
    }

    private var iconSize: CGFloat {
        switch style {
        case .stop: (10 * metricsScale).rounded()
        case .discard: (12 * metricsScale).rounded()
        default: 0
        }
    }

    private var titleWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: controlFont]).width)
    }

    var intrinsicWidth: CGFloat {
        if isGrove {
            switch style {
            case .stop, .discard: return (22 * metricsScale).rounded()
            case .chip: return titleWidth + 20 * metricsScale
            case .keycap: return titleWidth + 12 * metricsScale
            }
        }
        return switch style {
        case .stop: (10 * metricsScale).rounded() + iconSize + (6 * metricsScale).rounded() + titleWidth + (11 * metricsScale).rounded()
        case .chip: titleWidth + 2 * (11 * metricsScale).rounded()
        case .keycap: titleWidth + 2 * (6 * metricsScale).rounded()
        case .discard: (28 * metricsScale).rounded()
        }
    }

    var intrinsicHeight: CGFloat {
        let f = controlFont
        return ceil(f.ascender - f.descender) + 2 * (3 * metricsScale).rounded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard style != .keycap else { return }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    override func mouseDown(with event: NSEvent) {
        guard style != .keycap, isEnabled, !isHidden else { return }
        // Respond on press, not release: the overlay is on screen only briefly.
        isPressed = true
        performClick(nil)
    }

    override func mouseUp(with event: NSEvent) { isPressed = false }

    override func performClick(_ sender: Any?) {
        guard style != .keycap, isEnabled, !isHidden else { return }
        pressAction?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard style != .keycap, isEnabled, !isHidden else { return false }
        pressAction?()
        return true
    }

    private var fill: NSColor {
        if isGrove {
            switch style {
            case .stop, .chip: return GrovePalette.cream.withAlphaComponent(isPressed ? 0.82 : (isHovered ? 0.94 : 1))
            case .discard: return NSColor.white.withAlphaComponent(isPressed ? 0.22 : (isHovered ? 0.16 : 0.12))
            case .keycap: return NSColor.white.withAlphaComponent(0.12)
            }
        }
        switch style {
        case .stop:
            return OverlayPalette.stopFill
        case .chip:
            return .white.withAlphaComponent(isPressed ? 0.26 : (isHovered ? 0.18 : 0.10))
        case .discard:
            return .white.withAlphaComponent(isPressed ? 0.26 : (isHovered ? 0.18 : 0.09))
        case .keycap:
            return .white.withAlphaComponent(0.12)
        }
    }

    private var foreground: NSColor {
        if isGrove {
            switch style {
            case .stop, .chip: return GrovePalette.onCream
            case .keycap: return GrovePalette.cream
            case .discard: return increaseContrast ? GrovePalette.cream : GrovePalette.subtext
            }
        }
        return switch style {
        case .stop: OverlayPalette.stopLabel
        case .chip, .keycap: OverlayPalette.ink
        case .discard: increaseContrast ? OverlayPalette.ink : OverlayPalette.discardGlyph
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // One radius system: every control is a capsule, concentric with the island.
        let radius = style == .keycap && !isGrove ? (5 * metricsScale).rounded() : bounds.height / 2
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if increaseContrast, style != .stop {
            (isGrove ? GrovePalette.cream : OverlayPalette.ink).withAlphaComponent(0.48).setStroke()
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            edge.lineWidth = 1
            edge.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: controlFont, .foregroundColor: foreground]
        let titleSize = (title as NSString).size(withAttributes: attributes)
        let titleY = (bounds.height - titleSize.height) / 2
        switch style {
        case .discard:
            let side = isGrove ? (11 * metricsScale).rounded() : iconSize
            let box = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            drawIcon(in: box, stroke: 1.6) { path in
                path.move(to: NSPoint(x: 4.2, y: 4.2)); path.line(to: NSPoint(x: 11.8, y: 11.8))
                path.move(to: NSPoint(x: 11.8, y: 4.2)); path.line(to: NSPoint(x: 4.2, y: 11.8))
            }
        case .stop where isGrove:
            // A forest square, 8 pt of the 22 pt disc.
            let side = (8 * metricsScale).rounded()
            foreground.setFill()
            let square = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()
        case .stop:
            let side = iconSize
            let leading = (10 * metricsScale).rounded()
            let box = NSRect(x: leading, y: (bounds.height - side) / 2, width: side, height: side)
            drawIcon(in: box, stroke: 1.6) { path in
                path.appendRoundedRect(NSRect(x: 4, y: 4, width: 8, height: 8), xRadius: 1.6, yRadius: 1.6)
            }
            (title as NSString).draw(at: NSPoint(x: box.maxX + (6 * metricsScale).rounded(), y: titleY), withAttributes: attributes)
        case .chip, .keycap:
            (title as NSString).draw(at: NSPoint(x: (bounds.width - titleSize.width) / 2, y: titleY), withAttributes: attributes)
        }
    }

    /// Strokes a 16-unit icon (the design's icon grid) into `box`.
    private func drawIcon(in box: NSRect, stroke: CGFloat, build: (NSBezierPath) -> Void) {
        let path = NSBezierPath()
        build(path)
        var transform = AffineTransform(translationByX: box.minX, byY: box.minY)
        transform.scale(box.width / 16)
        path.transform(using: transform)
        path.lineWidth = stroke * box.width / 16
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        foreground.setStroke()
        path.stroke()
    }
}

private func colorsApproximatelyEqual(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
    guard let lhs = lhs?.usingColorSpace(.deviceRGB),
          let rhs = rhs.usingColorSpace(.deviceRGB) else { return false }
    return approximatelyEqual(lhs.redComponent, rhs.redComponent)
        && approximatelyEqual(lhs.greenComponent, rhs.greenComponent)
        && approximatelyEqual(lhs.blueComponent, rhs.blueComponent)
        && approximatelyEqual(lhs.alphaComponent, rhs.alphaComponent)
}

private func approximatelyEqual(
    _ lhs: CGFloat,
    _ rhs: CGFloat,
    tolerance: CGFloat = 0.01
) -> Bool {
    abs(lhs - rhs) <= tolerance
}

/// The overlay's window: never key, never main, so it cannot take focus from the app that is
/// receiving the dictation.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayPassthroughContainer: NSView {
    var interactiveButtons: [NSView] = []
    var appearanceDidChange: (() -> Void)?

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        OverlayHitTesting.interactiveView(at: point, in: self, interactiveViews: interactiveButtons)
    }
}
#endif
