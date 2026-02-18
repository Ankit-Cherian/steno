#if os(macOS)
import AppKit

/// Shared state between MacHotkeyMonitor and its CGEventTap C callback.
/// All access occurs on the main thread (tap is on the main run loop),
/// but the class must be nonisolated because the C callback is nonisolated.
private final class TapContext: @unchecked Sendable {
    var keyCode: UInt16?
    var onToggle: (() -> Void)?
    var machPort: CFMachPort?
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
            tapContext.keyCode = globalToggleKeyCode
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isOptionHeld = false

    private var hasStarted = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tapContext = TapContext()

    private let optionFlag: NSEvent.ModifierFlags

    public init(
        optionFlag: NSEvent.ModifierFlags = .option
    ) {
        self.optionFlag = optionFlag
        tapContext.keyCode = globalToggleKeyCode
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        installOptionMonitors()
        updateHandsFreeStatus()
    }

    public func stop() {
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
        if optionIsNowHeld {
            onPressToTalkStart?()
        } else {
            onPressToTalkStop?()
        }
    }

    // MARK: - CGEventTap (Hands-Free Toggle)

    private func installEventTap() {
        guard eventTap == nil else { return }

        let refcon = Unmanaged.passUnretained(tapContext).toOpaque()
        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: refcon
        ) else {
            onRegistrationStatusChanged?(
                .unavailable(reason: "Accessibility permission required for global hotkey.")
            )
            return
        }

        eventTap = tap
        tapContext.machPort = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        onRegistrationStatusChanged?(.registered)
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
            onRegistrationStatusChanged?(
                .unavailable(reason: "Global hands-free key disabled in settings.")
            )
            return
        }
        installEventTap()
    }

    // MARK: - CGEventTap Callback

    /// C-compatible callback for the CGEventTap. Runs on the main thread
    /// (tap is installed on the main run loop). Accesses TapContext via userInfo
    /// to avoid @MainActor isolation issues.
    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        // Re-enable tap if macOS disabled it due to timeout or user input
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let ctx = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
                if let machPort = ctx.machPort {
                    CGEvent.tapEnable(tap: machPort, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let ctx = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let userMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

        guard let targetKey = ctx.keyCode,
              keyCode == targetKey,
              flags.intersection(userMods).isEmpty,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { ctx.onToggle?() }
        return nil // suppress the event — no app sees it
    }

    // MARK: - Utilities

    static func functionKeyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64:  return "F17"
        case 79:  return "F18"
        case 80:  return "F19"
        case 90:  return "F20"
        default:  return nil
        }
    }
}
#endif
