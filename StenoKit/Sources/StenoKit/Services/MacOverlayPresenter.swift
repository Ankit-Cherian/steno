#if os(macOS)
import AppKit

@MainActor
public final class MacOverlayPresenter: OverlayPresenter {
    private var window: NSWindow?
    private var statusDot: NSView?
    private var textField: NSTextField?
    private var timer: Timer?
    private var listeningStartDate: Date?
    private var listeningHandsFree = false
    private var pulseTimer: Timer?
    private var dotPulseHigh = true
    private var wasHidden = true

    private static let dotBlue = NSColor(red: 0.118, green: 0.565, blue: 1.0, alpha: 1.0)

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public init() {}

    public func show(state: OverlayState) {
        ensureWindow()

        let isFirstShow = wasHidden
        wasHidden = false

        switch state {
        case .listening(let handsFree, _):
            listeningHandsFree = handsFree
            listeningStartDate = Date()
            updateListeningText()
            startTimer()
            animateDotColor(Self.dotBlue)
            startDotPulse()

        case .transcribing:
            stopTimer()
            stopDotPulse()
            updateText("Transcribing...")
            animateDotColor(.darkGray)

        case .inserted:
            stopTimer()
            stopDotPulse()
            updateText("Inserted")
            animateDotColor(.systemGreen)

        case .copiedOnly:
            stopTimer()
            stopDotPulse()
            updateText("Copied to clipboard")
            animateDotColor(.systemOrange)

        case .failure(let message):
            stopTimer()
            stopDotPulse()
            updateText("Error: \(message)")
            animateDotColor(.systemRed)
        }

        centerWindowNearTop()

        if isFirstShow && !reduceMotion {
            // Entrance animation: fade in + slide up
            window?.alphaValue = 0
            let finalOrigin = window?.frame.origin ?? .zero
            window?.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y - 20))
            window?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window?.animator().alphaValue = 1
                self.window?.animator().setFrameOrigin(finalOrigin)
            }
        } else {
            window?.alphaValue = 1
            window?.orderFrontRegardless()
        }
    }

    public func hide() {
        stopTimer()
        stopDotPulse()
        wasHidden = true

        if !reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self.window?.animator().alphaValue = 0
            }, completionHandler: {
                self.window?.orderOut(nil)
            })
        } else {
            window?.orderOut(nil)
        }
    }

    private func ensureWindow() {
        if window != nil {
            return
        }

        let contentRect = NSRect(x: 0, y: 0, width: 260, height: 44)
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
        content.layer?.cornerRadius = 22
        content.layer?.masksToBounds = false
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
        content.layer?.shadowOffset = CGSize(width: 0, height: -2)
        content.layer?.shadowRadius = 16
        content.layer?.shadowOpacity = 1

        // Status dot
        let dot = NSView(frame: NSRect(x: 16, y: 16, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.backgroundColor = Self.dotBlue.cgColor
        content.addSubview(dot)
        self.statusDot = dot

        // Status text
        let label = NSTextField(labelWithString: "Listening 00:00")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        panel.contentView = content
        self.window = panel
        self.textField = label
    }

    private func animateDotColor(_ color: NSColor) {
        guard !reduceMotion else {
            statusDot?.layer?.backgroundColor = color.cgColor
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            self.statusDot?.layer?.backgroundColor = color.cgColor
        }
    }

    private func updateText(_ newText: String) {
        guard !reduceMotion else {
            textField?.stringValue = newText
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            self.textField?.animator().alphaValue = 0
        }, completionHandler: {
            self.textField?.stringValue = newText
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.textField?.animator().alphaValue = 1
            }
        })
    }

    private func startDotPulse() {
        stopDotPulse()
        dotPulseHigh = true
        statusDot?.alphaValue = 1.0
        let newTimer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dotPulseHigh.toggle()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.6
                    self.statusDot?.animator().alphaValue = self.dotPulseHigh ? 1.0 : 0.4
                }
            }
        }
        RunLoop.current.add(newTimer, forMode: .common)
        pulseTimer = newTimer
    }

    private func stopDotPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusDot?.alphaValue = 1.0
    }

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

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        listeningStartDate = nil
    }

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

    private func centerWindowNearTop() {
        guard let window,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.origin.x + (screenFrame.width - window.frame.width) / 2
        let y = screenFrame.origin.y + screenFrame.height - window.frame.height - 40
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
#endif
