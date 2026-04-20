#if os(macOS)
import AppKit
import QuartzCore

@MainActor
public final class WaveformOverlayPresenter: NSObject, OverlayPresenter {
    private var window: NSWindow?
    private var contentBackground: NSView?
    private var barLayers: [CALayer] = []
    private var iconLayer: CALayer?
    private var textField: NSTextField?
    private var timer: Timer?
    private var listeningStartDate: Date?
    private var listeningHandsFree = false
    private var wasHidden = true
    private var pendingTextUpdate: String?
    private var barsVisible = true
    private var accentColor = WaveformOverlayPresenter.defaultAccent
    private var accentGlowColor = WaveformOverlayPresenter.defaultAccentGlow

    // MARK: - Constants

    private static let panelWidth: CGFloat = 292
    private static let panelHeight: CGFloat = 52
    private static let cornerRadius: CGFloat = 26
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
    public func show(state: OverlayState) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(finishHide), object: nil)
        ensureWindow()

        let isFirstShow = wasHidden
        wasHidden = false

        switch state {
        case .listening(let handsFree, _):
            listeningHandsFree = handsFree
            listeningStartDate = Date()
            updateListeningText()
            startTimer()
            showBars()
            setBarColor(accentColor)
            startBarAnimations()
            startBorderGlow()

        case .transcribing:
            stopTimer()
            collapseBars()
            stopBorderGlow()
            updateText("Transcribing...")
            setBarColor(.darkGray)

        case .inserted:
            stopTimer()
            hideBarsShowIcon("checkmark.circle.fill", color: Self.successColor)
            stopBorderGlow()
            flashSuccessBackground()
            updateText("Inserted")

        case .copiedOnly:
            stopTimer()
            hideBarsShowIcon("doc.on.clipboard.fill", color: Self.warningColor)
            stopBorderGlow()
            updateText("Copied to clipboard")

        case .failure(let message):
            stopTimer()
            hideBarsShowIcon("exclamationmark.triangle.fill", color: Self.errorColor)
            stopBorderGlow()
            updateText("Error: \(message)")

        case .noSpeechDetected:
            stopTimer()
            hideBarsShowIcon("mic.slash.fill", color: .systemGray)
            stopBorderGlow()
            updateText("No speech detected")
        }

        centerWindowNearTop()
        presentWindow(isFirstShow: isFirstShow)
    }

    @MainActor
    public func hide() {
        stopTimer()
        stopBarAnimations()
        stopBorderGlow()
        wasHidden = true
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

        let contentRect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let content = NSView(frame: contentRect)
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.masksToBounds = false
        content.layer?.backgroundColor = panelBackgroundColor.cgColor
        content.layer?.borderWidth = 0.5
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
        outerShadow.cornerRadius = Self.cornerRadius
        outerShadow.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.01).cgColor
        outerShadow.shadowColor = NSColor.black.withAlphaComponent(0.28).cgColor
        outerShadow.shadowOffset = CGSize(width: 0, height: -6)
        outerShadow.shadowRadius = 28
        outerShadow.shadowOpacity = 1

        // Insert outer shadow behind content in the panel
        let wrapper = NSView(frame: contentRect)
        wrapper.wantsLayer = true
        wrapper.layer?.addSublayer(outerShadow)
        wrapper.addSubview(content)

        // Waveform bars
        let barClusterWidth = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing
        let clusterCenterY = Self.panelHeight / 2
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
        let iconY = (Self.panelHeight - Self.iconSize) / 2
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
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        let textLeading = Self.barClusterX + barClusterWidth + 14
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: textLeading),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        panel.contentView = wrapper
        self.window = panel
        self.textField = label
    }

    // MARK: - Bar Animations

    @MainActor
    private func startBarAnimations() {
        guard !reduceMotion else { return }
        for (i, bar) in barLayers.enumerated() {
            let range = Self.barRanges[i]
            let centerY = Self.panelHeight / 2

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
        iconLayer?.opacity = 0
        for (i, bar) in barLayers.enumerated() {
            bar.removeAllAnimations()
            let range = Self.barRanges[i]
            let midHeight = (range.min + range.max) / 2
            let centerY = Self.panelHeight / 2
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

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.05) {
                    bar.removeAnimation(forKey: "staggerEntrance")
                    bar.opacity = 1
                    bar.transform = CATransform3DIdentity
                }
            } else {
                bar.opacity = 1
            }
        }
    }

    @MainActor
    private func collapseBars() {
        guard barsVisible else { return }
        let centerY = Self.panelHeight / 2
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

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                iconLayer.removeAnimation(forKey: "iconBounce")
                iconLayer.opacity = 1
                iconLayer.transform = CATransform3DIdentity
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
        guard let window, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
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
        NSColor(
            calibratedRed: 11.0 / 255.0,
            green: 14.0 / 255.0,
            blue: 20.0 / 255.0,
            alpha: 0.94
        )
    }

    @MainActor
    private var panelBorderColor: NSColor {
        NSColor.white.withAlphaComponent(0.12)
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
