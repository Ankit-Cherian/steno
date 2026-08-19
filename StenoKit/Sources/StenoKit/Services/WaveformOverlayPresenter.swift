#if os(macOS)
import AppKit
import QuartzCore

#if DEBUG
enum WaveformOverlayHostedEvidenceEvent: Equatable {
    case listeningPresented(elapsedMilliseconds: Double)
    case previewAccepted(queueDepth: Int, totalCoalesced: UInt64)
    case previewRendered(
        elapsedMilliseconds: Double,
        monotonicMilliseconds: Double,
        sessionID: UUID,
        revision: UInt64?
    )
    case previewCleared
}
#endif

@MainActor
public final class WaveformOverlayPresenter: NSObject, OverlayPresenter {
    private var window: NSWindow?
    private var wrapperView: NSView?
    private var contentBackground: NSView?
    private var outerShadowLayer: CALayer?
    private var barLayers: [CALayer] = []
    private var iconLayer: CALayer?
    private var textField: NSTextField?
    private var stableTranscriptField: NSTextField?
    private var draftTranscriptField: NSTextField?
    private var cancelButton: OverlayCancelButton?
    private var cancelAction: (() -> Void)?
    private var cancelButtonVisible = false
    private var timer: Timer?
    private var listeningStartDate: Date?
    private var listeningHandsFree = false
    private var wasHidden = true
    private var pendingTextUpdate: String?
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
    private var livePreviewUnavailable = false
    private var liveUpdateGate = OverlayLiveUpdateGate()
    private var pinnedScreenFrame: NSRect?
    private var captureTargetPoint: NSPoint?
    private var lastAnnouncement: OverlayAnnouncement?
    private var announcementGate = OverlayAnnouncementGate()
    private var presentationEpoch: UInt64 = 0
    private var barIconTransitionToken: UUID?
    private var cancelControlTransitionToken: UUID?
    private var accentColor = WaveformOverlayPresenter.defaultAccent
    private var accentGlowColor = WaveformOverlayPresenter.defaultAccentGlow
    #if DEBUG
    private var hostedEvidenceHandler: ((WaveformOverlayHostedEvidenceEvent) -> Void)?
    private var hostedPendingAcceptedAt: TimeInterval?
    #endif

    // MARK: - Constants

    private static let compactPanelWidth: CGFloat = 292
    private static let compactPanelHeight: CGFloat = 52
    private static let livePanelWidth: CGFloat = 500
    private static let livePanelHeight: CGFloat = 116
    private static let compactCornerRadius: CGFloat = 26
    private static let liveCornerRadius: CGFloat = 18
    private static let barCount = 5
    private static let barWidth: CGFloat = 3.5
    private static let barSpacing: CGFloat = 3
    private static let barCornerRadius: CGFloat = 1.75
    private static let barClusterX: CGFloat = 22
    private static let iconSize: CGFloat = 16

    private static let defaultAccent = NSColor(red: 30.0 / 255.0, green: 144.0 / 255.0, blue: 1.0, alpha: 1.0)
    private static let defaultAccentGlow = NSColor(red: 30.0 / 255.0, green: 144.0 / 255.0, blue: 1.0, alpha: 0.45)
    private static let successColor = NSColor(red: 110.0 / 255.0, green: 191.0 / 255.0, blue: 140.0 / 255.0, alpha: 1.0)
    private static let warningColor = NSColor(red: 224.0 / 255.0, green: 183.0 / 255.0, blue: 113.0 / 255.0, alpha: 1.0)
    private static let errorColor = NSColor(red: 242.0 / 255.0, green: 113.0 / 255.0, blue: 106.0 / 255.0, alpha: 1.0)

    /// Min and max heights for each bar (index 0..4). Center bar tallest.
    private static let barRanges: [(min: CGFloat, max: CGFloat)] = [
        (5, 10), (7, 14), (10, 20), (7, 14), (5, 10)
    ]
    /// Animation duration for each bar — staggered for organic feel.
    private static let barDurations: [CFTimeInterval] = [0.7, 0.9, 0.6, 0.8, 1.0]

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private var accessibilityMetrics: OverlayAccessibilityMetrics {
        OverlayAccessibilityMetrics(
            preferences: OverlayAccessibilityPreferences(
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast,
                preferredBodyPointSize: NSFont.preferredFont(
                    forTextStyle: .body,
                    options: [:]
                ).pointSize
            )
        )
    }

    private var activePanelSize: NSSize {
        let expansion = accessibilityMetrics.textScale - 1
        return liveTranscriptEnabled
            ? NSSize(
                width: Self.livePanelWidth + (120 * expansion),
                height: Self.livePanelHeight + (64 * expansion)
            )
            : NSSize(
                width: Self.compactPanelWidth + (64 * expansion),
                height: Self.compactPanelHeight + (24 * expansion)
            )
    }

    // MARK: - Lifecycle

    public override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            timer = nil
            liveRenderTimer?.invalidate()
            liveRenderTimer = nil
            liveRenderTimerToken = nil
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
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
        accentGlowColor = glowColor?.usingColorSpace(.deviceRGB) ?? accentColor.withAlphaComponent(0.45)

        if barsVisible {
            setBarColor(accentColor)
        }

        if timer != nil {
            stopBorderGlow()
            startBorderGlow()
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

        #if DEBUG
        hostedPendingAcceptedAt = ProcessInfo.processInfo.systemUptime
        #endif
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
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(finishHide), object: nil)
        ensureWindow()

        let isFirstShow = wasHidden
        wasHidden = false

        if case .listening(let handsFree, _) = state, listeningSessionIsActive {
            listeningHandsFree = handsFree
            updateListeningText()
            return
        }
        presentationEpoch &+= 1

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
            pendingTextUpdate = nil
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(applyPendingTextUpdate),
                object: nil
            )
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
            startBarAnimations()
            startBorderGlow()
            showCancelControl()
            announceOnce(.sessionStarted, message: "Steno dictation started")

        case .transcribing:
            endListeningPresentation()
            stopTimer()
            collapseBars()
            stopBorderGlow()
            updateText("Transcribing...")
            hideLiveTranscriptFields()
            setBarColor(.darkGray)
            hideCancelControl()

        case .inserted:
            endListeningPresentation()
            stopTimer()
            hideBarsShowIcon("checkmark.circle.fill", color: Self.successColor)
            stopBorderGlow()
            flashSuccessBackground()
            updateText("Inserted")
            hideLiveTranscriptFields()
            hideCancelControl()
            announceOnce(.inserted, message: "Steno inserted the final transcript")

        case .copiedOnly:
            endListeningPresentation()
            stopTimer()
            hideBarsShowIcon("doc.on.clipboard.fill", color: Self.warningColor)
            stopBorderGlow()
            updateText("Copied to clipboard")
            hideLiveTranscriptFields()
            hideCancelControl()
            announceOnce(.copiedOnly, message: "Steno copied the final transcript to the clipboard")

        case .failure(let message):
            endListeningPresentation()
            stopTimer()
            hideBarsShowIcon("exclamationmark.triangle.fill", color: Self.errorColor)
            stopBorderGlow()
            updateText("Error: \(message)")
            hideLiveTranscriptFields()
            hideCancelControl()
            announceOnce(.failure, message: "Steno error: \(message)")

        case .noSpeechDetected:
            endListeningPresentation()
            stopTimer()
            hideBarsShowIcon("mic.slash.fill", color: .systemGray)
            stopBorderGlow()
            updateText("No speech detected")
            hideLiveTranscriptFields()
            hideCancelControl()
            announceOnce(.noSpeech, message: "Steno detected no speech")
        }

        centerWindowNearTop()
        presentWindow(isFirstShow: isFirstShow)
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
        presentationEpoch &+= 1
        if listeningSessionIsActive {
            announceOnce(.cancelled, message: "Steno dictation cancelled")
        }
        endListeningPresentation()
        stopTimer()
        stopBarAnimations()
        stopBorderGlow()
        hideCancelControl()
        wasHidden = true
        pinnedScreenFrame = nil
        captureTargetPoint = nil
        liveTranscriptSession = nil
        lastReceivedLiveRevision = nil
        lastAnnouncement = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyPendingTextUpdate), object: nil)

        if !reduceMotion {
            guard let window else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.2
            window.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(finishHide), object: nil)
            perform(#selector(finishHide), with: nil, afterDelay: 0.2)
        } else {
            window?.orderOut(nil)
        }
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
        label.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("Dictation status")
        content.addSubview(label)

        let stableField = NSTextField(wrappingLabelWithString: "")
        stableField.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        stableField.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        stableField.maximumNumberOfLines = 2
        stableField.lineBreakMode = .byWordWrapping
        stableField.setAccessibilityLabel("Stable live transcript")
        content.addSubview(stableField)
        self.stableTranscriptField = stableField

        let draftField = NSTextField(wrappingLabelWithString: "")
        draftField.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        draftField.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
        draftField.maximumNumberOfLines = 1
        draftField.lineBreakMode = .byTruncatingHead
        draftField.setAccessibilityLabel("Revisable live transcript draft")
        content.addSubview(draftField)
        self.draftTranscriptField = draftField

        let cancel = OverlayCancelButton(frame: .zero)
        cancel.isHidden = true
        cancel.alphaValue = 0
        cancel.target = self
        cancel.action = #selector(handleCancelButtonPressed)
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
        let scale = accessibilityMetrics.textScale
        let transcriptLeading = Self.barClusterX
            + CGFloat(Self.barCount) * Self.barWidth
            + CGFloat(Self.barCount - 1) * Self.barSpacing
            + 14
        let trailingInset: CGFloat = 52
        let textWidth = max(80, size.width - transcriptLeading - trailingInset)

        if liveTranscriptEnabled {
            let statusHeight = 18 * scale
            let stableHeight = 42 * scale
            let draftHeight = 19 * scale
            textField?.frame = NSRect(
                x: transcriptLeading,
                y: size.height - 19 - statusHeight,
                width: textWidth,
                height: statusHeight
            )
            stableTranscriptField?.frame = NSRect(
                x: transcriptLeading,
                y: 13 + draftHeight,
                width: textWidth,
                height: stableHeight
            )
            draftTranscriptField?.frame = NSRect(
                x: transcriptLeading,
                y: 12,
                width: textWidth,
                height: draftHeight
            )
        } else {
            let statusHeight = 18 * scale
            textField?.frame = NSRect(
                x: transcriptLeading,
                y: (size.height - statusHeight) / 2,
                width: textWidth,
                height: statusHeight
            )
            stableTranscriptField?.isHidden = true
            draftTranscriptField?.isHidden = true
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
    private func layoutTerminalContent() {
        guard liveTranscriptEnabled else { return }
        let size = activePanelSize
        let transcriptLeading = Self.barClusterX
            + CGFloat(Self.barCount) * Self.barWidth
            + CGFloat(Self.barCount - 1) * Self.barSpacing
            + 14
        textField?.frame = NSRect(
            x: transcriptLeading,
            y: (size.height - 18) / 2,
            width: max(80, size.width - transcriptLeading - 52),
            height: 18
        )
        let centerY = size.height / 2
        for bar in barLayers {
            bar.position = CGPoint(x: bar.position.x, y: centerY)
        }
        iconLayer?.position = CGPoint(x: iconLayer?.position.x ?? 0, y: centerY)
        cancelButton?.frame = NSRect(
            x: size.width - 40,
            y: (size.height - 24) / 2,
            width: 24,
            height: 24
        )
    }

    @MainActor
    private var barCenterY: CGFloat {
        liveTranscriptEnabled ? activePanelSize.height - 28 : activePanelSize.height / 2
    }

    @MainActor
    private var activeCornerRadius: CGFloat {
        liveTranscriptEnabled ? Self.liveCornerRadius : Self.compactCornerRadius
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
        stableTranscriptField?.isHidden = false
        draftTranscriptField?.isHidden = false
        stableTranscriptField?.stringValue = ""
        draftTranscriptField?.attributedStringValue = NSAttributedString(
            string: "Live preview will appear here",
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: accessibilityMetrics.scaledFontSize(12.5)
                ),
                .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1)
            ]
        )
        stableTranscriptField?.setAccessibilityValue("")
        draftTranscriptField?.setAccessibilityValue("Live preview will appear here")
    }

    @MainActor
    private func hideLiveTranscriptFields() {
        stableTranscriptField?.isHidden = true
        draftTranscriptField?.isHidden = true
        layoutTerminalContent()
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

        let presentation = OverlayTranscriptFormatter.presentation(
            stablePrefix: snapshot.stablePrefix,
            revisableTail: snapshot.revisableTail
        )
        stableTranscriptField?.isHidden = false
        draftTranscriptField?.isHidden = false
        stableTranscriptField?.stringValue = presentation.stablePrefix
        stableTranscriptField?.setAccessibilityValue(presentation.stablePrefix)

        if presentation.revisableTail.isEmpty {
            draftTranscriptField?.attributedStringValue = NSAttributedString(
                string: presentation.stablePrefix.isEmpty ? "Listening locally..." : "",
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: accessibilityMetrics.scaledFontSize(12.5)
                    ),
                    .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1)
                ]
            )
            draftTranscriptField?.setAccessibilityValue("")
        } else {
            let draft = NSMutableAttributedString(
                string: "Draft  ",
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: accessibilityMetrics.scaledFontSize(11.5),
                        weight: .semibold
                    ),
                    .foregroundColor: accentColor
                ]
            )
            draft.append(NSAttributedString(
                string: presentation.revisableTail,
                attributes: [
                    .font: NSFontManager.shared.convert(
                        NSFont.systemFont(
                            ofSize: accessibilityMetrics.scaledFontSize(12.5)
                        ),
                        toHaveTrait: .italicFontMask
                    ),
                    .foregroundColor: NSColor(calibratedWhite: 0.68, alpha: 1)
                ]
            ))
            draftTranscriptField?.attributedStringValue = draft
            draftTranscriptField?.setAccessibilityValue("Draft: \(presentation.revisableTail)")
        }

        if liveRenderBuffer.pendingSnapshot != nil {
            scheduleLiveRenderIfNeeded()
        }
        #if DEBUG
        let renderedAt = ProcessInfo.processInfo.systemUptime
        if let acceptedAt = hostedPendingAcceptedAt,
           let renderedRevision = snapshot.lastAcceptedRevision {
            hostedEvidenceHandler?(.previewRendered(
                elapsedMilliseconds: max(0, (renderedAt - acceptedAt) * 1_000),
                monotonicMilliseconds: renderedAt * 1_000,
                sessionID: snapshot.session.sessionID,
                revision: renderedRevision
            ))
        }
        hostedPendingAcceptedAt = nil
        #endif
    }

    @MainActor
    private func renderLivePreviewUnavailable() {
        stableTranscriptField?.isHidden = false
        draftTranscriptField?.isHidden = false
        stableTranscriptField?.stringValue = "Live preview unavailable"
        stableTranscriptField?.setAccessibilityValue("Live preview unavailable")
        draftTranscriptField?.attributedStringValue = NSAttributedString(
            string: "Recording continues; the final transcript remains authoritative.",
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: accessibilityMetrics.scaledFontSize(12.5)
                ),
                .foregroundColor: Self.warningColor
            ]
        )
        draftTranscriptField?.setAccessibilityValue(
            "Recording continues; the final transcript remains authoritative."
        )
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
        hostedPendingAcceptedAt = nil
        hostedEvidenceHandler?(.previewCleared)
        #endif
    }

    @MainActor
    private func clearLiveTranscriptContent() {
        stableTranscriptField?.stringValue = ""
        stableTranscriptField?.attributedStringValue = NSAttributedString(string: "")
        stableTranscriptField?.setAccessibilityValue("")
        draftTranscriptField?.stringValue = ""
        draftTranscriptField?.attributedStringValue = NSAttributedString(string: "")
        draftTranscriptField?.setAccessibilityValue("")
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
        let stableValues = [
            stableTranscriptField?.stringValue ?? "",
            stableTranscriptField?.attributedStringValue.string ?? "",
            stableTranscriptField?.accessibilityValue() as? String ?? "",
        ]
        let draftValues = [
            draftTranscriptField?.stringValue ?? "",
            draftTranscriptField?.attributedStringValue.string ?? "",
            draftTranscriptField?.accessibilityValue() as? String ?? "",
        ]
        return (stableValues + draftValues).allSatisfy(\.isEmpty)
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
    #endif

    // MARK: - Bar Animations

    @MainActor
    private func startBarAnimations() {
        guard !reduceMotion else { return }
        for (i, bar) in barLayers.enumerated() {
            let range = Self.barRanges[i]
            let centerY = barCenterY

            let heightAnim = CABasicAnimation(keyPath: "bounds.size.height")
            heightAnim.fromValue = range.min
            heightAnim.toValue = range.max
            heightAnim.duration = Self.barDurations[i]
            heightAnim.autoreverses = true
            heightAnim.repeatCount = .infinity
            heightAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let posAnim = CABasicAnimation(keyPath: "position.y")
            posAnim.fromValue = centerY
            posAnim.toValue = centerY
            posAnim.duration = Self.barDurations[i]
            posAnim.autoreverses = true
            posAnim.repeatCount = .infinity
            posAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(x: bar.frame.midX, y: centerY)
            bar.add(heightAnim, forKey: "waveformHeight")
            bar.add(posAnim, forKey: "waveformPosition")
        }
    }

    @MainActor
    private func stopBarAnimations() {
        for bar in barLayers {
            bar.removeAllAnimations()
        }
    }

    @MainActor
    private func showBars() {
        barsVisible = true
        let transitionToken = UUID()
        let expectedEpoch = presentationEpoch
        barIconTransitionToken = transitionToken
        iconLayer?.opacity = 0
        for (i, bar) in barLayers.enumerated() {
            bar.removeAllAnimations()
            let range = Self.barRanges[i]
            let midHeight = (range.min + range.max) / 2
            let centerY = barCenterY
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(x: bar.frame.midX, y: centerY)
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: midHeight)

            if !reduceMotion {
                bar.opacity = 0
                bar.transform = CATransform3DMakeScale(0.7, 0.7, 1)

                let group = CAAnimationGroup()
                group.beginTime = CACurrentMediaTime() + Double(i) * 0.05
                group.duration = 0.25
                group.fillMode = .forwards
                group.isRemovedOnCompletion = false
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)

                let fadeIn = CABasicAnimation(keyPath: "opacity")
                fadeIn.fromValue = 0
                fadeIn.toValue = 1

                let scaleUp = CABasicAnimation(keyPath: "transform.scale")
                scaleUp.fromValue = 0.7
                scaleUp.toValue = 1.0

                group.animations = [fadeIn, scaleUp]
                bar.add(group, forKey: "staggerEntrance")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.05) { [weak self, weak bar] in
                    Task { @MainActor [weak self, weak bar] in
                        guard let self, let bar,
                              self.presentationEpoch == expectedEpoch,
                              self.barIconTransitionToken == transitionToken,
                              self.barsVisible else {
                            return
                        }
                        bar.removeAnimation(forKey: "staggerEntrance")
                        bar.opacity = 1
                        bar.transform = CATransform3DIdentity
                    }
                }
            } else {
                bar.opacity = 1
            }
        }
    }

    @MainActor
    private func collapseBars() {
        guard barsVisible else { return }
        barIconTransitionToken = UUID()
        let centerY = barCenterY
        let duration: CFTimeInterval = reduceMotion ? 0 : 0.25

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
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
        let transitionToken = UUID()
        let expectedEpoch = presentationEpoch
        barIconTransitionToken = transitionToken
        let duration: CFTimeInterval = reduceMotion ? 0 : 0.3

        // Fade out bars
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        for bar in barLayers {
            bar.removeAllAnimations()
            bar.opacity = 0
        }
        CATransaction.commit()

        // Show icon with bounce
        guard let iconLayer else { return }
        let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .medium)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let tinted = image.tinted(with: color)
            iconLayer.contents = tinted
            iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        }

        if !reduceMotion {
            iconLayer.opacity = 0
            iconLayer.transform = CATransform3DMakeScale(0.5, 0.5, 1)

            let group = CAAnimationGroup()
            group.duration = 0.35
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1

            let scaleUp = CASpringAnimation(keyPath: "transform.scale")
            scaleUp.fromValue = 0.5
            scaleUp.toValue = 1.0
            scaleUp.damping = 8
            scaleUp.initialVelocity = 5
            scaleUp.mass = 0.6
            scaleUp.stiffness = 180

            group.animations = [fadeIn, scaleUp]
            iconLayer.add(group, forKey: "iconBounce")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak iconLayer] in
                Task { @MainActor [weak self, weak iconLayer] in
                    guard let self, let iconLayer,
                          self.presentationEpoch == expectedEpoch,
                          self.barIconTransitionToken == transitionToken,
                          !self.barsVisible else {
                        return
                    }
                    iconLayer.removeAnimation(forKey: "iconBounce")
                    iconLayer.opacity = 1
                    iconLayer.transform = CATransform3DIdentity
                }
            }
        } else {
            iconLayer.opacity = 1
        }
    }

    @MainActor
    private func setBarColor(_ color: NSColor) {
        let lighterColor = color.blended(withFraction: 0.15, of: .white) ?? color
        let duration: CFTimeInterval = reduceMotion ? 0 : 0.25
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        for bar in barLayers {
            if let gradient = bar as? CAGradientLayer {
                gradient.colors = [lighterColor.cgColor, color.cgColor]
            } else {
                bar.backgroundColor = color.cgColor
            }
        }
        CATransaction.commit()
    }

    // MARK: - Border Glow

    @MainActor
    private func startBorderGlow() {
        guard !reduceMotion, let layer = contentBackground?.layer else { return }

        let borderAnim = CABasicAnimation(keyPath: "borderColor")
        borderAnim.fromValue = accentColor.withAlphaComponent(0.35).cgColor
        borderAnim.toValue = accentColor.withAlphaComponent(0.55).cgColor
        borderAnim.duration = 1.2
        borderAnim.autoreverses = true
        borderAnim.repeatCount = .infinity
        borderAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(borderAnim, forKey: "borderGlow")

        let shadowColorAnim = CABasicAnimation(keyPath: "shadowColor")
        shadowColorAnim.fromValue = NSColor.black.withAlphaComponent(0.06).cgColor
        shadowColorAnim.toValue = accentGlowColor.cgColor
        shadowColorAnim.duration = 1.2
        shadowColorAnim.autoreverses = true
        shadowColorAnim.repeatCount = .infinity
        shadowColorAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(shadowColorAnim, forKey: "shadowGlow")
    }

    @MainActor
    private func stopBorderGlow() {
        guard let layer = contentBackground?.layer else { return }
        layer.removeAnimation(forKey: "borderGlow")
        layer.removeAnimation(forKey: "shadowGlow")

        let duration: CFTimeInterval = reduceMotion ? 0 : 0.25
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layer.borderColor = panelBorderColor.cgColor
        layer.shadowColor = NSColor.black.withAlphaComponent(0.06).cgColor
        CATransaction.commit()
    }

    // MARK: - Success Flash

    @MainActor
    private func flashSuccessBackground() {
        guard !reduceMotion, let layer = contentBackground?.layer else { return }

        let successTint = Self.successColor.withAlphaComponent(0.08)
        let normalBg = panelBackgroundColor

        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = successTint.cgColor
        flash.toValue = normalBg.cgColor
        flash.duration = 0.4
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(flash, forKey: "successFlash")
    }

    // MARK: - Text

    @MainActor
    private func updateText(_ newText: String) {
        guard !reduceMotion else {
            textField?.stringValue = newText
            return
        }
        guard let textField else { return }
        pendingTextUpdate = newText
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyPendingTextUpdate), object: nil)

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.1
        textField.animator().alphaValue = 0
        NSAnimationContext.endGrouping()
        perform(#selector(applyPendingTextUpdate), with: nil, afterDelay: 0.1)
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
        if pinnedScreenFrame == nil {
            let candidates = NSScreen.screens.map {
                OverlayDisplayCandidate(frame: $0.frame, visibleFrame: $0.visibleFrame)
            }
            pinnedScreenFrame = OverlayDisplayPinPolicy.resolvedVisibleFrame(
                pinnedVisibleFrame: pinnedScreenFrame,
                targetPoint: captureTargetPoint ?? NSEvent.mouseLocation,
                candidates: candidates,
                fallbackVisibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            )
        }
        guard let screenFrame = pinnedScreenFrame else { return }
        let x = screenFrame.origin.x + (screenFrame.width - window.frame.width) / 2
        let y = screenFrame.origin.y + screenFrame.height - window.frame.height - 40
        window.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    // MARK: - Presentation

    @MainActor
    private func presentWindow(isFirstShow: Bool) {
        guard let window else { return }

        if isFirstShow && !reduceMotion {
            window.alphaValue = 0
            let finalOrigin = window.frame.origin
            window.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y - 16))
            window.orderFrontRegardless()

            NSAnimationContext.beginGrouping()
            let context = NSAnimationContext.current
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrameOrigin(finalOrigin)
            NSAnimationContext.endGrouping()
        } else {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
    }

    // MARK: - Callbacks

    @objc @MainActor
    private func accessibilityChanged(_: Notification) {
        if reduceMotion {
            stopBarAnimations()
            stopBorderGlow()
        } else if listeningSessionIsActive {
            startBarAnimations()
            startBorderGlow()
        }
        resizePanelForCurrentSession()
        if !wasHidden {
            centerWindowNearTop()
        }
    }

    @objc @MainActor
    private func finishHide() {
        window?.orderOut(nil)
    }

    @objc @MainActor
    private func applyPendingTextUpdate() {
        guard let pendingTextUpdate else { return }
        self.pendingTextUpdate = nil
        textField?.stringValue = pendingTextUpdate
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.15
        textField?.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
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
        outerShadowLayer?.cornerRadius = activeCornerRadius
        outerShadowLayer?.shadowOpacity = accessibilityMetrics.outerShadowOpacity
        textField?.font = NSFont.monospacedSystemFont(
            ofSize: accessibilityMetrics.scaledFontSize(12.5),
            weight: .medium
        )
        stableTranscriptField?.font = NSFont.systemFont(
            ofSize: accessibilityMetrics.scaledFontSize(13.5),
            weight: .medium
        )
        draftTranscriptField?.font = NSFont.systemFont(
            ofSize: accessibilityMetrics.scaledFontSize(12.5),
            weight: .regular
        )
        stableTranscriptField?.textColor = increaseContrast
            ? .white
            : NSColor(calibratedWhite: 0.96, alpha: 1)
    }

    @MainActor
    private func announceOnce(_ announcement: OverlayAnnouncement, message: String) {
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
        cancelControlTransitionToken = UUID()
        guard let cancelButton else { return }
        cancelButton.isHidden = false
        if reduceMotion {
            cancelButton.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                cancelButton.animator().alphaValue = 1
            }
        }
    }

    @MainActor
    private func hideCancelControl() {
        cancelButtonVisible = false
        let transitionToken = UUID()
        let expectedEpoch = presentationEpoch
        cancelControlTransitionToken = transitionToken
        guard let cancelButton else { return }
        if reduceMotion {
            cancelButton.alphaValue = 0
            cancelButton.isHidden = true
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                cancelButton.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak cancelButton] in
                Task { @MainActor [weak self, weak cancelButton] in
                    guard let self, let cancelButton,
                          self.presentationEpoch == expectedEpoch,
                          self.cancelControlTransitionToken == transitionToken,
                          !self.cancelButtonVisible else {
                        return
                    }
                    cancelButton.isHidden = true
                }
            })
        }
    }

    @objc @MainActor
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
    let stablePrefix: String
    let revisableTail: String
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
    let outerShadowOpacity: Float
    let animationDurationScale: Double

    init(preferences: OverlayAccessibilityPreferences) {
        textScale = min(
            1.6,
            max(1, preferences.preferredBodyPointSize / Self.baselineBodyPointSize)
        )
        backgroundAlpha = preferences.reduceTransparency ? 1 : 0.94
        borderWidth = preferences.increaseContrast ? 1.5 : 0.5
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
    static let maximumStableGraphemes = 96
    static let maximumDraftGraphemes = 48

    static func presentation(
        stablePrefix: String,
        revisableTail: String
    ) -> OverlayTranscriptPresentation {
        OverlayTranscriptPresentation(
            stablePrefix: boundedSuffix(
                stablePrefix.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumGraphemes: maximumStableGraphemes
            ),
            revisableTail: boundedSuffix(
                revisableTail.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumGraphemes: maximumDraftGraphemes
            )
        )
    }

    private static func boundedSuffix(_ text: String, maximumGraphemes: Int) -> String {
        guard text.count > maximumGraphemes else { return text }

        let start = text.index(text.endIndex, offsetBy: -maximumGraphemes)
        let rawSuffix = text[start...]
        guard let firstBoundary = rawSuffix.firstIndex(where: { $0.isWhitespace }) else {
            return String(rawSuffix)
        }

        let completeWordStart = rawSuffix.index(after: firstBoundary)
        let wordBounded = rawSuffix[completeWordStart...]
            .drop(while: { $0.isWhitespace })
        return wordBounded.isEmpty ? String(rawSuffix) : String(wordBounded)
    }
}

private final class OverlayCancelButton: NSButton {
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
