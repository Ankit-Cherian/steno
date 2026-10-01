import AppKit
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

    func unloadTranscriptionRuntime() async {}
    func shutdown() async {}
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

    @Published var status: String = "Idle"
    @Published var lastTranscript: String = ""
    @Published var lastError: String = ""
    @Published var isRecording: Bool = false
    @Published var handsFreeOn: Bool = false
    @Published var recentEntries: [TranscriptEntry] = []
    @Published var hotkeyRegistrationMessage: String = ""
    @Published var launchAtLoginWarning: String = ""
    @Published var preferences: AppPreferences = .default
    @Published var microphonePermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var accessibilityPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var inputMonitoringPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var recordingElapsed: TimeInterval = 0
    @Published var recordingStartedAt: Date?
    @Published var hasBootstrapped = false
    @Published var activeModelDownloadID: WhisperModelID?
    @Published var modelDownloadMessage: String = ""
    @Published var usageAnalyticsSnapshot: UsageAnalyticsSnapshot = .empty
    @Published var usageAnalyticsError: String = ""
    @Published var usageAnalyticsWriteWarning: String = ""
    @Published var isLoadingUsageAnalytics = false
    /// A data file couldn't be read in full, or a transcript couldn't be saved.
    @Published var storageNotice: StorageRecoveryNotice?
    /// Why the last Settings save failed; empty after a successful save.
    @Published var settingsSaveError: String = ""

    private let captureService = MacAudioCaptureService()
    private let clipboardService: any ClipboardService
    private let historyStore: HistoryStore
    private let usageAnalyticsStore: any UsageAnalyticsStoreServicing
    private let legacyHistoryURL: URL
    private let hotkey: any HotkeyService
    private let overlay: WaveformOverlayPresenter
    private let mediaInterruption: MediaInterruptionService
    private let preferencesStore: AppPreferencesStore
    private let launchAtLoginService: LaunchAtLoginService
    private let runtimeRebuildOverride: (@MainActor () async -> (any DictationSessionCoordinating)?)?
    private let overlayDismissDelay: @Sendable () async -> Void
    private let overlayDismissAction: @MainActor @Sendable () -> Void
    private let modelDownloadService = WhisperModelDownloadService()
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
    /// Replaces the microphone status read at the start of a session. Tests
    /// set it; the app reads the status from macOS.
    var microphoneAccessProvider: (@MainActor () -> PermissionDiagnostics.AccessStatus)?
    private var hasWarnedAboutRecordingLimit = false
    private var currentSessionID: SessionID?
    private var currentCaptureStopCapability: PressToTalkCaptureStopCapability?
    private var activeCaptureStartHandoff: CaptureStartHandoff?
    private var activeRecordingMode: RecordingMode?
    private var activeMediaToken: MediaInterruptionToken?
    private var deferredMediaTokens: [MediaInterruptionToken] = []
    private var mediaReleaseTasks: [UUID: Task<Void, Never>] = [:]
    private var captureTerminationBarriers: [UUID: Task<Void, Never>] = [:]
    private var activeStartTask: Task<Void, Never>?
    private var activeSessionGeneration: UUID?
    private var pendingLiveSnapshots: [SessionID: LiveTranscriptionSnapshot] = [:]
    private var pendingLiveUnavailableSessionIDs: Set<SessionID> = []
    private var sessionCleanupStartGate = SessionCleanupStartGate()
    private var cleanupTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var completionTaskID: UUID?
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
    private var launchAtLoginServicePreference = AppPreferences.default.general.launchAtLoginEnabled
    private let menuBar = MenuBarController()
    private var recordingTimer: Timer?
    private var terminationTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var workspaceSleepObserver: NSObjectProtocol?
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
        preferencesStore: AppPreferencesStore = AppPreferencesStore(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        coordinator: (any DictationSessionCoordinating)? = nil,
        runtimeRebuildOverride: (@MainActor () async -> (any DictationSessionCoordinating)?)? = nil,
        overlayDismissDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(2))
        },
        overlayDismissAction: (@MainActor @Sendable () -> Void)? = nil,
        historyStore: HistoryStore? = nil,
        usageAnalyticsStore: (any UsageAnalyticsStoreServicing)? = nil,
        legacyHistoryURL: URL? = nil,
        systemIntegrationsEnabled: Bool = true,
        isIsolatedPreview: Bool = false,
        appContextProvider: @escaping @MainActor () -> AppContext = { AppContextProvider.current() },
        targetDisplayPointProvider: (@MainActor () -> CGPoint)? = nil,
        workspaceNotificationCenter: NotificationCenter? = nil
    ) {
        self.isIsolatedPreview = isIsolatedPreview
        self.systemIntegrationsEnabled = systemIntegrationsEnabled
        self.appContextProvider = appContextProvider
        self.targetDisplayPointProvider = targetDisplayPointProvider
        self.workspaceNotificationCenter = workspaceNotificationCenter
            ?? (systemIntegrationsEnabled && !isIsolatedPreview ? NSWorkspace.shared.notificationCenter : nil)
        self.hotkey = hotkey
        self.clipboardService = clipboardService
        self.overlay = overlay
        self.mediaInterruption = mediaInterruption
        self.preferencesStore = preferencesStore
        self.launchAtLoginService = launchAtLoginService
        self.coordinator = coordinator
        self.runtimeRebuildOverride = runtimeRebuildOverride
        self.overlayDismissDelay = overlayDismissDelay
        self.overlayDismissAction = overlayDismissAction ?? { [weak overlay] in
            overlay?.hide()
        }
        self.historyStore = historyStore ?? HistoryStore(clipboardService: clipboardService)
        self.usageAnalyticsStore = usageAnalyticsStore ?? UsageAnalyticsStore()
        self.legacyHistoryURL = legacyHistoryURL ?? Self.defaultLegacyHistoryURL()
        self.lexiconService = PersonalLexiconService(entries: AppPreferences.default.lexiconEntries)
        self.styleProfileService = StyleProfileService(
            globalProfile: AppPreferences.default.globalStyleProfile,
            appProfiles: AppPreferences.default.appStyleProfiles
        )
        self.snippetService = SnippetService(snippets: AppPreferences.default.snippets)
        self.overlay.setStopAction { [weak self] in
            self?.stopRecording()
        }
        self.overlay.setCancelAction { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelActiveRecording()
            }
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
        // The hands-free key registers once saved preferences load, so a
        // saved Disabled never registers the built-in default at launch.
        hotkey.globalToggleKeyCode = nil
        if systemIntegrationsEnabled && !isIsolatedPreview {
            hotkey.start()
            menuBar.setup(controller: self)
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
        invalidatePendingOverlayDismissal()
        pendingMemoryPressureRuntimeUnload = false
        runtimeRebuildGeneration &+= 1
        terminationTask?.cancel()
        terminationTask = nil
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
        let coordinator = self.coordinator
        self.coordinator = nil
        recordingTimer?.invalidate()
        recordingTimer = nil

        shutdownTask = Task {
            await promptCaptureCancelTask?.value
            await pendingCleanup?.value
            await pendingStart?.value
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

    func replaceCoordinatorForLifecycleTesting(
        _ replacement: any DictationSessionCoordinating
    ) {
        coordinator = replacement
    }

    func unloadRuntimeForLifecycleTesting() async {
        await unloadRetainedRuntimeForSystemEvent()
    }

    func unloadRuntimeForMemoryPressureTesting() async {
        await requestRetainedRuntimeUnloadForMemoryPressure()
    }
    #endif

    var whisperModelOptions: [WhisperModelOption] {
        if isIsolatedPreview {
            return WhisperModelLibrary.managedModelIDs.map {
                WhisperModelOption(modelID: $0, source: $0 == .smallEn ? .bundled : nil,
                    path: nil, isInstalled: $0 == .smallEn, isActive: $0 == .smallEn,
                    isRecommended: $0 == .smallEn)
            }
        }
        return WhisperModelLibrary.installedOptions(
            preferences: preferences,
            compatibilityService: compatibilityService
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
            // A crash or force quit leaves the recording in progress behind.
            // It holds the user's speech, and no session can own it at launch.
            Task.detached(priority: .utility) {
                MacAudioCaptureService.removeStaleRecordings()
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

        applyPreferencesLocally(loaded)
        launchAtLoginServicePreference = loaded.general.launchAtLoginEnabled
        launchAtLoginWarning = ""
        refreshPermissionStatuses()
        validateWhisperPaths()
        await rebuildRuntime()
        await refreshHistory()
        await refreshUsageAnalytics()
        overlay.prepareWindow()
        hasBootstrapped = true
    }

    func savePreferences() {
        guard !isIsolatedPreview else { status = "Preview settings updated."; return }
        var snapshot = preferences
        snapshot.normalize()
        applyPreferencesLocally(snapshot)

        Task {
            guard await persistSettings(snapshot) else { return }
            await rebuildRuntimeOrDefer()
        }
    }

    /// Applies a Settings draft and saves it. The returned task reports whether
    /// the save succeeded; on failure the previous settings are restored so the
    /// draft stays unsaved and can be saved again or discarded.
    @discardableResult
    func applySettingsDraft(preferences draft: AppPreferences) -> Task<Bool, Never> {
        guard !isIsolatedPreview else {
            preferences = draft
            status = "Preview settings updated."
            return Task { true }
        }
        let previous = preferences
        var snapshot = draft
        snapshot.normalize()
        applyPreferencesLocally(snapshot)

        return Task {
            guard await persistSettings(snapshot) else {
                if preferences == snapshot {
                    applyPreferencesLocally(previous)
                }
                return false
            }
            await rebuildRuntimeOrDefer()
            return true
        }
    }

    /// Writes settings and reports the real outcome; never claims a save that failed.
    private func persistSettings(_ snapshot: AppPreferences) async -> Bool {
        switch await preferencesStore.save(snapshot) {
        case .success:
            if !settingsSaveError.isEmpty, lastError == settingsSaveError {
                lastError = ""
            }
            settingsSaveError = ""
            applyLaunchAtLoginPreference(
                requestedPreference: snapshot.general.launchAtLoginEnabled,
                userInitiated: true
            )
            status = "Settings saved."
            return true
        case .failure(let error):
            settingsSaveError = error.localizedDescription
            status = "Settings couldn't be saved."
            lastError = error.localizedDescription
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

        Task {
            await preferencesStore.save(snapshot)
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

        var snapshot = preferences
        snapshot.dictation.updateModelPath(path)
        snapshot.normalize()
        preferences = snapshot

        Task {
            await preferencesStore.save(snapshot)
            await MainActor.run {
                modelDownloadMessage = "Using \(WhisperModelCatalog.title(for: modelID))."
                status = "Using \(WhisperModelCatalog.title(for: modelID))."
            }
            await rebuildRuntimeOrDefer()
        }
    }

    func downloadWhisperModel(_ modelID: WhisperModelID) {
        guard !isIsolatedPreview else { return }
        guard activeModelDownloadID == nil else { return }

        activeModelDownloadID = modelID
        modelDownloadMessage = "Downloading \(WhisperModelCatalog.title(for: modelID))..."

        let bundledVADPath = BundledWhisperRuntime.resolvedPaths()?.vadModelPath
        let currentVADPath = FileManager.default.fileExists(atPath: preferences.dictation.vadModelPath)
            ? preferences.dictation.vadModelPath
            : nil
        let preferredVADSource = bundledVADPath ?? currentVADPath

        Task {
            do {
                let installed = try await modelDownloadService.install(
                    modelID: modelID,
                    vadSourcePath: preferredVADSource
                )

                var snapshot = preferences
                snapshot.dictation.updateModelPath(installed.modelPath)
                if let installedVADPath = installed.vadModelPath {
                    snapshot.dictation.vadModelPath = installedVADPath
                }
                snapshot.normalize()

                await preferencesStore.save(snapshot)

                await MainActor.run {
                    preferences = snapshot
                    activeModelDownloadID = nil
                    modelDownloadMessage = "Downloaded \(WhisperModelCatalog.title(for: modelID)) and switched to it."
                    status = "Downloaded \(WhisperModelCatalog.title(for: modelID)) and switched to it."
                    lastError = ""
                }

                await rebuildRuntimeOrDefer()
            } catch {
                await MainActor.run {
                    activeModelDownloadID = nil
                    modelDownloadMessage = ""
                    status = "Model download failed."
                    lastError = error.localizedDescription
                }
            }
        }
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

    func refreshPermissionStatuses() {
        guard !isIsolatedPreview else { return }
        microphonePermissionStatus = PermissionDiagnostics.microphoneStatus()
        accessibilityPermissionStatus = PermissionDiagnostics.accessibilityStatus()
        inputMonitoringPermissionStatus = PermissionDiagnostics.inputMonitoringStatus()

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
            overlay.show(state: .failure(message: reason))
            dismissOverlaySoon()
        }
    }

    func pressToTalkStart() {
        guard !isIsolatedPreview else { return }
        guard !isTearingDown else { return }
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
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
        if sessionCleanupStartGate.cancelDeferredPressToTalkStart() {
            status = "Option released before the previous recording finished."
            return
        }
        apply(transition: recordingStateMachine.handleOptionKeyUp())
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
        guard case .cancel = transition else { return }
        let wasPresented = confirmation?.isConfirmed == true
        let previousStatus = status
        let previousError = lastError
        apply(transition: transition)
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

    func toggleHandsFree() {
        guard !isIsolatedPreview else { return }
        guard !isTearingDown else { return }
        if sessionCleanupStartGate.deferHandsFreeToggle() {
            status = sessionCleanupStartGate.deferredMode == .handsFree
                ? "Finishing the previous recording. Hands-free will start when ready."
                : "Deferred hands-free start canceled."
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
        overlay.showNotice("Still finishing. Try again.")
    }

    func cancelActiveRecording() {
        guard !isIsolatedPreview else { return }
        guard !isTearingDown else { return }
        apply(transition: recordingStateMachine.handleCancel())
    }

    func pasteLastTranscript() {
        guard !isIsolatedPreview else { return }
        Task {
            do {
                if let entry = try await historyStore.pasteLast() {
                    lastTranscript = entry.cleanText
                    status = "Last transcript copied to clipboard. Paste with Cmd+V."
                } else {
                    status = "No transcript history yet."
                }
            } catch {
                status = "Paste last failed"
                lastError = error.localizedDescription
                overlay.show(state: .failure(message: error.localizedDescription))
                dismissOverlaySoon()
            }
        }
    }

    func deleteEntry(_ entry: TranscriptEntry) {
        guard !isIsolatedPreview else { return }
        Task {
            do {
                try await historyStore.delete(entryID: entry.id)
                await refreshHistory()
                status = "Transcript deleted."
            } catch {
                status = "Delete failed"
                lastError = error.localizedDescription
            }
        }
    }

    func retryCleanup(for entry: TranscriptEntry) {
        guard !isIsolatedPreview else { return }
        Task {
            let context = appContext(for: entry.appBundleID)
            let profile = await styleProfileService.resolve(for: context)
            let lexicon = await lexiconService.snapshot(for: context)

            do {
                _ = try await historyStore.retry(
                    entryID: entry.id,
                    using: RuleBasedCleanupEngine(),
                    profile: profile,
                    lexicon: lexicon
                )
                await refreshHistory()
                await refreshUsageAnalytics(forceHistoryReconciliation: true)
                status = "Cleanup re-run with current rules."
                lastError = ""
            } catch {
                status = "Cleanup re-run failed"
                lastError = error.localizedDescription
            }
        }
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
            recoverableText: result.insertedText.isEmpty ? nil : result.insertedText
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
        guard !isIsolatedPreview, let text = storageNotice?.recoverableText else { return }
        Task {
            do {
                try await clipboardService.setString(text)
                status = "Transcript copied to clipboard. Paste with Cmd+V."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    func pasteEntry(_ entry: TranscriptEntry) {
        guard !isIsolatedPreview else { return }
        Task {
            do {
                let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
                try await clipboardService.setString(text)
                status = "Transcript copied to clipboard. Paste with Cmd+V."
            } catch {
                status = "Paste failed"
                lastError = error.localizedDescription
            }
        }
    }

    func copyEntry(_ entry: TranscriptEntry) {
        guard !isIsolatedPreview else { return }
        Task {
            do {
                try await clipboardService.setString(entry.cleanText)
                status = "Selected transcript copied."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    func refreshHistory() async {
        guard !isIsolatedPreview else { return }
        let all = await historyStore.recent(limit: 1_000)
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        recentEntries = all.filter { $0.createdAt >= thirtyDaysAgo }
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
            startSession(mode: mode)
        case .stop(let mode):
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
            refuseSessionWithoutMicrophoneAccess(mode: mode)
            return
        }
        guard !isRuntimeUnloadingForSystemEvent else {
            recordingStateMachine.markTranscriptionFailed()
            status = "Runtime is releasing memory. Try again in a moment."
            return
        }
        guard let coordinator else {
            status = "Runtime not ready yet."
            recordingStateMachine.markTranscriptionFailed()
            return
        }

        invalidatePendingOverlayDismissal()
        // Capture the lightweight app identity at keydown, then start audio.
        // Display enumeration, overlay presentation, and recording UI wait for
        // the coordinator's post-capture acknowledgement.
        let capturedContext = appContextProvider()
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

        activeStartTask = Task {
            var ownedMediaToken: MediaInterruptionToken?
            var returnedSessionID: SessionID?
            defer { captureHandoff.finishPublication() }

            do {
                try Task.checkCancellation()
                guard activeSessionGeneration == generation else { throw CancellationError() }

                returnedSessionID = try await coordinator.startPressToTalkWithCaptureStopCapability(
                    appContext: capturedContext,
                    options: startOptions,
                    captureStarted: { [weak self] capability in
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
                                await pressConfirmation?.wait()
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
                // A press that turns out to be a keyboard shortcut never touches media.
                if shouldPauseMedia, await pressConfirmation?.wait() ?? true {
                    ownedMediaToken = await mediaInterruption.beginInterruption()
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
            self.overlay.show(state: .failure(message: message))
            self.dismissOverlaySoon()
        }
        guard mode == .pressToTalk, let confirmation = pressToTalkConfirmation else {
            present()
            return
        }
        Task { @MainActor in
            if await confirmation.wait() { present() }
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
        handsFreeOn = mode == .handsFree
        menuBar.updateIcon(isRecording: true, handsFreeOn: mode == .handsFree)
        activeRecordingMode = mode
        recordingElapsed = 0
        recordingStartedAt = Date()
        hasWarnedAboutRecordingLimit = false
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
        overlay.show(state: .listening(handsFree: mode == .handsFree, elapsedSeconds: 0))
    }

    /// A recording that reaches the length limit stops normally, so its audio
    /// is transcribed rather than lost.
    private func enforceRecordingDurationLimit() {
        guard let recordingStartedAt else { return }
        switch recordingDurationLimit.action(forElapsed: Date().timeIntervalSince(recordingStartedAt)) {
        case .none:
            return
        case .warn:
            guard !hasWarnedAboutRecordingLimit else { return }
            hasWarnedAboutRecordingLimit = true
            status = "Recording stops automatically in one minute."
            overlay.showRecordingLimitWarning(limitSeconds: recordingDurationLimit.maximumSeconds)
        case .stop:
            stopRecording()
        }
    }

    private func cancelSession(mode: RecordingMode) {
        invalidatePendingOverlayDismissal()
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

        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingElapsed = 0
        recordingStartedAt = nil
        isRecording = false
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        status = mode == .handsFree ? "Hands-free dictation canceled." : "Recording canceled."
        lastError = ""
        overlay.hide()

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
            cleanupTask = nil
            await applyDeferredMemoryPressureUnloadIfNeeded()
        }
    }

    private func stopSession(mode: RecordingMode) {
        invalidatePendingOverlayDismissal()
        let sessionGeneration = activeSessionGeneration
        let pendingStart = activeStartTask
        activeStartTask = nil
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
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil

        let taskID = UUID()
        completionTaskID = taskID
        let task = Task {
            guard !isTearingDown,
                  completionTaskID == taskID
            else {
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
                // Capture closes at the key-up boundary above. Only final
                // inference waits for optional media setup to settle, so a
                // late pause token's resume begins before transcription. The
                // resume then verifies alongside transcription instead of
                // delaying it.
                await pendingStart?.value
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
                    languageHints: ["en-US"]
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

                switch result.status {
                case .inserted:
                    lastTranscript = result.insertedText
                    status = "Transcript inserted."
                    lastError = ""
                    overlay.show(state: .inserted)
                case .copiedOnly:
                    lastTranscript = result.insertedText
                    status = copiedOnlyStatusMessage(for: result)
                    lastError = result.errorMessage ?? ""
                    overlay.show(state: result.pasteAttempted == true ? .inserted : .copiedOnly)
                case .failed:
                    lastTranscript = result.insertedText
                    status = "Transcript ready but insertion failed."
                    let reason = result.errorMessage ?? "Insertion chain exhausted."
                    lastError = reason
                    overlay.show(state: .failure(message: reason))
                case .noSpeech:
                    status = "No speech detected."
                    lastError = ""
                    if result.captureWarning == nil {
                        overlay.show(state: .noSpeechDetected)
                    }
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

                dismissOverlaySoon()
                await refreshHistory()
                if result.usageAnalyticsWarning == nil {
                    await refreshUsageAnalyticsSnapshot()
                } else {
                    // Recover the session as an estimate from transcript history
                    // while keeping the exact-metrics warning visible.
                    await refreshUsageAnalytics(forceHistoryReconciliation: true)
                }
                let stillOwnsLifecycle = acceptsCancelledCommit
                    ? recordingStateMachine.state == .idle
                    : !Task.isCancelled && recordingStateMachine.state == .transcribing
                guard !isTearingDown,
                      completionTaskID == taskID,
                      stillOwnsLifecycle
                else {
                    await finishCompletionTask(id: taskID)
                    return
                }
                if recordingStateMachine.state == .transcribing {
                    recordingStateMachine.markTranscriptionCompleted()
                }
                await applyDeferredRebuildIfNeeded()
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
                    let isRecordingFailure = error is CaptureStartFailure
                        || error is PromptCaptureStopError
                    status = isRecordingFailure ? "Recording failed" : "Transcription failed"
                    lastError = error.localizedDescription
                    overlay.show(state: .failure(message: error.localizedDescription))
                    dismissOverlaySoon()
                    recordingStateMachine.markTranscriptionFailed()
                    await applyDeferredRebuildIfNeeded()
                }
            }
            await finishCompletionTask(id: taskID)
        }
        completionTask = task
        completionTasks[taskID] = task
    }

    /// The recording stopped before the user ended it. Say so where the user
    /// is looking; "No speech detected" would blame them for the silence.
    private func presentCaptureWarning(_ warning: String, for resultStatus: InsertionStatus) {
        status = resultStatus == .noSpeech
            ? "Microphone stopped."
            : "\(status) Microphone stopped early."
        lastError = lastError.isEmpty ? warning : "\(lastError) \(warning)"
        switch resultStatus {
        case .noSpeech, .inserted:
            overlay.show(state: .failure(message: warning))
        case .copiedOnly, .failed:
            // Their own overlay already asks for attention and says what to do.
            break
        }
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
        guard activeSessionGeneration == generation,
              activeCaptureStartHandoff === handoff else { return false }
        if currentSessionID == sessionID,
           currentCaptureStopCapability?.sessionID == sessionID {
            return true
        }
        guard currentSessionID == nil,
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
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        recordingStateMachine.markTranscriptionFailed()
        status = "Failed to start"
        lastError = error.localizedDescription
        overlay.show(state: .failure(message: error.localizedDescription))
        dismissOverlaySoon()
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
        } else if activeStartTask != nil {
            pendingLiveSnapshots[snapshot.session.sessionID] = snapshot
        }
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
        preferences = newValue
        hotkey.isOptionPressToTalkEnabled = newValue.hotkeys.optionPressToTalkEnabled
        hotkey.globalToggleKeyCode = newValue.hotkeys.handsFreeGlobalKeyCode
        applyDockVisibility(showDockIcon: newValue.general.showDockIcon)
        applyOverlayAppearance(for: newValue.appearance)
        overlay.setLiveTranscriptEnabled(newValue.dictation.showLiveTranscriptWhileRecording)
    }

    private func rebuildRuntimeOrDefer() async {
        guard !isTearingDown else { return }
        // Cancellation returns the state machine to idle before its async capture
        // cleanup completes, so idle alone is not a safe rebuild boundary.
        if recordingStateMachine.state == .idle,
           !sessionCleanupStartGate.isCleanupInProgress {
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
              !sessionCleanupStartGate.isCleanupInProgress
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
        coordinator = nil
        await previousCoordinator?.shutdown()
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
            status = "Running local transcription + local cleanup."
            return
        }

        var snapshot = preferences
        snapshot.normalize()
        applyPreferencesLocally(snapshot)

        let runtimeFactory = DictationRuntimeFactory(
            snapshot: snapshot,
            clipboardService: clipboardService
        )
        lexiconService = runtimeFactory.makeLexiconService()
        styleProfileService = runtimeFactory.makeStyleProfileService()
        snippetService = runtimeFactory.makeSnippetService()

        let transcription = runtimeFactory.makeTranscriptionEngine()
        let cleanupEngine: any CleanupEngine = runtimeFactory.makeCleanupEngine()
        let insertion = InsertionService(transports: runtimeFactory.makeInsertionTransports())

        coordinator = SessionCoordinator(
            captureService: captureService,
            transcriptionEngine: transcription,
            cleanupEngine: cleanupEngine,
            insertionService: insertion,
            historyStore: historyStore,
            lexiconService: lexiconService,
            styleProfileService: styleProfileService,
            snippetService: snippetService,
            fallbackCleanupEngine: RuleBasedCleanupEngine(),
            usageRecorder: usageAnalyticsStore,
            liveSnapshotHandler: { [weak self] snapshot in
                await self?.receiveLiveTranscript(snapshot)
            },
            liveUnavailableHandler: { [weak self] sessionID, _ in
                await self?.receiveLiveTranscriptUnavailable(sessionID: sessionID)
            }
        )

        status = "Running local transcription + local cleanup."
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
              completionTasks.isEmpty
        else {
            return
        }

        pendingMemoryPressureRuntimeUnload = false
        await unloadRetainedRuntimeForSystemEvent()
    }

    private func applyLaunchAtLoginPreference(requestedPreference: Bool, userInitiated: Bool) {
        guard systemIntegrationsEnabled else { return }
        let decision = LaunchAtLoginMutationPolicy.decision(
            currentPreference: launchAtLoginServicePreference,
            requestedPreference: requestedPreference,
            userInitiated: userInitiated
        )

        switch decision {
        case .skip:
            launchAtLoginWarning = ""
        case .setEnabled(let enabled):
            do {
                try launchAtLoginService.setEnabled(enabled)
                launchAtLoginServicePreference = enabled
                launchAtLoginWarning = ""
            } catch {
                launchAtLoginWarning = LaunchAtLoginMutationPolicy.warningMessage(
                    requestedPreference: requestedPreference,
                    userInitiated: userInitiated,
                    errorDescription: error.localizedDescription
                ) ?? ""
            }
        }
    }

    private func fallbackWarningText(from outcome: CleanupOutcome?) -> String? {
        guard let outcome, outcome.source == .localFallback else {
            return nil
        }
        return outcome.warning ?? "Primary cleanup unavailable, used local fallback."
    }

    private func validateWhisperPaths() {
        let cliExists = FileManager.default.fileExists(atPath: preferences.dictation.whisperCLIPath)
        let modelExists = FileManager.default.fileExists(atPath: preferences.dictation.modelPath)

        if !cliExists && !modelExists {
            status = "whisper-cli and model not found. Check Settings \u{2192} Engine."
        } else if !cliExists {
            status = "whisper-cli not found. Check Settings \u{2192} Engine."
        } else if !modelExists {
            status = "Model file not found. Check Settings \u{2192} Engine."
        }
    }

    private func applyDockVisibility(showDockIcon: Bool) {
        guard systemIntegrationsEnabled else { return }
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    private func appContext(for bundleID: String) -> AppContext {
        let name = StenoDesign.appDisplayName(for: bundleID)
        return AppContext(
            bundleIdentifier: bundleID,
            appName: name,
            isRemoteDesktop: bundleID.lowercased().contains("remote"),
            isIDE: bundleID.contains("Xcode") || bundleID.contains("com.todesktop") || bundleID.contains("warp")
        )
    }

    private func copiedOnlyStatusMessage(for result: InsertResult) -> String {
        if result.pasteAttempted == true {
            // Steno restores the previous clipboard shortly after pasting, so
            // this must not suggest pasting again.
            return "Transcript pasted."
        }
        guard let reason = result.errorMessage?.lowercased() else {
            return "Transcript copied to clipboard. Paste with Cmd+V."
        }

        // These reasons already say why the text was copied.
        if reason.contains("secure text field")
            || reason.contains("focused field changed")
            || reason.contains("respond in time") {
            return result.errorMessage ?? "Transcript copied to clipboard. Paste with Cmd+V."
        }

        if reason.contains("accessibility permission") {
            return "Transcript copied. Auto-paste unavailable until Accessibility is re-granted for this Steno build."
        }

        if reason.contains("exact editor target")
            || reason.contains("selection changed")
            || reason.contains("selectionchanged")
            || reason.contains("target changed") {
            return "Target changed—final text copied."
        }

        return "Transcript copied to clipboard. Paste with Cmd+V."
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

    private static func defaultLegacyHistoryURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("WhisperClone", isDirectory: true)
            .appendingPathComponent("transcript-history.json")
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
    private var isSettled = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func confirm() {
        settle(confirmed: true)
    }

    func release() {
        settle(confirmed: false)
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

    mutating func beginCleanup() {
        isCleanupInProgress = true
        deferredMode = nil
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
    }
}

private struct DictationRuntimeFactory {
    let snapshot: AppPreferences
    let clipboardService: any ClipboardService

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

    func makeTranscriptionEngine() -> any TranscriptionEngine {
        let modelPath = URL(fileURLWithPath: snapshot.dictation.modelPath)
        let extraArgs = WhisperRuntimeConfiguration.additionalArguments(
            threadCount: snapshot.dictation.threadCount,
            vadEnabled: snapshot.dictation.vadEnabled,
            vadModelPath: snapshot.dictation.vadModelPath
        )

        let retainedPaths = WhisperRuntimeConfiguration.retainedRuntimePaths(
            relativeTo: snapshot.dictation.whisperCLIPath
        )
        let fallbackCLIPath = retainedPaths?.whisperCLIPath ?? snapshot.dictation.whisperCLIPath
        let fallback = WhisperCLITranscriptionEngine(
            config: .init(
                whisperCLIPath: URL(fileURLWithPath: fallbackCLIPath),
                modelPath: modelPath,
                additionalArguments: extraArgs
            )
        )

        guard let retainedPaths else {
            return fallback
        }

        let configuredVADPath = snapshot.dictation.vadModelPath
        let vadModelPath: URL? = if snapshot.dictation.vadEnabled,
                                   FileManager.default.fileExists(atPath: configuredVADPath) {
            URL(fileURLWithPath: configuredVADPath)
        } else {
            nil
        }

        return RetainedWhisperTranscriptionEngine(
            configuration: RetainedWhisperTranscriptionConfiguration(
                helperExecutableURL: URL(fileURLWithPath: retainedPaths.helperPath),
                modelPath: modelPath,
                threadCount: snapshot.dictation.threadCount,
                vadModelPath: vadModelPath,
                suppressNonSpeechTokens: true,
                suppressRegex: nil,
                beamSize: 5,
                bestOf: 5
            ),
            fallback: fallback
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
