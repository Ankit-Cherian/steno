import AppKit
import SwiftUI
import StenoKit

/// The main window: a unified toolbar with Today, History and Insights, the status pill and
/// Settings; recovery strips under the toolbar; the page below.
struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.drawsWindowChromeInline) private var drawsChromeInline
    @State private var selectedTab: StenoTab
    @State private var historyQuery: String
    @State private var historyFocus: HistoryFocusRequest?
    @State private var dismissedStrips: Set<RecoveryStripModel.Kind> = []
    @State private var dismissedAttention = ""
    @StateObject private var feedback = GroveFeedback()
    /// Where History and Insights were left. Each section is rebuilt when it is shown, so it
    /// reads its place back from here.
    @State private var places = SectionPlaces()
    private let start: InitialState

    /// Where the window opens. Previews and render tests use the extra fields to show a state
    /// without driving the interface.
    struct InitialState {
        var historyEntryID: UUID?
        var historyQuery = ""
        var historyFilter: HistoryFilter = .all
        var historyBeforeCleanupExpanded = false
        var fix: FixWordState?
        var fixResult: FixWordResult?
        var todayStartedHere = false
        var insightsDay: Date?
    }

    init(initialTab: StenoTab = .today, initialState: InitialState = InitialState()) {
        _selectedTab = State(initialValue: initialTab)
        _historyQuery = State(initialValue: initialState.historyQuery)
        let places = SectionPlaces()
        places.insightsDay = initialState.insightsDay
        _places = State(initialValue: places)
        start = initialState
    }

    var body: some View {
        window
            .task { await controller.refreshHistory() }
            #if DEBUG
            .task { await runTabSwitchBenchmarkIfAsked() }
            #endif
    }

    #if DEBUG
    /// `--tab-switch-benchmark`, in an isolated preview: cycles the sections with 1,000
    /// dictations, timed by the main-thread watch. `PerfTour` walks every other flow.
    private func runTabSwitchBenchmarkIfAsked() async {
        guard controller.isIsolatedPreview else { return }
        guard ProcessInfo.processInfo.arguments.contains("--tab-switch-benchmark") else { return }
        DictationLatency.watchMainThread()
        try? await Task.sleep(for: .seconds(2))
        controller.recentEntries = WindowSampleData.thousandEntries()
        try? await Task.sleep(for: .seconds(1))
        for index in 0..<12 {
            let tab = StenoTab.allCases[(index + 1) % 3]
            DictationLatency.note("switch tab")
            selectedTab = tab
            try? await Task.sleep(for: .milliseconds(1200))
        }
        DictationLatency.note("benchmark done")
    }
    #endif

    // MARK: Window

    private var window: some View {
        GroveWindowContent(accent: controller.preferences.appearance.accent, feedback: feedback) {
            VStack(spacing: 0) {
                if drawsChromeInline {
                    InlineWindowChrome(tab: $selectedTab, inputs: statusInputs)
                }
                page
                    .environment(\.sectionPlaces, places)
                    .safeAreaInset(edge: .top, spacing: 0) { strips }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .modifier(windowToolbar)
            .focusedSceneValue(\.selectedStenoTab, $selectedTab)
            .background(alignment: .topLeading) { fallbackTabShortcuts }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .today:
            GroveTodayView(onOpenHistory: openHistory, initialFix: start.fix, initialStartedHere: start.todayStartedHere)
        case .history:
            GroveHistoryView(searchQuery: $historyQuery, focusRequest: $historyFocus,
                             initialSelectedEntryID: start.historyEntryID, initialFilter: start.historyFilter,
                             initialFix: start.fix, initialFixResult: start.fixResult,
                             initialBeforeCleanupExpanded: start.historyBeforeCleanupExpanded)
        case .insights:
            GroveInsightsView()
        }
    }

    private var strips: some View {
        let standing = RecoveryStrips.strips(for: stripContext, onToday: selectedTab == .today)
        let visible = standing.filter(isVisible)
        return VStack(spacing: 8) {
            ForEach(visible) { strip in
                GroveStripView(model: strip, perform: perform, onDismiss: { dismiss(strip) })
            }
        }
        .padding(.horizontal, visible.isEmpty ? 0 : GroveMetrics.pageLeading)
        .padding(.top, visible.isEmpty ? 0 : 14)
        .onChange(of: standing.map(\.kind)) { kinds in forgetDismissals(standing: kinds) }
    }

    private var windowToolbar: WindowToolbar {
        WindowToolbar(tab: $selectedTab, inputs: statusInputs, onFix: openFix(for:))
    }

    /// ⌘1–3 for windows whose scene does not install `StenoWindowCommands` yet.
    @ViewBuilder
    private var fallbackTabShortcuts: some View {
        if !StenoWindowCommandsInstallation.isInstalled {
            ZStack {
                ForEach(StenoTab.allCases) { tab in
                    Button(tab.title) { selectedTab = tab }
                        .keyboardShortcut(tab.shortcut, modifiers: .command)
                }
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Strips

    private func isVisible(_ strip: RecoveryStripModel) -> Bool {
        switch strip.kind {
        case .attention: dismissedAttention != strip.title + strip.body
        default: !dismissedStrips.contains(strip.kind)
        }
    }

    /// A dismissal covers one occurrence of a problem. When a problem ends (the error clears at
    /// the next recording, a permission comes back), its dismissal ends with it, so the next
    /// occurrence shows its strip.
    private func forgetDismissals(standing kinds: [RecoveryStripModel.Kind]) {
        dismissedStrips.formIntersection(kinds)
        if !kinds.contains(.attention) { dismissedAttention = "" }
    }

    private var handsFreeKeyName: String? {
        controller.preferences.hotkeys.handsFreeGlobalKeyCode.flatMap(HandsFreeKey.displayName(for:))
    }

    private var stripContext: RecoveryStrips.Context {
        RecoveryStrips.Context(
            status: statusInputs,
            handsFreeKeyName: handsFreeKeyName,
            optionHold: controller.preferences.hotkeys.optionPressToTalkEnabled,
            modelName: SpeechModelNames.title(forPath: controller.preferences.dictation.modelPath),
            downloadingModelName: controller.activeModelDownloadID.map(WhisperModelCatalog.title(for:)),
            storageNotice: controller.storageNotice,
            lastError: controller.lastError,
            hotkeyMessage: controller.hotkeyRegistrationMessage,
            recoverySection: controller.recoverySection
        )
    }

    private func dismiss(_ strip: RecoveryStripModel) {
        switch strip.kind {
        case .storage: controller.dismissStorageNotice()
        case .attention: dismissedAttention = strip.title + strip.body
        default: dismissedStrips.insert(strip.kind)
        }
    }

    private func perform(_ action: RecoveryStripModel.Action) {
        switch action {
        case .openMicrophoneSettings: controller.openMicrophoneSettings()
        case .requestMicrophone: controller.requestMicrophonePermission()
        case .openAccessibilitySettings: controller.openAccessibilitySettings()
        case .openInputMonitoringSettings: controller.openInputMonitoringSettings()
        case .openSettings(let section): SettingsRouter.shared.open(section)
        case .copyStorageText: controller.copyStorageNoticeText()
        case .revealStorageFile: controller.revealStorageNoticeFile()
        }
    }

    // MARK: Status

    private var statusInputs: WindowStatusInputs {
        WindowStatusInputs(
            lifecycle: controller.recordingLifecycleState,
            recordingStartedAt: controller.recordingStartedAt,
            microphone: controller.microphonePermissionStatus,
            accessibility: controller.accessibilityPermissionStatus,
            inputMonitoring: controller.inputMonitoringPermissionStatus,
            speechModelMissing: SpeechModelAvailability.isMissing(for: controller),
            downloadPercent: nil,
            optionHold: controller.preferences.hotkeys.optionPressToTalkEnabled,
            handsFreeKeyName: handsFreeKeyName
        )
    }

    /// The pill opens the setting that fixes its state, and shows its strip again.
    private func openFix(for state: QuillStatusPillState) {
        dismissedStrips.removeAll()
        if let section = state.settingsSection { SettingsRouter.shared.open(section) }
    }

    private func openHistory(_ entryID: UUID?, showsWhatHappened: Bool) {
        if let entryID { historyFocus = HistoryFocusRequest(entryID: entryID, showsWhatHappened: showsWhatHappened) }
        selectedTab = .history
    }
}

/// The window's toolbar: the section picker, the status pill and Settings.
/// It is a modifier that compares only what the toolbar shows, because the window redraws about
/// four times a second while recording and rebuilding the toolbar each time cost more than the
/// page under it.
private struct WindowToolbar: ViewModifier, @preconcurrency Equatable {
    @Binding var tab: StenoTab
    let inputs: WindowStatusInputs
    /// Not compared: it only opens a setting.
    let onFix: (QuillStatusPillState) -> Void

    static func == (a: WindowToolbar, b: WindowToolbar) -> Bool {
        a.tab == b.tab && a.inputs == b.inputs
    }

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .principal) {
                SectionPicker(selection: $tab)
            }
            StatusPillToolbarItem(inputs: inputs, onTodayTab: tab == .today, action: onFix)
            ToolbarItem(placement: .primaryAction) {
                SettingsToolbarButton()
            }
        }
    }
}

/// The status pill's place in the toolbar. It stays there on every section and is made clear
/// where it is not wanted; on macOS 26 the item's own glass background goes with it.
private struct StatusPillToolbarItem: ToolbarContent {
    let inputs: WindowStatusInputs
    let onTodayTab: Bool
    let action: (QuillStatusPillState) -> Void

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                WindowStatusPill(inputs: inputs, onTodayTab: onTodayTab, action: action)
            }
            .sharedBackgroundVisibility(QuillStatusPillState.derive(inputs).isShown(onToday: onTodayTab) ? .automatic : .hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                WindowStatusPill(inputs: inputs, onTodayTab: onTodayTab, action: action)
            }
        }
    }
}

/// Whether the speech model file is missing. Isolated previews never touch the real file.
@MainActor
enum SpeechModelAvailability {
    #if DEBUG
    /// Lets render tests show the missing-model state.
    static var previewMissing = false
    #endif

    static func isMissing(for controller: DictationController) -> Bool {
        #if DEBUG
        if controller.isIsolatedPreview { return previewMissing }
        #endif
        guard controller.hasBootstrapped else { return false }
        return !FileManager.default.fileExists(atPath: controller.preferences.dictation.modelPath)
    }
}


/// Where a person left History and Insights, so switching to another section and back returns
/// to the same dictation, filter and day. A class, so remembering a selection redraws nothing.
@MainActor
final class SectionPlaces {
    var historyEntryID: UUID?
    var historyFilter: HistoryFilter?
    var insightsDay: Date?
}

extension EnvironmentValues {
    /// The window's remembered places. Nil outside the main window, where nothing is kept.
    @Entry var sectionPlaces: SectionPlaces?
}
