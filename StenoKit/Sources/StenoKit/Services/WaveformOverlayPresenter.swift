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

@MainActor
public final class WaveformOverlayPresenter: OverlayPresenter {
    private var window: NSWindow?
    private var wrapperView: NSView?
    private var contentBackground: NSView?
    private var outerShadowLayer: CALayer?
    private var barLayers: [CALayer] = []
    private var iconLayer: CALayer?
    private var textField: NSTextField?
    private var transcriptField: NSTextField?
    private var cancelButton: OverlayCancelButton?
    private var cancelAction: (() -> Void)?
    private var cancelButtonVisible = false
    private var timer: Timer?
    private var listeningStartDate: Date?
    private var listeningHandsFree = false
    private var wasHidden = true
    private var barsVisible = true
    private var configuredLiveTranscriptEnabled = true
    private var liveTranscriptEnabled = true
    private var listeningSessionIsActive = false
    private var liveTranscriptSession: LiveTranscriptionSession?
    private var lastReceivedLiveRevision: UInt64?
    private var liveRenderBuffer = OverlayLiveRenderBuffer()
    private var liveRenderTimer: Timer?
    private var liveRenderTimerToken: UUID?
    private var lastLiveRenderTime: TimeInterval?
    private var lastRenderedProvisionalText: String?
    private var livePreviewUnavailable = false
    private var liveUpdateGate = OverlayLiveUpdateGate()
    private var pinnedScreenFrame: NSRect?
    private var captureTargetPoint: NSPoint?
    private var lastAnnouncement: OverlayAnnouncement?
    private var announcementGate = OverlayAnnouncementGate()
    private var accentColor = WaveformOverlayPresenter.defaultAccent
    private var accessibilityObserver: NSObjectProtocol?
    #if DEBUG
    private var hostedEvidenceHandler: ((WaveformOverlayHostedEvidenceEvent) -> Void)?
    private var hostedAccessibilityPreferencesOverride: OverlayAccessibilityPreferences?
    private var rendersOffscreen = false
    #endif

    // MARK: - Constants

    private static let compactCornerRadius: CGFloat = 18
    private static let liveCornerRadius: CGFloat = 18
    private static let barCount = 5
    private static let barWidth: CGFloat = 3.5
    private static let barSpacing: CGFloat = 3
    private static let barCornerRadius: CGFloat = 1.75
    private static let barClusterX: CGFloat = 22
    private static let iconSize: CGFloat = 16

    private static let defaultAccent = NSColor(red: 30.0 / 255.0, green: 144.0 / 255.0, blue: 1.0, alpha: 1.0)
    private static let successColor = NSColor(red: 110.0 / 255.0, green: 191.0 / 255.0, blue: 140.0 / 255.0, alpha: 1.0)
    private static let warningColor = NSColor(red: 224.0 / 255.0, green: 183.0 / 255.0, blue: 113.0 / 255.0, alpha: 1.0)
    private static let errorColor = NSColor(red: 242.0 / 255.0, green: 113.0 / 255.0, blue: 106.0 / 255.0, alpha: 1.0)

    /// Min and max heights for each bar (index 0..4). Center bar tallest.
    private static let barRanges: [(min: CGFloat, max: CGFloat)] = [
        (5, 10), (7, 14), (10, 20), (7, 14), (5, 10)
    ]
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
            preferredBodyPointSize: NSFont.preferredFont(
                forTextStyle: .body,
                options: [:]
            ).pointSize
        )
    }

    private var reduceTransparency: Bool { accessibilityPreferences.reduceTransparency }
    private var increaseContrast: Bool { accessibilityPreferences.increaseContrast }

    private var preferredBodyFont: NSFont {
        #if DEBUG
        if let hostedAccessibilityPreferencesOverride {
            return NSFont.systemFont(ofSize: hostedAccessibilityPreferencesOverride.preferredBodyPointSize)
        }
        #endif
        return NSFont.preferredFont(forTextStyle: .body, options: [:])
    }

    private var preferredCaptionFont: NSFont {
        #if DEBUG
        if let hostedAccessibilityPreferencesOverride {
            return NSFont.systemFont(
                ofSize: max(11, hostedAccessibilityPreferencesOverride.preferredBodyPointSize * 0.82),
                weight: .medium
            )
        }
        #endif
        return NSFont.preferredFont(forTextStyle: .caption1, options: [:])
    }

    private var accessibilityMetrics: OverlayAccessibilityMetrics {
        OverlayAccessibilityMetrics(preferences: accessibilityPreferences)
    }

    private var activePanelSize: NSSize {
        OverlayPanelLayoutPolicy.panelSize(
            showsTranscript: showsLiveTranscriptPanel,
            textScale: accessibilityMetrics.textScale,
            preferredBodyPointSize: preferredBodyFont.pointSize,
            preferredCaptionPointSize: preferredCaptionFont.pointSize,
            visibleFrameSize: pinnedScreenFrame?.size
                ?? window?.screen?.visibleFrame.size
                ?? NSScreen.main?.visibleFrame.size
        )
    }

    private var showsLiveTranscriptPanel: Bool {
        listeningSessionIsActive && liveTranscriptEnabled && !livePreviewUnavailable
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
    }

    isolated deinit {
        timer?.invalidate()
        timer = nil
        liveRenderTimer?.invalidate()
        liveRenderTimer = nil
        liveRenderTimerToken = nil
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
    }

    // MARK: - OverlayPresenter

    @MainActor
    public func prepareWindow() {
        ensureWindow()
    }

    @MainActor
    public func setCancelAction(_ action: (() -> Void)?) {
        cancelAction = action
    }

    @MainActor
    public func updateAccentColor(_ color: NSColor, glowColor: NSColor? = nil) {
        accentColor = color.usingColorSpace(.deviceRGB) ?? color
        _ = glowColor

        if barsVisible {
            setBarColor(accentColor)
        }
    }

    @MainActor
    public func setLiveTranscriptEnabled(_ isEnabled: Bool) {
        configuredLiveTranscriptEnabled = isEnabled
        liveUpdateGate.setConfiguredEnabled(isEnabled)
        guard !listeningSessionIsActive else { return }
        liveTranscriptEnabled = isEnabled
    }

    @MainActor
    public func pinNextSessionToDisplay(containing targetPoint: CGPoint?) {
        guard !listeningSessionIsActive else { return }
        captureTargetPoint = targetPoint
        pinnedScreenFrame = nil
    }

    @MainActor
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

    @MainActor
    public func showLiveTranscriptUnavailable() {
        guard liveUpdateGate.markUnavailable() else { return }
        livePreviewUnavailable = true
        liveRenderBuffer.clear()
        liveRenderTimer?.invalidate()
        liveRenderTimer = nil
        liveRenderTimerToken = nil
        renderLivePreviewUnavailable()
    }

    @MainActor
    public func show(state: OverlayState) {
        #if DEBUG
        let hostedCallStart = ProcessInfo.processInfo.systemUptime
        #endif
        ensureWindow()

        wasHidden = false

        if case .listening(let handsFree, _) = state, listeningSessionIsActive {
            listeningHandsFree = handsFree
            updateListeningText()
            return
        }
        switch state {
        case .listening(let handsFree, _):
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
            resizePanelForCurrentSession()
            listeningHandsFree = handsFree
            if case .listening(_, let elapsedSeconds) = state {
                listeningStartDate = Date().addingTimeInterval(-TimeInterval(max(0, elapsedSeconds)))
            }
            updateListeningText()
            showLiveTranscriptPlaceholderIfNeeded()
            startTimer()
            showBars()
            setBarColor(accentColor)
            showCancelControl()
            announceOnce(.sessionStarted, message: "Steno dictation started")

        case .transcribing:
            endListeningPresentation()
            resizePanelForCurrentSession()
            stopTimer()
            collapseBars()
            updateText("Transcribing...")
            hideLiveTranscriptFields()
            setBarColor(.darkGray)
            hideCancelControl()

        case .inserted:
            endListeningPresentation()
            resizePanelForCurrentSession()
            stopTimer()
            hideBarsShowIcon("checkmark.circle.fill", color: Self.successColor)
            updateText("Inserted")
            hideLiveTranscriptFields()
            hideCancelControl()
            announceOnce(.inserted, message: "Steno inserted the final transcript")

        case .copiedOnly:
            endListeningPresentation()
            resizePanelForCurrentSession()
            stopTimer()
            hideBarsShowIcon("doc.on.clipboard.fill", color: Self.warningColor)
            updateText("Copied to clipboard")
            hideLiveTranscriptFields()
            hideCancelControl()
            announceOnce(.copiedOnly, message: "Steno copied the final transcript to the clipboard")

        case .failure(let message):
            endListeningPresentation()
            resizePanelForCurrentSession()
            stopTimer()
            hideBarsShowIcon("exclamationmark.triangle.fill", color: Self.errorColor)
            updateText("Error: \(message)")
            hideLiveTranscriptFields()
            hideCancelControl()
            announceOnce(.failure, message: "Steno error: \(message)")

        case .noSpeechDetected:
            endListeningPresentation()
            resizePanelForCurrentSession()
            stopTimer()
            hideBarsShowIcon("mic.slash.fill", color: .systemGray)
            updateText("No speech detected")
            hideLiveTranscriptFields()
            hideCancelControl()
            announceOnce(.noSpeech, message: "Steno detected no speech")
        }

        centerWindowNearTop()
        presentWindow()
        #if DEBUG
        if case .listening = state {
            hostedEvidenceHandler?(.listeningPresented(
                elapsedMilliseconds: max(
                    0,
                    (ProcessInfo.processInfo.systemUptime - hostedCallStart) * 1_000
                )
            ))
        }
        #endif
    }

    @MainActor
    public func hide() {
        if listeningSessionIsActive {
            announceOnce(.cancelled, message: "Steno dictation cancelled")
        }
        endListeningPresentation()
        stopTimer()
        stopBarAnimations()
        hideCancelControl()
        wasHidden = true
        pinnedScreenFrame = nil
        captureTargetPoint = nil
        liveTranscriptSession = nil
        lastReceivedLiveRevision = nil
        lastAnnouncement = nil
        window?.alphaValue = 1
        window?.orderOut(nil)
    }

    // MARK: - Window Setup

    @MainActor
    private func ensureWindow() {
        if window != nil { return }

        let size = activePanelSize
        let contentRect = NSRect(origin: .zero, size: size)
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let content = NSView(frame: contentRect)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = activeCornerRadius
        content.layer?.masksToBounds = false
        content.layer?.backgroundColor = panelBackgroundColor.cgColor
        content.layer?.borderWidth = panelBorderWidth
        content.layer?.borderColor = panelBorderColor.cgColor

        // Layered shadow system for natural depth
        // Inner contact shadow
        content.layer?.shadowColor = NSColor.black.withAlphaComponent(0.10).cgColor
        content.layer?.shadowOffset = CGSize(width: 0, height: -1)
        content.layer?.shadowRadius = 6
        content.layer?.shadowOpacity = 1
        self.contentBackground = content

        // Outer ambient shadow (separate layer behind content)
        let outerShadow = CALayer()
        outerShadow.frame = contentRect
        outerShadow.cornerRadius = activeCornerRadius
        outerShadow.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.01).cgColor
        outerShadow.shadowColor = NSColor.black.withAlphaComponent(0.28).cgColor
        outerShadow.shadowOffset = CGSize(width: 0, height: -6)
        outerShadow.shadowRadius = 28
        outerShadow.shadowOpacity = 1

        // Insert outer shadow behind content in the panel
        let wrapper = OverlayPassthroughContainer(frame: contentRect)
        wrapper.autoresizingMask = [.width, .height]
        wrapper.wantsLayer = true
        wrapper.layer?.addSublayer(outerShadow)
        wrapper.addSubview(content)
        self.wrapperView = wrapper
        self.outerShadowLayer = outerShadow

        // Waveform bars
        let barClusterWidth = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing
        let clusterCenterY = barCenterY
        barLayers = []

        for i in 0..<Self.barCount {
            let barX = Self.barClusterX + CGFloat(i) * (Self.barWidth + Self.barSpacing)
            let range = Self.barRanges[i]
            let midHeight = (range.min + range.max) / 2

            // Use gradient layer for each bar
            let bar = CAGradientLayer()
            bar.frame = CGRect(x: barX, y: clusterCenterY - midHeight / 2, width: Self.barWidth, height: midHeight)
            bar.cornerRadius = Self.barCornerRadius
            bar.colors = [accentHighlightColor.cgColor, accentColor.cgColor]
            bar.startPoint = CGPoint(x: 0.5, y: 0)
            bar.endPoint = CGPoint(x: 0.5, y: 1)
            content.layer?.addSublayer(bar)
            barLayers.append(bar)
        }

        // Icon layer (hidden by default, used for terminal states)
        let iconX = Self.barClusterX + (barClusterWidth - Self.iconSize) / 2
        let iconY = clusterCenterY - Self.iconSize / 2
        let icon = CALayer()
        icon.frame = CGRect(x: iconX, y: iconY, width: Self.iconSize, height: Self.iconSize)
        icon.contentsGravity = .resizeAspect
        icon.opacity = 0
        content.layer?.addSublayer(icon)
        self.iconLayer = icon

        // Text label
        let label = NSTextField(labelWithString: "Listening 00:00")
        label.font = preferredCaptionFont
        label.textColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("Dictation status")
        content.addSubview(label)

        let transcript = NSTextField(wrappingLabelWithString: "")
        transcript.font = preferredBodyFont
        transcript.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        transcript.maximumNumberOfLines = 3
        transcript.lineBreakMode = .byWordWrapping
        transcript.setAccessibilityLabel("Live transcript")
        transcript.setAccessibilityValue("")
        content.addSubview(transcript)
        self.transcriptField = transcript

        let cancel = OverlayCancelButton(frame: .zero)
        cancel.isHidden = true
        cancel.alphaValue = 0
        cancel.setPressAction { [weak self] in
            self?.handleCancelButtonPressed()
        }
        content.addSubview(cancel)
        self.cancelButton = cancel
        wrapper.interactiveButton = cancel

        panel.contentView = wrapper
        self.window = panel
        self.textField = label
        layoutOverlayContent(for: size)
        applyAccessibilityAppearance()
    }

    @MainActor
    private func resizePanelForCurrentSession() {
        ensureWindow()
        resolvePinnedScreenFrameIfNeeded()
        guard let window else { return }
        let size = activePanelSize
        window.setContentSize(size)
        wrapperView?.frame = NSRect(origin: .zero, size: size)
        contentBackground?.frame = NSRect(origin: .zero, size: size)
        outerShadowLayer?.frame = NSRect(origin: .zero, size: size)
        layoutOverlayContent(for: size)
        applyAccessibilityAppearance()
    }

    @MainActor
    private func layoutOverlayContent(for size: NSSize) {
        let geometry = OverlayPanelLayoutPolicy.contentGeometry(
            panelSize: size,
            showsTranscript: showsLiveTranscriptPanel,
            preferredBodyPointSize: preferredBodyFont.pointSize,
            preferredCaptionPointSize: preferredCaptionFont.pointSize
        )
        let transcriptLeading = Self.barClusterX
            + CGFloat(Self.barCount) * Self.barWidth
            + CGFloat(Self.barCount - 1) * Self.barSpacing
            + 14
        let trailingInset: CGFloat = 52
        let textWidth = max(80, size.width - transcriptLeading - trailingInset)

        if showsLiveTranscriptPanel {
            textField?.frame = NSRect(
                x: transcriptLeading,
                y: geometry.statusFrame.minY,
                width: textWidth,
                height: geometry.statusFrame.height
            )
            transcriptField?.frame = NSRect(
                x: Self.barClusterX,
                y: geometry.transcriptFrame.minY,
                width: max(0, size.width - 2 * Self.barClusterX),
                height: geometry.transcriptFrame.height
            )
        } else {
            textField?.frame = NSRect(
                x: transcriptLeading,
                y: geometry.statusFrame.minY,
                width: textWidth,
                height: geometry.statusFrame.height
            )
            transcriptField?.isHidden = true
        }

        cancelButton?.frame = NSRect(
            x: size.width - 40,
            y: size.height - 40,
            width: 24,
            height: 24
        )

        for bar in barLayers {
            bar.position = CGPoint(x: bar.position.x, y: barCenterY)
        }
        iconLayer?.position = CGPoint(
            x: iconLayer?.position.x ?? 0,
            y: barCenterY
        )
    }

    @MainActor
    private var barCenterY: CGFloat {
        showsLiveTranscriptPanel ? activePanelSize.height - 28 : activePanelSize.height / 2
    }

    @MainActor
    private var activeCornerRadius: CGFloat {
        showsLiveTranscriptPanel ? Self.liveCornerRadius : Self.compactCornerRadius
    }

    @MainActor
    private var panelBorderWidth: CGFloat {
        accessibilityMetrics.borderWidth
    }

    @MainActor
    private func showLiveTranscriptPlaceholderIfNeeded() {
        guard liveTranscriptEnabled else {
            hideLiveTranscriptFields()
            return
        }
        transcriptField?.isHidden = false
        transcriptField?.attributedStringValue = NSAttributedString(string: "")
        transcriptField?.setAccessibilityValue("")
    }

    @MainActor
    private func hideLiveTranscriptFields() {
        transcriptField?.isHidden = true
    }

    @MainActor
    private func scheduleLiveRenderIfNeeded() {
        guard liveRenderTimer == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay: TimeInterval
        delay = OverlayLiveUpdatePolicy.delay(
            lastRenderTime: lastLiveRenderTime,
            now: now
        )

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

    @MainActor
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

        let presentation = fittedTranscriptPresentation(
            provisionalText: snapshot.provisionalText
        )
        lastRenderedProvisionalText = snapshot.provisionalText
        transcriptField?.isHidden = false
        transcriptField?.attributedStringValue = transcriptAttributedString(presentation.text)
        transcriptField?.setAccessibilityValue(presentation.text)

        if liveRenderBuffer.pendingSnapshot != nil {
            scheduleLiveRenderIfNeeded()
        }
        #if DEBUG
        let renderedAt = ProcessInfo.processInfo.systemUptime
        if let renderedRevision = snapshot.lastAcceptedRevision {
            hostedEvidenceHandler?(.previewRendered(
                mainActorWorkMilliseconds: max(
                    0,
                    (renderedAt - hostedRenderStartedAt) * 1_000
                ),
                renderStartedMonotonicMilliseconds: hostedRenderStartedAt * 1_000,
                sessionID: snapshot.session.sessionID,
                revision: renderedRevision
            ))
        }
        #endif
    }

    @MainActor
    private func fittedTranscriptPresentation(
        provisionalText: String
    ) -> OverlayTranscriptPresentation {
        guard let transcriptField else {
            return OverlayTranscriptFormatter.presentation(provisionalText: provisionalText)
        }
        var budget = max(
            1,
            OverlayPanelLayoutPolicy.estimatedVisibleGraphemeBudget(
                textWidth: transcriptField.bounds.width,
                textHeight: transcriptField.bounds.height,
                preferredBodyPointSize: preferredBodyFont.pointSize
            )
        )

        while budget > 0 {
            let presentation = OverlayTranscriptFormatter.presentation(
                provisionalText: provisionalText,
                maximumVisibleGraphemes: budget
            )
            guard !presentation.text.isEmpty else { return presentation }
            if transcriptTextFitsField(presentation.text) {
                return presentation
            }
            budget = min(budget - 1, presentation.text.count - 1)
        }
        return OverlayTranscriptPresentation(text: "")
    }

    @MainActor
    private func transcriptAttributedString(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: preferredBodyFont,
                .foregroundColor: increaseContrast
                    ? NSColor.white
                    : NSColor(calibratedWhite: 0.96, alpha: 1)
            ]
        )
    }

    @MainActor
    private func transcriptTextFitsField(_ text: String) -> Bool {
        guard let transcriptField,
              transcriptField.bounds.width > 0,
              transcriptField.bounds.height > 0 else {
            return text.isEmpty
        }
        let measured = transcriptAttributedString(text).boundingRect(
            with: CGSize(
                width: transcriptField.bounds.width,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(measured.height) <= floor(transcriptField.bounds.height)
            && ceil(measured.width) <= ceil(transcriptField.bounds.width)
    }

    @MainActor
    private func renderLivePreviewUnavailable() {
        clearLiveTranscriptContent()
        resizePanelForCurrentSession()
        centerWindowNearTop()
    }

    @MainActor
    private func endListeningPresentation() {
        listeningSessionIsActive = false
        liveUpdateGate.endListening()
        liveTranscriptSession = nil
        liveRenderBuffer.clear()
        liveRenderTimer?.invalidate()
        liveRenderTimer = nil
        liveRenderTimerToken = nil
        lastLiveRenderTime = nil
        livePreviewUnavailable = false
        clearLiveTranscriptContent()
        #if DEBUG
        hostedEvidenceHandler?(.previewCleared)
        #endif
    }

    @MainActor
    private func clearLiveTranscriptContent() {
        lastRenderedProvisionalText = nil
        transcriptField?.stringValue = ""
        transcriptField?.attributedStringValue = NSAttributedString(string: "")
        transcriptField?.setAccessibilityValue("")
    }

    @MainActor
    private func rerenderCurrentTranscriptToFitIfNeeded() {
        guard showsLiveTranscriptPanel,
              let lastRenderedProvisionalText else { return }
        let presentation = fittedTranscriptPresentation(
            provisionalText: lastRenderedProvisionalText
        )
        transcriptField?.attributedStringValue = transcriptAttributedString(presentation.text)
        transcriptField?.setAccessibilityValue(presentation.text)
    }

    #if DEBUG
    @MainActor
    func setHostedEvidenceHandler(
        _ handler: ((WaveformOverlayHostedEvidenceEvent) -> Void)?
    ) {
        hostedEvidenceHandler = handler
    }

    @MainActor
    func hostedEvidenceTextSurfacesAreEmpty() -> Bool {
        [
            transcriptField?.stringValue ?? "",
            transcriptField?.attributedStringValue.string ?? "",
            transcriptField?.accessibilityValue() as? String ?? "",
        ].allSatisfy(\.isEmpty)
    }

    @MainActor
    func hostedEvidenceRenderPNG(
        state: OverlayState,
        snapshot: LiveTranscriptionSnapshot? = nil
    ) -> Data? {
        // Render only this presenter's view tree. Never order a panel or
        // announce synthetic content while generating visual fixtures.
        rendersOffscreen = true
        defer {
            hide()
            rendersOffscreen = false
        }
        show(state: state)
        if let snapshot {
            updateLiveTranscript(snapshot)
            renderPendingLiveSnapshot()
        }
        stopTimer()
        guard let content = contentBackground else { return nil }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    @MainActor
    func hostedEvidenceHasOneTranscriptSurface() -> Bool {
        transcriptField != nil
            && transcriptField?.accessibilityLabel() == "Live transcript"
            && transcriptField?.maximumNumberOfLines == 3
            && transcriptField?.lineBreakMode == .byWordWrapping
    }

    @MainActor
    func hostedEvidenceVisibleTranscript() -> String {
        transcriptField?.attributedStringValue.string ?? ""
    }

    @MainActor
    func hostedEvidenceUsesCompactUnavailableShell() -> Bool {
        livePreviewUnavailable
            && !showsLiveTranscriptPanel
            && window?.frame.size == activePanelSize
            && transcriptField?.isHidden == true
            && hostedEvidenceTextSurfacesAreEmpty()
            && hostedEvidenceControlsMatchListeningState()
    }

    @MainActor
    func hostedEvidenceUsesPreferredTypography() -> Bool {
        textField?.font == NSFont.preferredFont(forTextStyle: .caption1, options: [:])
            && transcriptField?.font == NSFont.preferredFont(forTextStyle: .body, options: [:])
    }

    @MainActor
    func hostedEvidenceRecordingPresentationIsImmediateAndStatic() -> Bool {
        window?.alphaValue == 1
            && barsVisible
            && barLayers.allSatisfy {
                $0.opacity == 1
                    && ($0.animationKeys() ?? []).isEmpty
                    && CATransform3DEqualToTransform($0.transform, CATransform3DIdentity)
            }
            && iconLayer?.opacity == 0
            && cancelButton?.isHidden == false
            && cancelButton?.alphaValue == 1
    }

    @MainActor
    func hostedEvidenceUserFacingStrings() -> [String] {
        [
            textField?.stringValue ?? "",
            textField?.accessibilityLabel() ?? "",
            textField?.accessibilityValue() as? String ?? "",
            transcriptField?.stringValue ?? "",
            transcriptField?.attributedStringValue.string ?? "",
            transcriptField?.accessibilityLabel() ?? "",
            transcriptField?.accessibilityValue() as? String ?? "",
            cancelButton?.toolTip ?? "",
            cancelButton?.accessibilityLabel() ?? "",
        ]
    }

    @MainActor
    func hostedEvidenceControlsMatchListeningState() -> Bool {
        barsVisible
            && barLayers.allSatisfy { $0.opacity == 1 }
            && iconLayer?.opacity == 0
            && cancelButtonVisible
            && cancelButton?.isHidden == false
            && (cancelButton?.alphaValue ?? 0) >= 0.99
    }

    @MainActor
    func setHostedAccessibilityPreferences(
        _ preferences: OverlayAccessibilityPreferences?
    ) {
        hostedAccessibilityPreferencesOverride = preferences
        resizePanelForCurrentSession()
        rerenderCurrentTranscriptToFitIfNeeded()
        if !wasHidden {
            centerWindowNearTop()
        }
    }

    @MainActor
    func hostedEvidenceLargeTextTranscriptIsFullyVisible(
        preferredBodyPointSize: CGFloat
    ) -> Bool {
        guard let transcriptField,
              let window,
              let pinnedScreenFrame,
              !transcriptField.isHidden else { return false }
        let visibleText = transcriptField.attributedStringValue.string
        return transcriptField.font?.pointSize ?? 0 >= preferredBodyPointSize
            && transcriptField.maximumNumberOfLines == OverlayPanelLayoutPolicy.maximumTranscriptLines
            && window.frame.width <= pinnedScreenFrame.width
            && window.frame.height <= pinnedScreenFrame.height
            && pinnedScreenFrame.insetBy(dx: -0.5, dy: -0.5).contains(window.frame)
            && transcriptField.frame.minX >= 0
            && transcriptField.frame.maxX <= (contentBackground?.bounds.maxX ?? 0)
            && transcriptField.frame.minY >= 0
            && transcriptField.frame.maxY <= (contentBackground?.bounds.maxY ?? 0)
            && !visibleText.isEmpty
            && transcriptTextFitsField(visibleText)
    }

    @MainActor
    func hostedEvidenceAccessibilityAppearanceMatchesPreferences() -> Bool {
        let expected = accessibilityPreferences
        let metrics = OverlayAccessibilityMetrics(preferences: expected)
        let expectedStatusColor = expected.increaseContrast
            ? NSColor.white
            : NSColor(calibratedWhite: 0.92, alpha: 1)
        let expectedTranscriptColor = expected.increaseContrast
            ? NSColor.white
            : NSColor(calibratedWhite: 0.96, alpha: 1)
        let expectedCancelTint = expected.increaseContrast
            ? NSColor.white
            : NSColor(calibratedWhite: 0.82, alpha: 1)
        let expectedCancelBackgroundAlpha: CGFloat = expected.increaseContrast ? 0.20 : 0.08
        let expectedCancelBorderAlpha: CGFloat = expected.increaseContrast ? 0.72 : 0.12

        return contentBackground?.layer?.shadowOpacity == metrics.innerShadowOpacity
            && outerShadowLayer?.shadowOpacity == metrics.outerShadowOpacity
            && colorsApproximatelyEqual(textField?.textColor, expectedStatusColor)
            && colorsApproximatelyEqual(transcriptField?.textColor, expectedTranscriptColor)
            && colorsApproximatelyEqual(cancelButton?.contentTintColor, expectedCancelTint)
            && approximatelyEqual(
                cancelButton?.layer?.backgroundColor?.alpha ?? -1,
                expectedCancelBackgroundAlpha
            )
            && cancelButton?.layer?.borderWidth == (expected.increaseContrast ? 1 : 0.5)
            && approximatelyEqual(
                cancelButton?.layer?.borderColor?.alpha ?? -1,
                expectedCancelBorderAlpha
            )
    }

    @MainActor
    func hostedEvidenceTerminalPresentationIsCompact() -> Bool {
        !listeningSessionIsActive
            && !showsLiveTranscriptPanel
            && transcriptField?.isHidden == true
            && window?.frame.size == activePanelSize
    }
    #endif

    // MARK: - Bar Animations

    @MainActor
    private func stopBarAnimations() {
        for bar in barLayers {
            bar.removeAllAnimations()
        }
    }

    @MainActor
    private func showBars() {
        // A static silhouette communicates recording without pretending to
        // visualize amplitude that this presenter does not receive.
        barsVisible = true
        iconLayer?.opacity = 0
        iconLayer?.transform = CATransform3DIdentity
        for (i, bar) in barLayers.enumerated() {
            bar.removeAllAnimations()
            let range = Self.barRanges[i]
            let midHeight = (range.min + range.max) / 2
            let centerY = barCenterY
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(x: bar.frame.midX, y: centerY)
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: midHeight)
            bar.opacity = 1
            bar.transform = CATransform3DIdentity
        }
    }

    @MainActor
    private func collapseBars() {
        guard barsVisible else { return }
        let centerY = barCenterY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            bar.removeAnimation(forKey: "waveformHeight")
            bar.removeAnimation(forKey: "waveformPosition")
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: 2)
            bar.position = CGPoint(x: bar.position.x, y: centerY)
        }
        CATransaction.commit()
    }

    @MainActor
    private func hideBarsShowIcon(_ symbolName: String, color: NSColor) {
        barsVisible = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            bar.removeAllAnimations()
            bar.opacity = 0
        }
        CATransaction.commit()

        guard let iconLayer else { return }
        let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .medium)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let tinted = image.tinted(with: color)
            iconLayer.contents = tinted
            iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        }

        iconLayer.removeAllAnimations()
        iconLayer.opacity = 1
        iconLayer.transform = CATransform3DIdentity
    }

    @MainActor
    private func setBarColor(_ color: NSColor) {
        let lighterColor = color.blended(withFraction: 0.15, of: .white) ?? color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            if let gradient = bar as? CAGradientLayer {
                gradient.colors = [lighterColor.cgColor, color.cgColor]
            } else {
                bar.backgroundColor = color.cgColor
            }
        }
        CATransaction.commit()
    }

    // MARK: - Text

    @MainActor
    private func updateText(_ newText: String) {
        textField?.stringValue = newText
    }

    // MARK: - Timer

    @MainActor
    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateListeningText()
            }
        }
        RunLoop.current.add(newTimer, forMode: .common)
        timer = newTimer
    }

    @MainActor
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        listeningStartDate = nil
    }

    @MainActor
    private func updateListeningText() {
        guard let start = listeningStartDate else {
            textField?.stringValue = "Listening 00:00"
            return
        }
        let elapsed = Int(Date().timeIntervalSince(start))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let mode = listeningHandsFree ? "Hands-Free" : "Hold-to-Talk"
        textField?.stringValue = "\(mode) \(String(format: "%02d:%02d", minutes, seconds))"
    }

    // MARK: - Positioning

    @MainActor
    private func centerWindowNearTop() {
        guard let window else { return }
        resolvePinnedScreenFrameIfNeeded()
        guard let screenFrame = pinnedScreenFrame else { return }
        let x = screenFrame.origin.x + (screenFrame.width - window.frame.width) / 2
        let remainingVerticalSpace = max(0, screenFrame.height - window.frame.height)
        let topInset = min(40, remainingVerticalSpace / 2)
        let y = screenFrame.maxY - window.frame.height - topInset
        window.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    @MainActor
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

    // MARK: - Presentation

    @MainActor
    private func presentWindow() {
        #if DEBUG
        guard !rendersOffscreen else { return }
        #endif
        guard let window else { return }
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    // MARK: - Callbacks

    @MainActor
    private func accessibilityChanged() {
        stopBarAnimations()
        resizePanelForCurrentSession()
        rerenderCurrentTranscriptToFitIfNeeded()
        if !wasHidden {
            centerWindowNearTop()
        }
    }

    @MainActor
    private var accentHighlightColor: NSColor {
        accentColor.blended(withFraction: 0.15, of: .white) ?? accentColor
    }

    @MainActor
    private var panelBackgroundColor: NSColor {
        if reduceTransparency {
            return NSColor(
                calibratedRed: 11.0 / 255.0,
                green: 14.0 / 255.0,
                blue: 20.0 / 255.0,
                alpha: 1
            )
        }
        return NSColor(
            calibratedRed: 11.0 / 255.0,
            green: 14.0 / 255.0,
            blue: 20.0 / 255.0,
            alpha: accessibilityMetrics.backgroundAlpha
        )
    }

    @MainActor
    private var panelBorderColor: NSColor {
        NSColor.white.withAlphaComponent(increaseContrast ? 0.62 : 0.12)
    }

    @MainActor
    private func applyAccessibilityAppearance() {
        guard let layer = contentBackground?.layer else { return }
        layer.backgroundColor = panelBackgroundColor.cgColor
        layer.borderColor = panelBorderColor.cgColor
        layer.borderWidth = panelBorderWidth
        layer.cornerRadius = activeCornerRadius
        layer.shadowOpacity = accessibilityMetrics.innerShadowOpacity
        outerShadowLayer?.cornerRadius = activeCornerRadius
        outerShadowLayer?.shadowOpacity = accessibilityMetrics.outerShadowOpacity
        textField?.font = preferredCaptionFont
        textField?.textColor = increaseContrast
            ? .white
            : NSColor(calibratedWhite: 0.92, alpha: 1)
        transcriptField?.font = preferredBodyFont
        transcriptField?.textColor = increaseContrast
            ? .white
            : NSColor(calibratedWhite: 0.96, alpha: 1)
        cancelButton?.applyAccessibilityAppearance(increaseContrast: increaseContrast)
    }

    @MainActor
    private func announceOnce(_ announcement: OverlayAnnouncement, message: String) {
        #if DEBUG
        guard !rendersOffscreen else { return }
        #endif
        guard announcementGate.accept(announcement),
              lastAnnouncement != announcement
        else { return }
        lastAnnouncement = announcement
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    @MainActor
    private func showCancelControl() {
        cancelButtonVisible = true
        guard let cancelButton else { return }
        cancelButton.isHidden = false
        cancelButton.alphaValue = 1
    }

    @MainActor
    private func hideCancelControl() {
        cancelButtonVisible = false
        guard let cancelButton else { return }
        cancelButton.alphaValue = 0
        cancelButton.isHidden = true
    }

    @MainActor
    private func handleCancelButtonPressed() {
        hideCancelControl()
        announceOnce(.cancelled, message: "Steno dictation cancelled")
        cancelAction?()
    }
}

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

        case .inserted, .copiedOnly, .failure, .noSpeech, .cancelled:
            guard sessionIsActive, !terminalAnnouncementWasSent else { return false }
            terminalAnnouncementWasSent = true
            sessionIsActive = false
            return true
        }
    }
}

struct OverlayTranscriptPresentation: Equatable {
    let text: String
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

struct OverlayAccessibilityMetrics: Equatable {
    static let baselineBodyPointSize: CGFloat = 13

    let textScale: CGFloat
    let backgroundAlpha: CGFloat
    let borderWidth: CGFloat
    let innerShadowOpacity: Float
    let outerShadowOpacity: Float
    let animationDurationScale: Double

    init(preferences: OverlayAccessibilityPreferences) {
        textScale = max(1, preferences.preferredBodyPointSize / Self.baselineBodyPointSize)
        backgroundAlpha = preferences.reduceTransparency ? 1 : 0.94
        borderWidth = preferences.increaseContrast ? 1.5 : 0.5
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
}

struct OverlayPanelContentGeometry: Equatable {
    let statusFrame: CGRect
    let transcriptFrame: CGRect
}

enum OverlayPanelLayoutPolicy {
    static let screenEdgeInset: CGFloat = 16
    static let maximumTranscriptLines = 3

    static func panelSize(
        showsTranscript: Bool,
        textScale: CGFloat,
        preferredBodyPointSize: CGFloat,
        preferredCaptionPointSize: CGFloat,
        visibleFrameSize: CGSize?
    ) -> CGSize {
        let expansion = max(0, textScale - 1)
        let desired: CGSize
        if showsTranscript {
            let widthForThreeLines = 120
                + (48 * preferredBodyPointSize * 0.58)
            let desiredWidth = max(500 + (120 * expansion), widthForThreeLines)
            let desiredHeight = max(
                116 + (64 * expansion),
                12
                    + (CGFloat(maximumTranscriptLines) * preferredBodyPointSize * 1.35)
                    + 8
                    + (preferredCaptionPointSize * 1.35)
                    + 19
            )
            desired = CGSize(width: desiredWidth, height: desiredHeight)
        } else {
            desired = CGSize(
                width: 292 + (64 * expansion),
                height: 52 + (24 * expansion)
            )
        }

        guard let visibleFrameSize else { return desired }
        return CGSize(
            width: min(desired.width, max(1, visibleFrameSize.width - (2 * screenEdgeInset))),
            height: min(desired.height, max(1, visibleFrameSize.height - (2 * screenEdgeInset)))
        )
    }

    static func contentGeometry(
        panelSize: CGSize,
        showsTranscript: Bool,
        preferredBodyPointSize: CGFloat,
        preferredCaptionPointSize: CGFloat
    ) -> OverlayPanelContentGeometry {
        let statusHeight = max(18, ceil(preferredCaptionPointSize * 1.35))
        guard showsTranscript else {
            let statusFrame = CGRect(
                x: 0,
                y: max(0, (panelSize.height - statusHeight) / 2),
                width: panelSize.width,
                height: min(statusHeight, panelSize.height)
            )
            return OverlayPanelContentGeometry(statusFrame: statusFrame, transcriptFrame: .zero)
        }

        let bottomInset: CGFloat = 12
        let topInset: CGFloat = 19
        let interItemSpacing: CGFloat = 8
        let statusY = max(bottomInset, panelSize.height - topInset - statusHeight)
        let transcriptHeight = max(0, statusY - interItemSpacing - bottomInset)
        return OverlayPanelContentGeometry(
            statusFrame: CGRect(
                x: 0,
                y: statusY,
                width: panelSize.width,
                height: min(statusHeight, max(0, panelSize.height - statusY))
            ),
            transcriptFrame: CGRect(
                x: 0,
                y: bottomInset,
                width: panelSize.width,
                height: transcriptHeight
            )
        )
    }

    static func estimatedVisibleGraphemeBudget(
        textWidth: CGFloat,
        textHeight: CGFloat,
        preferredBodyPointSize: CGFloat
    ) -> Int {
        guard textWidth > 0, textHeight > 0, preferredBodyPointSize > 0 else { return 0 }
        let lineHeight = preferredBodyPointSize * 1.35
        let visibleLines = min(
            maximumTranscriptLines,
            max(1, Int(floor(textHeight / lineHeight)))
        )
        let averageGraphemeWidth = max(1, preferredBodyPointSize * 0.58)
        let graphemesPerLine = max(1, Int(floor(textWidth / averageGraphemeWidth)))
        return min(
            OverlayTranscriptFormatter.maximumVisibleGraphemes,
            visibleLines * graphemesPerLine
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

private final class OverlayCancelButton: NSButton {
    private var pressAction: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .regularSquare
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))?
            .tinted(with: NSColor(calibratedWhite: 0.82, alpha: 1.0))
        imagePosition = NSControl.ImagePosition.imageOnly
        contentTintColor = NSColor(calibratedWhite: 0.82, alpha: 1.0)
        toolTip = "Cancel and discard this transcript"
        setAccessibilityLabel("Cancel dictation")
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius = frameRect.width / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        target = self
        action = #selector(handlePress)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func setPressAction(_ action: @escaping @MainActor () -> Void) {
        pressAction = action
    }

    @objc private func handlePress() {
        pressAction?()
    }

    func applyAccessibilityAppearance(increaseContrast: Bool) {
        let foregroundColor = increaseContrast
            ? NSColor.white
            : NSColor(calibratedWhite: 0.82, alpha: 1)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))?
            .tinted(with: foregroundColor)
        contentTintColor = foregroundColor
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(increaseContrast ? 0.20 : 0.08)
            .cgColor
        layer?.borderWidth = increaseContrast ? 1 : 0.5
        layer?.borderColor = NSColor.white
            .withAlphaComponent(increaseContrast ? 0.72 : 0.12)
            .cgColor
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

private final class OverlayPassthroughContainer: NSView {
    weak var interactiveButton: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        OverlayHitTesting.interactiveView(at: point, in: self, interactiveView: interactiveButton)
    }
}

// MARK: - NSImage Tinting Helper

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
#endif
