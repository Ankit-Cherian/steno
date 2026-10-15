#if os(macOS)
import AppKit

/// Shared state between MacHotkeyMonitor and its CGEventTap C callback.
/// All access occurs on the main thread (tap is on the main run loop),
/// but the class must be nonisolated because the C callback is nonisolated.
private final class TapContext: @unchecked Sendable {
    var filter = HandsFreeKeyFilter(keyCode: nil)
    var onToggle: (() -> Void)?
    var shortcutFilter = GlobalShortcutFilter(shortcut: nil)
    var onShortcut: (() -> Void)?
    var machPort: CFMachPort?
    /// Timestamp of the last tap re-enable, used to debounce rapid
    /// disable/re-enable cycles that can occur when the system times out the tap.
    var lastReenableTime: CFAbsoluteTime = 0
}

/// macOS disables an event tap after a callback timeout or during secure
/// input. A disabled tap receives nothing further, including another disable
/// notice, so a re-enable inside the debounce interval is deferred, not dropped.
enum EventTapReenablePolicy {
    static let minimumInterval: TimeInterval = 0.1

    static func delay(now: TimeInterval, lastReenable: TimeInterval) -> TimeInterval {
        max(0, minimumInterval - (now - lastReenable))
    }
}

@MainActor
public final class MacHotkeyMonitor: HotkeyService {
    public let confirmsPressToTalk = true
    public var onPressToTalkStart: (() -> Void)?
    public var onPressToTalkConfirmed: (() -> Void)?
    public var onPressToTalkStop: (() -> Void)?
    public var onPressToTalkDiscarded: (() -> Void)?
    public var onToggleHandsFree: (() -> Void)? {
        didSet { tapContext.onToggle = onToggleHandsFree }
    }
    public var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?

    public var isOptionPressToTalkEnabled: Bool = true {
        didSet {
            guard hasStarted, isOptionPressToTalkEnabled != oldValue else { return }
            if isOptionPressToTalkEnabled {
                installOptionMonitors()
            } else {
                uninstallOptionMonitors()
            }
        }
    }
    public var globalToggleKeyCode: UInt16? = 79 {
        didSet {
            tapContext.filter.keyCode = globalToggleKeyCode
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }
    public var pasteLastShortcut: GlobalShortcut? {
        didSet {
            tapContext.shortcutFilter.shortcut = pasteLastShortcut
            guard hasStarted, pasteLastShortcut != oldValue else { return }
            updateHandsFreeStatus()
        }
    }
    public var onPasteLastShortcut: (() -> Void)?
    public var onPasteLastShortcutStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    private var lastReportedShortcutStatus: HotkeyRegistrationStatus = .disabled

    private var optionMonitors: [Any] = []
    private var pressFilter = PressToTalkKeyFilter()
    private var confirmationWorkItem: DispatchWorkItem?
    /// Internal so tests can read its interval and fire it.
    private(set) var modifierResyncTimer: Timer?
    private var callbackGeneration: UInt64 = 0

    private var hasStarted = false
    private var lastReportedStatus: HotkeyRegistrationStatus?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tapContext = TapContext()

    private let optionFlag: NSEvent.ModifierFlags
    private let modifierResyncInterval: TimeInterval
    private let currentModifierFlags: @MainActor () -> NSEvent.ModifierFlags
    private let makeEventTap: @MainActor (UnsafeMutableRawPointer) -> CFMachPort?

    /// - Parameters:
    ///   - modifierResyncInterval: how often held modifiers are re-read while
    ///     Option is down, so a missed key-up still ends the press.
    ///   - currentModifierFlags: the live modifier state.
    public convenience init(
        optionFlag: NSEvent.ModifierFlags = .option,
        modifierResyncInterval: TimeInterval = 1,
        currentModifierFlags: @escaping @MainActor () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    ) {
        self.init(
            optionFlag: optionFlag,
            modifierResyncInterval: modifierResyncInterval,
            currentModifierFlags: currentModifierFlags,
            makeEventTap: MacHotkeyMonitor.makeLiveEventTap
        )
    }

    /// `makeEventTap` creates the keyboard event tap, or returns nil when
    /// macOS refuses it.
    init(
        optionFlag: NSEvent.ModifierFlags = .option,
        modifierResyncInterval: TimeInterval = 1,
        currentModifierFlags: @escaping @MainActor () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
        makeEventTap: @escaping @MainActor (UnsafeMutableRawPointer) -> CFMachPort?
    ) {
        self.optionFlag = optionFlag
        self.modifierResyncInterval = modifierResyncInterval
        self.currentModifierFlags = currentModifierFlags
        self.makeEventTap = makeEventTap
        tapContext.filter.keyCode = globalToggleKeyCode
        tapContext.onShortcut = { [weak self] in
            MainActor.assumeIsolated { self?.receivePasteLastShortcut() }
        }
    }

    /// The Paste Last Dictation shortcut fired. The event tap swallowed its
    /// key, so the Option filter never saw it: tell the filter a key went
    /// down, which makes a press holding Option a shortcut, not a dictation.
    /// The paste is queued behind the discard that key-down may queue, so the
    /// controller has stopped treating the press as a recording when it runs.
    /// Internal so tests can drive it without posting keyboard events.
    func receivePasteLastShortcut() {
        guard hasStarted else { return }
        receive(.keyDown, at: ProcessInfo.processInfo.systemUptime)
        let generation = callbackGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hasStarted, self.callbackGeneration == generation else { return }
                self.onPasteLastShortcut?()
            }
        }
    }

    public func start() {
        guard !hasStarted else { return }
        callbackGeneration &+= 1
        hasStarted = true
        if isOptionPressToTalkEnabled {
            installOptionMonitors()
        }
        updateHandsFreeStatus()
    }

    public func stop() {
        callbackGeneration &+= 1
        hasStarted = false
        uninstallEventTap()
        uninstallOptionMonitors()
    }

    // MARK: - Option (Press-to-Talk) Monitors

    private func installOptionMonitors() {
        guard optionMonitors.isEmpty else { return }
        let pointerDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // Key and click events only tell a held Option apart from a shortcut.
        // Which key was pressed is never read.
        optionMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.receiveModifiers(event)
            },
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.receiveModifiers(event)
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.receive(.keyDown, at: event.timestamp)
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.receive(.keyDown, at: event.timestamp)
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: pointerDown) { [weak self] event in
                self?.receive(.pointerDown, at: event.timestamp)
            },
            NSEvent.addLocalMonitorForEvents(matching: pointerDown) { [weak self] event in
                self?.receive(.pointerDown, at: event.timestamp)
                return event
            },
        ].compactMap { $0 }
    }

    private func uninstallOptionMonitors() {
        for monitor in optionMonitors {
            NSEvent.removeMonitor(monitor)
        }
        optionMonitors.removeAll()
        pressFilter.reset()
        cancelConfirmationDeadline()
        stopModifierResync()
    }

    private func receiveModifiers(_ event: NSEvent) {
        receive(.modifiersChanged(pressModifiers(from: event.modifierFlags)), at: event.timestamp)
    }

    private func pressModifiers(from flags: NSEvent.ModifierFlags) -> PressToTalkKeyFilter.Modifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        let others = flags.subtracting(optionFlag)
        var modifiers: PressToTalkKeyFilter.Modifiers = []
        if flags.contains(optionFlag) { modifiers.insert(.option) }
        if others.contains(.command) { modifiers.insert(.command) }
        if others.contains(.control) { modifiers.insert(.control) }
        if others.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// Feeds one input to the press filter. Internal so tests can drive the
    /// monitor without posting keyboard events.
    ///
    /// - Parameter timestamp: seconds since system startup, the clock of `NSEvent.timestamp`.
    func receive(_ input: PressToTalkKeyFilter.Input, at timestamp: TimeInterval) {
        guard hasStarted, isOptionPressToTalkEnabled else { return }
        let actions = pressFilter.handle(input, at: timestamp)
        if pressFilter.confirmationDeadline == nil {
            cancelConfirmationDeadline()
        } else {
            scheduleConfirmationDeadline()
        }
        if pressFilter.phase == .idle {
            stopModifierResync()
        } else {
            startModifierResync()
        }
        dispatch(actions)
    }

    /// A modifier key-up can be lost, for example around secure input or a
    /// screen lock. While Option is down, the live modifier state is re-read
    /// so a missed release still ends the recording.
    private func startModifierResync() {
        guard modifierResyncTimer == nil else { return }
        let timer = Timer(timeInterval: modifierResyncInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.receive(
                    .modifiersSampled(self.pressModifiers(from: self.currentModifierFlags())),
                    at: ProcessInfo.processInfo.systemUptime
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierResyncTimer = timer
    }

    private func stopModifierResync() {
        modifierResyncTimer?.invalidate()
        modifierResyncTimer = nil
    }

    private func scheduleConfirmationDeadline() {
        guard confirmationWorkItem == nil,
              let deadline = pressFilter.confirmationDeadline
        else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.confirmationWorkItem = nil
                self.receive(.confirmationDeadline, at: ProcessInfo.processInfo.systemUptime)
            }
        }
        confirmationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelConfirmationDeadline() {
        confirmationWorkItem?.cancel()
        confirmationWorkItem = nil
    }

    private func dispatch(_ actions: [PressToTalkKeyFilter.Action]) {
        guard !actions.isEmpty else { return }
        let generation = callbackGeneration
        // Dispatch async to avoid re-entrancy while the NSEvent monitor
        // callback is still unwinding. The main queue keeps actions in order.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.hasStarted,
                      self.callbackGeneration == generation
                else { return }
                for action in actions {
                    switch action {
                    case .start: self.onPressToTalkStart?()
                    case .confirm: self.onPressToTalkConfirmed?()
                    case .stop: self.onPressToTalkStop?()
                    case .discard: self.onPressToTalkDiscarded?()
                    }
                }
            }
        }
    }

    // MARK: - CGEventTap (Hands-Free Toggle)

    private static func makeLiveEventTap(refcon: UnsafeMutableRawPointer) -> CFMachPort? {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: refcon
        )
    }

    /// Returns false when macOS refused the tap.
    private func installEventTap() -> Bool {
        if let eventTap {
            // Settings saves and runtime rebuilds recover a tap macOS left disabled.
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                tapContext.lastReenableTime = CFAbsoluteTimeGetCurrent()
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return true
        }

        let refcon = Unmanaged.passUnretained(tapContext).toOpaque()
        guard let tap = makeEventTap(refcon) else {
            return false
        }

        // Keep this assignment immediately after tap creation so callback re-enable
        // logic can always find the live mach port.
        eventTap = tap
        tapContext.machPort = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    private func uninstallEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        tapContext.machPort = nil
    }

    /// Installs the event tap while the hands-free key or the Paste Last
    /// Dictation shortcut needs it, and reports each one's status.
    private func updateHandsFreeStatus() {
        guard globalToggleKeyCode != nil || pasteLastShortcut != nil else {
            uninstallEventTap()
            reportStatus(.disabled)
            reportShortcutStatus(.disabled)
            return
        }
        let installed = installEventTap()
        if globalToggleKeyCode == nil {
            reportStatus(.disabled)
        } else {
            reportStatus(installed
                ? .registered
                : .unavailable(reason: "Accessibility permission required for global hotkey."))
        }
        if pasteLastShortcut == nil {
            reportShortcutStatus(.disabled)
        } else {
            reportShortcutStatus(installed
                ? .registered
                : .unavailable(reason: "The Paste Last Dictation shortcut needs Accessibility permission."))
        }
    }

    private func reportShortcutStatus(_ status: HotkeyRegistrationStatus) {
        guard status != lastReportedShortcutStatus else { return }
        lastReportedShortcutStatus = status
        onPasteLastShortcutStatusChanged?(status)
    }

    /// Settings saves, runtime rebuilds, and permission refreshes reassign the
    /// same key repeatedly. Only a real change is reported.
    private func reportStatus(_ status: HotkeyRegistrationStatus) {
        guard status != lastReportedStatus else { return }
        lastReportedStatus = status
        onRegistrationStatusChanged?(status)
    }

    // MARK: - CGEventTap Callback

    /// C-compatible callback for the CGEventTap. Runs on the main thread
    /// (tap is installed on the main run loop). Accesses TapContext via userInfo
    /// to avoid @MainActor isolation issues.
    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        // Re-enable tap if macOS disabled it due to timeout or user input,
        // with a debounce to avoid rapid re-enable cycling.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let ctx = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
                reenableTap(ctx)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp, let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let ctx = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let userMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let filterEvent: HandsFreeKeyFilter.Event = type == .keyDown
            ? .keyDown(
                keyCode: keyCode,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                hasModifiers: !event.flags.intersection(userMods).isEmpty
            )
            : .keyUp(keyCode: keyCode)
        let decision = ctx.filter.handle(
            filterEvent,
            at: TimeInterval(event.timestamp) / 1_000_000_000
        )

        if decision.toggle {
            // Callback already runs on the main run loop; dispatch async to avoid
            // re-entrancy while the tap callback is still unwinding.
            DispatchQueue.main.async { ctx.onToggle?() }
        }
        if decision.swallow {
            // For .defaultTap, nil suppresses delivery to downstream apps.
            return nil
        }

        let shortcutDecision = ctx.shortcutFilter.handle(type == .keyDown
            ? .keyDown(
                keyCode: keyCode,
                modifiers: shortcutModifiers(from: event.flags),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
            : .keyUp(keyCode: keyCode))
        if shortcutDecision.fire {
            DispatchQueue.main.async { ctx.onShortcut?() }
        }
        return shortcutDecision.swallow ? nil : Unmanaged.passUnretained(event)
    }

    private static func shortcutModifiers(from flags: CGEventFlags) -> GlobalShortcut.Modifiers {
        var modifiers: GlobalShortcut.Modifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
    }

    private static func reenableTap(_ ctx: TapContext) {
        guard let machPort = ctx.machPort else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let delay = EventTapReenablePolicy.delay(now: now, lastReenable: ctx.lastReenableTime)
        guard delay > 0 else {
            ctx.lastReenableTime = now
            CGEvent.tapEnable(tap: machPort, enable: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let machPort = ctx.machPort, !CGEvent.tapIsEnabled(tap: machPort) else { return }
            ctx.lastReenableTime = CFAbsoluteTimeGetCurrent()
            CGEvent.tapEnable(tap: machPort, enable: true)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            uninstallEventTap()
            uninstallOptionMonitors()
            // Clear callback state defensively after uninstall.
            tapContext.machPort = nil
            tapContext.onToggle = nil
            tapContext.onShortcut = nil
            tapContext.filter.keyCode = nil
            tapContext.shortcutFilter.shortcut = nil
        }
    }
}
#endif
