#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

public enum MacInsertionError: Error, LocalizedError {
    case eventSourceUnavailable
    case accessibilityPermissionMissing
    case focusedElementUnavailable
    case unsupportedFocusedElement
    case attributeUpdateFailed

    public var errorDescription: String? {
        switch self {
        case .eventSourceUnavailable:
            return "Unable to access event source for direct typing insertion"
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required for this insertion mode"
        case .focusedElementUnavailable:
            return "No focused text element was found"
        case .unsupportedFocusedElement:
            return "Focused element does not support AX text insertion"
        case .attributeUpdateFailed:
            return "Failed to update focused element text"
        }
    }
}

public struct DirectTypingInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .direct

    public init() {}

    public func insert(text: String, target: AppContext) async throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            throw MacInsertionError.accessibilityPermissionMissing
        }

        await Self.activateTargetApp(target)

        let preValue = Self.readFocusedElementValue()

        try typeUnicode(text)

        // Only verify if we could read the pre-value (AX permission + element supports it)
        if preValue != nil {
            try await Task.sleep(nanoseconds: 150_000_000) // 150ms
            let postValue = Self.readFocusedElementValue()
            if let postValue, postValue == preValue {
                // Positive evidence: value readable and unchanged → insertion failed
                throw MacInsertionError.attributeUpdateFailed
            }
            // postValue changed or became nil (element lost focus) → assume success
        }
        // preValue nil → can't verify, assume CGEvent delivered
    }

    private static func activateTargetApp(_ target: AppContext) async {
        guard target.bundleIdentifier != "unknown" else { return }

        for attempt in 0..<3 {
            let activationTriggered = await MainActor.run { () -> Bool in
                guard let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: target.bundleIdentifier
                ).first else {
                    return false
                }
                return app.activate()
            }

            let delay = UInt64(150_000_000 + (50_000_000 * attempt))
            try? await Task.sleep(nanoseconds: delay)

            let isFrontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleIdentifier
            }
            if isFrontmost || !activationTriggered {
                return
            }
        }
    }

    private static func readFocusedElementValue() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success else {
            return nil
        }
        return valueRef as? String
    }

    private func typeUnicode(_ text: String) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw MacInsertionError.eventSourceUnavailable
        }

        let allCodeUnits = Array(text.utf16)
        guard !allCodeUnits.isEmpty else { return }

        let chunkSize = 20
        for offset in stride(from: 0, to: allCodeUnits.count, by: chunkSize) {
            let end = min(offset + chunkSize, allCodeUnits.count)
            let chunk = Array(allCodeUnits[offset..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw MacInsertionError.eventSourceUnavailable
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            if end < allCodeUnits.count {
                usleep(10_000) // 10ms between chunks
            }
        }
    }
}

public struct AccessibilityInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .accessibility

    public init() {}

    public func insert(text: String, target: AppContext) async throws {
        _ = target
        guard AXIsProcessTrusted() else {
            throw MacInsertionError.accessibilityPermissionMissing
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard focusedStatus == .success, let focusedRef else {
            throw MacInsertionError.focusedElementUnavailable
        }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            throw MacInsertionError.unsupportedFocusedElement
        }

        let element = unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
        let newValue = try composeUpdatedValue(for: element, insertion: text)
        let setStatus = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newValue as CFTypeRef
        )

        guard setStatus == .success else {
            throw MacInsertionError.attributeUpdateFailed
        }
    }

    private func composeUpdatedValue(for element: AXUIElement, insertion: String) throws -> String {
        var valueRef: CFTypeRef?
        let valueStatus = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard valueStatus == .success else {
            throw MacInsertionError.unsupportedFocusedElement
        }

        let current = valueRef as? String ?? ""

        var selectedRangeRef: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )

        guard selectedStatus == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return current + insertion
        }

        let selectedRangeValue = unsafeDowncast(selectedRangeRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(selectedRangeValue) == .cfRange else {
            return current + insertion
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange) else {
            return current + insertion
        }

        guard let swiftRange = range(from: selectedRange, in: current) else {
            return current + insertion
        }

        var updated = current
        updated.replaceSubrange(swiftRange, with: insertion)
        return updated
    }

    private func range(from cfRange: CFRange, in text: String) -> Range<String.Index>? {
        guard cfRange.location >= 0, cfRange.length >= 0 else { return nil }
        guard let startUTF16 = text.utf16.index(text.utf16.startIndex, offsetBy: cfRange.location, limitedBy: text.utf16.endIndex),
              let endUTF16 = text.utf16.index(startUTF16, offsetBy: cfRange.length, limitedBy: text.utf16.endIndex),
              let start = String.Index(startUTF16, within: text),
              let end = String.Index(endUTF16, within: text) else {
            return nil
        }
        return start..<end
    }
}

public enum MacPasteHelper {
    private enum ActivationResult {
        case activated
        case appNotFound
        case focusNotAcquired
        case unknownTarget
    }

    public static func activateAndPaste(target: AppContext) async -> AutoPasteOutcome {
        guard AXIsProcessTrusted() else {
            return .skipped(reason: "Accessibility permission is required for auto-paste.")
        }

        let activationResult = await activateTargetApp(target)
        switch activationResult {
        case .activated, .unknownTarget:
            break
        case .appNotFound:
            return .skipped(reason: "Target app was not found for auto-paste reactivation.")
        case .focusNotAcquired:
            return .skipped(reason: "Could not focus target app before auto-paste.")
        }

        for attempt in 0..<2 {
            if simulateCommandV() {
                return .attempted
            }

            let delay = UInt64(60_000_000 * UInt64(attempt + 1))
            try? await Task.sleep(nanoseconds: delay)
        }

        return .skipped(reason: "Unable to synthesize Cmd+V for auto-paste.")
    }

    private static func activateTargetApp(_ target: AppContext) async -> ActivationResult {
        guard target.bundleIdentifier != "unknown" else {
            return .unknownTarget
        }

        for attempt in 0..<3 {
            let didFindApp = await MainActor.run { () -> Bool in
                guard let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: target.bundleIdentifier
                ).first else {
                    return false
                }
                app.activate()
                return true
            }

            guard didFindApp else {
                return .appNotFound
            }

            let delay = UInt64(150_000_000 + (50_000_000 * attempt))
            try? await Task.sleep(nanoseconds: delay)

            let isFrontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleIdentifier
            }
            if isFrontmost {
                return .activated
            }
        }

        return .focusNotAcquired
    }

    public static func simulateCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
#endif
