#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

final class MacAXElementReference: @unchecked Sendable {
    fileprivate let nativeElement: AXUIElement?
    fileprivate let testIdentifier: String?

    fileprivate init(nativeElement: AXUIElement) {
        self.nativeElement = nativeElement
        testIdentifier = nil
    }

    init(testIdentifier: String) {
        nativeElement = nil
        self.testIdentifier = testIdentifier
    }

    func isSameElement(as other: MacAXElementReference) -> Bool {
        if let nativeElement, let otherElement = other.nativeElement {
            return CFEqual(nativeElement, otherElement)
        }
        return testIdentifier != nil && testIdentifier == other.testIdentifier
    }
}

struct MacAXTargetSnapshot: @unchecked Sendable {
    let process: EditorTargetProcessIdentity
    let window: MacAXElementReference
    let element: MacAXElementReference
    let role: String
    let subrole: String?
    let isProtected: Bool
    let selection: EditorTextSelection
    let characterCount: Int

    func isExactlySameTarget(as other: MacAXTargetSnapshot) -> Bool {
        isSameTargetIdentity(as: other)
            && selection == other.selection
            && characterCount == other.characterCount
    }

    func isSameTargetIdentity(as other: MacAXTargetSnapshot) -> Bool {
        process == other.process
            && window.isSameElement(as: other.window)
            && element.isSameElement(as: other.element)
            && role == other.role
            && subrole == other.subrole
            && isProtected == other.isProtected
    }
}

enum MacAXSetTextResult: Sendable, Equatable {
    case inserted
    case rejected
    case indeterminate
}

protocol MacAccessibilityClient: Sendable {
    func isProcessTrusted() -> Bool
    func captureFocusedTarget(expectedBundleIdentifier: String) throws -> MacAXTargetSnapshot
    func string(for range: EditorTextSelection, in element: MacAXElementReference) throws -> String
    func isSelectedTextSettable(in element: MacAXElementReference) throws -> Bool
    func setSelectedText(_ text: String, in element: MacAXElementReference) -> MacAXSetTextResult
}

struct SystemMacAccessibilityClient: MacAccessibilityClient, @unchecked Sendable {
    private static let callDeadline: TimeInterval = 0.250

    func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func captureFocusedTarget(expectedBundleIdentifier: String) throws -> MacAXTargetSnapshot {
        try timed {
            let systemWide = AXUIElementCreateSystemWide()
            guard AXUIElementSetMessagingTimeout(systemWide, Float(Self.callDeadline)) == .success else {
                throw EditorTargetUnavailableReason.accessibilityError
            }
            let element = try copyElement(
                from: systemWide,
                attribute: kAXFocusedUIElementAttribute,
                unavailable: .focusedElementUnavailable
            )

            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
                throw EditorTargetUnavailableReason.processIdentityUnavailable
            }
            try configureTimeout(on: element)
            guard let application = NSRunningApplication(processIdentifier: pid),
                  let bundleIdentifier = application.bundleIdentifier,
                  let launchDate = application.launchDate else {
                throw EditorTargetUnavailableReason.processIdentityUnavailable
            }
            guard expectedBundleIdentifier != "unknown",
                  bundleIdentifier == expectedBundleIdentifier else {
                throw EditorTargetUnavailableReason.bundleIdentifierMismatch
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw EditorTargetUnavailableReason.applicationNotFrontmost
            }

            let applicationElement = AXUIElementCreateApplication(pid)
            try configureTimeout(on: applicationElement)
            let window = try copyWindow(for: element, applicationElement: applicationElement)
            let role = try copyRequiredString(from: element, attribute: kAXRoleAttribute)
            let subrole = try copyOptionalString(from: element, attribute: kAXSubroleAttribute)
            let hasProtectedContent = try copyProtectedContentStatus(from: element)
            let isProtected = subrole == (kAXSecureTextFieldSubrole as String) || hasProtectedContent
            if isProtected {
                throw EditorTargetUnavailableReason.secureOrProtectedElement
            }

            let selection = try copySelection(from: element)
            let characterCount = try copyCharacterCount(from: element)
            guard selection.location >= 0,
                  selection.length >= 0,
                  selection.location <= characterCount,
                  selection.length <= characterCount - selection.location else {
                throw EditorTargetUnavailableReason.malformedSelection
            }

            return MacAXTargetSnapshot(
                process: EditorTargetProcessIdentity(
                    processIdentifier: pid,
                    launchMarker: launchDate.timeIntervalSinceReferenceDate.bitPattern,
                    bundleIdentifier: bundleIdentifier
                ),
                window: MacAXElementReference(nativeElement: window),
                element: MacAXElementReference(nativeElement: element),
                role: role,
                subrole: subrole,
                isProtected: false,
                selection: selection,
                characterCount: characterCount
            )
        }
    }

    func string(for range: EditorTextSelection, in element: MacAXElementReference) throws -> String {
        try timed {
            guard let nativeElement = element.nativeElement else {
                throw EditorTargetUnavailableReason.parameterizedTextUnavailable
            }
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
                throw EditorTargetUnavailableReason.malformedSelection
            }

            var value: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(
                nativeElement,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &value
            )
            guard status == .success, let text = value as? String else {
                throw map(status, fallback: .parameterizedTextUnavailable)
            }
            guard text.utf16.count == range.length else {
                throw EditorTargetUnavailableReason.parameterizedTextUnavailable
            }
            return text
        }
    }

    func isSelectedTextSettable(in element: MacAXElementReference) throws -> Bool {
        try timed {
            guard let nativeElement = element.nativeElement else {
                throw EditorTargetUnavailableReason.unsupportedElement
            }
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(
                nativeElement,
                kAXSelectedTextAttribute as CFString,
                &settable
            )
            guard status == .success else {
                throw map(status, fallback: .selectedTextNotSettable)
            }
            return settable.boolValue
        }
    }

    func setSelectedText(_ text: String, in element: MacAXElementReference) -> MacAXSetTextResult {
        guard let nativeElement = element.nativeElement else { return .rejected }
        let start = ProcessInfo.processInfo.systemUptime
        let status = AXUIElementSetAttributeValue(
            nativeElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard ProcessInfo.processInfo.systemUptime - start <= Self.callDeadline else {
            return .indeterminate
        }
        switch status {
        case .success:
            return .inserted
        case .attributeUnsupported, .notImplemented, .illegalArgument:
            return .rejected
        default:
            return .indeterminate
        }
    }

    private func timed<T>(_ operation: () throws -> T) throws -> T {
        let start = ProcessInfo.processInfo.systemUptime
        let value = try operation()
        guard ProcessInfo.processInfo.systemUptime - start <= Self.callDeadline else {
            throw EditorTargetUnavailableReason.timedOut
        }
        return value
    }

    private func copyElement(
        from source: AXUIElement,
        attribute: String,
        unavailable: EditorTargetUnavailableReason
    ) throws -> AXUIElement {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(source, attribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw map(status, fallback: unavailable)
        }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    private func configureTimeout(on element: AXUIElement) throws {
        guard AXUIElementSetMessagingTimeout(element, Float(Self.callDeadline)) == .success else {
            throw EditorTargetUnavailableReason.accessibilityError
        }
    }

    private func copyWindow(for element: AXUIElement, applicationElement: AXUIElement) throws -> AXUIElement {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value)
        switch status {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw EditorTargetUnavailableReason.focusedWindowUnavailable
            }
            return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
        case .noValue, .attributeUnsupported:
            break
        default:
            throw map(status, fallback: .focusedWindowUnavailable)
        }
        return try copyElement(
            from: applicationElement,
            attribute: kAXFocusedWindowAttribute,
            unavailable: .focusedWindowUnavailable
        )
    }

    private func copyRequiredString(from element: AXUIElement, attribute: String) throws -> String {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let text = value as? String, !text.isEmpty else {
            throw map(status, fallback: .unsupportedElement)
        }
        return text
    }

    private func copyOptionalString(from element: AXUIElement, attribute: String) throws -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch status {
        case .success:
            guard let value else {
                throw EditorTargetUnavailableReason.unsupportedElement
            }
            guard let text = value as? String else {
                throw EditorTargetUnavailableReason.unsupportedElement
            }
            return text
        case .noValue, .attributeUnsupported:
            return nil
        default:
            throw map(status, fallback: .unsupportedElement)
        }
    }

    /// This probe must run before selection, character-count, or text reads.
    private func copyProtectedContentStatus(from element: AXUIElement) throws -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString,
            &value
        )
        switch status {
        case .success:
            guard let number = value as? NSNumber else {
                throw EditorTargetUnavailableReason.secureOrProtectedElement
            }
            return number.boolValue
        case .noValue, .attributeUnsupported:
            return false
        default:
            // An unreadable protection signal is not permission to read text.
            throw EditorTargetUnavailableReason.secureOrProtectedElement
        }
    }

    private func copySelection(from element: AXUIElement) throws -> EditorTextSelection {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            throw map(status, fallback: .selectionUnavailable)
        }
        let rangeValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else {
            throw EditorTargetUnavailableReason.malformedSelection
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else {
            throw EditorTargetUnavailableReason.malformedSelection
        }
        return EditorTextSelection(location: range.location, length: range.length)
    }

    private func copyCharacterCount(from element: AXUIElement) throws -> Int {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &value
        )
        guard status == .success, let number = value as? NSNumber else {
            throw map(status, fallback: .characterCountUnavailable)
        }
        let count = number.int64Value
        guard count >= 0, count <= Int64(Int.max) else {
            throw EditorTargetUnavailableReason.characterCountUnavailable
        }
        return Int(count)
    }

    private func map(_ error: AXError, fallback: EditorTargetUnavailableReason) -> EditorTargetUnavailableReason {
        switch error {
        case .apiDisabled:
            return .accessibilityPermissionMissing
        case .invalidUIElement:
            return .targetChanged
        case .cannotComplete:
            return .timedOut
        case .success:
            return fallback
        default:
            return fallback
        }
    }
}

/// A process-local, exact reference to the editor that was focused when the
/// handle was captured. Every read and write revalidates that exact identity.
public actor EditorTargetHandle {
    private static let maxUTF16UnitsPerSide = 512
    private static let maxGraphemesPerSide = 256
    private static let maxSerializedContextBytes = 8 * 1_024

    private let expectedBundleIdentifier: String
    private let capturedTarget: MacAXTargetSnapshot
    private let client: any MacAccessibilityClient
    private var expectedSelection: EditorTextSelection
    private var expectedCharacterCount: Int
    private var contextBaseline: EditorContextSnapshot?
    private var invalidReason: EditorTargetUnavailableReason?
    public nonisolated let targetIdentityToken: UUID
    public nonisolated let metadata: EditorTargetMetadata

    private init(
        expectedBundleIdentifier: String,
        snapshot: MacAXTargetSnapshot,
        client: any MacAccessibilityClient
    ) {
        let targetIdentityToken = UUID()
        self.targetIdentityToken = targetIdentityToken
        metadata = EditorTargetMetadata(
            targetIdentityToken: targetIdentityToken,
            process: snapshot.process,
            role: snapshot.role,
            subrole: snapshot.subrole,
            isProtected: snapshot.isProtected,
            selection: snapshot.selection,
            characterCount: snapshot.characterCount
        )
        self.expectedBundleIdentifier = expectedBundleIdentifier
        capturedTarget = snapshot
        self.client = client
        expectedSelection = snapshot.selection
        expectedCharacterCount = snapshot.characterCount
    }

    public static func capture(target: AppContext) -> Result<EditorTargetHandle, EditorTargetUnavailableReason> {
        capture(target: target, client: SystemMacAccessibilityClient())
    }

    static func capture(
        target: AppContext,
        client: any MacAccessibilityClient
    ) -> Result<EditorTargetHandle, EditorTargetUnavailableReason> {
        guard client.isProcessTrusted() else {
            return .failure(.accessibilityPermissionMissing)
        }
        do {
            let snapshot = try client.captureFocusedTarget(
                expectedBundleIdentifier: target.bundleIdentifier
            )
            guard !snapshot.isProtected else {
                return .failure(.secureOrProtectedElement)
            }
            return .success(
                EditorTargetHandle(
                    expectedBundleIdentifier: target.bundleIdentifier,
                    snapshot: snapshot,
                    client: client
                )
            )
        } catch let reason as EditorTargetUnavailableReason {
            return .failure(reason)
        } catch {
            return .failure(.accessibilityError)
        }
    }

    public func context() -> EditorContextResult {
        let currentTarget: MacAXTargetSnapshot
        do {
            try Task.checkCancellation()
            currentTarget = try captureExpectedTarget()
            try Task.checkCancellation()
        } catch is CancellationError {
            // Task cancellation is session lifecycle, not evidence that the
            // captured target drifted.
            return .unavailable(.cancelled)
        } catch let reason as EditorTargetUnavailableReason {
            markInvalidIfTargetCompromised(reason)
            return .unavailable(reason)
        } catch {
            return .unavailable(.accessibilityError)
        }

        let currentContext: EditorContextSnapshot
        do {
            currentContext = try readBoundedContext(
                from: currentTarget,
                checkingTaskCancellation: true
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch let reason as EditorTargetUnavailableReason {
            // A bounded parameterized-text request can be unsupported or time
            // out while the exact element identity remains valid. Context is
            // unavailable for this attempt without permanently invalidating
            // the handle. A previously installed baseline remains mandatory.
            return .unavailable(reason)
        } catch {
            return .unavailable(.accessibilityError)
        }

        do {
            _ = try captureExpectedTarget()
            try Task.checkCancellation()
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch let reason as EditorTargetUnavailableReason {
            markInvalidIfTargetCompromised(reason)
            return .unavailable(reason)
        } catch {
            return .unavailable(.accessibilityError)
        }

        let matchesBaseline: Bool
        if let contextBaseline {
            matchesBaseline = contextBaseline == currentContext
        } else {
            contextBaseline = currentContext
            matchesBaseline = true
        }
        guard matchesBaseline else {
            markInvalid(.targetChanged)
            return .unavailable(.targetChanged)
        }
        return .available(currentContext)
    }

    public func replaceSelectedText(with text: String) -> EditorTargetWriteResult {
        (try? replaceSelectedText(
            with: text,
            commitAuthorization: nil,
            commitLease: nil
        ))
            ?? .rejected(.accessibilityError)
    }

    func replaceSelectedText(
        with text: String,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) throws -> EditorTargetWriteResult {
        guard commitAuthorization?.canStartNewCommit != false else {
            throw CancellationError()
        }
        do {
            try ensureExactTarget()
            guard try client.isSelectedTextSettable(in: capturedTarget.element) else {
                return .rejected(.selectedTextNotSettable)
            }
            // The settable query is itself an AX call. Revalidate again so it
            // cannot create a stale-target window before the write commit.
            try ensureExactTarget()
            let writeResult: MacAXSetTextResult
            if let commitAuthorization {
                guard let commitLease,
                      let committed = commitAuthorization.commitIfAuthorized(lease: commitLease, {
                    client.setSelectedText(text, in: capturedTarget.element)
                }) else {
                    throw CancellationError()
                }
                writeResult = committed
            } else {
                writeResult = client.setSelectedText(text, in: capturedTarget.element)
            }
            switch writeResult {
            case .inserted:
                if let commitAuthorization, let commitLease {
                    commitAuthorization.seal(commitLease)
                }
                return .inserted
            case .rejected:
                if let commitAuthorization, let commitLease {
                    commitAuthorization.release(commitLease)
                }
                return .rejected(.selectedTextNotSettable)
            case .indeterminate:
                if let commitAuthorization, let commitLease {
                    commitAuthorization.seal(commitLease)
                }
                markInvalid(.accessibilityError)
                return .indeterminate
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let reason as EditorTargetUnavailableReason {
            markInvalidIfTargetCompromised(reason)
            return .rejected(reason)
        } catch {
            return .rejected(.accessibilityError)
        }
    }

    public func revalidate() -> Result<Void, EditorTargetUnavailableReason> {
        do {
            try ensureExactTarget()
            return .success(())
        } catch let reason as EditorTargetUnavailableReason {
            markInvalidIfTargetCompromised(reason)
            return .failure(reason)
        } catch {
            return .failure(.accessibilityError)
        }
    }

    /// Revalidates direct typing before its first event without opting a
    /// context-disabled session into AX text reads. If context was already
    /// captured, `revalidate()` also verifies that bounded baseline.
    func prepareForDirectInsertion() -> Result<Void, EditorTargetUnavailableReason> {
        revalidate()
    }

    /// Confirms that one direct-typing chunk replaced the previously captured
    /// selection in the same exact editor, then advances only the mutable text
    /// state expected by the next chunk. Identity and protection metadata stay
    /// anchored to the original capture for the lifetime of the handle.
    func verifyAndAdvanceAfterDirectInsertion(
        _ insertedText: String
    ) -> Result<Void, EditorTargetUnavailableReason> {
        do {
            if let invalidReason {
                throw invalidReason
            }
            if let contextBaseline,
               contextBaseline.selection != expectedSelection
                    || contextBaseline.characterCount != expectedCharacterCount {
                throw EditorTargetUnavailableReason.targetChanged
            }

            let insertedCount = insertedText.utf16.count
            let replacementEnd = expectedSelection.location.addingReportingOverflow(insertedCount)
            let countWithoutSelection = expectedCharacterCount.subtractingReportingOverflow(
                expectedSelection.length
            )
            let advancedCount = countWithoutSelection.partialValue.addingReportingOverflow(insertedCount)
            guard !replacementEnd.overflow,
                  !countWithoutSelection.overflow,
                  !advancedCount.overflow else {
                throw EditorTargetUnavailableReason.targetChanged
            }

            let advancedSelection = EditorTextSelection(
                location: replacementEnd.partialValue,
                length: 0
            )
            let currentTarget = try captureTarget(
                expectedSelection: advancedSelection,
                expectedCharacterCount: advancedCount.partialValue
            )
            var advancedContext: EditorContextSnapshot?
            if let contextBaseline {
                let expectedAdvancedContext = expectedContext(
                    afterReplacingSelectionIn: contextBaseline,
                    with: insertedText,
                    selection: advancedSelection,
                    characterCount: advancedCount.partialValue
                )
                let currentContext = try readBoundedContext(from: currentTarget)
                _ = try captureTarget(
                    expectedSelection: advancedSelection,
                    expectedCharacterCount: advancedCount.partialValue
                )
                guard currentContext == expectedAdvancedContext else {
                    throw EditorTargetUnavailableReason.targetChanged
                }
                advancedContext = expectedAdvancedContext
            }

            expectedSelection = advancedSelection
            expectedCharacterCount = advancedCount.partialValue
            if let advancedContext {
                self.contextBaseline = advancedContext
            }
            return .success(())
        } catch let reason as EditorTargetUnavailableReason {
            markInvalidIfTargetCompromised(reason)
            return .failure(reason)
        } catch {
            return .failure(.accessibilityError)
        }
    }

    private func ensureExactTarget() throws {
        if let invalidReason {
            throw invalidReason
        }
        let currentTarget = try captureExpectedTarget()
        if let baseline = contextBaseline {
            let currentContext = try readBoundedContext(from: currentTarget)
            guard currentContext == baseline else {
                throw EditorTargetUnavailableReason.targetChanged
            }
            _ = try captureExpectedTarget()
        }
    }

    private func markInvalid(_ reason: EditorTargetUnavailableReason) {
        if invalidReason == nil {
            invalidReason = reason
        }
    }

    /// Only durable evidence that the captured target is no longer the same
    /// safe editor makes a handle permanently unusable. Unsupported or
    /// transient bounded-context reads remain fail-closed for that operation
    /// without poisoning a later retry; an installed baseline is still proof.
    private func markInvalidIfTargetCompromised(
        _ reason: EditorTargetUnavailableReason
    ) {
        switch reason {
        case .applicationUnavailable,
             .applicationNotFrontmost,
             .bundleIdentifierMismatch,
             .processIdentityUnavailable,
             .focusedWindowUnavailable,
             .focusedElementUnavailable,
             .secureOrProtectedElement,
             .targetChanged:
            markInvalid(reason)
        case .accessibilityPermissionMissing,
             .unsupportedElement,
             .selectionUnavailable,
             .malformedSelection,
             .characterCountUnavailable,
             .parameterizedTextUnavailable,
             .selectedTextNotSettable,
             .cancelled,
             .timedOut,
             .accessibilityError:
            break
        }
    }

    private func captureExpectedTarget() throws -> MacAXTargetSnapshot {
        try captureTarget(
            expectedSelection: expectedSelection,
            expectedCharacterCount: expectedCharacterCount
        )
    }

    private func captureTarget(
        expectedSelection: EditorTextSelection,
        expectedCharacterCount: Int
    ) throws -> MacAXTargetSnapshot {
        let current = try client.captureFocusedTarget(
            expectedBundleIdentifier: expectedBundleIdentifier
        )
        guard !current.isProtected else {
            throw EditorTargetUnavailableReason.secureOrProtectedElement
        }
        guard capturedTarget.isSameTargetIdentity(as: current),
              current.selection == expectedSelection,
              current.characterCount == expectedCharacterCount else {
            throw EditorTargetUnavailableReason.targetChanged
        }
        return current
    }

    private func expectedContext(
        afterReplacingSelectionIn baseline: EditorContextSnapshot,
        with insertedText: String,
        selection: EditorTextSelection,
        characterCount: Int
    ) -> EditorContextSnapshot {
        var prefix = baseline.prefix + insertedText
        while prefix.utf16.count > Self.maxUTF16UnitsPerSide, !prefix.isEmpty {
            prefix.removeFirst()
        }
        prefix = String(prefix.suffix(Self.maxGraphemesPerSide))
        var suffix = baseline.suffix
        trimToSerializedLimit(prefix: &prefix, suffix: &suffix)
        return EditorContextSnapshot(
            prefix: prefix,
            suffix: suffix,
            selection: selection,
            characterCount: characterCount
        )
    }

    private func readBoundedContext(
        from target: MacAXTargetSnapshot,
        checkingTaskCancellation: Bool = false
    ) throws -> EditorContextSnapshot {
        let selection = target.selection
        let prefixStart = max(0, selection.location - Self.maxUTF16UnitsPerSide)
        let prefixRange = EditorTextSelection(
            location: prefixStart,
            length: selection.location - prefixStart
        )
        let suffixStart = selection.location + selection.length
        let suffixRange = EditorTextSelection(
            location: suffixStart,
            length: min(Self.maxUTF16UnitsPerSide, target.characterCount - suffixStart)
        )

        if checkingTaskCancellation {
            try Task.checkCancellation()
        }
        var prefix = prefixRange.length == 0
            ? ""
            : try client.string(for: prefixRange, in: target.element)
        if checkingTaskCancellation {
            try Task.checkCancellation()
        }
        var suffix = suffixRange.length == 0
            ? ""
            : try client.string(for: suffixRange, in: target.element)
        if checkingTaskCancellation {
            try Task.checkCancellation()
        }
        guard prefix.utf16.count == prefixRange.length,
              suffix.utf16.count == suffixRange.length else {
            throw EditorTargetUnavailableReason.parameterizedTextUnavailable
        }
        prefix = String(prefix.suffix(Self.maxGraphemesPerSide))
        suffix = String(suffix.prefix(Self.maxGraphemesPerSide))
        trimToSerializedLimit(prefix: &prefix, suffix: &suffix)

        return EditorContextSnapshot(
            prefix: prefix,
            suffix: suffix,
            selection: selection,
            characterCount: target.characterCount
        )
    }

    private func trimToSerializedLimit(prefix: inout String, suffix: inout String) {
        while serializedContextByteCount(prefix: prefix, suffix: suffix) > Self.maxSerializedContextBytes {
            if prefix.utf8.count >= suffix.utf8.count, !prefix.isEmpty {
                prefix.removeFirst()
            } else if !suffix.isEmpty {
                suffix.removeLast()
            } else {
                break
            }
        }
    }

    private func serializedContextByteCount(prefix: String, suffix: String) -> Int {
        let object: [String: String] = [
            "leadingText": prefix,
            "trailingText": suffix
        ]
        return (try? JSONSerialization.data(withJSONObject: object).count) ?? Int.max
    }
}
#endif
