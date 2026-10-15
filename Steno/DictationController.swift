import AppKit
import Combine
import Foundation
import SwiftUI
import StenoKit

protocol DictationSessionCoordinating: Sendable {
    func startPressToTalk(appContext: AppContext) async throws -> SessionID
    func startPressToTalk(
        appContext: AppContext,
        options: SessionStartOptions
    ) async throws -> SessionID
    func startPressToTalk(
        appContext: AppContext,
        options: SessionStartOptions,
        captureStarted: @Sendable (SessionID) -> Void
    ) async throws -> SessionID
    func startPressToTalkWithCaptureStopCapability(
        appContext: AppContext,
        options: SessionStartOptions,
        captureStarted: @Sendable (PressToTalkCaptureStopCapability) -> Void
    ) async throws -> SessionID
    func endPressToTalkCapture(sessionID: SessionID) async throws
    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult
    /// Completes a held recording; with a reason, the text is copied
    /// instead of inserted.
    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String],
        copyingBecause copyReason: InsertionCopyReason?
    ) async throws -> InsertResult
    /// Completes a recording and hands `whenDelivered` the result once the text is inserted or
    /// copied, before History and the usage ledger are written.
    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String],
        copyingBecause copyReason: InsertionCopyReason?,
        whenDelivered: (@Sendable (InsertResult) -> Void)?
    ) async throws -> InsertResult
    /// Inserts text that is not a new dictation, once, through the normal
    /// insertion chain and target check.
    func insertText(_ text: String, into target: AppContext) async -> InsertResult
    /// As `insertText(_:into:)`, for text that was meant for a secure field:
    /// `concealed` marks every copy of it as concealed.
    func insertText(_ text: String, into target: AppContext, concealed: Bool) async -> InsertResult
    /// Whether a recording whose capture has ended is still held.
    func holdsCapturedRecording(sessionID: SessionID) async -> Bool
    func cancel(sessionID: SessionID) async
    func setHandsFreeEnabled(_ enabled: Bool) async
    func unloadTranscriptionRuntime() async
    func shutdown() async
}

extension SessionCoordinator: DictationSessionCoordinating {}

extension DictationSessionCoordinating {
    func startPressToTalk(
        appContext: AppContext,
        options: SessionStartOptions
    ) async throws -> SessionID {
        try await startPressToTalk(appContext: appContext)
    }

    func startPressToTalk(
        appContext: AppContext,
        options: SessionStartOptions,
        captureStarted: @Sendable (SessionID) -> Void
    ) async throws -> SessionID {
        let sessionID = try await startPressToTalk(
            appContext: appContext,
            options: options
        )
        captureStarted(sessionID)
        return sessionID
    }

    func startPressToTalkWithCaptureStopCapability(
        appContext: AppContext,
        options: SessionStartOptions,
        captureStarted: @Sendable (PressToTalkCaptureStopCapability) -> Void
    ) async throws -> SessionID {
        let sessionID = try await startPressToTalk(
            appContext: appContext,
            options: options
        )
        captureStarted(PressToTalkCaptureStopCapability(
            sessionID: sessionID,
            stopOperation: { [self] in
                try await endPressToTalkCapture(sessionID: sessionID)
            },
            cancelOperation: { [self] in
                await cancel(sessionID: sessionID)
            }
        ))
        return sessionID
    }

    /// A coordinator without a copy-only path never inserts a copy request.
    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String],
        copyingBecause copyReason: InsertionCopyReason?
    ) async throws -> InsertResult {
        guard copyReason == nil else { throw SessionCoordinatorError.runtimeUnavailable }
        return try await completePressToTalk(sessionID: sessionID, languageHints: languageHints)
    }

    /// A coordinator that cannot report delivery early returns the result once, at the end.
    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String],
        copyingBecause copyReason: InsertionCopyReason?,
        whenDelivered: (@Sendable (InsertResult) -> Void)?
    ) async throws -> InsertResult {
        try await completePressToTalk(sessionID: sessionID, languageHints: languageHints, copyingBecause: copyReason)
    }

    func holdsCapturedRecording(sessionID: SessionID) async -> Bool { true }

    func insertText(_ text: String, into target: AppContext) async -> InsertResult {
        InsertResult(status: .failed, method: .none, insertedText: text, errorMessage: "Insertion is unavailable.")
    }

    /// A coordinator that cannot conceal a copy inserts as before.
    func insertText(_ text: String, into target: AppContext, concealed: Bool) async -> InsertResult {
        await insertText(text, into: target)
    }

    func unloadTranscriptionRuntime() async {}
    func shutdown() async {}
}

/// Dictated text kept for Copy, with whether its own copy was concealed
/// because it was meant for a secure field.
private struct RecoverableDictation: Equatable {
    let text: String
    let concealed: Bool
}

/// A long recording kept after a discard so Undo can still insert it.
private struct HeldDiscard {
    let id: UUID
    let sessionID: SessionID
    let coordinator: any DictationSessionCoordinating
    /// The app the recording was meant for.
    let context: AppContext
    /// False until capture has closed and the recording is parked.
    var isReady = false
    /// Undo was pressed before the recording was parked.
    var undoRequested = false
    var expiryTask: Task<Void, Never>?
    /// The status line that offers Undo, replaced when the window ends.
    var status = ""
    /// The overlay dismissal generation while it shows the discarded
    /// recording, so ending the window early hides only that overlay.
    var overlayGeneration: UInt64 = 0
}

protocol UsageAnalyticsStoreServicing: UsageAnalyticsRecording {
    func recoverCorruptArchiveIfNeeded() async throws -> URL?
    func reconcileHistory(
        legacyURL: URL?,
        currentEntries: [TranscriptEntry]
    ) async throws -> String?
    func snapshot(
        now: Date,
        calendar: Calendar,
        months: Int
    ) async throws -> UsageAnalyticsSnapshot
}

extension UsageAnalyticsStore: UsageAnalyticsStoreServicing {}

struct DictationLifecycleDiagnostics: Equatable {
    let hasActiveStartTask: Bool
    let isCleanupInProgress: Bool
    let hasPendingRuntimeRebuild: Bool
}

private struct UsageAnalyticsRefreshRequest {
    var now: Date
    var calendar: Calendar
    var forceHistoryReconciliation: Bool
}

private enum CaptureHandoffRequest: Equatable {
    case stop
    case cancel
}

private enum PromptCaptureStopResult: Sendable {
    case unavailable
    case startFailed(message: String)
    case stopped(PressToTalkCaptureStopCapability)
    case failed(PressToTalkCaptureStopCapability, message: String)
}

private struct PromptCaptureStopError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Opens once the coordinator has returned from starting a session. Media
/// setup comes after that, so stopping can wait for this without waiting for
/// a media Pause to be acknowledged.
@MainActor
private final class CoordinatorStartSignal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Capture never started. A stop that arrived first reports this error
/// instead of a missing session.
private struct CaptureStartFailure: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private final class CaptureStartHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var capability: PressToTalkCaptureStopCapability?
    private var pendingRequest: CaptureHandoffRequest?
    private var publicationFinished = false
    private var stopCapabilityClaimed = false
    private var startFailureMessage: String?
    private var stopWaiters: [CheckedContinuation<PressToTalkCaptureStopCapability?, Never>] = []

    func publish(
        _ capability: PressToTalkCaptureStopCapability
    ) -> CaptureHandoffRequest? {
        var waiters: [CheckedContinuation<PressToTalkCaptureStopCapability?, Never>] = []
        let request = lock.withLock {
            guard self.capability == nil else { return pendingRequest }
            self.capability = capability
            if pendingRequest == .stop, !stopWaiters.isEmpty {
                stopCapabilityClaimed = true
                self.capability = nil
                waiters = stopWaiters
                stopWaiters.removeAll()
            }
            return pendingRequest
        }
        for waiter in waiters {
            waiter.resume(returning: capability)
        }
        return request
    }

    func request(_ request: CaptureHandoffRequest) -> PressToTalkCaptureStopCapability? {
        var cancelledStopWaiters: [CheckedContinuation<PressToTalkCaptureStopCapability?, Never>] = []
        let result = lock.withLock { () -> PressToTalkCaptureStopCapability? in
            let previousRequest = pendingRequest
            let effectiveRequest: CaptureHandoffRequest = previousRequest == .cancel
                ? .cancel
                : request
            pendingRequest = effectiveRequest
            if previousRequest == .stop, effectiveRequest == .cancel {
                cancelledStopWaiters = stopWaiters
                stopWaiters.removeAll()
            }
            guard effectiveRequest == request, let capability else { return nil }
            self.capability = nil
            if effectiveRequest == .stop {
                stopCapabilityClaimed = true
            }
            return capability
        }
        for waiter in cancelledStopWaiters {
            waiter.resume(returning: nil)
        }
        return result
    }

    func awaitStopCapability() async -> PressToTalkCaptureStopCapability? {
        await withCheckedContinuation { continuation in
            var immediate: PressToTalkCaptureStopCapability?
            var shouldResume = false
            lock.withLock {
                if let capability {
                    self.capability = nil
                    stopCapabilityClaimed = true
                    immediate = capability
                    shouldResume = true
                } else if publicationFinished {
                    shouldResume = true
                } else {
                    stopWaiters.append(continuation)
                }
            }
            if shouldResume {
                continuation.resume(returning: immediate)
            }
        }
    }

    /// Keeps the reason capture failed to start for a stop that is already
    /// waiting on this handoff. Record it before `finishPublication`.
    func recordStartFailure(_ error: Error) {
        let message = error.localizedDescription
        lock.withLock { startFailureMessage = message }
    }

    var startFailure: String? {
        lock.withLock { startFailureMessage }
    }

    func finishPublication() {
        var waiters: [CheckedContinuation<PressToTalkCaptureStopCapability?, Never>] = []
        lock.withLock {
            publicationFinished = true
            guard capability == nil, !stopCapabilityClaimed else { return }
            waiters = stopWaiters
            stopWaiters.removeAll()
        }
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func take(sessionID: SessionID? = nil) -> PressToTalkCaptureStopCapability? {
        lock.withLock {
            if pendingRequest == .stop || stopCapabilityClaimed {
                return nil
            }
            guard sessionID == nil || capability?.sessionID == sessionID else { return nil }
            defer { capability = nil }
            return capability
        }
    }

    var stopOwnsCapture: Bool {
        lock.withLock {
            pendingRequest == .stop || stopCapabilityClaimed
        }
    }
}

@MainActor
final class DictationController: ObservableObject {
    /// Preview controllers never access capture, permissions, personal storage, or system integrations.
    let isIsolatedPreview: Bool
    private let systemIntegrationsEnabled: Bool
    private let appContextProvider: @MainActor () -> AppContext
    private let targetDisplayPointProvider: (@MainActor () -> CGPoint)?
    private let workspaceNotificationCenter: NotificationCenter?
    private let applicationNotificationCenter: NotificationCenter?
    private let permissionStatusReader: @MainActor () -> PermissionStatusSnapshot
    /// Whether Option is down right now, read from the system rather than from key events.
    private let isOptionHeld: @MainActor () -> Bool
    private var optionReleaseWatch: Task<Void, Never>?

    @Published var status: String = "Idle"
    @Published var lastTranscript: String = ""
    @Published var lastError: String = ""
    @Published var isRecording: Bool = false
    @Published var handsFreeOn: Bool = false
    @Published var recentEntries: [TranscriptEntry] = []
    @Published var hotkeyRegistrationMessage: String = ""
    @Published var launchAtLoginWarning: String = ""
    /// macOS registered the login item but shows it as off until the user allows it.
    @Published var launchAtLoginNeedsApproval = false
    @Published var preferences: AppPreferences = .default {
        didSet {
            // Read by the next capture; a recording in progress keeps its input.
            let deviceID = preferences.recording.inputDeviceID
            captureService.preferredInputDeviceID = deviceID
            microphone.savedChoiceChanged(deviceID)
        }
    }
    @Published var microphonePermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var accessibilityPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var inputMonitoringPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    /// Seconds recorded so far, for the duration limit. Not published: views show elapsed time
    /// from `recordingStartedAt`, so this ticking must not redraw every window each second.
    var recordingElapsed: TimeInterval = 0
    @Published var recordingStartedAt: Date?
    @Published var hasBootstrapped = false
    @Published var activeModelDownloadID: WhisperModelID?
    @Published var modelDownloadMessage: String = ""
    /// The model message reports a failure and uses the error color role.
    @Published var modelDownloadMessageIsError = false
    @Published var usageAnalyticsSnapshot: UsageAnalyticsSnapshot = .empty
    @Published var usageAnalyticsError: String = ""
    @Published var usageAnalyticsWriteWarning: String = ""
    @Published var isLoadingUsageAnalytics = false
    /// A data file couldn't be read in full, or a transcript couldn't be saved.
    @Published var storageNotice: StorageRecoveryNotice?
    /// Why the last Settings save failed; empty after a successful save.
    @Published var settingsSaveError: String = ""
    /// True while a discarded recording can still be restored with Undo.
    @Published private(set) var canUndoDiscard = false
    /// Why the Paste Last Dictation shortcut isn't working, or empty.
    @Published private(set) var pasteLastShortcutMessage = ""
    /// The app the recording in progress will write into, for the Library's recording plate.
    /// Nil when nothing is recording or the app is unknown.
    @Published private(set) var recordingTargetAppName: String?
    /// True while a dictation started from the window's Dictate button is capturing; its words
    /// are copied, since the window itself is the focused app.
    @Published private(set) var dictationStartedInWindow = false
    /// The recording's words so far, for the recording plate. Published only when the words
    /// change, a few times a second at most, never at the input-level rate. Nil when not recording.
    /// They are published by their own object, so an update redraws the plate alone and not every
    /// view that observes the controller.
    let liveWordsFeed = LiveWordsFeed()
    var liveWords: LiveWords? { liveWordsFeed.words }

    /// The settled part of the live words and the tail that may still change.
    struct LiveWords: Equatable, Sendable {
        var stable: String
        var tail: String

        init(stable: String, tail: String) {
            self.stable = stable
            self.tail = tail
        }

        init(_ snapshot: LiveTranscriptionSnapshot) {
            self.init(stable: snapshot.stablePrefix, tail: snapshot.revisableTail)
        }
    }

    private let captureService: MacAudioCaptureService
    /// The level of the recording in progress, forwarded to the overlay only
    /// while a dictation is recording.
    private let inputLevelMeter: InputLevelMeter
    /// Settings › Microphone: inputs, the saved choice and the microphone test.
    let microphone: MicrophoneSettingsModel
    /// Republishes the microphone model's changes as the controller's, so a view that reads the
    /// connected inputs through the controller (Today's Ready line) draws a plug-in or a changed
    /// system input.
    private var microphoneChanges: AnyCancellable?
    /// Receives each level forwarded to the overlay. Tests observe it.
    var inputLevelObserver: (@MainActor (Float) -> Void)?
    /// Every surface that draws the recording's level subscribes here, so the overlay, Today's
    /// recording plate and the menu bar icon all read the one meter.
    let inputLevels = InputLevelBroadcast()
    private let clipboardService: any ClipboardService
    private let historyStore: HistoryStore
    private let usageAnalyticsStore: any UsageAnalyticsStoreServicing
    private let legacyHistoryURL: URL
    /// Where this copy keeps temporary capture and transcript files.
    private let temporaryDirectory: URL
    private let hotkey: any HotkeyService
    private let overlay: WaveformOverlayPresenter
    private let mediaInterruption: MediaInterruptionService
    private let preferencesStore: AppPreferencesStore
    /// Every preferences write goes through here, in the order requested.
    private let preferencesWriter: OrderedPreferencesWriter
    private let launchAtLoginService: (any LaunchAtLoginServicing)?
    private let runtimeRebuildOverride: (@MainActor () async -> (any DictationSessionCoordinating)?)?
    private let transcriptionEngineFactory: @MainActor (TranscriptionEngineSettings) -> any TranscriptionEngine
    /// Outlives coordinator rebuilds while its settings are unchanged, so a
    /// settings save does not discard the loaded model.
    private var retainedTranscriptionEngine: (engine: any TranscriptionEngine, settings: TranscriptionEngineSettings)?
    /// How long after a result the controller lets the overlay finish it. The overlay times
    /// each result itself, so this only ends a state that has no time of its own.
    private let overlayDismissDelay: @Sendable () async -> Void
    private let overlayDismissAction: @MainActor @Sendable () -> Void
    private let modelDownloadService: WhisperModelDownloadService
    private let compatibilityService = try? WhisperCompatibilityService.bundled()

    private var lexiconService: PersonalLexiconService
    private var styleProfileService: StyleProfileService
    private var snippetService: SnippetService
    private var coordinator: (any DictationSessionCoordinating)?

    private var recordingStateMachine = RecordingStateMachine()
    /// The overlay and media pause for the current Option press wait until the
    /// hotkey service confirms the press is a dictation, not a keyboard shortcut.
    private var pressToTalkConfirmation: PressToTalkConfirmation?
    /// An Option press refused because the previous dictation is still
    /// finishing is only worth a cue once it proves to be a dictation.
    private var showsFinishingNoticeOnConfirmation = false
    var recordingDurationLimit = RecordingDurationLimit.standard
    /// The time the length limit is checked against. Tests move it to reach the
    /// warning and the limit without waiting for them.
    var recordingLimitClock: @MainActor () -> Date = { Date() }
    /// Discarding a recording longer than this keeps it for Undo.
    var undoDiscardMinimumRecording: TimeInterval = 30
    /// How long a discarded recording can be restored.
    var undoDiscardWindow: Duration = .seconds(5)
    /// Waits out the Undo window. Tests replace it to end the window when they choose.
    var undoDiscardWait: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Replaces how a result that is not shown is spoken, for tests. Left nil, the overlay
    /// speaks it, such as a successful insertion with After inserting set to Show nothing.
    var announce: (@MainActor (String) -> Void)?
    /// Whether the selected speech model file is present, to tell a missing
    /// model apart from a failed transcription.
    var speechModelExists: @MainActor (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// Replaces the microphone status read at the start of a session. Tests
    /// set it; the app reads the status from macOS.
    var microphoneAccessProvider: (@MainActor () -> PermissionDiagnostics.AccessStatus)?
    /// Seconds into the recording at which it stops, set once the warning is shown.
    private var recordingLimitStopsAt: TimeInterval?
    private var currentSessionID: SessionID?
    private var currentCaptureStopCapability: PressToTalkCaptureStopCapability?
    private var activeCaptureStartHandoff: CaptureStartHandoff?
    private var activeRecordingMode: RecordingMode?
    private var activeMediaToken: MediaInterruptionToken?
    /// The app the active recording is meant for, captured at key-down.
    private var activeSessionContext: AppContext?
    private var heldDiscard: HeldDiscard?
    /// The latest dictation when History couldn't save it, so Copy and Paste
    /// Last Dictation still find it.
    private var unsavedLastDictation: RecoverableDictation?
    /// Whether a dictation History couldn't save can still be copied or pasted.
    var hasUnsavedLastDictation: Bool { unsavedLastDictation != nil }
    /// The result the overlay shows, for its Copy button.
    private var lastResult: RecoverableDictation?
    private var pasteLastShortcutProblem: String?
    private var pasteLastShortcutTapProblem: String?
    private var deferredMediaTokens: [MediaInterruptionToken] = []
    private var mediaReleaseTasks: [UUID: Task<Void, Never>] = [:]
    private var captureTerminationBarriers: [UUID: Task<Void, Never>] = [:]
    private var activeStartTask: Task<Void, Never>?
    /// Start tasks that Stop took from `activeStartTask` and that have not finished: one can
    /// still be waiting for a media Pause to be answered, and quitting has to wait for it so
    /// the Pause it is about to own is resumed.
    private var stoppedStartTasks: [UUID: Task<Void, Never>] = [:]
    private var activeCoordinatorStart: CoordinatorStartSignal?
    private var activeSessionGeneration: UUID?
    private var pendingLiveSnapshots: [SessionID: LiveTranscriptionSnapshot] = [:]
    private var pendingLiveUnavailableSessionIDs: Set<SessionID> = []
    private var sessionCleanupStartGate = SessionCleanupStartGate()
    private var cleanupTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var completionTaskID: UUID?
    /// The completion whose result is already on screen, shown as soon as its text was
    /// delivered rather than after History and the usage ledger were written.
    private var resultShownForTaskID: UUID?
    private var completionTasks: [UUID: Task<Void, Never>] = [:]
    private var overlayDismissTask: Task<Void, Never>?
    private var overlayDismissGeneration: UInt64 = 0
    private var isTearingDown = false
    private var isRuntimeUnloadingForSystemEvent = false
    private var pendingMemoryPressureRuntimeUnload = false
    private var pendingRuntimeRebuild = false
    private var runtimeRebuildGeneration: UInt64 = 0
    private var activeRuntimeRebuilds = 0
    private var runtimeRebuildWaiters: [CheckedContinuation<Void, Never>] = []
    /// The launch-at-login value last written to the settings file.
    private var savedLaunchAtLoginPreference = AppPreferences.default.general.launchAtLoginEnabled
    /// The model failure currently shown in `lastError`, cleared once a model change succeeds.
    private var lastModelError = ""
    private let menuBar = MenuBarController()
    private var recordingTimer: Timer?
    private var terminationTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var workspaceSleepObserver: NSObjectProtocol?
    private var applicationActiveObserver: NSObjectProtocol?
    /// The page that fixes the problem in `lastError`, when the error names one.
    private(set) var lastErrorTarget: ErrorRecoveryTarget?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var hasPreparedUsageAnalyticsHistory = false
    private var usageAnalyticsMigrationWarning = ""
    private var pendingUsageAnalyticsRefresh: UsageAnalyticsRefreshRequest?

    init(
        hotkey: any HotkeyService = MacHotkeyMonitor(),
        clipboardService: any ClipboardService = MacClipboardService(),
        overlay: WaveformOverlayPresenter = WaveformOverlayPresenter(),
        mediaInterruption: MediaInterruptionService = MacMediaInterruptionService(),
        preferencesStore: AppPreferencesStore? = nil,
        launchAtLoginService: (any LaunchAtLoginServicing)? = nil,
        modelDownloadService: WhisperModelDownloadService? = nil,
        coordinator: (any DictationSessionCoordinating)? = nil,
        runtimeRebuildOverride: (@MainActor () async -> (any DictationSessionCoordinating)?)? = nil,
        transcriptionEngineFactory: (@MainActor (TranscriptionEngineSettings) -> any TranscriptionEngine)? = nil,
        overlayDismissDelay: (@Sendable () async -> Void)? = nil,
        overlayDismissAction: (@MainActor @Sendable () -> Void)? = nil,
        historyStore: HistoryStore? = nil,
        usageAnalyticsStore: (any UsageAnalyticsStoreServicing)? = nil,
        legacyHistoryURL: URL? = nil,
        systemIntegrationsEnabled: Bool = true,
        isIsolatedPreview: Bool = false,
        appContextProvider: @escaping @MainActor () -> AppContext = { AppContextProvider.current() },
        targetDisplayPointProvider: (@MainActor () -> CGPoint)? = nil,
        workspaceNotificationCenter: NotificationCenter? = nil,
        applicationNotificationCenter: NotificationCenter? = nil,
        permissionStatusReader: @escaping @MainActor () -> PermissionStatusSnapshot = { .current() },
        isOptionHeld: (@MainActor () -> Bool)? = nil,
        inputLevelMeter: InputLevelMeter? = nil,
        makeMicrophoneTester: (@MainActor (_ isDictationActive: @escaping @MainActor () -> Bool) -> any MicrophoneTesting)? = nil,
        audioInputDevices: (@MainActor () -> [AudioInputDevice])? = nil,
        audioComponentWarmup: (@Sendable () async -> Duration)? = nil,
        launchConfiguration: LaunchConfiguration = .current
    ) {
        // First, before the shortcut monitor starts: the first recording would otherwise load
        // Core Audio's component list on the main thread, waiting up to 1.8 s for the system's
        // component registrar. Nothing here waits for it.
        let systemWarmup: (@Sendable () async -> Duration)? = systemIntegrationsEnabled && !isIsolatedPreview
            ? Self.loadAudioComponents
            : nil
        if let warmup = audioComponentWarmup ?? systemWarmup {
            Task.detached(priority: .userInitiated) {
                DictationLatency.audioComponentsLoaded(in: await warmup())
            }
        }
        let storage = launchConfiguration.storage
        let captureService = MacAudioCaptureService(recordingDirectory: storage.temporaryDirectory)
        self.temporaryDirectory = storage.temporaryDirectory
        self.captureService = captureService
        self.inputLevelMeter = inputLevelMeter ?? captureService.inputLevelMeter
        self.isIsolatedPreview = isIsolatedPreview
        self.systemIntegrationsEnabled = systemIntegrationsEnabled
        self.appContextProvider = appContextProvider
        self.targetDisplayPointProvider = targetDisplayPointProvider
        self.workspaceNotificationCenter = workspaceNotificationCenter
            ?? (systemIntegrationsEnabled && !isIsolatedPreview ? NSWorkspace.shared.notificationCenter : nil)
        self.applicationNotificationCenter = applicationNotificationCenter
            ?? (systemIntegrationsEnabled && !isIsolatedPreview ? NotificationCenter.default : nil)
        self.permissionStatusReader = permissionStatusReader
        // Without system integrations, as in tests, no real key is down to read.
        if let isOptionHeld {
            self.isOptionHeld = isOptionHeld
        } else if systemIntegrationsEnabled {
            self.isOptionHeld = { NSEvent.modifierFlags.contains(.option) }
        } else {
            self.isOptionHeld = { true }
        }
        self.hotkey = hotkey
        self.clipboardService = clipboardService
        self.overlay = overlay
        self.mediaInterruption = mediaInterruption
        let preferencesStore = preferencesStore ?? AppPreferencesStore(root: storage)
        self.preferencesStore = preferencesStore
        self.preferencesWriter = OrderedPreferencesWriter(persisted: nil) { [preferencesStore] snapshot in
            await preferencesStore.save(snapshot)
        }
        self.launchAtLoginService = launchAtLoginService
            ?? (systemIntegrationsEnabled && !isIsolatedPreview && launchConfiguration.managesLaunchAtLogin
                ? LaunchAtLoginService()
                : nil)
        self.modelDownloadService = modelDownloadService
            ?? WhisperModelDownloadService(locations: .root(storage))
        self.coordinator = coordinator
        self.runtimeRebuildOverride = runtimeRebuildOverride
        let engineOutputDirectory = storage.temporaryDirectory
        self.transcriptionEngineFactory = transcriptionEngineFactory ?? {
            DictationRuntimeFactory.makeTranscriptionEngine(settings: $0, outputDirectory: engineOutputDirectory)
        }
        self.overlayDismissDelay = overlayDismissDelay ?? { try? await Task.sleep(for: .seconds(2)) }
        // A timed result keeps its own time and hover hold; anything else hides.
        self.overlayDismissAction = overlayDismissAction ?? { [weak overlay] in
            overlay?.finishResultPresentation()
        }
        self.historyStore = historyStore ?? HistoryStore(
            storageURL: storage.historyURL
        )
        self.usageAnalyticsStore = usageAnalyticsStore ?? UsageAnalyticsStore(storageURL: storage.usageAnalyticsURL)
        self.legacyHistoryURL = legacyHistoryURL ?? storage.legacyHistoryURL
        self.lexiconService = PersonalLexiconService(entries: AppPreferences.default.lexiconEntries)
        self.styleProfileService = StyleProfileService(
            globalProfile: AppPreferences.default.globalStyleProfile,
            appProfiles: AppPreferences.default.appStyleProfiles
        )
        self.snippetService = SnippetService(snippets: AppPreferences.default.snippets)
        let dictationActivity = DictationActivityProbe()
        if isIsolatedPreview {
            self.microphone = .preview()
        } else {
            let usesSystemAudio = systemIntegrationsEnabled
            self.microphone = MicrophoneSettingsModel(
                tester: makeMicrophoneTester.map { $0({ dictationActivity.isActive() }) }
                    ?? (usesSystemAudio ? MacMicrophoneTester(isDictationActive: { dictationActivity.isActive() }) : nil),
                listDevices: audioInputDevices ?? { usesSystemAudio ? AudioInputDevices.list() : [] },
                observesDeviceChanges: usesSystemAudio && audioInputDevices == nil
            )
        }
        dictationActivity.isActive = { [weak self] in
            guard let self else { return false }
            return self.isRecording || self.recordingStateMachine.state != .idle
        }
        if !isIsolatedPreview {
            self.inputLevelMeter.onLevel = { [weak self] level in
                MainActor.assumeIsolated { self?.forwardInputLevel(level) }
            }
        }
        self.overlay.setStopAction { [weak self] in
            self?.stopRecording()
        }
        self.overlay.setCancelAction { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelActiveRecording()
            }
        }
        wireOverlayHooks()
        microphoneChanges = microphone.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        hotkey.onPressToTalkStart = { [weak self] in
            self?.pressToTalkStart()
        }
        hotkey.onPressToTalkStop = { [weak self] in
            self?.pressToTalkStop()
        }
        hotkey.onToggleHandsFree = { [weak self] in
            self?.toggleHandsFree()
        }
        hotkey.onPressToTalkConfirmed = { [weak self] in
            self?.pressToTalkConfirmed()
        }
        hotkey.onPressToTalkDiscarded = { [weak self] in
            self?.pressToTalkDiscarded()
        }
        hotkey.onRegistrationStatusChanged = { [weak self] status in
            self?.handleHotkeyRegistrationStatus(status)
        }
        hotkey.onPasteLastShortcut = { [weak self] in
            self?.pasteLastDictation()
        }
        hotkey.onPasteLastShortcutStatusChanged = { [weak self] status in
            guard let self else { return }
            if case .unavailable(let reason) = status {
                self.pasteLastShortcutTapProblem = reason
            } else {
                self.pasteLastShortcutTapProblem = nil
            }
            self.updatePasteLastShortcutMessage()
        }
        // The hands-free key registers once saved preferences load, so a
        // saved Disabled never registers the built-in default at launch.
        hotkey.globalToggleKeyCode = nil
        if systemIntegrationsEnabled && !isIsolatedPreview {
            hotkey.start()
            menuBar.setup(controller: self)
        }

        // Permissions are granted and revoked in System Settings, so read them
        // again whenever the user comes back to Steno.
        applicationActiveObserver = self.applicationNotificationCenter?.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionStatuses(reinstallHotkeysOnlyIfChanged: true)
            }
        }

        workspaceSleepObserver = self.workspaceNotificationCenter?.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.unloadRetainedRuntimeForSystemEvent()
            }
        }
        workspaceWakeObserver = self.workspaceNotificationCenter?.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.unloadRetainedRuntimeForSystemEvent()
            }
        }

        guard systemIntegrationsEnabled, !isIsolatedPreview else { return }
        let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        memoryPressureSource.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.requestRetainedRuntimeUnloadForMemoryPressure()
            }
        }
        memoryPressureSource.activate()
        self.memoryPressureSource = memoryPressureSource

        terminationTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default
                .notifications(named: NSApplication.willTerminateNotification)
                .map { _ in () }

            for await _ in notifications {
                self?.teardown()
                break
            }
        }
    }

    /// Idempotent shutdown: stops hotkeys, cancels in-flight work, releases media,
    /// hides the overlay, and invalidates timers. Triggered by willTerminateNotification.
    @MainActor
    func teardown() {
        guard shutdownTask == nil else { return }
        isTearingDown = true
        optionReleaseWatch?.cancel()
        invalidatePendingOverlayDismissal()
        pendingMemoryPressureRuntimeUnload = false
        runtimeRebuildGeneration &+= 1
        terminationTask?.cancel()
        terminationTask = nil
        if let applicationActiveObserver {
            applicationNotificationCenter?.removeObserver(applicationActiveObserver)
            self.applicationActiveObserver = nil
        }
        if let workspaceSleepObserver {
            workspaceNotificationCenter?.removeObserver(workspaceSleepObserver)
            self.workspaceSleepObserver = nil
        }
        if let workspaceWakeObserver {
            workspaceNotificationCenter?.removeObserver(workspaceWakeObserver)
            self.workspaceWakeObserver = nil
        }
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        hotkey.stop()
        microphone.shutdown()
        overlay.hide()
        sessionCleanupStartGate.reset()
        let pendingCleanup = cleanupTask
        cleanupTask = nil
        pendingCleanup?.cancel()
        let pendingCompletions = Array(completionTasks.values)
        completionTasks.removeAll()
        completionTask = nil
        completionTaskID = nil
        for completion in pendingCompletions {
            completion.cancel()
        }
        pendingLiveSnapshots.removeAll()
        pendingLiveUnavailableSessionIDs.removeAll()
        let sessionGeneration = activeSessionGeneration
        let pendingStart = activeStartTask
        activeStartTask = nil
        let stoppedStarts = Array(stoppedStartTasks.values)
        let captureStopCapability = currentCaptureStopCapability
            ?? activeCaptureStartHandoff?.request(.cancel)
        captureStopCapability?.markStopRequested()
        let promptCaptureCancelTask = captureStopCapability.map { capability in
            Task { await capability.cancelCapture() }
        }
        installCaptureTerminationBarrier(
            promptCaptureCancelTask,
            for: sessionGeneration,
            pendingStart: pendingStart
        )
        activeSessionGeneration = nil
        pendingStart?.cancel()
        currentCaptureStopCapability = nil
        activeCaptureStartHandoff = nil
        let mediaToken = activeMediaToken
        activeMediaToken = nil
        let deferredMediaTokens = self.deferredMediaTokens
        self.deferredMediaTokens.removeAll()
        let sessionID = currentSessionID ?? captureStopCapability?.sessionID
        currentSessionID = nil
        activeSessionContext = nil
        let coordinator = self.coordinator
        self.coordinator = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        let heldDiscard = self.heldDiscard
        self.heldDiscard = nil
        heldDiscard?.expiryTask?.cancel()
        canUndoDiscard = false

        shutdownTask = Task {
            await promptCaptureCancelTask?.value
            if let heldDiscard {
                await heldDiscard.coordinator.cancel(sessionID: heldDiscard.sessionID)
            }
            await pendingCleanup?.value
            await pendingStart?.value
            for start in stoppedStarts {
                await start.value
            }
            for completion in pendingCompletions {
                await completion.value
            }
            if let coordinator, let sessionID {
                await coordinator.cancel(sessionID: sessionID)
            }
            if let mediaToken {
                await mediaInterruption.endInterruption(token: mediaToken)
            }
            for token in deferredMediaTokens {
                await mediaInterruption.endInterruption(token: token)
            }
            // Quitting completes any resume still verifying in the background.
            for release in Array(mediaReleaseTasks.values) {
                await release.value
            }
            await waitForRuntimeRebuilds()
            await coordinator?.shutdown()
            let engine = retainedTranscriptionEngine?.engine
            retainedTranscriptionEngine = nil
            await engine?.shutdown()
        }
    }

    func teardownAndWait() async {
        teardown()
        await shutdownTask?.value
    }

    var menuBarIconName: String {
        if isRecording { return "waveform.circle.fill" }
        return handsFreeOn ? "mic.circle.fill" : "mic.circle"
    }

    var recordingLifecycleState: RecordingLifecycleState {
        recordingStateMachine.state
    }

    var lifecycleDiagnostics: DictationLifecycleDiagnostics {
        DictationLifecycleDiagnostics(
            hasActiveStartTask: activeStartTask != nil,
            isCleanupInProgress: sessionCleanupStartGate.isCleanupInProgress,
            hasPendingRuntimeRebuild: pendingRuntimeRebuild
        )
    }

    #if DEBUG
    func stageIsolatedPreviewLifecycle(_ state: RecordingLifecycleState) {
        guard isIsolatedPreview else { return }
        recordingStateMachine = RecordingStateMachine(initialState: state)
        isRecording = state == .recordingPressToTalk || state == .recordingHandsFree
        handsFreeOn = state == .recordingHandsFree
        recordingElapsed = isRecording ? 72 : 0
    }

    /// Shows a destination and live words on the recording plate of an isolated preview.
    func stageIsolatedPreviewRecording(targetApp: String?, words: LiveWords?) {
        guard isIsolatedPreview else { return }
        recordingTargetAppName = targetApp
        liveWordsFeed.words = words
    }

    func replaceCoordinatorForLifecycleTesting(
        _ replacement: any DictationSessionCoordinating
    ) {
        coordinator = replacement
    }

    /// Where each store and temporary folder of this controller actually points.
    struct StorageLocations: Equatable {
        var preferences: URL
        var history: URL
        var usageAnalytics: URL?
        var legacyHistory: URL
        var recordings: URL
        var transcriptOutput: URL
        var models: URL?
    }

    func storageLocationsForTesting() async -> StorageLocations {
        StorageLocations(
            preferences: preferencesStore.storageURL,
            history: historyStore.storageURL,
            usageAnalytics: (usageAnalyticsStore as? UsageAnalyticsStore)?.storageURL,
            legacyHistory: legacyHistoryURL,
            recordings: captureService.recordingDirectory,
            transcriptOutput: temporaryDirectory,
            models: try? modelDownloadService.locations.modelsDirectory()
        )
    }

    func unloadRuntimeForLifecycleTesting() async {
        await unloadRetainedRuntimeForSystemEvent()
    }

    func unloadRuntimeForMemoryPressureTesting() async {
        await requestRetainedRuntimeUnloadForMemoryPressure()
    }
    #endif

    #if DEBUG
    /// Model rows shown by an isolated preview instead of the default sample rows.
    var previewWhisperModelOptions: [WhisperModelOption]?
    #endif

    var whisperModelOptions: [WhisperModelOption] {
        if isIsolatedPreview {
            #if DEBUG
            if let previewWhisperModelOptions { return previewWhisperModelOptions }
            #endif
            return WhisperModelLibrary.managedModelIDs.map {
                WhisperModelOption(modelID: $0, source: $0 == .smallEn ? .bundled : nil,
                    path: nil, isInstalled: $0 == .smallEn, isActive: $0 == .smallEn,
                    isRecommended: $0 == .smallEn)
            }
        }
        return WhisperModelLibrary.installedOptions(
            preferences: preferences,
            compatibilityService: compatibilityService,
            locations: modelDownloadService.locations
        )
    }

    var recommendedWhisperModel: WhisperModelOption? {
        whisperModelOptions.first(where: \.isRecommended)
    }

    var currentHardwareSummary: String? {
        if isIsolatedPreview { return "Preview device" }
        guard let hardwareProfile = WhisperCompatibilityService.currentHardwareProfile() else {
            return nil
        }
        return "\(hardwareProfile.chipClass.displayName) · \(hardwareProfile.memoryGB)GB unified memory"
    }

    var recommendedWhisperModelNote: String? {
        if isIsolatedPreview { return "Sample model selection. No model is loaded in this preview." }
        guard let hardwareProfile = WhisperCompatibilityService.currentHardwareProfile(),
              let row = compatibilityService?.recommendation(for: hardwareProfile)
        else {
            return nil
        }
        return row.notes
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        await bootstrap()
    }

    func bootstrap() async {
        guard !isIsolatedPreview else { hasBootstrapped = true; return }
        captureService.onRecorderStoppedEarly = { [weak self] sessionID in
            self?.recorderStoppedEarly(sessionID: sessionID)
        }
        if systemIntegrationsEnabled {
            // A crash or force quit leaves the recording in progress and the
            // backup engine's transcript files behind. They hold the user's
            // speech and text, and no session can own them at launch.
            let temporaryDirectory = temporaryDirectory
            Task.detached(priority: .utility) {
                MacAudioCaptureService.removeStaleRecordings(in: temporaryDirectory)
                WhisperCLITranscriptionEngine.removeStaleOutputFiles(in: temporaryDirectory)
            }
        }
        await historyStore.setRecoveryNoticeHandler { [weak self] notice in
            Task { @MainActor [weak self] in self?.presentStorageNotice(notice) }
        }
        await preferencesStore.setRecoveryNoticeHandler { [weak self] notice in
            Task { @MainActor [weak self] in self?.presentStorageNotice(notice) }
        }
        var loaded = await preferencesStore.load()
        loaded.normalize()
        preferencesWriter.markPersisted(loaded)

        applyPreferencesLocally(loaded)
        savedLaunchAtLoginPreference = loaded.general.launchAtLoginEnabled
        launchAtLoginWarning = ""
        await refreshLaunchAtLoginStatus()
        refreshPermissionStatuses()
        await rebuildRuntime()
        // After the rebuild, whose own status would otherwise replace the warning.
        validateWhisperPaths()
        await refreshHistory()
        await refreshUsageAnalytics()
        overlay.prepareWindow()
        hasBootstrapped = true
    }

    func savePreferences() {
        guard !isIsolatedPreview else { status = "Preview settings updated."; return }
        var snapshot = preferences
        snapshot.normalize()
        snapshot.general.launchAtLoginEnabled = applyLaunchAtLoginChange(
            requestedPreference: snapshot.general.launchAtLoginEnabled,
            previousPreference: savedLaunchAtLoginPreference
        )
        applyPreferencesLocally(snapshot)
        let write = preferencesWriter.enqueue(snapshot)

        Task {
            guard await persistSettings(snapshot, write: write, savedFrom: .general) else { return }
            await rebuildRuntimeOrDefer()
        }
    }

    /// Applies a Settings draft and saves it. The returned task reports whether
    /// the save succeeded; on failure the previous settings are restored so the
    /// draft stays unsaved and can be saved again or discarded, and Review
    /// settings opens `section`, the page the draft was saved from.
    @discardableResult
    func applySettingsDraft(
        preferences draft: AppPreferences,
        savedFrom section: SettingsSection = .general
    ) -> Task<Bool, Never> {
        guard !isIsolatedPreview else {
            preferences = draft
            status = "Preview settings updated."
            return Task { true }
        }
        let previous = preferences
        var snapshot = draft
        // Dictations update this count; a draft opened earlier must not roll it back.
        snapshot.general.successNoticesShown = previous.general.successNoticesShown
        snapshot.normalize()
        snapshot.general.launchAtLoginEnabled = applyLaunchAtLoginChange(
            requestedPreference: snapshot.general.launchAtLoginEnabled,
            previousPreference: previous.general.launchAtLoginEnabled
        )
        applyPreferencesLocally(snapshot)
        let write = preferencesWriter.enqueue(snapshot)

        return Task {
            guard await persistSettings(snapshot, write: write, savedFrom: section) else {
                if preferences == snapshot {
                    applyPreferencesLocally(previous)
                }
                return false
            }
            await rebuildRuntimeOrDefer()
            return true
        }
    }

    /// Chooses the microphone dictation records from; nil follows the system input. Saved like any
    /// other setting, so a recording in progress keeps the input it started with.
    @discardableResult
    func selectMicrophone(_ deviceID: String?) -> Task<Bool, Never> {
        var updated = preferences
        updated.recording.inputDeviceID = deviceID
        return applySettingsDraft(preferences: updated, savedFrom: .microphone)
    }

    /// Writes settings and reports the real outcome; never claims a save that failed.
    private func persistSettings(
        _ snapshot: AppPreferences,
        write: Task<Result<Void, AppPreferencesStoreError>, Never>,
        savedFrom section: SettingsSection
    ) async -> Bool {
        switch await write.value {
        case .success:
            if !settingsSaveError.isEmpty, lastError == settingsSaveError {
                lastError = ""
            }
            settingsSaveError = ""
            savedLaunchAtLoginPreference = snapshot.general.launchAtLoginEnabled
            status = "Settings saved."
            return true
        case .failure(let error):
            settingsSaveError = error.localizedDescription
            status = "Settings couldn't be saved."
            reportError(error.localizedDescription, fixedIn: section)
            return false
        }
    }

    func saveAppearance(_ appearance: AppPreferences.Appearance) {
        guard !isIsolatedPreview else { preferences.appearance = appearance; return }
        var snapshot = preferences
        snapshot.appearance = appearance
        snapshot.normalize()
        preferences = snapshot
        applyOverlayAppearance(for: snapshot.appearance)
        let write = preferencesWriter.enqueue(snapshot)

        Task {
            switch await write.value {
            case .success:
                if !settingsSaveError.isEmpty, lastError == settingsSaveError {
                    lastError = ""
                }
                settingsSaveError = ""
            case .failure(let error):
                settingsSaveError = error.localizedDescription
                status = "Appearance couldn't be saved."
                reportError(error.localizedDescription, fixedIn: .appearance)
            }
        }
    }

    func resetOnboarding() {
        preferences.general.showOnboarding = true
        savePreferences()
    }

    func completeOnboarding() {
        preferences.general.showOnboarding = false
        savePreferences()
    }

    func handleWhisperModelAction(for option: WhisperModelOption) {
        if option.isInstalled {
            activateWhisperModel(option.modelID)
        } else {
            downloadWhisperModel(option.modelID)
        }
    }

    func activateWhisperModel(_ modelID: WhisperModelID) {
        guard !isIsolatedPreview else { return }
        guard let option = whisperModelOptions.first(where: { $0.modelID == modelID }),
              let path = option.path
        else { return }

        let title = WhisperModelCatalog.title(for: modelID)
        var snapshot = preferences
        snapshot.dictation.updateModelPath(path)
        snapshot.normalize()

        Task {
            guard await commitModelSelection(snapshot, failurePrefix: "Couldn't switch to \(title).") else { return }
            showModelMessage("Using \(title).")
            status = "Using \(title)."
            await rebuildRuntimeOrDefer()
        }
    }

    func downloadWhisperModel(_ modelID: WhisperModelID) {
        guard !isIsolatedPreview else { return }
        guard activeModelDownloadID == nil else { return }

        let title = WhisperModelCatalog.title(for: modelID)
        activeModelDownloadID = modelID
        showModelMessage("Downloading \(title)...")

        let bundledVADPath = BundledWhisperRuntime.resolvedPaths()?.vadModelPath
        let currentVADPath = FileManager.default.fileExists(atPath: preferences.dictation.vadModelPath)
            ? preferences.dictation.vadModelPath
            : nil
        let preferredVADSource = bundledVADPath ?? currentVADPath

        Task {
            let installed: WhisperModelInstallResult
            do {
                installed = try await modelDownloadService.install(
                    modelID: modelID,
                    vadSourcePath: preferredVADSource
                )
            } catch {
                let failure = Self.modelDownloadFailureMessage(for: modelID, error: error)
                activeModelDownloadID = nil
                showModelMessage(failure, isError: true)
                status = "Model download failed."
                reportModelError(failure)
                return
            }

            // Start from the settings as they are now, so a change saved during
            // the download is kept.
            var snapshot = preferences
            let previousDictation = snapshot.dictation
            snapshot.dictation.updateModelPath(installed.modelPath)
            if let installedVADPath = installed.vadModelPath,
               Self.vadModelPathIsDerived(previousDictation) {
                snapshot.dictation.vadModelPath = installedVADPath
            }
            snapshot.normalize()

            activeModelDownloadID = nil
            guard await commitModelSelection(
                snapshot,
                failurePrefix: "Downloaded \(title), but couldn't switch to it."
            ) else { return }
            showModelMessage("Downloaded \(title) and switched to it.")
            status = "Downloaded \(title) and switched to it."
            await rebuildRuntimeOrDefer()
        }
    }

    /// Deletes a downloaded model. Removing the model in use switches to the
    /// included model first, so dictation never points at a missing file.
    func removeDownloadedModel(_ modelID: WhisperModelID) {
        guard !isIsolatedPreview, activeModelDownloadID == nil else { return }
        let title = WhisperModelCatalog.title(for: modelID)
        guard let downloadedPath = WhisperModelLibrary.downloadedModelPath(
            for: modelID,
            locations: modelDownloadService.locations
        ) else { return }
        let isInUse = preferences.dictation.modelPath == downloadedPath

        Task {
            var switchedTo: String?
            if isInUse {
                let fallbackID = WhisperModelCatalog.bundledDefaultModel
                guard let fallbackPath = modelDownloadService.locations.bundledModelPath(fallbackID) else {
                    let failure = "Couldn't remove \(title) because it's in use and the included model isn't available."
                    showModelMessage(failure, isError: true)
                    reportModelError(failure)
                    return
                }
                var snapshot = preferences
                snapshot.dictation.updateModelPath(fallbackPath)
                snapshot.normalize()
                guard await commitModelSelection(snapshot, failurePrefix: "Couldn't remove \(title).") else { return }
                switchedTo = WhisperModelCatalog.title(for: fallbackID)
                await rebuildRuntimeOrDefer()
            }

            do {
                try await modelDownloadService.removeDownloadedModel(modelID)
            } catch {
                let failure = "Couldn't remove \(title). \(error.localizedDescription)"
                showModelMessage(failure, isError: true)
                reportModelError(failure)
                return
            }
            let message = switchedTo.map { "Removed \(title) and switched to \($0)." } ?? "Removed \(title)."
            showModelMessage(message)
            status = message
        }
    }

    /// A voice-detection path the user didn't choose: empty, or the default
    /// that sits next to the selected model.
    static func vadModelPathIsDerived(_ dictation: AppPreferences.Dictation) -> Bool {
        dictation.vadModelPath.isEmpty
            || dictation.vadModelPath == WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: dictation.modelPath)
    }

    /// Applies a model change at once and saves it. If the save fails, the
    /// previous model stays selected and the failure is shown with the model controls.
    private func commitModelSelection(_ snapshot: AppPreferences, failurePrefix: String) async -> Bool {
        let previous = preferences
        preferences = snapshot
        switch await preferencesWriter.enqueue(snapshot).value {
        case .success:
            if !lastModelError.isEmpty, lastError == lastModelError {
                lastError = ""
            }
            lastModelError = ""
            return true
        case .failure(let error):
            if preferences == snapshot {
                preferences = previous
            }
            let failure = "\(failurePrefix) \(error.localizedDescription)"
            showModelMessage(failure, isError: true)
            status = "Settings couldn't be saved."
            reportModelError(failure)
            return false
        }
    }

    private func reportModelError(_ message: String) {
        lastModelError = message
        reportError(message, fixedIn: .engine)
    }

    private func reportError(_ message: String, fixedIn section: SettingsSection) {
        lastError = message
        lastErrorTarget = ErrorRecoveryTarget(message: message, section: section)
    }

    /// The Settings page that "Review settings" opens for the current problems.
    var recoverySection: SettingsSection {
        SettingsRecovery.section(for: .init(
            microphone: microphonePermissionStatus,
            accessibility: accessibilityPermissionStatus,
            inputMonitoring: inputMonitoringPermissionStatus,
            lastError: lastError,
            lastErrorTarget: lastErrorTarget,
            hotkeyMessage: hotkeyRegistrationMessage
        ))
    }

    /// Shown next to the control that started the download, in Settings and onboarding.
    static func modelDownloadFailureMessage(for modelID: WhisperModelID, error: Error) -> String {
        "Couldn't download \(WhisperModelCatalog.title(for: modelID)). \(error.localizedDescription) Your current model is still in use."
    }

    private func showModelMessage(_ message: String, isError: Bool = false) {
        modelDownloadMessage = message
        modelDownloadMessageIsError = isError
    }

    func requestMicrophonePermission() {
        guard !isIsolatedPreview else { return }
        Task {
            _ = await PermissionDiagnostics.requestMicrophonePermission()
            await MainActor.run {
                refreshPermissionStatuses()
            }
        }
    }

    func openMicrophoneSettings() {
        guard !isIsolatedPreview else { return }
        PermissionDiagnostics.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        guard !isIsolatedPreview else { return }
        PermissionDiagnostics.openAccessibilitySettings()
    }

    func openInputMonitoringSettings() {
        guard !isIsolatedPreview else { return }
        PermissionDiagnostics.openInputMonitoringSettings()
    }

    func requestAccessibilityPermission() {
        guard !isIsolatedPreview else { return }
        _ = PermissionDiagnostics.requestAccessibilityPermission()
        refreshPermissionStatuses()
    }

    func requestInputMonitoringPermission() {
        guard !isIsolatedPreview else { return }
        _ = PermissionDiagnostics.requestInputMonitoringPermission()
        refreshPermissionStatuses()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            refreshPermissionStatuses()
        }
    }

    func revealCurrentAppInFinder() {
        guard !isIsolatedPreview else { return }
        PermissionDiagnostics.revealCurrentAppInFinder()
    }

    /// Runs a short real transcription with the given settings through
    /// separately created engines. The warm runtime, any dictation, History,
    /// and Insights are left untouched.
    func runSetupCheck(preferences draft: AppPreferences) async -> [WhisperSetupCheckStage] {
        if isIsolatedPreview {
            return [.init(title: "Setup check", outcome: .skipped, detail: "Unavailable in preview.")]
        }
        guard recordingStateMachine.state == .idle,
              activeStartTask == nil,
              completionTasks.isEmpty,
              !sessionCleanupStartGate.isCleanupInProgress
        else {
            return [.init(title: "Setup check", outcome: .skipped, detail: "Finish the current dictation, then try again.")]
        }

        var snapshot = draft
        snapshot.normalize()
        let engines = DictationRuntimeFactory(
            snapshot: snapshot,
            clipboardService: clipboardService,
            temporaryDirectory: temporaryDirectory
        ).makeSetupCheckEngines()
        return await WhisperSetupSelfTest.run(.init(
            microphoneAllowed: permissionStatusReader().microphone == .granted,
            modelPath: snapshot.dictation.modelPath,
            vadEnabled: snapshot.dictation.vadEnabled,
            vadModelPath: snapshot.dictation.vadModelPath,
            mainEngine: engines.main,
            toolEngine: engines.tool,
            temporaryDirectory: temporaryDirectory
        ))
    }

    /// Reads permission status. The hotkey monitor is reinstalled only while
    /// idle; on app activation only when a shortcut permission changed or the
    /// last registration failed.
    func refreshPermissionStatuses(reinstallHotkeysOnlyIfChanged: Bool = false) {
        guard !isIsolatedPreview else { return }
        let previousShortcutAccess = (accessibilityPermissionStatus, inputMonitoringPermissionStatus)
        let current = permissionStatusReader()
        microphonePermissionStatus = current.microphone
        accessibilityPermissionStatus = current.accessibility
        inputMonitoringPermissionStatus = current.inputMonitoring

        let shortcutAccessChanged = previousShortcutAccess != (current.accessibility, current.inputMonitoring)
        if reinstallHotkeysOnlyIfChanged, !shortcutAccessChanged, hotkeyRegistrationMessage.isEmpty {
            return
        }

        // If permissions changed while app was running, reinstall monitors/hotkeys.
        if recordingStateMachine.state == .idle {
            hotkey.stop()
            hotkey.start()
            hotkey.isOptionPressToTalkEnabled = preferences.hotkeys.optionPressToTalkEnabled
            hotkey.globalToggleKeyCode = preferences.hotkeys.handsFreeGlobalKeyCode
        }
    }

    private func handleHotkeyRegistrationStatus(_ status: HotkeyRegistrationStatus) {
        switch status {
        case .registered, .disabled:
            hotkeyRegistrationMessage = ""
        case .unavailable(let reason):
            hotkeyRegistrationMessage = reason
            // A registration problem never replaces an active session's overlay
            // and its Stop and Cancel controls.
            guard recordingStateMachine.state == .idle else { return }
            showOverlay(.result(.shortcutsUnavailable, showsWords: true))
        }
    }

    func pressToTalkStart() {
        guard !isIsolatedPreview else { return }
        guard !isTearingDown else { return }
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        DictationLatency.note("option down")
        pressToTalkConfirmation?.release()
        pressToTalkConfirmation = hotkey.confirmsPressToTalk ? PressToTalkConfirmation() : nil
        showsFinishingNoticeOnConfirmation = false
        if sessionCleanupStartGate.deferPressToTalkStart() {
            status = "Finishing the previous recording. Hold Option to start when ready."
            return
        }
        let isFinishingPreviousSession = recordingStateMachine.state == .transcribing
        apply(transition: recordingStateMachine.handleOptionKeyDown())
        if isFinishingPreviousSession {
            if pressToTalkConfirmation == nil {
                showFinishingPreviousSessionNotice()
            } else {
                showsFinishingNoticeOnConfirmation = true
            }
        }
    }

    func pressToTalkStop() {
        guard !isIsolatedPreview else { return }
        guard !isTearingDown else { return }
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        DictationLatency.note("option up")
        if sessionCleanupStartGate.cancelDeferredPressToTalkStart() {
            status = "Option released before the previous recording finished."
            return
        }
        let transition = recordingStateMachine.handleOptionKeyUp()
        // A release that ends no Option recording, such as one whose start was
        // refused or that already stopped by itself, keeps the message that
        // says what happened.
        if case .ignore = transition {
            DictationLatency.note("option up ignored")
            return
        }
        apply(transition: transition)
    }

    /// Ends an Option recording whose release never arrived, whatever lost it: while the recording
    /// runs, the key's live state is read twice a second, and two readings without Option stop it
    /// through the normal release path. The monitor's own re-read stops when its press is reset.
    private func watchForMissedOptionRelease(generation: UUID) {
        optionReleaseWatch?.cancel()
        optionReleaseWatch = Task { @MainActor [weak self] in
            var readingsWithoutOption = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, !self.isTearingDown,
                      self.activeSessionGeneration == generation,
                      self.recordingStateMachine.state == .recordingPressToTalk
                else { return }
                readingsWithoutOption = self.isOptionHeld() ? 0 : readingsWithoutOption + 1
                if readingsWithoutOption >= 2 {
                    DictationLatency.note("option release missed, stopping")
                    self.pressToTalkStop()
                    return
                }
            }
        }
    }

    /// Option has been held alone long enough to be a dictation.
    func pressToTalkConfirmed() {
        guard !isIsolatedPreview, !isTearingDown else { return }
        pressToTalkConfirmation?.confirm()
        if showsFinishingNoticeOnConfirmation {
            showsFinishingNoticeOnConfirmation = false
            showFinishingPreviousSessionNotice()
        }
    }

    /// The Option press was part of a keyboard shortcut. The recording is
    /// thrown away through the cancel path: nothing is inserted or saved, and
    /// media is left as it was.
    func pressToTalkDiscarded() {
        guard !isIsolatedPreview, !isTearingDown else { return }
        showsFinishingNoticeOnConfirmation = false
        let confirmation = pressToTalkConfirmation
        pressToTalkConfirmation = nil
        defer { confirmation?.release() }
        if sessionCleanupStartGate.cancelDeferredPressToTalkStart() { return }
        let transition = recordingStateMachine.handleOptionShortcut()
        guard case .cancel(let mode) = transition else { return }
        let wasPresented = confirmation?.isConfirmed == true
        let previousStatus = status
        let previousError = lastError
        // The island still offers Undo for the recording discarded before this press.
        cancelSession(mode: mode, keepsOverlay: !wasPresented && heldDiscard != nil)
        if !wasPresented {
            // The press never showed as a recording, so it leaves no trace.
            status = previousStatus
            lastError = previousError
        }
    }

    func stopRecording() {
        guard !isIsolatedPreview, !isTearingDown else { return }
        switch recordingStateMachine.state {
        case .recordingPressToTalk:
            apply(transition: recordingStateMachine.handleOptionKeyUp())
        case .recordingHandsFree:
            apply(transition: recordingStateMachine.handleHandsFreeToggle())
        default:
            break
        }
    }

    /// The window's Dictate button: asks for the microphone the first time, otherwise starts a
    /// hands-free dictation whose words are copied when it stops.
    func startDictationFromWindow() {
        if microphonePermissionStatus == .unknown {
            requestMicrophonePermission()
            return
        }
        // Set first so the recording plate reads it from its first frame, then
        // taken back when the click started nothing: refused, ignored while a
        // dictation is finishing, or a deferred start it cancelled.
        dictationStartedInWindow = true
        toggleHandsFree()
        if recordingStateMachine.state != .recordingHandsFree,
           sessionCleanupStartGate.deferredMode != .handsFree {
            dictationStartedInWindow = false
        }
    }

    func toggleHandsFree() {
        guard !isIsolatedPreview else { return }
        guard !isTearingDown else { return }
        if sessionCleanupStartGate.deferHandsFreeToggle() {
            let startsLater = sessionCleanupStartGate.deferredMode == .handsFree
            status = startsLater
                ? "Finishing the previous recording. Hands-free will start when ready."
                : "Deferred hands-free start canceled."
            if startsLater {
                overlay.show(state: .busy(.handsFreeDeferred))
            } else {
                dictationStartedInWindow = false
            }
            return
        }
        let isFinishingPreviousSession = recordingStateMachine.state == .transcribing
        apply(transition: recordingStateMachine.handleHandsFreeToggle())
        if isFinishingPreviousSession {
            showFinishingPreviousSessionNotice()
        }
    }

    /// A press while the previous dictation is still finishing starts nothing.
    /// Say so where the user is looking, not only in the main window.
    private func showFinishingPreviousSessionNotice() {
        status = "Still finishing the previous dictation. Try again when it is done."
        overlay.show(state: .busy(.stillFinishing))
    }

    /// The overlay's buttons. Copy copies the result the overlay shows; Undo restores a
    /// discarded recording; the microphone result opens System Settings.
    private func wireOverlayHooks() {
        overlay.appearance = .grove
        overlay.onCopyResult = { [weak self] in self?.copyShownResult() }
        overlay.onUndoDiscard = { [weak self] in self?.undoDiscard() }
        overlay.onOpenSettings = { [weak self] result in
            guard let self, !self.isIsolatedPreview, self.systemIntegrationsEnabled else { return }
            if result == .microphoneAccessOff {
                PermissionDiagnostics.openMicrophoneSettings()
            }
        }
    }

    func cancelActiveRecording() {
        guard !isIsolatedPreview else { return }
        guard !isTearingDown else { return }
        apply(transition: recordingStateMachine.handleCancel())
    }

    /// Registers the saved Paste Last Dictation shortcut unless it can't be
    /// used, and says why when it can't.
    private func registerPasteLastShortcut(for preferences: AppPreferences) {
        let saved = preferences.recording.pasteLastShortcut
        var shortcut = preferences.recording.pasteLastGlobalShortcut
        pasteLastShortcutProblem = nil
        if let saved, !saved.isEmpty, shortcut == nil {
            pasteLastShortcutProblem = switch GlobalShortcut.problem(withPreferenceValue: saved) {
            case .reserved:
                "The Paste Last Dictation shortcut is already used by macOS or most apps. Choose another."
            case .modifierKey, .needsModifier, .optionNeedsCommandOrControl:
                "The Paste Last Dictation shortcut would get in the way of typing or dictating. Choose another."
            case nil:
                "The Paste Last Dictation shortcut couldn't be read. Choose it again."
            }
        } else if let candidate = shortcut,
                  candidate.collides(withHandsFreeKeyCode: preferences.hotkeys.handsFreeGlobalKeyCode) {
            shortcut = nil
            pasteLastShortcutProblem = "The Paste Last Dictation shortcut uses the hands-free key. Choose another."
        }
        if shortcut == nil {
            pasteLastShortcutTapProblem = nil
        }
        hotkey.pasteLastShortcut = shortcut
        updatePasteLastShortcutMessage()
    }

    private func updatePasteLastShortcutMessage() {
        pasteLastShortcutMessage = pasteLastShortcutProblem ?? pasteLastShortcutTapProblem ?? ""
    }

    /// Copies the most recent dictation to the clipboard.
    func copyLastDictation() {
        guard !isIsolatedPreview else { return }
        Task {
            guard let dictation = await lastDictation() else {
                status = "No dictation to copy yet."
                return
            }
            do {
                try await copy(dictation)
                status = "Last dictation copied."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    /// Inserts the most recent dictation into the frontmost app, once,
    /// through the normal insertion chain and target check. A secure field
    /// gets a copy instead. Nothing new is saved in History or Insights.
    func pasteLastDictation() {
        guard !isIsolatedPreview, !isTearingDown else { return }
        guard let coordinator else {
            status = "Runtime not ready yet."
            overlay.show(state: .busy(.modelLoading))
            return
        }
        // A paste pressed while a discarded recording is still closing, as
        // when its chord includes the held Option key, runs once that ends.
        if sessionCleanupStartGate.deferPasteLast() { return }
        // Guarded like a dictation's own insertion: a press meanwhile is
        // refused as still finishing, and Cancel stops it before it commits.
        guard recordingStateMachine.beginWorkWithoutRecording() else {
            status = "Finish the current dictation, then paste the last one."
            overlay.show(state: .busy(.pasteWaitsForDictation))
            return
        }
        let target = appContextProvider()
        let taskID = UUID()
        completionTaskID = taskID
        let task = Task {
            await pasteLastDictation(into: target, with: coordinator, taskID: taskID)
            await finishCompletionTask(id: taskID)
            await applyDeferredRebuildIfNeeded()
        }
        completionTask = task
        completionTasks[taskID] = task
    }

    private func pasteLastDictation(
        into target: AppContext,
        with coordinator: any DictationSessionCoordinating,
        taskID: UUID
    ) async {
        let ownsState = { [unowned self] in
            !Task.isCancelled && !isTearingDown && completionTaskID == taskID
        }
        guard let dictation = await lastDictation() else {
            if ownsState() {
                status = "No dictation to paste yet."
                recordingStateMachine.markTranscriptionCompleted()
                overlay.show(state: .busy(.nothingToPaste))
            }
            return
        }
        guard ownsState() else { return }
        var result = await coordinator.insertText(dictation.text, into: target, concealed: dictation.concealed)
        // A dictation meant for a secure field stays concealed wherever it is
        // shown or copied again: the island offers no words and Copy is concealed.
        if dictation.concealed { result.copyIsConcealed = true }
        let committed = result.status == .inserted || result.status == .copiedOnly
        guard !isTearingDown, completionTaskID == taskID, committed || !Task.isCancelled else { return }
        if recordingStateMachine.state == .transcribing {
            recordingStateMachine.markTranscriptionCompleted()
        }
        switch result.status {
        case .inserted:
            status = "Last dictation inserted."
        case .copiedOnly:
            status = copiedOnlyStatusMessage(for: result)
        case .failed, .noSpeech:
            status = "Last dictation couldn't be inserted."
            lastError = result.errorMessage ?? ""
        }
        presentResult(result, context: target, countsTowardSuccessNotices: false)
    }

    /// The overlay's Copy button: copies the text of the result it shows.
    private func copyShownResult() {
        guard !isIsolatedPreview, let dictation = lastResult else { return }
        Task {
            do {
                try await copy(dictation)
                status = "Transcript copied to clipboard. Paste with Cmd+V."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    private func forgetUnsavedDictation(matching texts: [String]) {
        let texts = Set(texts.filter { !$0.isEmpty })
        if let unsavedLastDictation, texts.contains(unsavedLastDictation.text) {
            self.unsavedLastDictation = nil
        }
        if let lastResult, texts.contains(lastResult.text) {
            self.lastResult = nil
        }
    }

    /// The newest dictation with text: one History couldn't save, or else
    /// the newest saved one.
    private func lastDictation() async -> RecoverableDictation? {
        if let unsavedLastDictation { return unsavedLastDictation }
        for entry in await historyStore.recent(limit: 50) {
            let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
            if !text.isEmpty {
                return RecoverableDictation(text: text, concealed: entry.concealedCopy == true)
            }
        }
        return nil
    }

    /// A dictation whose own copy was concealed is copied concealed again, so
    /// clipboard managers and clipboard history leave it out.
    private func copy(_ dictation: RecoverableDictation) async throws {
        if dictation.concealed {
            try await clipboardService.setConcealedString(dictation.text)
        } else {
            try await clipboardService.setString(dictation.text)
        }
    }

    /// Deletes the dictation. `completion` says whether it was removed, for the window's note.
    func deleteEntry(_ entry: TranscriptEntry, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !isIsolatedPreview else { return }
        // A deleted dictation must not come back through Copy or Paste Last
        // Dictation, including a copy kept because History couldn't save it.
        forgetUnsavedDictation(matching: [entry.cleanText, entry.rawText])
        Task {
            do {
                try await historyStore.delete(entryID: entry.id)
                await refreshHistory()
                status = "Transcript deleted."
                completion?(true)
            } catch {
                status = "Delete failed"
                lastError = error.localizedDescription
                completion?(false)
            }
        }
    }

    /// Re-runs cleanup on a saved dictation. `completion` receives false when the re-run gave
    /// back the words the dictation already had, so nothing was written and a Fix a Word edit
    /// stays.
    func retryCleanup(for entry: TranscriptEntry, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !isIsolatedPreview else { return }
        Task {
            let context = appContext(for: entry.appBundleID)
            let profile = await styleProfileService.resolve(for: context)
            let lexicon = await lexiconService.snapshot(for: context)

            do {
                let result = try await historyStore.rerunCleanup(
                    entryID: entry.id,
                    using: RuleBasedCleanupEngine(),
                    profile: profile,
                    lexicon: lexicon,
                    appContext: context,
                    snippets: snippetService
                )
                if result.changedEntry {
                    await refreshHistory()
                    await refreshUsageAnalytics(forceHistoryReconciliation: true)
                    status = "Cleanup re-run with current rules."
                } else {
                    status = "Cleanup gave the same words."
                }
                lastError = ""
                completion?(result.changedEntry)
            } catch {
                status = "Cleanup re-run failed"
                lastError = error.localizedDescription
                completion?(true)
            }
        }
    }

    /// Puts back the text live dictation produced before "Run cleanup again" replaced it.
    func restoreOriginalCleanup(for entry: TranscriptEntry) {
        guard !isIsolatedPreview else { return }
        Task {
            do {
                try await historyStore.restoreOriginalCleanText(entryID: entry.id)
                await refreshHistory()
                await refreshUsageAnalytics(forceHistoryReconciliation: true)
                status = "Original cleanup restored."
                lastError = ""
            } catch {
                status = "Restoring the original cleanup failed"
                lastError = error.localizedDescription
            }
        }
    }

    /// Replaces `occurrence` (counting whole-word matches from 0) of `original` in a saved
    /// dictation. With `appliesToFuture`, the word is also corrected in every later dictation and
    /// the correction is saved with the other word corrections. A common word throws
    /// `WordFixError.commonWord` until the call is repeated with `confirmingCommonWord`. Insights
    /// is not touched.
    @discardableResult
    func applyWordFix(
        entryID: UUID,
        original: String,
        occurrence: Int,
        replacement: String,
        appliesToFuture: Bool,
        confirmingCommonWord: Bool = false,
        expectingText: String? = nil
    ) async throws -> TranscriptEntry {
        if isIsolatedPreview {
            return try updatePreviewEntry(entryID) {
                try $0.applyingWordFix(
                    original: original,
                    occurrence: occurrence,
                    replacement: replacement,
                    appliesToFuture: appliesToFuture
                )
            }
        }
        let fixed = try await historyStore.applyWordFix(
            entryID: entryID,
            original: original,
            occurrence: occurrence,
            replacement: replacement,
            appliesToFuture: appliesToFuture,
            confirmingCommonWord: confirmingCommonWord,
            lexicon: lexiconService,
            expectingText: expectingText
        )
        await refreshHistory()
        status = "Word fixed."
        if appliesToFuture, let correction = fixed.futureCorrectionForLastFix() {
            await saveWordCorrection(correction)
        }
        return fixed
    }

    /// Reverts the most recent Fix a word in a saved dictation. A word correction it added for
    /// later dictations stays in Word corrections.
    @discardableResult
    func undoLastWordFix(entryID: UUID, expectingFixCount: Int? = nil) async throws -> TranscriptEntry {
        if isIsolatedPreview {
            return try updatePreviewEntry(entryID) { try $0.undoingLastWordFix() }
        }
        let undone = try await historyStore.undoLastWordFix(entryID: entryID, expectingFixCount: expectingFixCount)
        await refreshHistory()
        status = "Fix undone."
        return undone
    }

    /// Copies a saved dictation's text, including its fixes.
    func copyCorrectedText(entryID: UUID) async {
        guard !isIsolatedPreview,
              let entry = recentEntries.first(where: { $0.id == entryID })
        else { return }
        do {
            try await copy(RecoverableDictation(text: entry.cleanText, concealed: entry.concealedCopy == true))
            status = "Corrected text copied."
        } catch {
            status = "Copy failed"
            lastError = error.localizedDescription
        }
    }

    /// The isolated preview fixes its sample entries in memory only.
    private func updatePreviewEntry(
        _ entryID: UUID,
        _ change: (TranscriptEntry) throws -> TranscriptEntry
    ) throws -> TranscriptEntry {
        guard let index = recentEntries.firstIndex(where: { $0.id == entryID }) else {
            throw HistoryStoreError.missingEntry
        }
        let changed = try change(recentEntries[index])
        recentEntries[index] = changed
        return changed
    }

    /// Adds a correction made with Fix a word to the saved word corrections, the way Word
    /// corrections in Settings adds one.
    private func saveWordCorrection(_ correction: LexiconEntry) async {
        var snapshot = preferences
        if snapshot.lexiconEntries.contains(where: {
            $0.term.caseInsensitiveCompare(correction.term) == .orderedSame
                && $0.preferred == correction.preferred && $0.scope == correction.scope
        }) {
            // The same correction is already saved: keep it as configured.
            return
        }
        if let index = snapshot.lexiconEntries.firstIndex(where: {
            $0.term == correction.term && $0.scope == correction.scope
        }) {
            snapshot.lexiconEntries[index] = correction
        } else {
            snapshot.lexiconEntries.append(correction)
        }
        snapshot.normalize()
        preferences = snapshot
        switch await preferencesWriter.enqueue(snapshot).value {
        case .success:
            if !settingsSaveError.isEmpty, lastError == settingsSaveError {
                lastError = ""
            }
            settingsSaveError = ""
        case .failure(let error):
            settingsSaveError = error.localizedDescription
            status = "Word fixed, but the word correction couldn't be saved."
            reportError(error.localizedDescription, fixedIn: .corrections)
        }
    }

    /// The settings a dictation's record names.
    static func recordSettings(for snapshot: AppPreferences) -> DictationRecordSettings {
        let modelPath = snapshot.dictation.modelPath
        let fileName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        return DictationRecordSettings(
            modelName: modelDisplayName(forModelPath: modelPath),
            modelID: modelPath.isEmpty || fileName.isEmpty ? nil : fileName,
            vadEnabled: snapshot.dictation.vadEnabled
        )
    }

    /// The speech model's name for a dictation's record: the catalog title, or the file name of a
    /// custom model.
    static func modelDisplayName(forModelPath modelPath: String) -> String? {
        if let modelID = WhisperCompatibilityService.canonicalModelID(forModelPath: modelPath) {
            return WhisperModelCatalog.title(for: modelID)
        }
        let name = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        return modelPath.isEmpty || name.isEmpty ? nil : name
    }

    /// Discarding a draft that failed to save leaves nothing unsaved to explain.
    func clearSettingsSaveError() {
        if !settingsSaveError.isEmpty, lastError == settingsSaveError {
            lastError = ""
        }
        settingsSaveError = ""
    }

    /// The insertion outcome stands; only the History copy is missing, so the
    /// text is offered for copying instead of being inserted again.
    private func presentHistorySaveFailure(for result: InsertResult) {
        status = "\(status) It couldn't be saved to History."
        let message: String
        switch result.status {
        case .inserted:
            message = "This transcript was inserted but couldn't be saved to History."
        case .copiedOnly where result.pasteAttempted == true:
            message = "This transcript was pasted but couldn't be saved to History."
        case .copiedOnly:
            message = "This transcript was copied but couldn't be saved to History."
        case .failed, .noSpeech:
            message = "This transcript couldn't be inserted or saved to History."
        }
        storageNotice = StorageRecoveryNotice(
            message: message,
            fileURL: nil,
            recoverableText: result.insertedText.isEmpty ? nil : result.insertedText,
            recoverableTextIsConcealed: result.copyIsConcealed
        )
    }

    private func presentStorageNotice(_ notice: StorageRecoveryNotice) {
        storageNotice = notice
    }

    func dismissStorageNotice() {
        storageNotice = nil
    }

    func revealStorageNoticeFile() {
        guard let fileURL = storageNotice?.fileURL else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
        }
    }

    func copyStorageNoticeText() {
        guard !isIsolatedPreview, let notice = storageNotice, let text = notice.recoverableText else { return }
        let dictation = RecoverableDictation(text: text, concealed: notice.recoverableTextIsConcealed == true)
        Task {
            do {
                try await copy(dictation)
                status = "Transcript copied to clipboard. Paste with Cmd+V."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    /// Copies the dictation's words. `completion` says whether the clipboard took them, for the
    /// window's confirmation note.
    func pasteEntry(_ entry: TranscriptEntry, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !isIsolatedPreview else { return }
        Task {
            do {
                let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
                try await copy(RecoverableDictation(text: text, concealed: entry.concealedCopy == true))
                status = "Transcript copied to clipboard. Paste with Cmd+V."
                completion?(true)
            } catch {
                status = "Paste failed"
                lastError = error.localizedDescription
                completion?(false)
            }
        }
    }

    func copyEntry(_ entry: TranscriptEntry) {
        guard !isIsolatedPreview else { return }
        Task {
            do {
                try await copy(RecoverableDictation(text: entry.cleanText, concealed: entry.concealedCopy == true))
                status = "Selected transcript copied."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    func refreshHistory() async {
        guard !isIsolatedPreview else { return }
        recentEntries = await historyStore.recent(limit: 1_000)
    }

    /// Deletes every saved transcript. Insights totals are kept, as they are
    /// when a single transcript is deleted.
    func deleteAllHistory() async {
        guard !isIsolatedPreview else { return }
        unsavedLastDictation = nil
        lastResult = nil
        do {
            try await historyStore.deleteAll()
            status = "History deleted."
        } catch {
            status = "Delete failed"
            lastError = error.localizedDescription
        }
        await refreshHistory()
    }

    func refreshUsageAnalytics(
        now: Date = Date(),
        calendar: Calendar = .current,
        forceHistoryReconciliation: Bool = false
    ) async {
        guard !isIsolatedPreview else { return }
        let request = UsageAnalyticsRefreshRequest(
            now: now,
            calendar: calendar,
            forceHistoryReconciliation: forceHistoryReconciliation
                || !hasPreparedUsageAnalyticsHistory
        )

        if isLoadingUsageAnalytics {
            if var pending = pendingUsageAnalyticsRefresh {
                pending.now = now
                pending.calendar = calendar
                pending.forceHistoryReconciliation = pending.forceHistoryReconciliation
                    || request.forceHistoryReconciliation
                pendingUsageAnalyticsRefresh = pending
            } else {
                pendingUsageAnalyticsRefresh = request
            }
            return
        }

        isLoadingUsageAnalytics = true
        defer { isLoadingUsageAnalytics = false }

        var activeRequest = request
        while true {
            pendingUsageAnalyticsRefresh = nil
            await performUsageAnalyticsRefresh(activeRequest)
            guard let pending = pendingUsageAnalyticsRefresh else { break }
            activeRequest = pending
        }
    }

    private func performUsageAnalyticsRefresh(
        _ request: UsageAnalyticsRefreshRequest
    ) async {
        if request.forceHistoryReconciliation {
            hasPreparedUsageAnalyticsHistory = false
        }
        var preparationWarnings: [String] = []
        do {
            if !hasPreparedUsageAnalyticsHistory {
                let recoveredArchiveURL = try await usageAnalyticsStore
                    .recoverCorruptArchiveIfNeeded()
                if recoveredArchiveURL != nil {
                    preparationWarnings.append(
                        "A damaged usage archive was preserved, and Insights was rebuilt from available saved history."
                    )
                }

                let currentEntries = await historyStore.recent(limit: 1_000)
                let availableLegacyURL = FileManager.default.fileExists(
                    atPath: legacyHistoryURL.path
                ) ? legacyHistoryURL : nil
                if let warning = try await usageAnalyticsStore.reconcileHistory(
                    legacyURL: availableLegacyURL,
                    currentEntries: currentEntries
                ) {
                    preparationWarnings.append(
                        "Older Steno history could not be imported: \(warning)"
                    )
                }

                usageAnalyticsMigrationWarning = preparationWarnings.joined(separator: " ")
                hasPreparedUsageAnalyticsHistory = true
            }

            usageAnalyticsSnapshot = try await usageAnalyticsStore.snapshot(
                now: request.now,
                calendar: request.calendar,
                months: 6
            )
            usageAnalyticsError = usageAnalyticsMigrationWarning
        } catch {
            if !preparationWarnings.isEmpty {
                usageAnalyticsMigrationWarning = preparationWarnings.joined(separator: " ")
            }
            usageAnalyticsError = [usageAnalyticsMigrationWarning, error.localizedDescription]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    private func refreshUsageAnalyticsSnapshot(
        now: Date = Date(),
        calendar: Calendar = .current
    ) async {
        do {
            usageAnalyticsSnapshot = try await usageAnalyticsStore.snapshot(
                now: now,
                calendar: calendar,
                months: 6
            )
            usageAnalyticsError = usageAnalyticsMigrationWarning
        } catch {
            usageAnalyticsError = error.localizedDescription
        }
    }

    private func apply(transition: RecordingTransition) {
        switch transition {
        case .stop(.pressToTalk), .cancel(.pressToTalk):
            // Nothing may keep waiting on a press that has ended.
            pressToTalkConfirmation?.release()
            pressToTalkConfirmation = nil
        default:
            break
        }
        switch transition {
        case .start(let mode):
            DictationLatency.began()
            startSession(mode: mode)
        case .stop(let mode):
            DictationLatency.stopped()
            stopSession(mode: mode)
        case .cancel(let mode):
            cancelSession(mode: mode)
        case .cancelTranscription:
            cancelTranscription()
        case .ignore(let reason):
            status = reason
        }
    }

    private func startSession(mode: RecordingMode) {
        guard !isTearingDown else { return }
        // A synchronous status read: it never delays capture when access is
        // granted, and a denied microphone would record silence or fail with
        // an unclear error.
        guard currentMicrophoneAccess() != .denied else {
            dictationStartedInWindow = false
            refuseSessionWithoutMicrophoneAccess(mode: mode)
            return
        }
        guard !isRuntimeUnloadingForSystemEvent else {
            dictationStartedInWindow = false
            recordingStateMachine.markTranscriptionFailed()
            status = "Runtime is releasing memory. Try again in a moment."
            showWhenPressIsDictation(mode: mode) { [weak self] in
                self?.overlay.show(state: .busy(.modelLoading))
            }
            return
        }
        guard let coordinator else {
            dictationStartedInWindow = false
            status = "Runtime not ready yet."
            recordingStateMachine.markTranscriptionFailed()
            showWhenPressIsDictation(mode: mode) { [weak self] in
                self?.overlay.show(state: .busy(.modelLoading))
            }
            return
        }

        // A new dictation ends the Undo window for a discarded recording. A
        // press that still has to confirm is not yet known to be a dictation:
        // an Option tap or shortcut that is discarded leaves the window alone.
        // The Undo island keeps its dismissal while it may still be needed.
        if let pending = mode == .pressToTalk ? pressToTalkConfirmation : nil {
            if heldDiscard == nil { invalidatePendingOverlayDismissal() }
            Task { @MainActor [weak self] in
                guard await pending.wait(), let self else { return }
                self.endUndoWindow()
                self.invalidatePendingOverlayDismissal()
            }
        } else {
            endUndoWindow()
            invalidatePendingOverlayDismissal()
        }
        // Capture the lightweight app identity at keydown, then start audio.
        // Display enumeration, overlay presentation, and recording UI wait for
        // the coordinator's post-capture acknowledgement.
        let capturedContext = appContextProvider()
        activeSessionContext = capturedContext
        let generation = UUID()
        activeSessionGeneration = generation
        let captureHandoff = CaptureStartHandoff()
        activeCaptureStartHandoff = captureHandoff
        let startOptions = SessionStartOptions(
            controllerGeneration: generation,
            livePreviewEnabled: preferences.dictation.showLiveTranscriptWhileRecording,
            nearbyContextEnabled: preferences.dictation.useNearbyTextForContinuation,
            languageHints: ["en-US"]
        )

        let shouldPauseMedia = (mode == .handsFree && preferences.media.pauseDuringHandsFree)
                            || (mode == .pressToTalk && preferences.media.pauseDuringPressToTalk)
        let pressConfirmation = mode == .pressToTalk ? pressToTalkConfirmation : nil

        let coordinatorStart = CoordinatorStartSignal()
        activeCoordinatorStart = coordinatorStart
        activeStartTask = Task {
            var ownedMediaToken: MediaInterruptionToken?
            var returnedSessionID: SessionID?
            defer {
                captureHandoff.finishPublication()
                coordinatorStart.open()
            }

            do {
                try Task.checkCancellation()
                // A Stop that arrived before this task ran still wants the
                // recording: capture starts and is handed straight to it, as
                // for a Stop that arrives while the start is in flight.
                guard !isTearingDown,
                      activeSessionGeneration == generation || captureHandoff.stopOwnsCapture
                else { throw CancellationError() }

                returnedSessionID = try await coordinator.startPressToTalkWithCaptureStopCapability(
                    appContext: capturedContext,
                    options: startOptions,
                    captureStarted: { [weak self] capability in
                        DictationLatency.mark("capture started")
                        let pendingRequest = captureHandoff.publish(capability)
                        if pendingRequest != nil {
                            capability.markStopRequested()
                        }
                        Task { @MainActor [weak self] in
                            switch pendingRequest {
                            case .stop:
                                break
                            case .cancel:
                                await capability.cancelCapture()
                            case nil:
                                DictationLatency.mark("main actor reached")
                                await pressConfirmation?.wait()
                                DictationLatency.mark("press confirmed")
                                self?.acknowledgeCaptureStarted(
                                    capability: capability,
                                    handoff: captureHandoff,
                                    mode: mode,
                                    generation: generation
                                )
                            }
                        }
                    }
                )
                coordinatorStart.open()

                try Task.checkCancellation()
                guard activeSessionGeneration == generation else { throw CancellationError() }
                guard let returnedSessionID,
                      adoptCaptureStopCapability(
                          sessionID: returnedSessionID,
                          handoff: captureHandoff,
                          generation: generation
                      )
                else {
                    throw CancellationError()
                }

                // Capture always owns the opening words. Optional media detection
                // and pausing runs only after the microphone is already recording.
                // A press that turns out to be a keyboard shortcut never touches media,
                // and neither does one that has already ended.
                if shouldPauseMedia,
                   await pressConfirmation?.wait() ?? true,
                   activeSessionGeneration == generation {
                    ownedMediaToken = await beginMediaInterruption(whileHeld: pressConfirmation)
                }

                try Task.checkCancellation()
                guard activeSessionGeneration == generation else { throw CancellationError() }

                await coordinator.setHandsFreeEnabled(mode == .handsFree)

                try Task.checkCancellation()
                guard activeSessionGeneration == generation else { throw CancellationError() }

                if let sessionID = currentSessionID {
                    if pendingLiveUnavailableSessionIDs.remove(sessionID) != nil {
                        overlay.showLiveTranscriptUnavailable()
                    } else if let snapshot = pendingLiveSnapshots.removeValue(forKey: sessionID) {
                        overlay.updateLiveTranscript(snapshot)
                        publishLiveWords(snapshot)
                    }
                }
                pendingLiveSnapshots.removeAll()
                pendingLiveUnavailableSessionIDs.removeAll()
                activeCaptureStartHandoff = nil
                activeMediaToken = ownedMediaToken
                ownedMediaToken = nil
            } catch is CancellationError {
                if let sessionID = takeFailedStartSession(
                    returnedSessionID: returnedSessionID,
                    handoff: captureHandoff,
                    generation: generation
                ) {
                    await coordinator.cancel(sessionID: sessionID)
                }

                if let ownedMediaToken {
                    await releaseMediaToken(
                        ownedMediaToken,
                        originatingGeneration: generation
                    )
                }

                if !Task.isCancelled,
                   !isTearingDown,
                   activeSessionGeneration == generation
                {
                    await markStartFailed(
                        error: CancellationError(),
                        generation: generation
                    )
                }
            } catch {
                captureHandoff.recordStartFailure(error)
                if let sessionID = takeFailedStartSession(
                    returnedSessionID: returnedSessionID,
                    handoff: captureHandoff,
                    generation: generation
                ) {
                    await coordinator.cancel(sessionID: sessionID)
                }

                if let ownedMediaToken {
                    await releaseMediaToken(
                        ownedMediaToken,
                        originatingGeneration: generation
                    )
                }

                await markStartFailed(error: error, generation: generation)
            }

            if activeSessionGeneration == generation {
                activeStartTask = nil
            }
        }
    }

    private func currentMicrophoneAccess() -> PermissionDiagnostics.AccessStatus {
        if let microphoneAccessProvider { return microphoneAccessProvider() }
        return systemIntegrationsEnabled ? PermissionDiagnostics.microphoneStatus() : .granted
    }

    /// Nothing is recorded. The overlay says why, and the Dictate tab's
    /// Review settings opens Permissions, where access can be turned back on.
    /// An Option press says so only once it proves to be a dictation, so
    /// Option keyboard shortcuts stay silent.
    private func refuseSessionWithoutMicrophoneAccess(mode: RecordingMode) {
        recordingStateMachine.markTranscriptionFailed()
        microphonePermissionStatus = .denied
        let present: @MainActor () -> Void = { [weak self] in
            guard let self, !self.isTearingDown else { return }
            let message = "Microphone access is off. Turn it on for Steno in System Settings > Privacy & Security > Microphone."
            self.status = "Microphone access is off."
            self.lastError = message
            self.showOverlay(.result(.microphoneAccessOff, showsWords: true))
        }
        showWhenPressIsDictation(mode: mode, present)
    }

    /// Presents at once, or for an Option press only once it proves to be a
    /// dictation, so Option keyboard shortcuts stay silent.
    private func showWhenPressIsDictation(mode: RecordingMode, _ present: @escaping @MainActor () -> Void) {
        guard mode == .pressToTalk, let confirmation = pressToTalkConfirmation else {
            present()
            return
        }
        Task { @MainActor in
            if await confirmation.wait() { present() }
        }
    }

    /// Pauses media while the press is still held. A press that ends while
    /// playing media is still being checked cancels the check, so a quick
    /// press never pauses media only to resume it at once.
    private func beginMediaInterruption(
        whileHeld press: PressToTalkConfirmation?
    ) async -> MediaInterruptionToken? {
        guard let press else { return await mediaInterruption.beginInterruption() }
        guard !press.hasEnded else { return nil }
        let mediaInterruption = self.mediaInterruption
        let begin = Task { @MainActor in await mediaInterruption.beginInterruption() }
        press.onEnd { begin.cancel() }
        return await withTaskCancellationHandler {
            await begin.value
        } onCancel: {
            begin.cancel()
        }
    }

    private func acknowledgeCaptureStarted(
        capability: PressToTalkCaptureStopCapability,
        handoff: CaptureStartHandoff,
        mode: RecordingMode,
        generation: UUID
    ) {
        guard !isTearingDown,
              activeSessionGeneration == generation,
              adoptCaptureStopCapability(
                  sessionID: capability.sessionID,
                  handoff: handoff,
                  generation: generation
              ),
              recordingStateMachine.state == (mode == .handsFree
                  ? .recordingHandsFree
                  : .recordingPressToTalk)
        else { return }

        status = mode == .handsFree ? "Hands-free listening..." : "Recording..."
        lastError = ""
        isRecording = true
        // Capture already holds the microphone, so a running test ends now
        // without delaying the start.
        microphone.dictationStarted(using: captureService.lastInputSelection)
        handsFreeOn = mode == .handsFree
        menuBar.updateIcon(isRecording: true, handsFreeOn: mode == .handsFree)
        activeRecordingMode = mode
        if mode == .pressToTalk { watchForMissedOptionRelease(generation: generation) }
        recordingElapsed = 0
        recordingStartedAt = Date()
        recordingTargetAppName = Self.displayName(of: activeSessionContext)
        recordingLimitStopsAt = nil
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isRecording,
                      self.activeSessionGeneration == generation else { return }
                self.recordingElapsed += 1
                self.enforceRecordingDurationLimit()
            }
        }
        overlay.setLiveTranscriptEnabled(preferences.dictation.showLiveTranscriptWhileRecording)
        overlay.pinNextSessionToDisplay(containing: captureStartTargetDisplayPoint())
        defer { DictationLatency.mark("listening shown") }
        overlay.show(state: .listening(handsFree: mode == .handsFree, elapsedSeconds: 0))
    }

    /// A recording that reaches the length limit stops normally, so its audio
    /// is transcribed rather than lost. The warning always comes first, and
    /// the stop at least its full lead after it: a check that runs late, past
    /// the limit, warns and moves the stop back rather than stopping unannounced.
    private func enforceRecordingDurationLimit() {
        guard let recordingStartedAt else { return }
        let elapsed = recordingLimitClock().timeIntervalSince(recordingStartedAt)
        if let recordingLimitStopsAt {
            if elapsed >= recordingLimitStopsAt { stopRecording() }
            return
        }
        guard recordingDurationLimit.action(forElapsed: elapsed) != .none else { return }
        let stopsAt = max(
            TimeInterval(recordingDurationLimit.maximumSeconds),
            elapsed + TimeInterval(recordingDurationLimit.warningLeadSeconds)
        )
        recordingLimitStopsAt = stopsAt
        status = "Recording stops automatically in one minute."
        overlay.showRecordingLimitWarning(limitSeconds: Int(stopsAt.rounded(.up)))
    }

    private func cancelSession(mode: RecordingMode, keepsOverlay: Bool = false) {
        if let recordingStartedAt,
           Date().timeIntervalSince(recordingStartedAt) > undoDiscardMinimumRecording,
           holdDiscardedSession(mode: mode) {
            return
        }
        if !keepsOverlay { invalidatePendingOverlayDismissal() }
        sessionCleanupStartGate.beginCleanup()
        // Settings may rebuild the runtime once the state machine returns to idle.
        // Retain the coordinator that created this session before cleanup suspends.
        let sessionCoordinator = coordinator
        pendingLiveSnapshots.removeAll()
        pendingLiveUnavailableSessionIDs.removeAll()
        let sessionGeneration = activeSessionGeneration
        let pendingStart = activeStartTask
        activeStartTask = nil
        let captureStopCapability = currentCaptureStopCapability
            ?? activeCaptureStartHandoff?.request(.cancel)
        captureStopCapability?.markStopRequested()
        let promptCaptureCancelTask = captureStopCapability.map { capability in
            Task { await capability.cancelCapture() }
        }
        installCaptureTerminationBarrier(
            promptCaptureCancelTask,
            for: sessionGeneration,
            pendingStart: pendingStart
        )
        activeSessionGeneration = nil
        pendingStart?.cancel()
        currentCaptureStopCapability = nil
        activeCaptureStartHandoff = nil
        let mediaToken = activeMediaToken
        activeMediaToken = nil
        let deferredMediaTokens = self.deferredMediaTokens
        self.deferredMediaTokens.removeAll()
        let sessionID = currentSessionID ?? captureStopCapability?.sessionID
        currentSessionID = nil
        activeSessionContext = nil

        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingElapsed = 0
        recordingStartedAt = nil
        isRecording = false
        resetInputLevel()
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        status = mode == .handsFree ? "Hands-free dictation canceled." : "Recording canceled."
        lastError = ""
        if !keepsOverlay { overlay.hide() }

        cleanupTask = Task {
            await promptCaptureCancelTask?.value
            await pendingStart?.value

            if let sessionCoordinator, let sessionID {
                await sessionCoordinator.cancel(sessionID: sessionID)
            }

            // A new press must not wait for this session's resume to verify.
            await startMediaRelease([mediaToken].compactMap { $0 } + deferredMediaTokens)

            guard !Task.isCancelled, !isTearingDown else {
                sessionCleanupStartGate.reset()
                cleanupTask = nil
                return
            }

            let deferredMode = sessionCleanupStartGate.finishCleanup()
            let pastesLast = sessionCleanupStartGate.takeDeferredPasteLast()
            await applyDeferredRebuildIfNeeded()
            if let deferredMode {
                let transition: RecordingTransition = switch deferredMode {
                case .pressToTalk:
                    recordingStateMachine.handleOptionKeyDown()
                case .handsFree:
                    recordingStateMachine.handleHandsFreeToggle()
                }
                apply(transition: transition)
            }
            if pastesLast { pasteLastDictation() }
            cleanupTask = nil
            await applyDeferredMemoryPressureUnloadIfNeeded()
        }
    }

    /// Discards a long recording the way a cancel does, except that the
    /// captured audio is kept for `undoDiscardWindow` so Undo can still
    /// insert it. Capture closes now and media is released as for any
    /// discard. Returns false, before any side effect, when the session is
    /// not fully started, so the caller cancels it as usual.
    private func holdDiscardedSession(mode: RecordingMode) -> Bool {
        guard activeStartTask == nil,
              let sessionCoordinator = coordinator,
              let capability = currentCaptureStopCapability,
              let sessionID = currentSessionID,
              capability.sessionID == sessionID else { return false }

        invalidatePendingOverlayDismissal()
        sessionCleanupStartGate.beginCleanup()
        endUndoWindow()
        pendingLiveSnapshots.removeAll()
        pendingLiveUnavailableSessionIDs.removeAll()
        capability.markStopRequested()
        // Stopping, rather than canceling, closes the microphone and keeps
        // the recorded audio.
        let captureStop = Task<Bool, Never> {
            do {
                try await capability.stopCapture()
                return true
            } catch {
                return false
            }
        }
        activeSessionGeneration = nil
        currentCaptureStopCapability = nil
        activeCaptureStartHandoff = nil
        currentSessionID = nil
        let mediaToken = activeMediaToken
        activeMediaToken = nil
        let deferredMediaTokens = self.deferredMediaTokens
        self.deferredMediaTokens.removeAll()
        let context = activeSessionContext ?? .unknown
        activeSessionContext = nil

        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingElapsed = 0
        recordingStartedAt = nil
        isRecording = false
        resetInputLevel()
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        let undoStatus = mode == .handsFree
            ? "Hands-free dictation discarded. Undo restores it for a few seconds."
            : "Recording discarded. Undo restores it for a few seconds."
        status = undoStatus
        lastError = ""

        let holdID = UUID()
        let windowComponents = undoDiscardWindow.components
        let undoUntil = Date().addingTimeInterval(
            TimeInterval(windowComponents.seconds) + TimeInterval(windowComponents.attoseconds) / 1e18
        )
        heldDiscard = HeldDiscard(
            id: holdID,
            sessionID: sessionID,
            coordinator: sessionCoordinator,
            context: context,
            status: undoStatus
        )
        canUndoDiscard = true
        showOverlay(.discarded(undoUntil: undoUntil))
        heldDiscard?.overlayGeneration = overlayDismissGeneration
        let window = undoDiscardWindow
        let wait = undoDiscardWait
        heldDiscard?.expiryTask = Task { @MainActor [weak self] in
            await wait(window)
            guard !Task.isCancelled, let self, self.heldDiscard?.id == holdID else { return }
            self.endUndoWindow()
        }

        cleanupTask = Task {
            var parked = false
            if await captureStop.value {
                do {
                    try await sessionCoordinator.endPressToTalkCapture(sessionID: sessionID)
                    parked = true
                } catch {}
            }
            if !parked {
                await sessionCoordinator.cancel(sessionID: sessionID)
            }
            // A new press must not wait for this session's resume to verify.
            await startMediaRelease([mediaToken].compactMap { $0 } + deferredMediaTokens)

            guard !Task.isCancelled, !isTearingDown else {
                sessionCleanupStartGate.reset()
                cleanupTask = nil
                return
            }

            if heldDiscard?.id == holdID {
                if parked {
                    heldDiscard?.isReady = true
                } else {
                    // Nothing was kept, so there is nothing to undo.
                    endUndoWindow()
                }
            } else if parked {
                // The window ended while capture was closing.
                await sessionCoordinator.cancel(sessionID: sessionID)
            }

            let deferredMode = sessionCleanupStartGate.finishCleanup()
            let pastesLast = sessionCleanupStartGate.takeDeferredPasteLast()
            await applyDeferredRebuildIfNeeded()
            if let deferredMode {
                let transition: RecordingTransition = switch deferredMode {
                case .pressToTalk:
                    recordingStateMachine.handleOptionKeyDown()
                case .handsFree:
                    recordingStateMachine.handleHandsFreeToggle()
                }
                apply(transition: transition)
            } else if heldDiscard?.id == holdID, heldDiscard?.undoRequested == true {
                undoDiscard()
            }
            if pastesLast { pasteLastDictation() }
            cleanupTask = nil
            await applyDeferredMemoryPressureUnloadIfNeeded()
        }
        return true
    }

    /// Restores the recording discarded last and finishes it as Stop would
    /// have: transcribed, inserted once into the app it was meant for, and
    /// saved in History. If another app is now in front, the text is copied
    /// instead. Media is not touched. Valid only while the overlay shows the
    /// discarded recording.
    func undoDiscard() {
        guard !isIsolatedPreview, !isTearingDown, let held = heldDiscard else { return }
        guard held.isReady else {
            heldDiscard?.undoRequested = true
            return
        }
        guard recordingStateMachine.beginWorkWithoutRecording() else { return }
        held.expiryTask?.cancel()
        heldDiscard = nil
        canUndoDiscard = false

        let copyReason: InsertionCopyReason? =
            appContextProvider().bundleIdentifier == held.context.bundleIdentifier ? nil : .appChanged
        invalidatePendingOverlayDismissal()
        status = "Transcribing..."
        lastError = ""
        overlay.show(state: .transcribing)

        let taskID = UUID()
        completionTaskID = taskID
        let task = Task {
            // The recording can be dropped before Undo reaches it, for
            // example by a runtime unload. Nothing was transcribed, so this
            // is not a transcription failure.
            guard await held.coordinator.holdsCapturedRecording(sessionID: held.sessionID) else {
                if !isTearingDown, completionTaskID == taskID {
                    invalidatePendingOverlayDismissal()
                    overlay.hide()
                    status = "The discarded recording is no longer available."
                    lastError = ""
                    recordingStateMachine.markTranscriptionFailed()
                    await applyDeferredRebuildIfNeeded()
                }
                await finishCompletionTask(id: taskID)
                return
            }
            do {
                let result = try await held.coordinator.completePressToTalk(
                    sessionID: held.sessionID,
                    languageHints: ["en-US"],
                    copyingBecause: copyReason
                )
                // As for Stop: a cancel that came after the text was committed
                // still reports what happened; any other cancel shows nothing.
                let insertionCommitted = result.status == .inserted || result.status == .copiedOnly
                let acceptsCancelledCommit = Task.isCancelled
                    && insertionCommitted
                    && recordingStateMachine.state == .idle
                if Task.isCancelled && !acceptsCancelledCommit {
                    throw CancellationError()
                }
                if !isTearingDown, completionTaskID == taskID,
                   acceptsCancelledCommit || recordingStateMachine.state == .transcribing {
                    await finishDictation(
                        result,
                        context: held.context,
                        taskID: taskID,
                        acceptsCancelledCommit: acceptsCancelledCommit
                    )
                }
            } catch {
                await held.coordinator.cancel(sessionID: held.sessionID)
                if !Task.isCancelled, !isTearingDown, completionTaskID == taskID {
                    await presentTranscriptionFailure(error)
                }
            }
            await finishCompletionTask(id: taskID)
        }
        completionTask = task
        completionTasks[taskID] = task
    }

    /// Ends the Undo window. The held recording is canceled, which deletes
    /// its audio; nothing is inserted. A status line or overlay still
    /// offering Undo is replaced. Work deferred for the window runs after.
    private func endUndoWindow() {
        guard let held = heldDiscard else { return }
        heldDiscard = nil
        canUndoDiscard = false
        held.expiryTask?.cancel()
        if status == held.status {
            status = "Recording discarded."
        }
        if overlayDismissGeneration == held.overlayGeneration {
            invalidatePendingOverlayDismissal()
            overlay.hide()
        }
        Task { @MainActor [weak self] in
            await held.coordinator.cancel(sessionID: held.sessionID)
            await self?.applyDeferredRebuildIfNeeded()
            await self?.applyDeferredMemoryPressureUnloadIfNeeded()
        }
    }

    private func stopSession(mode: RecordingMode) {
        invalidatePendingOverlayDismissal()
        let sessionGeneration = activeSessionGeneration
        let pendingStart = activeStartTask
        activeStartTask = nil
        trackStoppedStart(pendingStart)
        let coordinatorStart = activeCoordinatorStart
        activeCoordinatorStart = nil
        let sessionCoordinator = coordinator
        let captureHandoff = activeCaptureStartHandoff
        let captureStopCapability = currentCaptureStopCapability
            ?? captureHandoff?.request(.stop)
        captureStopCapability?.markStopRequested()
        let promptCaptureStopTask = Task<PromptCaptureStopResult, Never> {
            let capability: PressToTalkCaptureStopCapability?
            if let captureStopCapability {
                capability = captureStopCapability
            } else {
                capability = await captureHandoff?.awaitStopCapability()
            }
            guard let capability else {
                if let startFailure = captureHandoff?.startFailure {
                    return .startFailed(message: startFailure)
                }
                return .unavailable
            }
            capability.markStopRequested()
            do {
                try await capability.stopCapture()
                return .stopped(capability)
            } catch {
                return .failed(capability, message: error.localizedDescription)
            }
        }
        let captureTerminationBarrier = Task<Void, Never> {
            if case .failed(let capability, _) = await promptCaptureStopTask.value {
                if let sessionCoordinator {
                    await sessionCoordinator.cancel(sessionID: capability.sessionID)
                } else {
                    await capability.cancelCapture()
                }
            }
        }
        installCaptureTerminationBarrier(
            captureTerminationBarrier,
            for: sessionGeneration,
            pendingStart: pendingStart
        )
        currentCaptureStopCapability = nil
        activeCaptureStartHandoff = nil
        let sessionID = currentSessionID ?? captureStopCapability?.sessionID
        currentSessionID = nil
        let sessionContext = activeSessionContext
        activeSessionContext = nil
        let mediaToken = activeMediaToken
        activeMediaToken = nil
        let deferredMediaTokens = self.deferredMediaTokens
        self.deferredMediaTokens.removeAll()
        activeSessionGeneration = nil
        pendingLiveSnapshots.removeAll()
        pendingLiveUnavailableSessionIDs.removeAll()

        // Shared cleanup — runs on every path including the guard-return.
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingElapsed = 0
        recordingStartedAt = nil
        isRecording = false
        resetInputLevel()
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil

        let taskID = UUID()
        completionTaskID = taskID
        let task = Task {
            guard !isTearingDown,
                  completionTaskID == taskID
            else {
                // This task already took the session's media tokens, so
                // teardown cannot see them. Release them here once capture has
                // closed, or media Steno paused stays paused after quitting.
                await captureTerminationBarrier.value
                await startMediaRelease([mediaToken].compactMap { $0 } + deferredMediaTokens)
                await finishCompletionTask(id: taskID)
                return
            }

            guard let sessionCoordinator else {
                await captureTerminationBarrier.value
                await pendingStart?.value
                if let mediaToken {
                    await mediaInterruption.endInterruption(token: mediaToken)
                }
                for token in deferredMediaTokens {
                    await mediaInterruption.endInterruption(token: token)
                }
                if !isTearingDown, completionTaskID == taskID {
                    recordingStateMachine.markTranscriptionFailed()
                    status = "No active recording session."
                }
                await finishCompletionTask(id: taskID)
                return
            }

            var releasedMedia = false
            var resolvedSessionID = sessionID
            var captureCancelledAfterStopFailure = false
            do {
                let captureStopResult = await promptCaptureStopTask.value
                await captureTerminationBarrier.value
                switch captureStopResult {
                case .unavailable:
                    break
                case .startFailed(let message):
                    throw CaptureStartFailure(message: message)
                case .stopped(let capability):
                    if resolvedSessionID == nil {
                        resolvedSessionID = capability.sessionID
                    }
                case .failed(let capability, let message):
                    if resolvedSessionID == nil {
                        resolvedSessionID = capability.sessionID
                    }
                    captureCancelledAfterStopFailure = true
                    throw PromptCaptureStopError(message: message)
                }
                guard let activeSessionID = resolvedSessionID else {
                    throw SessionCoordinatorError.sessionNotFound
                }
                status = "Finishing recording..."
                lastError = ""
                overlay.show(state: .transcribing)
                // Capture closes at the key-up boundary above. Stopping never
                // waits for media setup: a Pause still awaiting its
                // acknowledgement stays with the start task, which releases
                // its token as soon as the Pause is answered. If the Pause was
                // accepted, that release resumes exactly the paused app,
                // alongside transcription rather than after it.
                await coordinatorStart?.wait()
                try await sessionCoordinator.endPressToTalkCapture(sessionID: activeSessionID)
                await startMediaRelease([mediaToken].compactMap { $0 } + deferredMediaTokens)
                releasedMedia = true

                try Task.checkCancellation()
                guard !isTearingDown, completionTaskID == taskID else {
                    throw CancellationError()
                }

                status = "Transcribing..."
                let result = try await sessionCoordinator.completePressToTalk(
                    sessionID: activeSessionID,
                    languageHints: ["en-US"],
                    copyingBecause: nil,
                    whenDelivered: { [weak self] delivered in
                        // Queued on the main actor without holding up the History write.
                        Task { @MainActor [weak self] in
                            self?.presentDeliveredResult(delivered, context: sessionContext, taskID: taskID)
                        }
                    }
                )
                let insertionCommitted = result.status == .inserted || result.status == .copiedOnly
                let acceptsCancelledCommit = Task.isCancelled
                    && insertionCommitted
                    && recordingStateMachine.state == .idle
                if Task.isCancelled && !acceptsCancelledCommit {
                    throw CancellationError()
                }
                guard !isTearingDown,
                      completionTaskID == taskID,
                      acceptsCancelledCommit || recordingStateMachine.state == .transcribing
                else {
                    await finishCompletionTask(id: taskID)
                    return
                }

                await finishDictation(
                    result,
                    context: sessionContext,
                    taskID: taskID,
                    acceptsCancelledCommit: acceptsCancelledCommit
                )
            } catch {
                if let resolvedSessionID, !captureCancelledAfterStopFailure {
                    await sessionCoordinator.cancel(sessionID: resolvedSessionID)
                }
                if !releasedMedia {
                    await startMediaRelease([mediaToken].compactMap { $0 } + deferredMediaTokens)
                }

                if !Task.isCancelled,
                   !isTearingDown,
                   completionTaskID == taskID
                {
                    await presentTranscriptionFailure(error)
                }
            }
            await finishCompletionTask(id: taskID)
        }
        completionTask = task
        completionTasks[taskID] = task
    }

    /// Shows a finished dictation's outcome, returns the state machine to
    /// idle and refreshes History and Insights. Used by Stop and by Undo.
    private func finishDictation(
        _ result: InsertResult,
        context: AppContext?,
        taskID: UUID,
        acceptsCancelledCommit: Bool = false
    ) async {
        switch result.status {
        case .inserted:
            lastTranscript = result.insertedText
            status = "Transcript inserted."
            lastError = ""
        case .copiedOnly:
            lastTranscript = result.insertedText
            status = copiedOnlyStatusMessage(for: result)
            if let reason = result.errorMessage {
                reportError(reason, fixedIn: .output)
            } else {
                lastError = ""
            }
        case .failed:
            lastTranscript = result.insertedText
            status = "Transcript ready but insertion failed."
            let reason = result.errorMessage ?? "Insertion chain exhausted."
            reportError(reason, fixedIn: .output)
        case .noSpeech:
            status = "No speech detected."
            lastError = ""
        }
        if result.status != .noSpeech {
            unsavedLastDictation = result.historyWarning == nil
                ? nil
                : RecoverableDictation(text: result.insertedText, concealed: result.copyIsConcealed == true)
        }
        if resultShownForTaskID == taskID {
            resultShownForTaskID = nil
        } else {
            presentResult(result, context: context, countsTowardSuccessNotices: true)
        }

        if let fallbackWarning = fallbackWarningText(from: result.cleanupOutcome) {
            status = "\(status) \(fallbackWarning)"
        }

        if let captureWarning = result.captureWarning {
            presentCaptureWarning(captureWarning, for: result.status)
        }

        if let analyticsWarning = result.usageAnalyticsWarning {
            usageAnalyticsWriteWarning = analyticsWarning
        }

        if result.historyWarning != nil {
            presentHistorySaveFailure(for: result)
        }

        // The dictation is finished once its result is shown. History
        // and Insights refresh afterwards, so a press during the
        // refresh starts a new recording instead of being ignored.
        if !acceptsCancelledCommit, recordingStateMachine.state == .transcribing {
            recordingStateMachine.markTranscriptionCompleted()
        }
        await refreshHistory()
        if result.usageAnalyticsWarning == nil {
            await refreshUsageAnalyticsSnapshot()
        } else {
            // Recover the session as an estimate from transcript history
            // while keeping the exact-metrics warning visible.
            await refreshUsageAnalytics(forceHistoryReconciliation: true)
        }
        guard !isTearingDown, completionTaskID == taskID else { return }
        await applyDeferredRebuildIfNeeded()
    }

    /// Shows the result of a dictation whose text was just inserted or copied, while History
    /// and the usage ledger are still being written. Only the current completion, still
    /// transcribing, shows it here; any other case is shown, as before, when the completion
    /// returns, and once that has happened this does nothing.
    private nonisolated static func loadAudioComponents() async -> Duration {
        await AudioComponentWarmup.run()
    }

    private func presentDeliveredResult(_ result: InsertResult, context: AppContext?, taskID: UUID) {
        guard !isTearingDown,
              completionTaskID == taskID,
              recordingStateMachine.state == .transcribing
        else { return }
        resultShownForTaskID = taskID
        presentResult(result, context: context, countsTowardSuccessNotices: true)
    }

    /// Transcription or recording failed; nothing was inserted.
    private func presentTranscriptionFailure(_ error: Error) async {
        let isRecordingFailure = error is CaptureStartFailure
            || error is PromptCaptureStopError
        if isRecordingFailure {
            status = "Recording failed"
            lastError = error.localizedDescription
            showOverlay(.failure(message: error is CaptureStartFailure ? Self.recordingDidNotStart : Self.recordingDidNotFinish))
        } else {
            status = "Transcription failed"
            reportError(error.localizedDescription, fixedIn: .engine)
            let modelIsMissing = !speechModelExists(preferences.dictation.modelPath)
            showOverlay(.result(modelIsMissing ? .speechModelMissing : .transcriptionFailed, showsWords: true))
        }
        recordingStateMachine.markTranscriptionFailed()
        await applyDeferredRebuildIfNeeded()
    }

    /// What the island says when the microphone stopped and nothing was heard before it did.
    static let microphoneStoppedWithoutSpeech = "Microphone stopped. No speech was heard."
    /// The island has one line, and a system error can be long enough to be cut before it says
    /// what happened. It says these instead; the system's message goes to the window's error.
    static let recordingDidNotStart = "Couldn’t start recording."
    static let recordingDidNotFinish = "Couldn’t finish recording."

    /// Shows the overlay result for a finished insertion under the After
    /// inserting rule. Nothing recognized as speech shows "No speech
    /// detected", or the microphone warning when the recording was cut short.
    private func presentResult(
        _ result: InsertResult,
        context: AppContext?,
        countsTowardSuccessNotices: Bool
    ) {
        DictationLatency.mark("result shown")
        defer { DictationLatency.mark("result presented") }
        lastResult = result.insertedText.isEmpty
            ? nil
            : RecoverableDictation(text: result.insertedText, concealed: result.copyIsConcealed == true)
        guard let overlayResult = DictationResultPresentation.overlayResult(
            for: result,
            appName: Self.displayName(of: context)
        ) else {
            // The island has one line: the full warning, which names the microphone, goes to the
            // window's status and error.
            showOverlay(result.captureWarning == nil ? .noSpeechDetected : .failure(message: Self.microphoneStoppedWithoutSpeech))
            return
        }
        let presentation = DictationResultPresentation.presentation(
            of: overlayResult,
            style: preferences.recording.successNoticeStyle,
            successNoticesShown: preferences.general.successNoticesShown ?? 0
        )
        switch presentation {
        case .overlay(let state):
            showOverlay(state, insertedWords: DictationResultPresentation.overlayWords(for: result, state: state))
            if countsTowardSuccessNotices, DictationResultPresentation.isSuccessNoticeWithWords(state) {
                recordSuccessNoticeShown()
            }
        case .silent(let announcement):
            invalidatePendingOverlayDismissal()
            overlay.hide()
            if let announce {
                announce(announcement)
            } else {
                overlay.announce(result: overlayResult)
            }
        }
    }

    private static func displayName(of context: AppContext?) -> String? {
        guard let context, context.bundleIdentifier != AppContext.unknown.bundleIdentifier,
              !context.appName.isEmpty else { return nil }
        return context.appName
    }

    /// Counts a successful insertion that said where the text went, up to
    /// the limit after which "Only when it matters" shows the brief check.
    private func recordSuccessNoticeShown() {
        let shown = preferences.general.successNoticesShown ?? 0
        guard shown < DictationResultPresentation.wordsNoticeLimit else { return }
        var snapshot = preferences
        snapshot.general.successNoticesShown = shown + 1
        preferences = snapshot
        guard !isIsolatedPreview else { return }
        // Written on top of the last saved settings, in order with every
        // other save. The count only decides when to stop naming the app,
        // so a failed write is not worth reporting.
        _ = preferencesWriter.enqueueSuccessNoticeCount(shown + 1, fallback: snapshot)
    }

    /// Shows `state`. The overlay times it and holds it while the pointer rests on it; the
    /// controller only chooses the state and asks the overlay to finish it afterwards.
    private func showOverlay(_ state: OverlayState, insertedWords: String? = nil) {
        overlay.show(state: state, insertedWords: insertedWords)
        dismissOverlaySoon()
    }

    /// The recording stopped before the user ended it. The overlay already
    /// says so; the status line and error say it too.
    private func presentCaptureWarning(_ warning: String, for resultStatus: InsertionStatus) {
        status = resultStatus == .noSpeech
            ? "Microphone stopped."
            : "\(status) Microphone stopped early."
        lastError = lastError.isEmpty ? warning : "\(lastError) \(warning)"
    }

    /// Forwards the recording's level only while a dictation is recording, so
    /// a level from a capture that is still starting or already ending is
    /// never drawn.
    private func forwardInputLevel(_ level: Float) {
        guard isRecording, activeRecordingMode != nil, !isTearingDown else { return }
        overlay.updateInputLevel(level)
        inputLevels.send(level)
        inputLevelObserver?(level)
    }

    /// Capture ended or was cancelled: the overlay's level drops to 0 at once.
    private func resetInputLevel() {
        // The recording plate's words and destination end with the capture.
        if liveWordsFeed.words != nil { liveWordsFeed.words = nil }
        if recordingTargetAppName != nil { recordingTargetAppName = nil }
        if dictationStartedInWindow { dictationStartedInWindow = false }
        overlay.updateInputLevel(0)
        inputLevels.send(0)
        inputLevelObserver?(0)
    }

    /// The recorder stopped by itself during this session, for example
    /// because the microphone was disconnected. The session stops normally,
    /// so what was recorded is transcribed rather than lost.
    func recorderStoppedEarly(sessionID: SessionID) {
        guard !isIsolatedPreview, !isTearingDown, currentSessionID == sessionID else { return }
        stopRecording()
    }

    private func adoptCaptureStopCapability(
        sessionID: SessionID,
        handoff: CaptureStartHandoff,
        generation: UUID
    ) -> Bool {
        guard activeSessionGeneration == generation else { return false }
        // The start task may already have adopted this session and cleared the
        // handoff (pausing off skips the wait on the press), so the late
        // acknowledgement is matched on the session itself.
        if currentSessionID == sessionID,
           currentCaptureStopCapability?.sessionID == sessionID {
            return true
        }
        guard activeCaptureStartHandoff === handoff,
              currentSessionID == nil,
              currentCaptureStopCapability == nil,
              let capability = handoff.take(sessionID: sessionID) else { return false }
        currentSessionID = sessionID
        currentCaptureStopCapability = capability
        return true
    }

    private func takeFailedStartSession(
        returnedSessionID: SessionID?,
        handoff: CaptureStartHandoff,
        generation: UUID
    ) -> SessionID? {
        guard !handoff.stopOwnsCapture else { return nil }
        guard activeSessionGeneration == generation,
              activeCaptureStartHandoff === handoff else {
            return handoff.take(sessionID: returnedSessionID)?.sessionID
        }

        let capability: PressToTalkCaptureStopCapability?
        if let currentCaptureStopCapability,
           returnedSessionID == nil || currentCaptureStopCapability.sessionID == returnedSessionID {
            capability = currentCaptureStopCapability
        } else {
            capability = handoff.take(sessionID: returnedSessionID)
        }
        currentCaptureStopCapability = nil
        currentSessionID = nil
        activeCaptureStartHandoff = nil
        return capability?.sessionID ?? returnedSessionID
    }

    private func releaseMediaToken(
        _ token: MediaInterruptionToken,
        originatingGeneration: UUID
    ) async {
        // Session termination can race with a media interruption whose token is
        // still owned by the start task. Never release that token until the same
        // generation's canonical capture has physically closed.
        await captureTerminationBarriers[originatingGeneration]?.value
        if let activeSessionGeneration,
           activeSessionGeneration != originatingGeneration {
            deferredMediaTokens.append(token)
            return
        }
        await startMediaRelease([token])
    }

    /// Begins releasing media ownership and returns once the release has
    /// started, without waiting for the resume to be verified. Work that
    /// follows (transcription, insertion, a new capture) therefore cannot
    /// delay the resume, and does not wait for it. The media service still
    /// decides whether to resume, so ownership rules are unchanged.
    private func startMediaRelease(_ tokens: [MediaInterruptionToken]) async {
        guard !tokens.isEmpty else { return }
        let releaseID = UUID()
        let mediaInterruption = self.mediaInterruption
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            let release = Task { @MainActor [weak self] in
                // Resuming the caller only enqueues it; the release below runs
                // first, up to its first real suspension.
                started.resume()
                for token in tokens {
                    await mediaInterruption.endInterruption(token: token)
                }
                self?.mediaReleaseTasks.removeValue(forKey: releaseID)
            }
            mediaReleaseTasks[releaseID] = release
        }
    }

    /// Keeps a start task that Stop has taken from `activeStartTask` reachable until it ends.
    private func trackStoppedStart(_ start: Task<Void, Never>?) {
        guard let start else { return }
        let id = UUID()
        stoppedStartTasks[id] = start
        Task { @MainActor [weak self] in
            await start.value
            self?.stoppedStartTasks.removeValue(forKey: id)
        }
    }

    private func installCaptureTerminationBarrier(
        _ barrier: Task<Void, Never>?,
        for generation: UUID?,
        pendingStart: Task<Void, Never>?
    ) {
        guard let barrier, let generation else { return }
        captureTerminationBarriers[generation] = barrier
        Task { @MainActor [weak self] in
            await pendingStart?.value
            self?.captureTerminationBarriers.removeValue(forKey: generation)
        }
    }

    private func cancelTranscription() {
        invalidatePendingOverlayDismissal()
        let pendingCompletion = completionTask
        pendingCompletion?.cancel()
        status = "Transcription canceled."
        lastError = ""
        overlay.hide()

        Task {
            await pendingCompletion?.value
            guard !isTearingDown else { return }
            await applyDeferredRebuildIfNeeded()
        }
    }

    private func markStartFailed(error: Error, generation: UUID) async {
        guard activeSessionGeneration == generation, !isTearingDown else { return }
        activeStartTask = nil
        activeSessionGeneration = nil
        currentSessionID = nil
        currentCaptureStopCapability = nil
        activeCaptureStartHandoff = nil
        pendingLiveSnapshots.removeAll()
        pendingLiveUnavailableSessionIDs.removeAll()
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingElapsed = 0
        recordingStartedAt = nil
        isRecording = false
        resetInputLevel()
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        recordingStateMachine.markTranscriptionFailed()
        status = "Failed to start"
        lastError = error.localizedDescription
        showOverlay(.failure(message: Self.recordingDidNotStart))
        await applyDeferredRebuildIfNeeded()
        await applyDeferredMemoryPressureUnloadIfNeeded()
        let deferredMediaTokens = self.deferredMediaTokens
        self.deferredMediaTokens.removeAll()
        await startMediaRelease(deferredMediaTokens)
        if !isTearingDown, activeSessionGeneration == nil, !isRecording {
            status = "Failed to start"
        }
    }

    private func receiveLiveTranscript(_ snapshot: LiveTranscriptionSnapshot) {
        guard !isTearingDown,
              isRecording,
              activeSessionGeneration == snapshot.session.controllerGeneration
        else { return }

        if let currentSessionID {
            guard currentSessionID == snapshot.session.sessionID else { return }
            overlay.updateLiveTranscript(snapshot)
            publishLiveWords(snapshot)
        } else if activeStartTask != nil {
            pendingLiveSnapshots[snapshot.session.sessionID] = snapshot
        }
    }

    /// Publishes the words for the recording plate when they differ from the last ones.
    func publishLiveWords(_ snapshot: LiveTranscriptionSnapshot) {
        let words = LiveWords(snapshot)
        if liveWordsFeed.words != words { liveWordsFeed.words = words }
    }

    private func receiveLiveTranscriptUnavailable(sessionID: SessionID) {
        guard !isTearingDown, isRecording, activeSessionGeneration != nil else { return }

        if let currentSessionID {
            guard currentSessionID == sessionID else { return }
            overlay.showLiveTranscriptUnavailable()
        } else if activeStartTask != nil {
            pendingLiveUnavailableSessionIDs.insert(sessionID)
        }
    }

    private func finishCompletionTask(id: UUID) async {
        completionTasks.removeValue(forKey: id)
        if completionTaskID == id {
            completionTask = nil
            completionTaskID = nil
        }
        await applyDeferredMemoryPressureUnloadIfNeeded()
    }

    private func dismissOverlaySoon() {
        overlayDismissTask?.cancel()
        overlayDismissGeneration &+= 1
        let expectedGeneration = overlayDismissGeneration
        let delay = overlayDismissDelay
        let action = overlayDismissAction
        overlayDismissTask = Task { @MainActor [weak self] in
            await delay()
            guard !Task.isCancelled,
                  let self,
                  self.overlayDismissGeneration == expectedGeneration else {
                return
            }
            self.overlayDismissTask = nil
            action()
        }
    }

    private func invalidatePendingOverlayDismissal() {
        overlayDismissGeneration &+= 1
        overlayDismissTask?.cancel()
        overlayDismissTask = nil
    }

    private func applyPreferencesLocally(_ newValue: AppPreferences) {
        let endsOptionRecording = !newValue.hotkeys.optionPressToTalkEnabled
            && recordingStateMachine.state == .recordingPressToTalk
        preferences = newValue
        hotkey.isOptionPressToTalkEnabled = newValue.hotkeys.optionPressToTalkEnabled
        hotkey.globalToggleKeyCode = newValue.hotkeys.handsFreeGlobalKeyCode
        registerPasteLastShortcut(for: newValue)
        applyDockVisibility(showDockIcon: newValue.general.showDockIcon)
        applyOverlayAppearance(for: newValue.appearance)
        overlay.setLiveTranscriptEnabled(newValue.dictation.showLiveTranscriptWhileRecording)
        // With Hold Option to talk off, Option's release is no longer
        // reported, so the recording in progress stops here and is transcribed.
        if endsOptionRecording {
            stopRecording()
        }
    }

    private func rebuildRuntimeOrDefer() async {
        guard !isTearingDown else { return }
        // Cancellation returns the state machine to idle before its async capture
        // cleanup completes, so idle alone is not a safe rebuild boundary.
        // A recording held for Undo belongs to the current runtime.
        if recordingStateMachine.state == .idle,
           !sessionCleanupStartGate.isCleanupInProgress,
           heldDiscard == nil {
            await rebuildRuntime()
        } else {
            pendingRuntimeRebuild = true
            status = "Settings saved. Changes will apply after current transcription."
        }
    }

    private func applyDeferredRebuildIfNeeded(allowDuringSystemEvent: Bool = false) async {
        guard !isTearingDown,
              (!isRuntimeUnloadingForSystemEvent || allowDuringSystemEvent),
              pendingRuntimeRebuild,
              recordingStateMachine.state == .idle,
              !sessionCleanupStartGate.isCleanupInProgress,
              heldDiscard == nil
        else { return }
        pendingRuntimeRebuild = false
        await rebuildRuntime()
    }

    private func rebuildRuntime() async {
        guard !isTearingDown else { return }
        activeRuntimeRebuilds += 1
        defer { finishRuntimeRebuild() }
        runtimeRebuildGeneration &+= 1
        let rebuildGeneration = runtimeRebuildGeneration
        let previousCoordinator = coordinator

        var snapshot = preferences
        snapshot.normalize()
        let engineSettings = TranscriptionEngineSettings(snapshot: snapshot)
        let reusableEngine = runtimeRebuildOverride == nil
            && retainedTranscriptionEngine?.settings == engineSettings
            ? retainedTranscriptionEngine?.engine
            : nil

        if let reusableEngine {
            // Nothing the engine depends on changed. Keep it, with its loaded
            // model, and replace only the coordinator's services. The old
            // coordinator stays in place until the new one is ready, so a
            // press during the rebuild is not dropped.
            applyPreferencesLocally(snapshot)
            coordinator = makeCoordinator(snapshot: snapshot, transcriptionEngine: reusableEngine)
            showRuntimeReady()
            await previousCoordinator?.shutdown()
            return
        }

        coordinator = nil
        await previousCoordinator?.shutdown()
        let previousEngine = retainedTranscriptionEngine?.engine
        retainedTranscriptionEngine = nil
        await previousEngine?.shutdown()
        guard !isTearingDown, runtimeRebuildGeneration == rebuildGeneration else {
            return
        }

        if let runtimeRebuildOverride {
            let replacement = await runtimeRebuildOverride()
            guard !isTearingDown, runtimeRebuildGeneration == rebuildGeneration else {
                await replacement?.shutdown()
                return
            }
            coordinator = replacement
            showRuntimeReady()
            return
        }

        snapshot = preferences
        snapshot.normalize()
        applyPreferencesLocally(snapshot)
        let settings = TranscriptionEngineSettings(snapshot: snapshot)
        let engine = transcriptionEngineFactory(settings)
        retainedTranscriptionEngine = (engine, settings)
        coordinator = makeCoordinator(snapshot: snapshot, transcriptionEngine: engine)
        showRuntimeReady()
    }

    /// Statuses that only say the runtime isn't ready yet, or nothing at all.
    private static let statusesReplacedWhenRuntimeIsReady: Set<String> = [
        "",
        "Idle",
        "Runtime not ready yet.",
        "Runtime is releasing memory. Try again in a moment.",
    ]

    /// Says the runtime is ready, unless the status line holds a more recent,
    /// more specific message, such as "Settings saved." or a dictation's result.
    private func showRuntimeReady() {
        guard Self.statusesReplacedWhenRuntimeIsReady.contains(status) else { return }
        status = "Running local transcription + local cleanup."
    }

    private func makeCoordinator(
        snapshot: AppPreferences,
        transcriptionEngine: any TranscriptionEngine
    ) -> SessionCoordinator {
        let runtimeFactory = DictationRuntimeFactory(
            snapshot: snapshot,
            clipboardService: clipboardService,
            temporaryDirectory: temporaryDirectory
        )
        lexiconService = runtimeFactory.makeLexiconService()
        styleProfileService = runtimeFactory.makeStyleProfileService()
        snippetService = runtimeFactory.makeSnippetService()

        let cleanupEngine: any CleanupEngine = runtimeFactory.makeCleanupEngine()
        let insertion = InsertionService(transports: runtimeFactory.makeInsertionTransports())

        return SessionCoordinator(
            captureService: captureService,
            transcriptionEngine: ControllerOwnedTranscriptionEngine(base: transcriptionEngine),
            cleanupEngine: cleanupEngine,
            insertionService: insertion,
            historyStore: historyStore,
            lexiconService: lexiconService,
            styleProfileService: styleProfileService,
            snippetService: snippetService,
            fallbackCleanupEngine: RuleBasedCleanupEngine(),
            usageRecorder: usageAnalyticsStore,
            recordSettings: Self.recordSettings(for: snapshot),
            liveSnapshotHandler: { [weak self] snapshot in
                await self?.receiveLiveTranscript(snapshot)
            },
            liveUnavailableHandler: { [weak self] sessionID, _ in
                await self?.receiveLiveTranscriptUnavailable(sessionID: sessionID)
            },
            stepObserver: DictationLatency.step
        )
    }

    private func waitForRuntimeRebuilds() async {
        guard activeRuntimeRebuilds > 0 else { return }
        await withCheckedContinuation { continuation in
            runtimeRebuildWaiters.append(continuation)
        }
    }

    private func finishRuntimeRebuild() {
        activeRuntimeRebuilds -= 1
        guard activeRuntimeRebuilds == 0 else { return }
        let waiters = runtimeRebuildWaiters
        runtimeRebuildWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func unloadRetainedRuntimeForSystemEvent() async {
        guard !isTearingDown, !isRuntimeUnloadingForSystemEvent else { return }
        isRuntimeUnloadingForSystemEvent = true
        defer { isRuntimeUnloadingForSystemEvent = false }
        if recordingStateMachine.state != .idle {
            cancelActiveRecording()
        }
        // Unloading drops parked recordings, so a discarded one can no longer
        // be restored. Say so before it happens.
        await cleanupTask?.value
        endUndoWindow()
        await cleanupTask?.value
        let pendingCompletions = Array(completionTasks.values)
        for completion in pendingCompletions {
            await completion.value
        }
        await waitForRuntimeRebuilds()
        await coordinator?.unloadTranscriptionRuntime()
        await applyDeferredRebuildIfNeeded(allowDuringSystemEvent: true)
    }

    private func requestRetainedRuntimeUnloadForMemoryPressure() async {
        guard !isTearingDown else { return }
        pendingMemoryPressureRuntimeUnload = true
        await applyDeferredMemoryPressureUnloadIfNeeded()
    }

    private func applyDeferredMemoryPressureUnloadIfNeeded() async {
        guard pendingMemoryPressureRuntimeUnload,
              !isTearingDown,
              !isRuntimeUnloadingForSystemEvent,
              recordingStateMachine.state == .idle,
              activeStartTask == nil,
              !sessionCleanupStartGate.isCleanupInProgress,
              completionTasks.isEmpty,
              // Memory pressure waits for the Undo window, which is brief.
              heldDiscard == nil
        else {
            return
        }

        pendingMemoryPressureRuntimeUnload = false
        await unloadRetainedRuntimeForSystemEvent()
    }

    /// Registers or unregisters the login item when the user changed the
    /// setting, and returns what macOS reports, so On is saved only after
    /// registration succeeds.
    private func applyLaunchAtLoginChange(requestedPreference: Bool, previousPreference: Bool) -> Bool {
        guard let launchAtLoginService else { return requestedPreference }
        let decision = LaunchAtLoginMutationPolicy.decision(
            systemStatus: launchAtLoginService.status,
            requestedPreference: requestedPreference,
            previousPreference: previousPreference
        )
        guard case .setEnabled(let enabled) = decision else {
            return requestedPreference
        }

        var errorDescription: String?
        do {
            try launchAtLoginService.setEnabled(enabled)
        } catch {
            errorDescription = error.localizedDescription
        }
        let outcome = LaunchAtLoginMutationPolicy.outcome(
            requestedPreference: requestedPreference,
            statusAfter: launchAtLoginService.status,
            errorDescription: errorDescription
        )
        showLaunchAtLoginNotice(outcome.notice, requestedPreference: requestedPreference)
        return outcome.preference
    }

    /// Reads the login item from macOS, which the user can change in System
    /// Settings at any time, and saves the setting when it no longer matches.
    func refreshLaunchAtLoginStatus() async {
        guard !isIsolatedPreview, let launchAtLoginService else { return }
        let status = launchAtLoginService.status
        launchAtLoginNeedsApproval = status == .requiresApproval
        if !launchAtLoginNeedsApproval, launchAtLoginWarning == Self.launchAtLoginApprovalMessage {
            launchAtLoginWarning = ""
        }
        guard preferences.general.launchAtLoginEnabled != status.isRegistered else { return }

        var snapshot = preferences
        snapshot.general.launchAtLoginEnabled = status.isRegistered
        preferences = snapshot
        if case .success = await preferencesWriter.enqueue(snapshot).value {
            savedLaunchAtLoginPreference = status.isRegistered
        }
    }

    func openLoginItemsSettings() {
        guard !isIsolatedPreview else { return }
        launchAtLoginService?.openLoginItemsSettings()
    }

    static let launchAtLoginApprovalMessage =
        "macOS needs your approval before Steno can open at login. Turn on Steno in Login Items."

    private func showLaunchAtLoginNotice(_ notice: LaunchAtLoginNotice?, requestedPreference: Bool) {
        launchAtLoginNeedsApproval = notice == .needsApproval
        switch notice {
        case nil:
            launchAtLoginWarning = ""
        case .needsApproval:
            launchAtLoginWarning = Self.launchAtLoginApprovalMessage
        case .failed(let reason):
            let action = requestedPreference ? "turn on" : "turn off"
            launchAtLoginWarning = "Steno couldn't \(action) launch at login."
                + (reason.map { " \($0)" } ?? " macOS didn't accept the change.")
        }
    }

    private func fallbackWarningText(from outcome: CleanupOutcome?) -> String? {
        guard let outcome, outcome.source == .localFallback else {
            return nil
        }
        return outcome.warning ?? "Primary cleanup unavailable, used local fallback."
    }

    private func validateWhisperPaths() {
        if let warning = Self.startupPathWarning(
            cliExists: FileManager.default.fileExists(atPath: preferences.dictation.whisperCLIPath),
            modelExists: FileManager.default.fileExists(atPath: preferences.dictation.modelPath)
        ) {
            status = warning
        }
    }

    static func startupPathWarning(cliExists: Bool, modelExists: Bool) -> String? {
        let location = "Check Settings \u{2192} Speech Model."
        switch (cliExists, modelExists) {
        case (true, true): return nil
        case (false, false): return "The transcription tool and speech model weren't found. \(location)"
        case (false, true): return "The transcription tool wasn't found. \(location)"
        case (true, false): return "The speech model file wasn't found. \(location)"
        }
    }

    private func applyDockVisibility(showDockIcon: Bool) {
        guard systemIntegrationsEnabled else { return }
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    private func appContext(for bundleID: String) -> AppContext {
        AppContext.classified(bundleIdentifier: bundleID, appName: StenoDesign.appDisplayName(for: bundleID))
    }

    private func copiedOnlyStatusMessage(for result: InsertResult) -> String {
        if result.pasteAttempted == true {
            // Steno restores the previous clipboard shortly after pasting, so
            // this must not suggest pasting again.
            return "Transcript pasted."
        }
        switch result.copyReason {
        case .secureField:
            return "Secure text field—final text copied instead of typed."
        case .fieldChanged:
            return "Target changed—final text copied."
        case .appChanged:
            return "Another app was in front—final text copied."
        case .appNotResponding:
            return "The app didn't respond in time—final text copied."
        case .accessibilityOff:
            return "Transcript copied. Auto-paste unavailable until Accessibility is re-granted for this Steno build."
        case .clipboardChanged:
            // Another app's text is on the clipboard now, so Cmd+V would paste that.
            return "Not pasted: the clipboard changed first. The transcript is in History."
        case .noTextField, .other, nil:
            return "Transcript copied to clipboard. Paste with Cmd+V."
        }
    }

    private func applyOverlayAppearance(for appearance: AppPreferences.Appearance) {
        let theme = StenoDesign.theme(for: appearance)
        let panelAppearance: NSAppearance?
        switch appearance.mode {
        case .system: panelAppearance = nil
        case .light: panelAppearance = NSAppearance(named: .aqua)
        case .dark: panelAppearance = NSAppearance(named: .darkAqua)
        }
        overlay.updateAppearance(panelAppearance)
        overlay.updateAccentColor(NSColor(theme.accent), glowColor: NSColor(theme.accentGlow))
    }

    /// Selects a display from content-free frontmost-window geometry captured at
    /// session start. Window names, text, and pixels are never requested.
    private func captureStartTargetDisplayPoint() -> CGPoint {
        if let targetDisplayPointProvider { return targetDisplayPointProvider() }
        let fallback = NSEvent.mouseLocation
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let rawWindows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[CFString: Any]]
        else { return fallback }

        let windows = rawWindows.compactMap { info -> CaptureTargetWindowGeometry? in
            guard let owner = info[kCGWindowOwnerPID] as? NSNumber,
                  let layer = info[kCGWindowLayer] as? NSNumber,
                  let rawBounds = info[kCGWindowBounds] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
            else { return nil }
            return CaptureTargetWindowGeometry(
                ownerProcessID: pid_t(owner.int32Value),
                layer: layer.intValue,
                quartzBounds: bounds
            )
        }

        let screens = NSScreen.screens.compactMap { screen -> CaptureTargetScreenGeometry? in
            let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else {
                return nil
            }
            return CaptureTargetScreenGeometry(
                appKitFrame: screen.frame,
                quartzFrame: CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            )
        }

        return CaptureTargetDisplaySelector.point(
            processID: processID,
            windows: windows,
            screens: screens,
            fallback: fallback
        )
    }
}

struct CaptureTargetWindowGeometry: Sendable, Equatable {
    let ownerProcessID: pid_t
    let layer: Int
    let quartzBounds: CGRect
}

struct CaptureTargetScreenGeometry: Sendable, Equatable {
    let appKitFrame: CGRect
    let quartzFrame: CGRect
}

enum CaptureTargetDisplaySelector {
    static func point(
        processID: pid_t,
        windows: [CaptureTargetWindowGeometry],
        screens: [CaptureTargetScreenGeometry],
        fallback: CGPoint
    ) -> CGPoint {
        guard let targetWindow = windows.first(where: {
            $0.ownerProcessID == processID
                && $0.layer == 0
                && !$0.quartzBounds.isEmpty
                && !$0.quartzBounds.isNull
        }) else { return fallback }

        let targetScreen = screens.max { lhs, rhs in
            lhs.quartzFrame.intersection(targetWindow.quartzBounds).area
                < rhs.quartzFrame.intersection(targetWindow.quartzBounds).area
        }
        guard let targetScreen,
              targetScreen.quartzFrame.intersection(targetWindow.quartzBounds).area > 0
        else { return fallback }

        return CGPoint(x: targetScreen.appKitFrame.midX, y: targetScreen.appKitFrame.midY)
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

/// Settles once per Option press: confirmed as a dictation, or released
/// because the press ended or was discarded first.
@MainActor
private final class PressToTalkConfirmation {
    private(set) var isConfirmed = false
    /// The press is over: the key was released, the press was discarded, or
    /// its session was canceled.
    private(set) var hasEnded = false
    private var isSettled = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var endHandlers: [() -> Void] = []

    func confirm() {
        settle(confirmed: true)
    }

    /// Ends the press. An unconfirmed press settles as not a dictation.
    func release() {
        settle(confirmed: false)
        guard !hasEnded else { return }
        hasEnded = true
        let handlers = endHandlers
        endHandlers.removeAll()
        handlers.forEach { $0() }
    }

    /// Runs `handler` when the press ends, or at once if it already has.
    func onEnd(_ handler: @escaping () -> Void) {
        if hasEnded {
            handler()
        } else {
            endHandlers.append(handler)
        }
    }

    /// Returns whether the press was confirmed.
    @discardableResult
    func wait() async -> Bool {
        if isSettled { return isConfirmed }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isSettled {
                    continuation.resume(returning: isConfirmed)
                } else {
                    waiters.append(continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.release() }
        }
    }

    private func settle(confirmed: Bool) {
        guard !isSettled else { return }
        isSettled = true
        isConfirmed = confirmed
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: confirmed)
        }
    }
}

struct SessionCleanupStartGate {
    private(set) var isCleanupInProgress = false
    private(set) var deferredMode: RecordingMode?
    private(set) var pastesLastAfterCleanup = false

    mutating func beginCleanup() {
        isCleanupInProgress = true
        deferredMode = nil
        pastesLastAfterCleanup = false
    }

    mutating func deferPasteLast() -> Bool {
        guard isCleanupInProgress else { return false }
        pastesLastAfterCleanup = true
        return true
    }

    mutating func takeDeferredPasteLast() -> Bool {
        defer { pastesLastAfterCleanup = false }
        return pastesLastAfterCleanup
    }

    mutating func deferPressToTalkStart() -> Bool {
        guard isCleanupInProgress else { return false }
        deferredMode = .pressToTalk
        return true
    }

    mutating func cancelDeferredPressToTalkStart() -> Bool {
        guard isCleanupInProgress, deferredMode == .pressToTalk else { return false }
        deferredMode = nil
        return true
    }

    mutating func deferHandsFreeToggle() -> Bool {
        guard isCleanupInProgress else { return false }
        deferredMode = deferredMode == .handsFree ? nil : .handsFree
        return true
    }

    mutating func finishCleanup() -> RecordingMode? {
        let mode = deferredMode
        deferredMode = nil
        isCleanupInProgress = false
        return mode
    }

    mutating func reset() {
        deferredMode = nil
        isCleanupInProgress = false
        pastesLastAfterCleanup = false
    }
}

private struct DictationRuntimeFactory {
    let snapshot: AppPreferences
    let clipboardService: any ClipboardService
    /// Where the backup transcription tool writes its transcript files.
    let temporaryDirectory: URL

    func makeLexiconService() -> PersonalLexiconService {
        PersonalLexiconService(entries: snapshot.lexiconEntries)
    }

    func makeStyleProfileService() -> StyleProfileService {
        StyleProfileService(
            globalProfile: snapshot.globalStyleProfile,
            appProfiles: snapshot.appStyleProfiles
        )
    }

    func makeSnippetService() -> SnippetService {
        SnippetService(snippets: snapshot.snippets)
    }

    /// Separate engines for the Speech model setup check. The main engine's
    /// fallback refuses, so a helper failure is reported rather than hidden.
    /// They never share the controller's engine.
    func makeSetupCheckEngines() -> (main: (any TranscriptionEngine)?, tool: any TranscriptionEngine) {
        let settings = TranscriptionEngineSettings(snapshot: snapshot)
        let main = settings.retainedHelperPath != nil
            ? Self.makeTranscriptionEngine(
                settings: settings,
                retainedFallback: WhisperSetupSelfTest.RefusingFallbackEngine(),
                outputDirectory: temporaryDirectory
            )
            : nil
        return (main, Self.makeTranscriptionEngine(
            settings: settings,
            includeRetained: false,
            outputDirectory: temporaryDirectory
        ))
    }

    static func makeTranscriptionEngine(
        settings: TranscriptionEngineSettings,
        retainedFallback: (any TranscriptionEngine)? = nil,
        includeRetained: Bool = true,
        outputDirectory: URL
    ) -> any TranscriptionEngine {
        let modelPath = URL(fileURLWithPath: settings.modelPath)
        let extraArgs = WhisperRuntimeConfiguration.additionalArguments(
            threadCount: settings.threadCount,
            vadEnabled: settings.vadEnabled,
            vadModelPath: settings.vadModelPath
        )

        let fallbackCLIPath = settings.retainedCLIPath ?? settings.whisperCLIPath
        let fallback = WhisperCLITranscriptionEngine(
            config: .init(
                whisperCLIPath: URL(fileURLWithPath: fallbackCLIPath),
                modelPath: modelPath,
                additionalArguments: extraArgs,
                outputDirectory: outputDirectory
            )
        )

        guard includeRetained, let helperPath = settings.retainedHelperPath else {
            return fallback
        }

        let vadModelPath: URL? = if settings.vadEnabled, settings.vadModelExists {
            URL(fileURLWithPath: settings.vadModelPath)
        } else {
            nil
        }

        return RetainedWhisperTranscriptionEngine(
            configuration: RetainedWhisperTranscriptionConfiguration(
                helperExecutableURL: URL(fileURLWithPath: helperPath),
                modelPath: modelPath,
                threadCount: settings.threadCount,
                vadModelPath: vadModelPath,
                suppressNonSpeechTokens: true,
                suppressRegex: nil,
                beamSize: 5,
                bestOf: 5
            ),
            fallback: retainedFallback ?? fallback,
            stepObserver: DictationLatency.step
        )
    }

    func makeCleanupEngine() -> any CleanupEngine {
        RuleBasedCleanupEngine()
    }

    func makeInsertionTransports() -> [any InsertionTransport] {
        MacInsertionTransportFactory.makeTransports(
            orderedMethods: snapshot.insertion.orderedMethods,
            clipboard: clipboardService
        )
    }
}

/// Every input that decides how the transcription engine is built. The
/// engine, and the model it keeps loaded, is replaced only when one changes.
struct TranscriptionEngineSettings: Equatable {
    var modelPath: String
    var threadCount: Int
    var vadEnabled: Bool
    var vadModelPath: String
    var vadModelExists: Bool
    var whisperCLIPath: String
    var retainedHelperPath: String?
    var retainedCLIPath: String?
    /// The model files on disk when the settings were read. A file replaced at
    /// the same path, such as a model downloaded again, changes these, so the
    /// engine that loaded the old file is replaced.
    var modelFileIdentity: StorageFilePreservation.Signature?
    var vadModelFileIdentity: StorageFilePreservation.Signature?

    init(
        modelPath: String,
        threadCount: Int,
        vadEnabled: Bool,
        vadModelPath: String,
        vadModelExists: Bool,
        whisperCLIPath: String,
        retainedHelperPath: String?,
        retainedCLIPath: String?,
        modelFileIdentity: StorageFilePreservation.Signature? = nil,
        vadModelFileIdentity: StorageFilePreservation.Signature? = nil
    ) {
        self.modelPath = modelPath
        self.threadCount = threadCount
        self.vadEnabled = vadEnabled
        self.vadModelPath = vadModelPath
        self.vadModelExists = vadModelExists
        self.whisperCLIPath = whisperCLIPath
        self.retainedHelperPath = retainedHelperPath
        self.retainedCLIPath = retainedCLIPath
        self.modelFileIdentity = modelFileIdentity
        self.vadModelFileIdentity = vadModelFileIdentity
    }

    init(snapshot: AppPreferences) {
        let dictation = snapshot.dictation
        let retainedPaths = WhisperRuntimeConfiguration.retainedRuntimePaths(
            relativeTo: dictation.whisperCLIPath
        )
        self.init(
            modelPath: dictation.modelPath,
            threadCount: dictation.threadCount,
            vadEnabled: dictation.vadEnabled,
            vadModelPath: dictation.vadModelPath,
            vadModelExists: FileManager.default.fileExists(atPath: dictation.vadModelPath),
            whisperCLIPath: dictation.whisperCLIPath,
            retainedHelperPath: retainedPaths?.helperPath,
            retainedCLIPath: retainedPaths?.whisperCLIPath,
            modelFileIdentity: Self.fileIdentity(atPath: dictation.modelPath),
            vadModelFileIdentity: Self.fileIdentity(atPath: dictation.vadModelPath)
        )
    }

    private static func fileIdentity(atPath path: String) -> StorageFilePreservation.Signature? {
        guard !path.isEmpty else { return nil }
        return StorageFilePreservation.signature(of: URL(fileURLWithPath: path))
    }
}

/// Lets coordinators use the controller's engine without ending it when a
/// coordinator is replaced. The controller shuts the engine down itself.
private struct ControllerOwnedTranscriptionEngine: LiveTranscriptionEngine {
    let base: any TranscriptionEngine

    private var live: (any LiveTranscriptionEngine)? {
        base as? any LiveTranscriptionEngine
    }

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        try await base.transcribe(audioURL: audioURL, request: request)
    }

    func shutdown() async {}

    func unloadRetainedResources() async {
        await base.unloadRetainedResources()
    }

    func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        guard let live else { throw RetainedWhisperRuntimeError.unsupportedConfiguration }
        return try await live.startLiveTranscription(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            request: request
        )
    }

    func appendLiveAudio(_ frame: LivePCMFrame, session: LiveTranscriptionSession) async throws {
        guard let live else { throw RetainedWhisperRuntimeError.unsupportedConfiguration }
        try await live.appendLiveAudio(frame, session: session)
    }

    func requestLiveHypothesis(
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        guard let live else { throw RetainedWhisperRuntimeError.unsupportedConfiguration }
        return try await live.requestLiveHypothesis(
            session: session,
            revision: revision,
            decodedAudioWatermark: decodedAudioWatermark
        )
    }

    func finishLiveTranscription(
        session: LiveTranscriptionSession,
        canonicalAudioURL: URL,
        streamSummary: LivePCMStreamSummary,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        guard let live else { throw RetainedWhisperRuntimeError.unsupportedConfiguration }
        return try await live.finishLiveTranscription(
            session: session,
            canonicalAudioURL: canonicalAudioURL,
            streamSummary: streamSummary,
            request: request
        )
    }

    func cancelLiveTranscription(session: LiveTranscriptionSession) async {
        await live?.cancelLiveTranscription(session: session)
    }
}

/// Lets the microphone test ask whether a dictation is active without the
/// test holding the controller.
@MainActor
private final class DictationActivityProbe {
    var isActive: @MainActor () -> Bool = { false }
}

/// The live words of the recording in progress. The recording plate observes this object rather
/// than the controller, so the words changing a few times a second redraws only the plate.
@MainActor
final class LiveWordsFeed: ObservableObject {
    @Published fileprivate(set) var words: DictationController.LiveWords?
}
