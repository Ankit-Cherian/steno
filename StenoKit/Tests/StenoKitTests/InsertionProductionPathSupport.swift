#if os(macOS)
import ApplicationServices
import Foundation
@testable import StenoKit

// Fakes for driving the production insertion transports, built by
// `MacInsertionTransportFactory` in the default order, with only the operating
// system boundary replaced: key posting, application activation, the
// Accessibility client, and the clipboard. Nothing here posts a real event,
// activates a real application, or touches the real pasteboard.

let productionPathBundleID = "com.example.ProductionPathEditor"
let productionPathContext = AppContext(
    bundleIdentifier: productionPathBundleID,
    appName: "Production Path Editor"
)
let defaultInsertionOrder: [InsertionMethod] = [.direct, .accessibility, .clipboardPaste]

struct PostedKeyEvent: Equatable, Sendable {
    var keyCode: Int64
    var command: Bool
    var text: String
}

/// Records every keyboard event the transports would have posted.
final class FakeKeyPoster: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PostedKeyEvent] = []

    func post(_ keyDown: CGEvent, _ keyUp: CGEvent) {
        _ = keyUp
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 64)
        keyDown.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        let event = PostedKeyEvent(
            keyCode: keyDown.getIntegerValueField(.keyboardEventKeycode),
            command: keyDown.flags.contains(.maskCommand),
            text: String(utf16CodeUnits: buffer, count: length)
        )
        lock.withLock { storage.append(event) }
    }

    var events: [PostedKeyEvent] { lock.withLock { storage } }

    /// Text typed through Unicode payload events, excluding Command shortcuts.
    var typedText: [String] {
        events.filter { !$0.command }.map(\.text)
    }

    var commandShortcuts: [PostedKeyEvent] {
        events.filter(\.command)
    }
}

/// Stands in for NSRunningApplication activation and the frontmost app.
final class FakeApplicationActivator: @unchecked Sendable {
    private let lock = NSLock()
    private var frontmost: String?
    private var runningStorage: Set<String>
    private var activatableStorage: Set<String>
    private var activationRequestsStorage: [String] = []

    init(
        frontmost: String? = productionPathBundleID,
        running: Set<String> = [productionPathBundleID],
        activatable: Set<String>? = nil
    ) {
        self.frontmost = frontmost
        runningStorage = running
        activatableStorage = activatable ?? running
    }

    func activate(_ bundleIdentifier: String) -> Bool {
        lock.withLock {
            activationRequestsStorage.append(bundleIdentifier)
            guard runningStorage.contains(bundleIdentifier) else { return false }
            if activatableStorage.contains(bundleIdentifier) {
                frontmost = bundleIdentifier
            }
            return true
        }
    }

    func frontmostBundleIdentifier() -> String? {
        lock.withLock { frontmost }
    }

    /// The user switched to another app, and the target can no longer be
    /// brought back to the front.
    func switchToOtherApp(_ bundleIdentifier: String, targetRefusesActivation: Bool) {
        lock.withLock {
            frontmost = bundleIdentifier
            runningStorage.insert(bundleIdentifier)
            if targetRefusesActivation {
                activatableStorage.remove(productionPathBundleID)
            }
        }
    }

    var activationRequests: [String] { lock.withLock { activationRequestsStorage } }
}

/// A scripted Accessibility client. Each capture reports the currently focused
/// element, or throws a scripted failure.
final class FakeAccessibilityClient: MacAccessibilityClient, @unchecked Sendable {
    private let lock = NSLock()
    private var focusedElementStorage: String
    private var secureStorage: Bool
    private var captureFailureStorage: EditorTargetUnavailableReason?
    private var focusedBundleStorage: String
    private var writesStorage: [String] = []
    private var captureCountStorage = 0
    private var setResultStorage: MacAXSetTextResult = .inserted
    private var settableStorage = true

    init(
        focusedElement: String = "field-A",
        secure: Bool = false,
        focusedBundle: String = productionPathBundleID
    ) {
        focusedElementStorage = focusedElement
        secureStorage = secure
        focusedBundleStorage = focusedBundle
    }

    func isProcessTrusted() -> Bool { true }

    func captureFocusedTarget(expectedBundleIdentifier: String) throws -> MacAXTargetSnapshot {
        try lock.withLock {
            captureCountStorage += 1
            if let captureFailureStorage {
                throw captureFailureStorage
            }
            guard focusedBundleStorage == expectedBundleIdentifier else {
                throw EditorTargetUnavailableReason.bundleIdentifierMismatch
            }
            if secureStorage {
                throw EditorTargetUnavailableReason.secureOrProtectedElement
            }
            return MacAXTargetSnapshot(
                process: EditorTargetProcessIdentity(
                    processIdentifier: 4_242,
                    launchMarker: 1,
                    bundleIdentifier: focusedBundleStorage
                ),
                window: MacAXElementReference(testIdentifier: "window-1"),
                element: MacAXElementReference(testIdentifier: focusedElementStorage),
                role: "AXTextField",
                subrole: nil,
                isProtected: false,
                selection: EditorTextSelection(location: 0, length: 0),
                characterCount: 0
            )
        }
    }

    func string(for range: EditorTextSelection, in element: MacAXElementReference) throws -> String {
        _ = element
        guard range.length == 0 else {
            throw EditorTargetUnavailableReason.parameterizedTextUnavailable
        }
        return ""
    }

    func isSelectedTextSettable(in element: MacAXElementReference) throws -> Bool {
        _ = element
        return lock.withLock { settableStorage }
    }

    func setSelectedText(_ text: String, in element: MacAXElementReference) -> MacAXSetTextResult {
        _ = element
        return lock.withLock {
            writesStorage.append(text)
            return setResultStorage
        }
    }

    func focus(_ elementID: String, secure: Bool = false) {
        lock.withLock {
            focusedElementStorage = elementID
            secureStorage = secure
        }
    }

    func focusOtherApp(_ bundleIdentifier: String) {
        lock.withLock { focusedBundleStorage = bundleIdentifier }
    }

    func failCaptures(with reason: EditorTargetUnavailableReason?) {
        lock.withLock { captureFailureStorage = reason }
    }

    func setSettable(_ settable: Bool) {
        lock.withLock { settableStorage = settable }
    }

    var writes: [String] { lock.withLock { writesStorage } }
    var captureCount: Int { lock.withLock { captureCountStorage } }
}

/// Builds the same OS seam the production factory uses, from the fakes.
func makeFakeInsertionSystem(
    keys: FakeKeyPoster,
    activator: FakeApplicationActivator,
    accessibility: FakeAccessibilityClient
) -> MacInsertionSystem {
    MacInsertionSystem(
        accessibility: accessibility,
        activateApplication: { activator.activate($0) },
        frontmostApplicationBundleIdentifier: { activator.frontmostBundleIdentifier() },
        postKeyEvents: { keys.post($0, $1) }
    )
}

func makeProductionInsertionService(
    order: [InsertionMethod] = defaultInsertionOrder,
    clipboard: any ClipboardService,
    keys: FakeKeyPoster,
    activator: FakeApplicationActivator,
    accessibility: FakeAccessibilityClient
) -> InsertionService {
    InsertionService(transports: MacInsertionTransportFactory.makeTransports(
        orderedMethods: order,
        clipboard: clipboard,
        system: makeFakeInsertionSystem(
            keys: keys,
            activator: activator,
            accessibility: accessibility
        )
    ))
}
#endif
