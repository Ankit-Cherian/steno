#if os(macOS)
import AppKit

/// Shared state between MacHotkeyMonitor and its CGEventTap C callback.
/// All access occurs on the main thread (tap is on the main run loop),
/// but the class must be nonisolated because the C callback is nonisolated.
private final class TapContext: @unchecked Sendable {
    var filter = HandsFreeKeyFilter(keyCode: nil)
    var onToggle: (() -> Void)?
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
    public var onPressToTalkStart: (() -> Void)?
    public var onPressToTalkStop: (() -> Void)?
    public var onToggleHandsFree: (() -> Void)? {
        didSet { tapContext.onToggle = onToggleHandsFree }
    }
    public var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?

    public var isOptionPressToTalkEnabled: Bool = true
    public var globalToggleKeyCode: UInt16? = 79 {
        didSet {
            tapContext.filter.keyCode = globalToggleKeyCode
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isOptionHeld = false
    private var callbackGeneration: UInt64 = 0

    private var hasStarted = false
    private var lastReportedStatus: HotkeyRegistrationStatus?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tapContext = TapContext()

    private let optionFlag: NSEvent.ModifierFlags

    public init(
        optionFlag: NSEvent.ModifierFlags = .option
    ) {
        self.optionFlag = optionFlag
        tapContext.filter.keyCode = globalToggleKeyCode
    }

    public func start() {
        guard !hasStarted else { return }
        callbackGeneration &+= 1
        hasStarted = true
        installOptionMonitors()
        updateHandsFreeStatus()
    }

    public func stop() {
        callbackGeneration &+= 1
        hasStarted = false
        uninstallEventTap()
        uninstallOptionMonitors()
        isOptionHeld = false
    }

    // MARK: - Option (Press-to-Talk) Monitors

    private func installOptionMonitors() {
        guard globalFlagsMonitor == nil, localFlagsMonitor == nil else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func uninstallOptionMonitors() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isOptionPressToTalkEnabled else { return }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let optionIsNowHeld = modifiers.contains(optionFlag)

        if optionIsNowHeld == isOptionHeld {
            return
        }

        isOptionHeld = optionIsNowHeld
        let generation = callbackGeneration

        // Dispatch callbacks async to avoid re-entrancy while the
        // NSEvent monitor callback is still unwinding.
        if optionIsNowHeld {
            Task { @MainActor [weak self] in
                guard let self,
                      self.hasStarted,
                      self.callbackGeneration == generation else {
                    return
                }
                self.onPressToTalkStart?()
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self,
                      self.hasStarted,
                      self.callbackGeneration == generation else {
                    return
                }
                self.onPressToTalkStop?()
            }
        }
    }

    // MARK: - CGEventTap (Hands-Free Toggle)

    private func installEventTap() {
        if let eventTap {
            // Settings saves and runtime rebuilds recover a tap macOS left disabled.
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                tapContext.lastReenableTime = CFAbsoluteTimeGetCurrent()
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let refcon = Unmanaged.passUnretained(tapContext).toOpaque()
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: refcon
        ) else {
            reportStatus(.unavailable(reason: "Accessibility permission required for global hotkey."))
            return
        }

        // Keep this assignment immediately after tap creation so callback re-enable
        // logic can always find the live mach port.
        eventTap = tap
        tapContext.machPort = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        reportStatus(.registered)
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

    private func updateHandsFreeStatus() {
        guard globalToggleKeyCode != nil else {
            uninstallEventTap()
            reportStatus(.disabled)
            return
        }
        installEventTap()
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
        // For .defaultTap, nil suppresses delivery to downstream apps.
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
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
            tapContext.filter.keyCode = nil
        }
    }
}
#endif
