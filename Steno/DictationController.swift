import AppKit
import Foundation
import SwiftUI
import StenoKit

protocol DictationSessionCoordinating: Sendable {
    func startPressToTalk(appContext: AppContext) async throws -> SessionID
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

@MainActor
final class DictationController: ObservableObject {
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

    private let captureService = MacAudioCaptureService()
    private let clipboardService: MacClipboardService
    private let historyStore: HistoryStore
    private let usageAnalyticsStore: any UsageAnalyticsStoreServicing
    private let legacyHistoryURL: URL
    private let hotkey: any HotkeyService
    private let overlay: WaveformOverlayPresenter
    private let mediaInterruption: MediaInterruptionService
    private let preferencesStore: AppPreferencesStore
    private let launchAtLoginService: LaunchAtLoginService
    private let runtimeRebuildOverride: (@MainActor () async -> (any DictationSessionCoordinating)?)?
    private let modelDownloadService = WhisperModelDownloadService()
    private let compatibilityService = try? WhisperCompatibilityService.bundled()

    private var lexiconService: PersonalLexiconService
    private var styleProfileService: StyleProfileService
    private var snippetService: SnippetService
    private var coordinator: (any DictationSessionCoordinating)?

    private var recordingStateMachine = RecordingStateMachine()
    private var currentSessionID: SessionID?
    private var activeRecordingMode: RecordingMode?
    private var activeMediaToken: MediaInterruptionToken?
    private var activeStartTask: Task<Void, Never>?
    private var activeSessionGeneration: UUID?
    private var sessionCleanupStartGate = SessionCleanupStartGate()
    private var cleanupTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var completionTaskID: UUID?
    private var completionTasks: [UUID: Task<Void, Never>] = [:]
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
        clipboardService: MacClipboardService = MacClipboardService(),
        overlay: WaveformOverlayPresenter = WaveformOverlayPresenter(),
        mediaInterruption: MediaInterruptionService = MacMediaInterruptionService(),
        preferencesStore: AppPreferencesStore = AppPreferencesStore(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        coordinator: (any DictationSessionCoordinating)? = nil,
        runtimeRebuildOverride: (@MainActor () async -> (any DictationSessionCoordinating)?)? = nil,
        historyStore: HistoryStore? = nil,
        usageAnalyticsStore: (any UsageAnalyticsStoreServicing)? = nil,
        legacyHistoryURL: URL? = nil
    ) {
        self.hotkey = hotkey
        self.clipboardService = clipboardService
        self.overlay = overlay
        self.mediaInterruption = mediaInterruption
        self.preferencesStore = preferencesStore
        self.launchAtLoginService = launchAtLoginService
        self.coordinator = coordinator
        self.runtimeRebuildOverride = runtimeRebuildOverride
        self.historyStore = historyStore ?? HistoryStore(clipboardService: clipboardService)
        self.usageAnalyticsStore = usageAnalyticsStore ?? UsageAnalyticsStore()
        self.legacyHistoryURL = legacyHistoryURL ?? Self.defaultLegacyHistoryURL()
        self.lexiconService = PersonalLexiconService(entries: AppPreferences.default.lexiconEntries)
        self.styleProfileService = StyleProfileService(
            globalProfile: AppPreferences.default.globalStyleProfile,
            appProfiles: AppPreferences.default.appStyleProfiles
        )
        self.snippetService = SnippetService(snippets: AppPreferences.default.snippets)
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
        hotkey.onRegistrationStatusChanged = { [weak self] status in
            switch status {
            case .registered:
                self?.hotkeyRegistrationMessage = ""
            case .unavailable(let reason):
                self?.hotkeyRegistrationMessage = reason
                self?.overlay.show(state: .failure(message: reason))
                self?.dismissOverlaySoon()
            }
        }
        hotkey.start()
        menuBar.setup(controller: self)

        workspaceSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.unloadRetainedRuntimeForSystemEvent()
            }
        }
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.unloadRetainedRuntimeForSystemEvent()
            }
        }

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
        pendingMemoryPressureRuntimeUnload = false
        runtimeRebuildGeneration &+= 1
        terminationTask?.cancel()
        terminationTask = nil
        if let workspaceSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceSleepObserver)
            self.workspaceSleepObserver = nil
        }
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
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
        activeSessionGeneration = nil
        let pendingStart = activeStartTask
        activeStartTask = nil
        pendingStart?.cancel()
        let mediaToken = activeMediaToken
        activeMediaToken = nil
        let sessionID = currentSessionID
        currentSessionID = nil
        let coordinator = self.coordinator
        self.coordinator = nil
        recordingTimer?.invalidate()
        recordingTimer = nil

        shutdownTask = Task {
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
        WhisperModelLibrary.installedOptions(
            preferences: preferences,
            compatibilityService: compatibilityService
        )
    }

    var recommendedWhisperModel: WhisperModelOption? {
        whisperModelOptions.first(where: \.isRecommended)
    }

    var currentHardwareSummary: String? {
        guard let hardwareProfile = WhisperCompatibilityService.currentHardwareProfile() else {
            return nil
        }
        return "\(hardwareProfile.chipClass.displayName) · \(hardwareProfile.memoryGB)GB unified memory"
    }

    var recommendedWhisperModelNote: String? {
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
        var snapshot = preferences
        snapshot.normalize()
        applyPreferencesLocally(snapshot)

        Task {
            await preferencesStore.save(snapshot)
            await MainActor.run {
                applyLaunchAtLoginPreference(
                    requestedPreference: snapshot.general.launchAtLoginEnabled,
                    userInitiated: true
                )
                status = "Settings saved."
            }
            await rebuildRuntimeOrDefer()
        }
    }

    func applySettingsDraft(preferences draft: AppPreferences) {
        var snapshot = draft
        snapshot.normalize()
        applyPreferencesLocally(snapshot)

        Task {
            await preferencesStore.save(snapshot)
            await MainActor.run {
                applyLaunchAtLoginPreference(
                    requestedPreference: snapshot.general.launchAtLoginEnabled,
                    userInitiated: true
                )
                status = "Settings saved."
            }
            await rebuildRuntimeOrDefer()
        }
    }

    func saveAppearance(_ appearance: AppPreferences.Appearance) {
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
        Task {
            _ = await PermissionDiagnostics.requestMicrophonePermission()
            await MainActor.run {
                refreshPermissionStatuses()
            }
        }
    }

    func openMicrophoneSettings() {
        PermissionDiagnostics.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        PermissionDiagnostics.openAccessibilitySettings()
    }

    func openInputMonitoringSettings() {
        PermissionDiagnostics.openInputMonitoringSettings()
    }

    func requestAccessibilityPermission() {
        _ = PermissionDiagnostics.requestAccessibilityPermission()
        refreshPermissionStatuses()
    }

    func requestInputMonitoringPermission() {
        _ = PermissionDiagnostics.requestInputMonitoringPermission()
        refreshPermissionStatuses()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            refreshPermissionStatuses()
        }
    }

    func revealCurrentAppInFinder() {
        PermissionDiagnostics.revealCurrentAppInFinder()
    }

    func refreshPermissionStatuses() {
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

    func pressToTalkStart() {
        guard !isTearingDown else { return }
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        if sessionCleanupStartGate.deferPressToTalkStart() {
            status = "Finishing the previous recording. Hold Option to start when ready."
            return
        }
        apply(transition: recordingStateMachine.handleOptionKeyDown())
    }

    func pressToTalkStop() {
        guard !isTearingDown else { return }
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        if sessionCleanupStartGate.cancelDeferredPressToTalkStart() {
            status = "Option released before the previous recording finished."
            return
        }
        apply(transition: recordingStateMachine.handleOptionKeyUp())
    }

    func toggleHandsFree() {
        guard !isTearingDown else { return }
        if sessionCleanupStartGate.deferHandsFreeToggle() {
            status = sessionCleanupStartGate.deferredMode == .handsFree
                ? "Finishing the previous recording. Hands-free will start when ready."
                : "Deferred hands-free start canceled."
            return
        }
        apply(transition: recordingStateMachine.handleHandsFreeToggle())
    }

    func cancelActiveRecording() {
        guard !isTearingDown else { return }
        apply(transition: recordingStateMachine.handleCancel())
    }

    func pasteLastTranscript() {
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

    func clearErrors() {
        lastError = ""
        hotkeyRegistrationMessage = ""
    }

    func pasteEntry(_ entry: TranscriptEntry) {
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
        let all = await historyStore.recent(limit: 500)
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        recentEntries = all.filter { $0.createdAt >= thirtyDaysAgo }
    }

    func refreshUsageAnalytics(
        now: Date = Date(),
        calendar: Calendar = .current,
        forceHistoryReconciliation: Bool = false
    ) async {
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

                let currentEntries = await historyStore.recent(limit: 500)
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

        status = mode == .handsFree ? "Hands-free listening..." : "Recording..."
        lastError = ""
        isRecording = true
        handsFreeOn = mode == .handsFree
        menuBar.updateIcon(isRecording: true, handsFreeOn: mode == .handsFree)
        activeRecordingMode = mode
        recordingElapsed = 0
        recordingStartedAt = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingElapsed += 1
            }
        }
        overlay.show(state: .listening(handsFree: mode == .handsFree, elapsedSeconds: 0))
        let capturedContext = AppContextProvider.current()

        let shouldPauseMedia = (mode == .handsFree && preferences.media.pauseDuringHandsFree)
                            || (mode == .pressToTalk && preferences.media.pauseDuringPressToTalk)

        let generation = UUID()
        activeSessionGeneration = generation
        activeStartTask = Task {
            var ownedMediaToken: MediaInterruptionToken?
            var ownedSessionID: SessionID?

            do {
                // Press-to-talk should start capture immediately so the first spoken
                // words are not clipped while media detection/pausing runs.
                if mode == .handsFree && shouldPauseMedia {
                    ownedMediaToken = await mediaInterruption.beginInterruption()
                }

                try Task.checkCancellation()
                guard activeSessionGeneration == generation else { throw CancellationError() }

                ownedSessionID = try await coordinator.startPressToTalk(appContext: capturedContext)

                try Task.checkCancellation()
                guard activeSessionGeneration == generation else { throw CancellationError() }

                if mode == .pressToTalk && shouldPauseMedia {
                    ownedMediaToken = await mediaInterruption.beginInterruption()
                }

                try Task.checkCancellation()
                guard activeSessionGeneration == generation else { throw CancellationError() }

                await coordinator.setHandsFreeEnabled(mode == .handsFree)

                try Task.checkCancellation()
                guard activeSessionGeneration == generation else { throw CancellationError() }

                currentSessionID = ownedSessionID
                ownedSessionID = nil
                activeMediaToken = ownedMediaToken
                ownedMediaToken = nil
            } catch is CancellationError {
                if let ownedSessionID {
                    await coordinator.cancel(sessionID: ownedSessionID)
                }

                if let ownedMediaToken {
                    await mediaInterruption.endInterruption(token: ownedMediaToken)
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
                if let ownedSessionID {
                    await coordinator.cancel(sessionID: ownedSessionID)
                }

                if let ownedMediaToken {
                    await mediaInterruption.endInterruption(token: ownedMediaToken)
                }

                await markStartFailed(error: error, generation: generation)
            }

            if activeSessionGeneration == generation {
                activeStartTask = nil
            }
        }
    }

    private func cancelSession(mode: RecordingMode) {
        sessionCleanupStartGate.beginCleanup()
        // Settings may rebuild the runtime once the state machine returns to idle.
        // Retain the coordinator that created this session before cleanup suspends.
        let sessionCoordinator = coordinator
        activeSessionGeneration = nil
        let pendingStart = activeStartTask
        activeStartTask = nil
        pendingStart?.cancel()
        let mediaToken = activeMediaToken
        activeMediaToken = nil
        let sessionID = currentSessionID
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
            await pendingStart?.value

            if let sessionCoordinator, let sessionID {
                await sessionCoordinator.cancel(sessionID: sessionID)
            }

            if let mediaToken {
                await mediaInterruption.endInterruption(token: mediaToken)
            }

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
        let generation = activeSessionGeneration
        let pendingStart = activeStartTask
        activeStartTask = nil

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
            // Wait for startSession's Task to finish so currentSessionID
            // and activeMediaToken are guaranteed to be set (or errored out).
            await pendingStart?.value

            guard !isTearingDown,
                  completionTaskID == taskID,
                  let generation,
                  activeSessionGeneration == generation
            else {
                await finishCompletionTask(id: taskID)
                return
            }

            let sessionID = currentSessionID
            currentSessionID = nil
            let mediaToken = activeMediaToken
            activeMediaToken = nil
            activeSessionGeneration = nil

            guard let coordinator, let sessionID else {
                if let mediaToken {
                    await mediaInterruption.endInterruption(token: mediaToken)
                }
                if !isTearingDown, completionTaskID == taskID {
                    recordingStateMachine.markTranscriptionFailed()
                    status = "No active recording session."
                }
                await finishCompletionTask(id: taskID)
                return
            }

            status = "Finishing recording..."
            lastError = ""
            overlay.show(state: .transcribing)

            var releasedMedia = false
            do {
                try await coordinator.endPressToTalkCapture(sessionID: sessionID)
                if let mediaToken {
                    await mediaInterruption.endInterruption(token: mediaToken)
                    releasedMedia = true
                }

                try Task.checkCancellation()
                guard !isTearingDown, completionTaskID == taskID else {
                    throw CancellationError()
                }

                status = "Transcribing..."
                let result = try await coordinator.completePressToTalk(
                    sessionID: sessionID,
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
                    overlay.show(state: .copiedOnly)
                case .failed:
                    lastTranscript = result.insertedText
                    status = "Transcript ready but insertion failed."
                    let reason = result.errorMessage ?? "Insertion chain exhausted."
                    lastError = reason
                    overlay.show(state: .failure(message: reason))
                case .noSpeech:
                    status = "No speech detected."
                    lastError = ""
                    overlay.show(state: .noSpeechDetected)
                }

                if let fallbackWarning = fallbackWarningText(from: result.cleanupOutcome) {
                    status = "\(status) \(fallbackWarning)"
                }

                if let analyticsWarning = result.usageAnalyticsWarning {
                    usageAnalyticsWriteWarning = analyticsWarning
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
                await coordinator.cancel(sessionID: sessionID)
                if let mediaToken, !releasedMedia {
                    await mediaInterruption.endInterruption(token: mediaToken)
                }

                if !Task.isCancelled,
                   !isTearingDown,
                   completionTaskID == taskID
                {
                    status = "Transcription failed"
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

    private func cancelTranscription() {
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
        if !isTearingDown, activeSessionGeneration == nil, !isRecording {
            status = "Failed to start"
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            overlay.hide()
        }
    }

    private func applyPreferencesLocally(_ newValue: AppPreferences) {
        preferences = newValue
        hotkey.isOptionPressToTalkEnabled = newValue.hotkeys.optionPressToTalkEnabled
        hotkey.globalToggleKeyCode = newValue.hotkeys.handsFreeGlobalKeyCode
        applyDockVisibility(showDockIcon: newValue.general.showDockIcon)
        applyOverlayAppearance(for: newValue.appearance)
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
            usageRecorder: usageAnalyticsStore
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
        guard let reason = result.errorMessage?.lowercased() else {
            return "Transcript copied to clipboard. Paste with Cmd+V."
        }

        if reason.contains("accessibility permission") {
            return "Transcript copied. Auto-paste unavailable until Accessibility is re-granted for this Steno build."
        }

        return "Transcript copied to clipboard. Paste with Cmd+V."
    }

    private func applyOverlayAppearance(for appearance: AppPreferences.Appearance) {
        let theme = StenoDesign.theme(for: appearance)
        overlay.updateAccentColor(NSColor(theme.accent), glowColor: NSColor(theme.accentGlow))
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
        var transports: [any InsertionTransport] = []

        for method in snapshot.insertion.orderedMethods {
            switch method {
            case .direct:
                transports.append(DirectTypingInsertionTransport())
            case .accessibility:
                transports.append(AccessibilityInsertionTransport())
            case .clipboardPaste:
                transports.append(ClipboardInsertionTransport(clipboard: clipboardService, autoPaste: { target in
                    await MacPasteHelper.activateAndPaste(target: target)
                }))
            case .none:
                continue
            }
        }

        if !transports.contains(where: { $0.method == .clipboardPaste }) {
            transports.append(ClipboardInsertionTransport(clipboard: clipboardService, autoPaste: { target in
                await MacPasteHelper.activateAndPaste(target: target)
            }))
        }

        return transports
    }
}
