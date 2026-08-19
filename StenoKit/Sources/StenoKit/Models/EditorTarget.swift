import Foundation

/// Process-local authorization for one insertion commit. Cancellation
/// invalidates it synchronously, including while coordinator actors are
/// suspended in target revalidation.
public final class InsertionCommitAuthorization: @unchecked Sendable {
    private enum State {
        case pending
        case owned(InsertionCommitLease, cancelRequested: Bool)
        case committed(InsertionCommitLease, cancelRequested: Bool)
        case invalidated
    }

    private let lock = NSLock()
    private var state: State = .pending

    public init() {}

    public func invalidate() {
        lock.withLock {
            switch state {
            case .pending:
                state = .invalidated
            case .owned(let lease, _):
                state = .owned(lease, cancelRequested: true)
            case .committed(let lease, _):
                state = .committed(lease, cancelRequested: true)
            case .invalidated:
                break
            }
        }
    }

    public var isAuthorized: Bool {
        lock.withLock {
            if case .invalidated = state { return false }
            return true
        }
    }

    var canStartNewCommit: Bool {
        lock.withLock {
            if case .pending = state { return true }
            return false
        }
    }

    var isInvalidated: Bool {
        lock.withLock {
            if case .invalidated = state { return true }
            return false
        }
    }

    /// Atomically grants one transport exclusive ownership immediately before
    /// its first potentially irreversible asynchronous side effect.
    func acquire(_ lease: InsertionCommitLease) -> Bool {
        lock.withLock {
            switch state {
            case .pending:
                state = .owned(lease, cancelRequested: false)
                return true
            case .owned(let current, _), .committed(let current, _):
                return current == lease
            case .invalidated:
                return false
            }
        }
    }

    /// A proven no-side-effect rejection releases ownership. Cancellation that
    /// arrived while the transport owned the lease wins before any fallback.
    func release(_ lease: InsertionCommitLease) {
        lock.withLock {
            guard case .owned(let current, let cancelRequested) = state,
                  current == lease else { return }
            state = cancelRequested ? .invalidated : .pending
        }
    }

    /// Inserted, indeterminate, and ambiguous outcomes permanently seal the
    /// lease. The owner may finish its multi-step commit; no other transport
    /// can inherit the authorization or start a fallback.
    func seal(_ lease: InsertionCommitLease) {
        lock.withLock {
            guard case .owned(let current, let cancelRequested) = state,
                  current == lease else { return }
            state = .committed(lease, cancelRequested: cancelRequested)
        }
    }

    func ownerMayContinue(_ lease: InsertionCommitLease) -> Bool {
        lock.withLock {
            switch state {
            case .owned(let current, _), .committed(let current, _):
                return current == lease
            case .pending, .invalidated:
                return false
            }
        }
    }

    func cancellationRequested(for lease: InsertionCommitLease) -> Bool {
        lock.withLock {
            switch state {
            case .owned(let current, let requested),
                 .committed(let current, let requested):
                return current == lease && requested
            case .pending, .invalidated:
                return false
            }
        }
    }

    /// Performs a later synchronous side effect for the current owner only
    /// when cancellation has not been requested. Holding the lock through the
    /// operation closes the check-to-commit race at boundaries such as posting
    /// the Command-V key events after asynchronous target revalidation.
    func performOwnedSideEffectIfAuthorized<T>(
        lease: InsertionCommitLease,
        _ operation: () throws -> T
    ) rethrows -> T? {
        try lock.withLock {
            switch state {
            case .owned(let current, let cancelRequested),
                 .committed(let current, let cancelRequested):
                guard current == lease, !cancelRequested else { return nil }
                return try operation()
            case .pending, .invalidated:
                return nil
            }
        }
    }

    /// Holds exclusive authorization through a synchronous irreversible side
    /// effect. The caller must then release or seal based on the disposition.
    func commitIfAuthorized<T>(
        lease: InsertionCommitLease,
        _ operation: () throws -> T
    ) rethrows -> T? {
        try lock.withLock {
            switch state {
            case .pending:
                state = .owned(lease, cancelRequested: false)
            case .owned(let current, _):
                guard current == lease else { return nil }
            case .committed(let current, _):
                guard current == lease else { return nil }
            case .invalidated:
                return nil
            }
            let value = try operation()
            return value
        }
    }
}

struct InsertionCommitLease: Sendable, Equatable {
    let id = UUID()
}

/// Opaque capability carried to an insertion transport's final synchronous
/// side-effect boundary. Callers can forward it but cannot mint one.
public struct InsertionCommitPermit: Sendable {
    let authorization: InsertionCommitAuthorization
    let lease: InsertionCommitLease

    init(
        authorization: InsertionCommitAuthorization,
        lease: InsertionCommitLease
    ) {
        self.authorization = authorization
        self.lease = lease
    }

    var cancellationRequested: Bool {
        authorization.cancellationRequested(for: lease)
    }

    func performIfAuthorized<T>(
        _ operation: () throws -> T
    ) rethrows -> T? {
        try authorization.performOwnedSideEffectIfAuthorized(
            lease: lease,
            operation
        )
    }
}

/// Process-local identity for the application that owned an editor target.
///
/// The launch marker prevents PID reuse from turning an old target into a new
/// process target. This type intentionally is not `Codable`: editor targets are
/// valid only for the lifetime of the current process and capture session.
public struct EditorTargetProcessIdentity: Sendable, Equatable {
    public let processIdentifier: Int32
    public let launchMarker: UInt64
    public let bundleIdentifier: String

    public init(processIdentifier: Int32, launchMarker: UInt64, bundleIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.launchMarker = launchMarker
        self.bundleIdentifier = bundleIdentifier
    }
}

/// UTF-16 selection coordinates reported by macOS Accessibility.
public struct EditorTextSelection: Sendable, Equatable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// Bounded text adjacent to a captured editor selection.
public struct EditorContextSnapshot: Sendable, Equatable {
    public let prefix: String
    public let suffix: String
    public let selection: EditorTextSelection
    public let characterCount: Int

    public init(
        prefix: String,
        suffix: String,
        selection: EditorTextSelection,
        characterCount: Int
    ) {
        self.prefix = prefix
        self.suffix = suffix
        self.selection = selection
        self.characterCount = characterCount
    }
}

/// Non-persistent metadata for a captured editor. The token is opaque and is
/// meaningful only while the owning `EditorTargetHandle` remains alive.
public struct EditorTargetMetadata: Sendable, Equatable {
    public let targetIdentityToken: UUID
    public let process: EditorTargetProcessIdentity
    public let role: String
    public let subrole: String?
    public let isProtected: Bool
    public let selection: EditorTextSelection
    public let characterCount: Int

    public init(
        targetIdentityToken: UUID,
        process: EditorTargetProcessIdentity,
        role: String,
        subrole: String?,
        isProtected: Bool,
        selection: EditorTextSelection,
        characterCount: Int
    ) {
        self.targetIdentityToken = targetIdentityToken
        self.process = process
        self.role = role
        self.subrole = subrole
        self.isProtected = isProtected
        self.selection = selection
        self.characterCount = characterCount
    }
}

/// Fail-closed reasons that prevent editor context or exact AX insertion.
public enum EditorTargetUnavailableReason: String, Error, Sendable, Equatable {
    case accessibilityPermissionMissing
    case applicationUnavailable
    case applicationNotFrontmost
    case bundleIdentifierMismatch
    case processIdentityUnavailable
    case focusedWindowUnavailable
    case focusedElementUnavailable
    case unsupportedElement
    case secureOrProtectedElement
    case selectionUnavailable
    case malformedSelection
    case characterCountUnavailable
    case parameterizedTextUnavailable
    case targetChanged
    case selectedTextNotSettable
    case cancelled
    case timedOut
    case accessibilityError
}

public enum EditorContextResult: Sendable, Equatable {
    case available(EditorContextSnapshot)
    case unavailable(EditorTargetUnavailableReason)
}

/// Result of the selected-text write commit. `indeterminate` means the caller
/// must not retry via another transport because the first write may have landed.
public enum EditorTargetWriteResult: Sendable, Equatable {
    case inserted
    case rejected(EditorTargetUnavailableReason)
    case indeterminate
}
