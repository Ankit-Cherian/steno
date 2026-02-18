import AppKit
import Foundation
import SwiftUI
import StenoKit

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
    @Published var openAIAPIKey: String = ""
    @Published var microphonePermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var accessibilityPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var inputMonitoringPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var recordingElapsed: TimeInterval = 0
    @Published var hasBootstrapped = false

    private let captureService = MacAudioCaptureService()
    private let clipboardService = MacClipboardService()
    private let historyStore: HistoryStore
    private let hotkey: MacHotkeyMonitor
    private let overlay: MacOverlayPresenter
    private let mediaInterruption: MediaInterruptionService
    private let preferencesStore: AppPreferencesStore
    private let apiKeyStore: any APIKeyStore
    private let launchAtLoginService: LaunchAtLoginService

    private var lexiconService: PersonalLexiconService
    private var styleProfileService: StyleProfileService
    private var snippetService: SnippetService
    private var budgetGuard: BudgetGuard
    private var coordinator: SessionCoordinator?

    private var recordingStateMachine = RecordingStateMachine()
    private var currentSessionID: SessionID?
    private var activeRecordingMode: RecordingMode?
    private var activeMediaToken: MediaInterruptionToken?
    private var activeStartTask: Task<Void, Never>?
    private var pendingRuntimeRebuild = false
    private let menuBar = MenuBarController()
    private var recordingTimer: Timer?

    init(
        hotkey: MacHotkeyMonitor = MacHotkeyMonitor(),
        overlay: MacOverlayPresenter = MacOverlayPresenter(),
        mediaInterruption: MediaInterruptionService = MacMediaInterruptionService(),
        preferencesStore: AppPreferencesStore = AppPreferencesStore(),
        apiKeyStore: any APIKeyStore = KeychainAPIKeyStore(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService()
    ) {
        self.hotkey = hotkey
        self.overlay = overlay
        self.mediaInterruption = mediaInterruption
        self.preferencesStore = preferencesStore
        self.apiKeyStore = apiKeyStore
        self.launchAtLoginService = launchAtLoginService
        self.historyStore = HistoryStore(clipboardService: clipboardService)
        self.lexiconService = PersonalLexiconService(entries: AppPreferences.default.lexiconEntries)
        self.styleProfileService = StyleProfileService(
            globalProfile: AppPreferences.default.globalStyleProfile,
            appProfiles: AppPreferences.default.appStyleProfiles
        )
        self.snippetService = SnippetService(snippets: AppPreferences.default.snippets)
        self.budgetGuard = BudgetGuard(storageURL: BudgetGuard.defaultStorageURL())

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

        Task {
            await bootstrap()
        }
    }

    var menuBarIconName: String {
        if isRecording { return "waveform.circle.fill" }
        return handsFreeOn ? "mic.circle.fill" : "mic.circle"
    }

    var recordingLifecycleState: RecordingLifecycleState {
        recordingStateMachine.state
    }

    func bootstrap() async {
        var loaded = await preferencesStore.load()
        loaded.normalize()

        if (apiKeyStore.loadAPIKey() ?? "").isEmpty,
           let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !envKey.isEmpty {
            apiKeyStore.saveAPIKey(envKey)
        }

        let savedKey = apiKeyStore.loadAPIKey() ?? ""
        openAIAPIKey = savedKey

        applyPreferencesLocally(loaded)
        refreshPermissionStatuses()
        validateWhisperPaths()
        await rebuildRuntime()
        await refreshHistory()
        hasBootstrapped = true
    }

    func savePreferences() {
        var snapshot = preferences
        snapshot.normalize()
        preferences = snapshot

        Task {
            await preferencesStore.save(snapshot)
            await MainActor.run {
                status = "Settings saved."
            }
            await rebuildRuntimeOrDefer()
        }
    }

    func saveAPIKey() {
        apiKeyStore.saveAPIKey(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            await rebuildRuntimeOrDefer()
        }
    }

    func clearAPIKey() {
        openAIAPIKey = ""
        apiKeyStore.saveAPIKey(nil)
        Task {
            await rebuildRuntimeOrDefer()
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
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        apply(transition: recordingStateMachine.handleOptionKeyDown())
    }

    func pressToTalkStop() {
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        apply(transition: recordingStateMachine.handleOptionKeyUp())
    }

    func toggleHandsFree() {
        apply(transition: recordingStateMachine.handleHandsFreeToggle())
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

    private func apply(transition: RecordingTransition) {
        switch transition {
        case .start(let mode):
            startSession(mode: mode)
        case .stop(let mode):
            stopSession(mode: mode)
        case .ignore(let reason):
            status = reason
        }
    }

    private func startSession(mode: RecordingMode) {
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
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingElapsed += 1
            }
        }
        overlay.show(state: .listening(handsFree: mode == .handsFree, elapsedSeconds: 0))
        let capturedContext = AppContextProvider.current()

        let shouldPauseMedia = (mode == .handsFree && preferences.media.pauseDuringHandsFree)
                            || (mode == .pressToTalk && preferences.media.pauseDuringPressToTalk)

        activeStartTask = Task {
            do {
                // Start recorder first — no latency for speech capture.
                // beginInterruption() runs after because its 4 sequential probes
                // (up to 250ms each) would clip the start of speech if we waited.
                currentSessionID = try await coordinator.startPressToTalk(appContext: capturedContext)
                await coordinator.setHandsFreeEnabled(mode == .handsFree)

                if shouldPauseMedia {
                    activeMediaToken = await mediaInterruption.beginInterruption()
                }
            } catch {
                if let token = activeMediaToken {
                    mediaInterruption.endInterruption(token: token)
                    activeMediaToken = nil
                }
                self.recordingTimer?.invalidate()
                self.recordingTimer = nil
                self.recordingElapsed = 0
                isRecording = false
                handsFreeOn = false
                menuBar.updateIcon(isRecording: false, handsFreeOn: false)
                activeRecordingMode = nil
                recordingStateMachine.markTranscriptionFailed()
                status = "Failed to start"
                lastError = error.localizedDescription
                overlay.show(state: .failure(message: error.localizedDescription))
                dismissOverlaySoon()
            }
            activeStartTask = nil
        }
    }

    private func stopSession(mode: RecordingMode) {
        let pendingStart = activeStartTask
        activeStartTask = nil

        // Shared cleanup — runs on every path including the guard-return.
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingElapsed = 0
        isRecording = false
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil

        Task {
            // Wait for startSession's Task to finish so currentSessionID
            // and activeMediaToken are guaranteed to be set (or errored out).
            await pendingStart?.value

            guard let coordinator, let sessionID = currentSessionID else {
                recordingStateMachine.markTranscriptionFailed()
                status = "No active recording session."
                return
            }
            currentSessionID = nil

            if let token = activeMediaToken {
                mediaInterruption.endInterruption(token: token)
                activeMediaToken = nil
            }

            status = "Transcribing..."
            lastError = ""
            overlay.show(state: .transcribing)

            do {
                let result = try await coordinator.stopPressToTalk(sessionID: sessionID)
                lastTranscript = result.insertedText
                switch result.status {
                case .inserted:
                    status = "Transcript inserted."
                    lastError = ""
                    overlay.show(state: .inserted)
                case .copiedOnly:
                    status = copiedOnlyStatusMessage(for: result)
                    lastError = result.errorMessage ?? ""
                    overlay.show(state: .copiedOnly)
                case .failed:
                    status = "Transcript ready but insertion failed."
                    let reason = result.errorMessage ?? "Insertion chain exhausted."
                    lastError = reason
                    overlay.show(state: .failure(message: reason))
                }
                dismissOverlaySoon()
                await refreshHistory()
                recordingStateMachine.markTranscriptionCompleted()
                await applyDeferredRebuildIfNeeded()
            } catch {
                status = "Transcription failed"
                lastError = error.localizedDescription
                overlay.show(state: .failure(message: error.localizedDescription))
                dismissOverlaySoon()
                recordingStateMachine.markTranscriptionFailed()
                await applyDeferredRebuildIfNeeded()
            }
        }
    }

    private func dismissOverlaySoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            overlay.hide()
        }
    }

    private func applyPreferencesLocally(_ newValue: AppPreferences) {
        preferences = newValue
        hotkey.isOptionPressToTalkEnabled = newValue.hotkeys.optionPressToTalkEnabled
        hotkey.globalToggleKeyCode = newValue.hotkeys.handsFreeGlobalKeyCode
        applyDockVisibility(showDockIcon: newValue.general.showDockIcon)
    }

    private func rebuildRuntimeOrDefer() async {
        if recordingStateMachine.state == .idle {
            await rebuildRuntime()
        } else {
            pendingRuntimeRebuild = true
            status = "Settings saved. Changes will apply after current transcription."
        }
    }

    private func applyDeferredRebuildIfNeeded() async {
        guard pendingRuntimeRebuild, recordingStateMachine.state == .idle else { return }
        pendingRuntimeRebuild = false
        await rebuildRuntime()
    }

    private func trimmedAPIKey() -> String {
        apiKeyStore.loadAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func rebuildRuntime() async {
        var snapshot = preferences
        snapshot.normalize()
        applyPreferencesLocally(snapshot)

        let runtimeFactory = DictationRuntimeFactory(
            snapshot: snapshot,
            apiKey: trimmedAPIKey(),
            clipboardService: clipboardService
        )
        lexiconService = runtimeFactory.makeLexiconService()
        styleProfileService = runtimeFactory.makeStyleProfileService()
        snippetService = runtimeFactory.makeSnippetService()
        budgetGuard = runtimeFactory.makeBudgetGuard()

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
            budgetGuard: budgetGuard
        )

        do {
            try launchAtLoginService.setEnabled(snapshot.general.launchAtLoginEnabled)
            launchAtLoginWarning = ""
        } catch {
            launchAtLoginWarning = error.localizedDescription
        }

        if snapshot.cleanup.mode == .localOnly {
            status = "Running local transcription + local cleanup."
        } else if runtimeFactory.hasCloudCleanupKey {
            status = "Running local transcription + cloud cleanup (text-only)."
        } else {
            status = "Cloud cleanup selected but API key missing. Using local cleanup."
        }
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

    private func copiedOnlyStatusMessage(for result: InsertResult) -> String {
        guard let reason = result.errorMessage?.lowercased() else {
            return "Transcript copied to clipboard. Paste with Cmd+V."
        }

        if reason.contains("accessibility permission") {
            return "Transcript copied. Auto-paste unavailable until Accessibility is re-granted for this Steno build."
        }

        return "Transcript copied to clipboard. Paste with Cmd+V."
    }
}

private struct DictationRuntimeFactory {
    let snapshot: AppPreferences
    let apiKey: String
    let clipboardService: any ClipboardService

    var hasCloudCleanupKey: Bool {
        !apiKey.isEmpty && snapshot.cleanup.mode == .cloudIfConfigured
    }

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

    func makeBudgetGuard() -> BudgetGuard {
        BudgetGuard(storageURL: BudgetGuard.defaultStorageURL())
    }

    func makeTranscriptionEngine() -> WhisperCLITranscriptionEngine {
        let whisperCLIPath = URL(fileURLWithPath: snapshot.dictation.whisperCLIPath)
        let modelPath = URL(fileURLWithPath: snapshot.dictation.modelPath)
        return WhisperCLITranscriptionEngine(
            config: .init(
                whisperCLIPath: whisperCLIPath,
                modelPath: modelPath,
                additionalArguments: ["-t", "\(snapshot.dictation.threadCount)"]
            )
        )
    }

    func makeCleanupEngine() -> any CleanupEngine {
        guard hasCloudCleanupKey else {
            return RuleBasedCleanupEngine()
        }

        return OpenAICleanupEngine(config: .init(apiKey: apiKey))
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
