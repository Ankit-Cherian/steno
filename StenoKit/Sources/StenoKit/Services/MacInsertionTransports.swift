#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// Preferred tap location for synthetic event posting.
/// Defaults to `.cgAnnotatedSessionEventTap` (avoids traversing other event taps).
/// Set `STENO_SYNTH_EVENT_TAP=hid` in the environment to revert to `.cghidEventTap`.
let stenoSyntheticEventTapLocation: CGEventTapLocation = {
    if ProcessInfo.processInfo.environment["STENO_SYNTH_EVENT_TAP"]?.lowercased() == "hid" {
        return .cghidEventTap
    }
    return .cgAnnotatedSessionEventTap
}()

public enum MacInsertionError: Error, LocalizedError {
    case eventSourceUnavailable
    case accessibilityPermissionMissing
    case focusedElementUnavailable
    case unsupportedFocusedElement
    case attributeUpdateFailed
    case exactTargetUnavailable(EditorTargetUnavailableReason)
    case attributeUpdateIndeterminate

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
        case .exactTargetUnavailable(let reason):
            return "Exact editor target is unavailable: \(reason.rawValue)"
        case .attributeUpdateIndeterminate:
            return "The editor did not confirm whether the insertion completed"
        }
    }
}

public struct DirectTypingInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .direct
    private let isProcessTrusted: @Sendable () -> Bool
    private let preparedEventPoster: @Sendable (
        _ keyDown: CGEvent,
        _ keyUp: CGEvent,
        _ chunk: String,
        _ chunkIndex: Int
    ) -> Void
    private let interChunkPause: @Sendable () -> Void

    public init() {
        isProcessTrusted = { AXIsProcessTrusted() }
        preparedEventPoster = { keyDown, keyUp, _, _ in
            keyDown.post(tap: stenoSyntheticEventTapLocation)
            keyUp.post(tap: stenoSyntheticEventTapLocation)
        }
        interChunkPause = { usleep(10_000) }
    }

    init(
        isProcessTrusted: @escaping @Sendable () -> Bool,
        preparedEventPoster: @escaping @Sendable (
            _ keyDown: CGEvent,
            _ keyUp: CGEvent,
            _ chunk: String,
            _ chunkIndex: Int
        ) -> Void,
        interChunkPause: @escaping @Sendable () -> Void = {}
    ) {
        self.isProcessTrusted = isProcessTrusted
        self.preparedEventPoster = preparedEventPoster
        self.interChunkPause = interChunkPause
    }

    public func insert(text: String, target: AppContext) async throws {
        try await insert(
            text: text,
            target: target,
            commitAuthorization: nil,
            commitLease: nil
        )
    }

    func insert(
        text: String,
        target: AppContext,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) async throws {
        try Task.checkCancellation()
        guard !text.isEmpty else { return }
        guard isProcessTrusted() else {
            throw MacInsertionError.accessibilityPermissionMissing
        }

        try await Self.activateTargetApp(target)
        try Task.checkCancellation()

        try await typeUnicode(
            text,
            editorTarget: nil,
            commitAuthorization: commitAuthorization,
            commitLease: commitLease
        )
    }

    /// Inserts only while the exact editor captured at session start is still
    /// focused. Target drift fails before the first synthetic key event.
    public func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle
    ) async throws {
        try await insert(
            text: text,
            target: target,
            editorTarget: editorTarget,
            commitAuthorization: nil,
            commitLease: nil
        )
    }

    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) async throws {
        try Task.checkCancellation()
        guard !text.isEmpty else { return }
        guard isProcessTrusted() else {
            throw MacInsertionError.accessibilityPermissionMissing
        }

        _ = target
        try await typeUnicode(
            text,
            editorTarget: editorTarget,
            commitAuthorization: commitAuthorization,
            commitLease: commitLease
        )
    }

    private static func activateTargetApp(_ target: AppContext) async throws {
        guard target.bundleIdentifier != "unknown" else { return }

        for attempt in 0..<3 {
            try Task.checkCancellation()
            let activationTriggered = await MainActor.run { () -> Bool in
                guard let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: target.bundleIdentifier
                ).first else {
                    return false
                }
                return app.activate()
            }

            let delay = UInt64(150_000_000 + (50_000_000 * attempt))
            try await Task.sleep(nanoseconds: delay)
            try Task.checkCancellation()

            let isFrontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleIdentifier
            }
            if isFrontmost || !activationTriggered {
                return
            }
        }
    }

    private func typeUnicode(
        _ text: String,
        editorTarget: EditorTargetHandle?,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) async throws {
        try Task.checkCancellation()
        let codeUnitChunks = Self.boundedUTF16Chunks(text, maximumCodeUnits: 20)
        guard !codeUnitChunks.isEmpty else { return }

        // Spawning this detached operation is the insertion commit point. It
        // prebuilds every event before posting the first one, then completes all
        // chunks even if the parent task is cancelled mid-insertion.
        let preparedEventPoster = self.preparedEventPoster
        let interChunkPause = self.interChunkPause
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGEventSource(stateID: .privateState) else {
                throw MacInsertionError.eventSourceUnavailable
            }

            var events: [(keyDown: CGEvent, keyUp: CGEvent, chunk: String)] = []
            for chunk in codeUnitChunks {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw MacInsertionError.eventSourceUnavailable
                }

                // Some frameworks ignore event Unicode payloads and derive text from keycode/state.
                // InsertionService keeps accessibility and clipboard transports as fallbacks.
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                events.append((
                    keyDown: keyDown,
                    keyUp: keyUp,
                    chunk: String(decoding: chunk, as: UTF16.self)
                ))
            }

            var hasPostedEvent = false
            if let editorTarget,
               case .failure(let reason) = await editorTarget.prepareForDirectInsertion() {
                throw MacInsertionError.exactTargetUnavailable(reason)
            }
            for (index, event) in events.enumerated() {
                let mayProceed = if let commitAuthorization {
                    if hasPostedEvent, let commitLease {
                        commitAuthorization.ownerMayContinue(commitLease)
                    } else {
                        commitAuthorization.canStartNewCommit
                    }
                } else {
                    true
                }
                guard mayProceed else {
                    if hasPostedEvent {
                        throw MacInsertionError.attributeUpdateIndeterminate
                    }
                    throw CancellationError()
                }
                if let editorTarget, case .failure(let reason) = await editorTarget.revalidate() {
                    if hasPostedEvent {
                        throw MacInsertionError.attributeUpdateIndeterminate
                    }
                    throw MacInsertionError.exactTargetUnavailable(reason)
                }
                let stillMayProceed = if let commitAuthorization {
                    if hasPostedEvent, let commitLease {
                        commitAuthorization.ownerMayContinue(commitLease)
                    } else {
                        commitAuthorization.canStartNewCommit
                    }
                } else {
                    true
                }
                guard stillMayProceed else {
                    if hasPostedEvent {
                        throw MacInsertionError.attributeUpdateIndeterminate
                    }
                    throw CancellationError()
                }

                if !hasPostedEvent, let commitAuthorization {
                    guard let commitLease else { throw CancellationError() }
                    let committed: Void? = commitAuthorization.commitIfAuthorized(lease: commitLease) {
                        preparedEventPoster(event.keyDown, event.keyUp, event.chunk, index)
                    }
                    guard committed != nil else { throw CancellationError() }
                    commitAuthorization.seal(commitLease)
                } else {
                    preparedEventPoster(event.keyDown, event.keyUp, event.chunk, index)
                }
                hasPostedEvent = true
                if let editorTarget {
                    interChunkPause()
                    if case .failure = await editorTarget.verifyAndAdvanceAfterDirectInsertion(event.chunk) {
                        throw MacInsertionError.attributeUpdateIndeterminate
                    }
                } else if index + 1 < events.count {
                    interChunkPause()
                }
            }
        }.value
    }

    /// Keeps ordinary grapheme clusters intact. A pathological grapheme larger
    /// than the event payload limit falls back to scalar boundaries, which
    /// still guarantees valid UTF-16 without an unpaired surrogate.
    private static func boundedUTF16Chunks(
        _ text: String,
        maximumCodeUnits: Int
    ) -> [[UInt16]] {
        precondition(maximumCodeUnits >= 2)
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for character in text {
            let characterUnits = Array(String(character).utf16)
            if characterUnits.count <= maximumCodeUnits {
                if current.count + characterUnits.count > maximumCodeUnits {
                    flush()
                }
                current.append(contentsOf: characterUnits)
                continue
            }

            flush()
            for scalar in character.unicodeScalars {
                let scalarUnits = Array(String(scalar).utf16)
                if current.count + scalarUnits.count > maximumCodeUnits {
                    flush()
                }
                current.append(contentsOf: scalarUnits)
            }
        }
        flush()
        return chunks
    }
}

public struct AccessibilityInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .accessibility

    private let client: any MacAccessibilityClient

    public init() {
        client = SystemMacAccessibilityClient()
    }

    init(client: any MacAccessibilityClient) {
        self.client = client
    }

    public func insert(text: String, target: AppContext) async throws {
        try await insert(
            text: text,
            target: target,
            commitAuthorization: nil,
            commitLease: nil
        )
    }

    func insert(
        text: String,
        target: AppContext,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) async throws {
        try Task.checkCancellation()
        guard client.isProcessTrusted() else {
            throw MacInsertionError.accessibilityPermissionMissing
        }
        switch EditorTargetHandle.capture(target: target, client: client) {
        case .success(let editorTarget):
            try await insert(
                text: text,
                target: target,
                editorTarget: editorTarget,
                commitAuthorization: commitAuthorization,
                commitLease: commitLease
            )
        case .failure(let reason):
            throw MacInsertionError.exactTargetUnavailable(reason)
        }
    }

    /// Replaces only the selected text of the exact captured element. This path
    /// never reads or rewrites the element's complete AXValue.
    public func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle
    ) async throws {
        try await insert(
            text: text,
            target: target,
            editorTarget: editorTarget,
            commitAuthorization: nil,
            commitLease: nil
        )
    }

    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle,
        commitAuthorization: InsertionCommitAuthorization?,
        commitLease: InsertionCommitLease?
    ) async throws {
        _ = target
        try Task.checkCancellation()
        guard !text.isEmpty else { return }
        switch try await editorTarget.replaceSelectedText(
            with: text,
            commitAuthorization: commitAuthorization,
            commitLease: commitLease
        ) {
        case .inserted:
            return
        case .rejected(let reason):
            throw MacInsertionError.exactTargetUnavailable(reason)
        case .indeterminate:
            throw MacInsertionError.attributeUpdateIndeterminate
        }
    }
}

public enum MacPasteHelper {
    private enum ActivationResult {
        case activated
        case appNotFound
        case focusNotAcquired
        case unknownTarget
    }

    public static func activateAndPaste(
        target: AppContext,
        commitPermit: InsertionCommitPermit?
    ) async -> AutoPasteOutcome {
        await activateAndPaste(
            target: target,
            editorTarget: nil,
            commitPermit: commitPermit
        )
    }

    /// Pastes only after exact target revalidation. A changed field returns a
    /// skipped outcome before Command-V is posted.
    public static func activateAndPaste(
        target: AppContext,
        editorTarget: EditorTargetHandle,
        commitPermit: InsertionCommitPermit?
    ) async -> AutoPasteOutcome {
        await activateAndPaste(
            target: target,
            editorTarget: Optional(editorTarget),
            commitPermit: commitPermit
        )
    }

    private static func activateAndPaste(
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        commitPermit: InsertionCommitPermit?
    ) async -> AutoPasteOutcome {
        guard !Task.isCancelled else {
            return .skipped(reason: "Auto-paste canceled.")
        }
        guard AXIsProcessTrusted() else {
            return .skipped(reason: "Accessibility permission is required for auto-paste.")
        }

        if editorTarget == nil {
            let activationResult = await activateTargetApp(target)
            switch activationResult {
            case .activated, .unknownTarget:
                break
            case .appNotFound:
                return .skipped(reason: "Target app was not found for auto-paste reactivation.")
            case .focusNotAcquired:
                return .skipped(reason: "Could not focus target app before auto-paste.")
            }
        } else if let editorTarget, case .failure(let reason) = await editorTarget.revalidate() {
            return .skipped(reason: "Exact editor target is unavailable: \(reason.rawValue).")
        }

        for attempt in 0..<2 {
            guard !Task.isCancelled else {
                return .skipped(reason: "Auto-paste canceled.")
            }
            if let editorTarget, case .failure(let reason) = await editorTarget.revalidate() {
                return .skipped(reason: "Exact editor target is unavailable: \(reason.rawValue).")
            }
            if simulateCommandV(commitPermit: commitPermit) {
                return .attempted
            }
            if commitPermit?.cancellationRequested == true {
                return .skipped(reason: "Auto-paste canceled.")
            }

            let delay = UInt64(60_000_000 * UInt64(attempt + 1))
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return .skipped(reason: "Auto-paste canceled.")
            }
        }

        return .skipped(reason: "Unable to synthesize Cmd+V for auto-paste.")
    }

    private static func activateTargetApp(_ target: AppContext) async -> ActivationResult {
        guard target.bundleIdentifier != "unknown" else {
            return .unknownTarget
        }

        for attempt in 0..<3 {
            guard !Task.isCancelled else {
                return .focusNotAcquired
            }
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
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return .focusNotAcquired
            }

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
        simulateCommandV(commitPermit: nil)
    }

    private static func simulateCommandV(
        commitPermit: InsertionCommitPermit?
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        guard !Task.isCancelled else { return false }
        let postEvents = {
            keyDown.post(tap: stenoSyntheticEventTapLocation)
            keyUp.post(tap: stenoSyntheticEventTapLocation)
            return true
        }
        return performCommandVPasteIfAuthorized(
            commitPermit: commitPermit,
            postEvents
        )
    }

    /// Shared by the production Command-V path and deterministic authorization
    /// tests so revocation is exercised at the actual synchronous boundary.
    static func performCommandVPasteIfAuthorized(
        commitPermit: InsertionCommitPermit?,
        _ postEvents: () -> Bool
    ) -> Bool {
        guard let commitPermit else { return postEvents() }
        return commitPermit.performIfAuthorized(postEvents) ?? false
    }
}
#endif
